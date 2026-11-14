//! `voiceStream.ts`: the app's only voice connection, a WebSocket at
//! `/v1/voice/stream`.
//!
//! The first text message must be `hello` with the account's token; it is
//! verified like a REST Bearer token, and a `sessionId` must be one of the
//! account's own sessions. The server then records the conversation, joins its
//! LiveKit room as the user and answers `ready`. From then on binary messages
//! are microphone frames and the agent's speech comes back the same way.
//! Closing the socket or sending `end` leaves the room; the room going away
//! closes the socket.

use super::bridge::{Bridge, BridgeClient, TOPICS, UPLINK_FRAME_BYTES};
use super::{backends, conversations, livekit_token};
use crate::app::App;
use crate::http::{HttpResponse, RespBody};
use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use hyper::body::Incoming;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, Role, WebSocketConfig};
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::WebSocketStream;

pub const PATH: &str = "/v1/voice/stream";
/// The app must say `hello` within this long after connecting.
pub const HELLO_TIMEOUT: Duration = Duration::from_millis(5000);
/// Largest message the app may send (an RPC result carries the session config).
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
/// Agent audio is dropped while this much is still unsent to the app (about
/// 1.3 s of speech), so a stalled connection never builds up a backlog the
/// user would hear late.
const MAX_DOWNLINK_BUFFERED_BYTES: usize = 64 * 1024;
/// How long a closing socket waits for the app's close frame.
const CLOSE_TIMEOUT: Duration = Duration::from_secs(30);

type Io = hyper_util::rt::TokioIo<hyper::upgrade::Upgraded>;

/// `ws`'s `handleUpgrade` checks, then the 101 answer; the connection runs on
/// its own task once hyper hands the socket over.
pub async fn upgrade(app: Arc<App>, mut req: hyper::Request<Incoming>) -> Result<HttpResponse, crate::engine::Destroy> {
    let h = req.headers();
    if req.method() != hyper::Method::GET {
        return Ok(abort_raw(405, "Invalid HTTP method", None));
    }
    if !h.get("upgrade").and_then(|v| v.to_str().ok()).is_some_and(|v| v.eq_ignore_ascii_case("websocket")) {
        return Ok(abort_raw(400, "Invalid Upgrade header", None));
    }
    let key = h.get("sec-websocket-key").and_then(|v| v.to_str().ok()).unwrap_or("");
    if !ws_key_valid(key) {
        return Ok(abort_raw(400, "Missing or invalid Sec-WebSocket-Key header", None));
    }
    let version = h.get("sec-websocket-version").and_then(|v| v.to_str().ok()).map(crate::js::number_from_str).unwrap_or(f64::NAN);
    if version != 13.0 && version != 8.0 {
        return Ok(abort_raw(400, "Missing or invalid Sec-WebSocket-Version header", Some(("Sec-WebSocket-Version", "13, 8"))));
    }
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    let on_upgrade = hyper::upgrade::on(&mut req);
    tokio::spawn(async move {
        let Ok(upgraded) = on_upgrade.await else { return };
        let config = WebSocketConfig::default().max_message_size(Some(MAX_MESSAGE_BYTES)).max_frame_size(Some(MAX_MESSAGE_BYTES));
        let ws = WebSocketStream::from_raw_socket(hyper_util::rt::TokioIo::new(upgraded), Role::Server, Some(config)).await;
        run(app, ws, HELLO_TIMEOUT).await;
    });
    Ok(hyper::Response::builder()
        .status(101)
        .header("Upgrade", "websocket")
        .header("Connection", "Upgrade")
        .header("Sec-WebSocket-Accept", accept)
        .body(RespBody::full(Bytes::new()))
        .unwrap())
}

/// `ws`'s `abortHandshake`: a bare response, then the socket is closed.
/// Copied from upstream's private `engine::abort_raw`.
// upstream-copy: src/engine.rs abort_raw b6b265f957bd7c00
fn abort_raw(status: u16, message: &str, extra: Option<(&str, &str)>) -> HttpResponse {
    let mut b = hyper::Response::builder()
        .status(status)
        .header("Connection", "close")
        .header("Content-Type", "text/html")
        .header("Content-Length", message.len().to_string());
    if let Some((k, v)) = extra {
        b = b.header(k, v);
    }
    b.body(RespBody::full(Bytes::from(message.to_string()))).unwrap()
}

/// `ws`'s `Sec-WebSocket-Key` check. Copied from upstream's private
/// `engine::ws_key_valid`.
// upstream-copy: src/engine.rs ws_key_valid dd1fed31dd050a48
fn ws_key_valid(k: &str) -> bool {
    let b = k.as_bytes();
    b.len() == 24 && b[22] == b'=' && b[23] == b'=' && b[..22].iter().all(|c| c.is_ascii_alphanumeric() || *c == b'+' || *c == b'/')
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum State {
    Hello,
    Starting,
    Ready,
    Closed,
}

/// A parsed `hello`.
#[derive(Debug, PartialEq)]
pub struct Hello {
    pub token: String,
    pub session_id: Option<String>,
    pub language: Option<String>,
}

/// A message after `hello` (`VoiceStreamClientMessageSchema`).
#[derive(Debug, PartialEq)]
pub enum ClientMessage {
    Hello,
    Text { topic: String, text: String },
    RpcResult { id: String, result: Option<String>, error: Option<String> },
    End,
}

/// zod's `.optional()` string: absent, or a string (not null).
fn optional_string(o: &serde_json::Map<String, Value>, key: &str) -> Result<Option<String>, ()> {
    match o.get(key) {
        None => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(()),
    }
}

fn required_string(o: &serde_json::Map<String, Value>, key: &str) -> Result<String, ()> {
    match o.get(key) {
        Some(Value::String(s)) => Ok(s.clone()),
        _ => Err(()),
    }
}

/// The first message: `Err((code, message))` as the app is told.
pub fn parse_hello(json: Option<&Value>) -> Result<Hello, (&'static str, &'static str)> {
    let o = match json {
        Some(Value::Object(o)) => o,
        _ => return Err(("bad_request", "First message must be hello")),
    };
    if o.get("type") != Some(&Value::String("hello".into())) {
        return Err(("bad_request", "First message must be hello"));
    }
    match o.get("token") {
        Some(Value::String(t)) if !t.is_empty() => {}
        _ => return Err(("unauthorized", "Missing token")),
    }
    let invalid = ("bad_request", "Invalid hello");
    Ok(Hello {
        token: required_string(o, "token").map_err(|_| invalid)?,
        session_id: optional_string(o, "sessionId").map_err(|_| invalid)?,
        language: optional_string(o, "language").map_err(|_| invalid)?,
    })
}

/// `None` for anything the schema rejects: newer apps may send messages this
/// server does not know yet.
pub fn parse_client(json: Option<&Value>) -> Option<ClientMessage> {
    let Some(Value::Object(o)) = json else { return None };
    let Some(Value::String(kind)) = o.get("type") else { return None };
    match kind.as_str() {
        "hello" => {
            parse_hello(json).ok()?;
            Some(ClientMessage::Hello)
        }
        "text" => {
            let topic = required_string(o, "topic").ok().filter(|t| TOPICS.contains(&t.as_str()))?;
            Some(ClientMessage::Text { topic, text: required_string(o, "text").ok()? })
        }
        "rpcResult" => Some(ClientMessage::RpcResult {
            id: required_string(o, "id").ok()?,
            result: optional_string(o, "result").ok()?,
            error: optional_string(o, "error").ok()?,
        }),
        "end" => Some(ClientMessage::End),
        _ => None,
    }
}

struct Conn {
    app: Arc<App>,
    state: Mutex<State>,
    out: mpsc::UnboundedSender<Message>,
    /// Bytes handed to the writer and not yet written (`ws.bufferedAmount`).
    buffered: Arc<AtomicUsize>,
    bridge: Mutex<Option<Arc<Bridge>>>,
    user_id: Mutex<Option<String>>,
    conversation_id: Mutex<Option<String>>,
    ready_at: AtomicI64,
}

struct Client(Weak<Conn>);

impl BridgeClient for Client {
    fn send(&self, message: Value) {
        if let Some(c) = self.0.upgrade() {
            c.send(&message);
        }
    }

    fn send_audio(&self, frame: Vec<u8>) {
        if let Some(c) = self.0.upgrade() {
            c.send_audio(frame);
        }
    }

    fn on_room_closed(&self) {
        if let Some(c) = self.0.upgrade() {
            tokio::spawn(async move { c.close(1000, "room closed").await });
        }
    }
}

async fn run(app: Arc<App>, ws: WebSocketStream<Io>, hello_timeout: Duration) {
    let (mut sink, mut stream) = ws.split();
    let (out, mut rx) = mpsc::unbounded_channel::<Message>();
    let buffered = Arc::new(AtomicUsize::new(0));
    let writer_buffered = buffered.clone();
    let writer = tokio::spawn(async move {
        while let Some(m) = rx.recv().await {
            let (len, closing) = (if m.is_binary() { m.len() } else { 0 }, m.is_close());
            let ok = sink.send(m).await.is_ok();
            writer_buffered.fetch_sub(len, Ordering::SeqCst);
            if !ok || closing {
                break;
            }
        }
    });
    let conn = Arc::new(Conn {
        app,
        state: Mutex::new(State::Hello),
        out,
        buffered,
        bridge: Mutex::new(None),
        user_id: Mutex::new(None),
        conversation_id: Mutex::new(None),
        ready_at: AtomicI64::new(0),
    });

    let hello_deadline = tokio::time::Instant::now() + hello_timeout;
    loop {
        let state = conn.state();
        let next = if state == State::Hello {
            match tokio::time::timeout_at(hello_deadline, stream.next()).await {
                Ok(n) => n,
                Err(_) => {
                    conn.fail("unauthorized", "No hello received").await;
                    continue;
                }
            }
        } else if state == State::Closed {
            // Wait for the app's close frame, as `ws` does, then let go.
            let _ = tokio::time::timeout(CLOSE_TIMEOUT, async { while let Some(Ok(_)) = stream.next().await {} }).await;
            break;
        } else {
            stream.next().await
        };
        match next {
            Some(Ok(Message::Binary(data))) => conn.on_binary(&data).await,
            Some(Ok(Message::Text(text))) => conn.on_text(text.as_str()).await,
            Some(Ok(Message::Close(_))) | None => {
                conn.close(1000, "").await;
                break;
            }
            Some(Ok(_)) => {}
            Some(Err(e)) => {
                tracing::info!(module = "voice-stream", "Socket error: {}", e);
                let code = match e {
                    tungstenite::Error::Capacity(_) => 1009,
                    tungstenite::Error::Utf8(_) => 1007,
                    tungstenite::Error::Protocol(_) => 1002,
                    _ => {
                        conn.close(1006, "").await;
                        break;
                    }
                };
                conn.close(code, "").await;
            }
        }
    }
    conn.close(1000, "").await;
    drop(conn);
    let _ = writer.await;
}

impl Conn {
    fn state(&self) -> State {
        *self.state.lock().unwrap()
    }

    fn send(&self, message: &Value) {
        if self.state() != State::Closed {
            let _ = self.out.send(Message::text(message.to_string()));
        }
    }

    fn send_audio(&self, frame: Vec<u8>) {
        if self.state() != State::Ready || self.buffered.load(Ordering::SeqCst) > MAX_DOWNLINK_BUFFERED_BYTES {
            return;
        }
        self.buffered.fetch_add(frame.len(), Ordering::SeqCst);
        if self.out.send(Message::binary(frame)).is_err() {
            self.buffered.store(0, Ordering::SeqCst);
        }
    }

    fn bridge(&self) -> Option<Arc<Bridge>> {
        self.bridge.lock().unwrap().clone()
    }

    async fn fail(self: &Arc<Self>, code: &'static str, message: &str) {
        if self.state() == State::Closed {
            return;
        }
        self.send(&json!({"type": "error", "code": code, "message": message}));
        self.close(if code == "unauthorized" || code == "bad_request" { 1008 } else { 1011 }, code).await;
    }

    /// Leaves the room and closes the socket. Safe to call more than once.
    async fn close(self: &Arc<Self>, code: u16, reason: &str) {
        let was_ready = {
            let mut state = self.state.lock().unwrap();
            if *state == State::Closed {
                return;
            }
            let was_ready = *state == State::Ready;
            *state = State::Closed;
            was_ready
        };
        // 1005/1006 are never sent: the socket is already gone.
        if code != 1006 {
            let frame = CloseFrame { code: CloseCode::from(code), reason: reason.to_string().into() };
            let _ = self.out.send(Message::Close(Some(frame)));
        }
        let bridge = self.bridge.lock().unwrap().take();
        if let Some(bridge) = bridge {
            bridge.close().await;
        }
        let conversation_id = self.conversation_id.lock().unwrap().clone();
        if let (true, Some(id)) = (was_ready, conversation_id) {
            let user = self.user_id.lock().unwrap().clone().unwrap_or_default();
            tracing::info!(module = "voice-stream", "Voice stream ended for user {}", user);
            let secs = conversations::duration_secs(self.ready_at.load(Ordering::SeqCst), crate::util::now_ms());
            if let Err(e) = conversations::record_duration(&self.app.pool, &id, secs).await {
                tracing::info!(module = "voice-stream", "Failed to record voice duration: {:#}", e);
            }
        }
    }

    async fn on_binary(self: &Arc<Self>, data: &[u8]) {
        // Audio before `ready` is dropped.
        if self.state() != State::Ready {
            return;
        }
        if data.len() != UPLINK_FRAME_BYTES {
            self.fail("bad_request", &format!("Audio frames must be {} bytes", UPLINK_FRAME_BYTES)).await;
            return;
        }
        if let Some(b) = self.bridge() {
            b.push_audio(data);
        }
    }

    async fn on_text(self: &Arc<Self>, text: &str) {
        let json: Option<Value> = crate::js::parse(text).ok();
        match self.state() {
            State::Closed => {}
            State::Hello => self.on_hello(json.as_ref()).await,
            _ => match parse_client(json.as_ref()) {
                None => {}
                Some(ClientMessage::Hello) => self.fail("bad_request", "Already said hello").await,
                Some(ClientMessage::Text { topic, text }) => {
                    if let Some(b) = self.bridge() {
                        b.send_text(&topic, &text);
                    }
                }
                Some(ClientMessage::RpcResult { id, result, error }) => {
                    if let Some(b) = self.bridge() {
                        b.rpc_result(&id, result, error);
                    }
                }
                Some(ClientMessage::End) => self.close(1000, "").await,
            },
        }
    }

    async fn on_hello(self: &Arc<Self>, json: Option<&Value>) {
        let hello = match parse_hello(json) {
            Ok(h) => h,
            Err((code, message)) => return self.fail(code, message).await,
        };
        *self.state.lock().unwrap() = State::Starting;
        *self.bridge.lock().unwrap() = Some(Arc::new(Bridge::new(Arc::new(Client(Arc::downgrade(self))))));
        let conn = self.clone();
        tokio::spawn(async move {
            if let Err(e) = conn.start(hello).await {
                tracing::info!(module = "voice-stream", "Voice stream start failed: {:#}", e);
                conn.fail("internal", "Failed to start voice").await;
            }
        });
    }

    fn starting(&self) -> bool {
        self.state() == State::Starting
    }

    async fn start(self: &Arc<Self>, hello: Hello) -> anyhow::Result<()> {
        let verified = self.app.auth.verify_token(&hello.token);
        if !self.starting() {
            return Ok(());
        }
        let Some(user_id) = verified else {
            self.fail("unauthorized", "Invalid token").await;
            return Ok(());
        };
        *self.user_id.lock().unwrap() = Some(user_id.clone());

        if let Some(session_id) = hello.session_id.as_deref().filter(|s| !s.is_empty()) {
            let owned = conversations::session_owned(&self.app.pool, &user_id, session_id).await?;
            if !self.starting() {
                return Ok(());
            }
            if !owned {
                tracing::info!(module = "voice-stream", "User {} asked for voice on a session that is not theirs", user_id);
                self.fail("unauthorized", "Session not found").await;
                return Ok(());
            }
        }

        let Some(livekit) = super::livekit() else {
            tracing::info!(module = "voice-stream", "LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured");
            self.fail("unavailable", "LiveKit is not configured").await;
            return Ok(());
        };
        if !super::backends().offers(backends::STREAM) {
            self.fail("unavailable", "Voice stream is not offered by this server").await;
            return Ok(());
        }

        let (conversation_id, room_name) =
            conversations::create(&self.app.pool, &user_id, hello.session_id.as_deref(), hello.language.as_deref()).await?;
        *self.conversation_id.lock().unwrap() = Some(conversation_id.clone());
        if !self.starting() {
            return Ok(());
        }
        let room_token = livekit_token::create(livekit, &user_id, &room_name);

        let Some(bridge) = self.bridge() else { return Ok(()) };
        if let Err(e) = bridge.connect(&livekit.url, &room_token).await {
            if !self.starting() {
                return Ok(());
            }
            tracing::info!(module = "voice-stream", "Failed to join voice room {} for user {}: {}", room_name, user_id, e);
            self.fail("unavailable", "Voice service unavailable").await;
            return Ok(());
        }
        {
            let mut state = self.state.lock().unwrap();
            if *state != State::Starting {
                return Ok(());
            }
            *state = State::Ready;
        }
        self.ready_at.store(crate::util::now_ms(), Ordering::SeqCst);
        tracing::info!(module = "voice-stream", "Voice stream ready in room {} for user {}", room_name, user_id);
        self.send(&json!({"type": "ready", "conversationId": conversation_id}));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello(v: Value) -> Result<Hello, (&'static str, &'static str)> {
        parse_hello(Some(&v))
    }

    #[test]
    fn hello_checks_come_in_order() {
        assert_eq!(parse_hello(None).unwrap_err(), ("bad_request", "First message must be hello"));
        assert_eq!(hello(json!("hello")).unwrap_err(), ("bad_request", "First message must be hello"));
        assert_eq!(hello(json!({"type": "text"})).unwrap_err(), ("bad_request", "First message must be hello"));
        assert_eq!(hello(json!({"type": "hello"})).unwrap_err(), ("unauthorized", "Missing token"));
        assert_eq!(hello(json!({"type": "hello", "token": ""})).unwrap_err(), ("unauthorized", "Missing token"));
        assert_eq!(hello(json!({"type": "hello", "token": 5})).unwrap_err(), ("unauthorized", "Missing token"));
        assert_eq!(hello(json!({"type": "hello", "token": "t", "sessionId": null})).unwrap_err(), ("bad_request", "Invalid hello"));
        assert_eq!(hello(json!({"type": "hello", "token": "t", "language": 1})).unwrap_err(), ("bad_request", "Invalid hello"));
        assert_eq!(
            hello(json!({"type": "hello", "token": "t", "sessionId": "s", "extra": 1})).unwrap(),
            Hello { token: "t".into(), session_id: Some("s".into()), language: None }
        );
    }

    #[test]
    fn client_messages_follow_the_schema() {
        let p = |v: Value| parse_client(Some(&v));
        assert_eq!(p(json!({"type": "end"})), Some(ClientMessage::End));
        assert_eq!(p(json!({"type": "hello", "token": "t"})), Some(ClientMessage::Hello));
        assert_eq!(p(json!({"type": "hello"})), None);
        assert_eq!(p(json!({"type": "text", "topic": "happy.text", "text": "hi"})), Some(ClientMessage::Text { topic: "happy.text".into(), text: "hi".into() }));
        assert_eq!(p(json!({"type": "text", "topic": "happy.other", "text": "hi"})), None);
        assert_eq!(p(json!({"type": "text", "topic": "happy.context"})), None);
        assert_eq!(
            p(json!({"type": "rpcResult", "id": "1", "result": "r"})),
            Some(ClientMessage::RpcResult { id: "1".into(), result: Some("r".into()), error: None })
        );
        assert_eq!(p(json!({"type": "rpcResult", "id": "1", "result": null})), None);
        assert_eq!(p(json!({"type": "rpcResult"})), None);
        assert_eq!(p(json!({"type": "future"})), None);
        assert_eq!(p(json!([1])), None);
        assert_eq!(parse_client(None), None);
    }
}
