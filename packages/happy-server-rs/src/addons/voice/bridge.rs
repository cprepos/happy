//! `voiceBridge.ts`: one app's seat in a LiveKit voice room.
//!
//! The server joins the room as the user (`user-<accountId>`), publishes the
//! app's microphone frames as the user's audio track, streams the agent's
//! speech back as 20 ms frames, and relays the room protocol the app used to
//! speak itself: the agent's RPCs, the `happy.text` / `happy.context` data
//! topics, the agent state attribute and interruptions.
//!
//! The decisions live in [`Core`], which knows nothing of LiveKit and is what
//! the unit tests drive; [`Bridge`] wires it to a `livekit::Room`.

use futures_util::StreamExt;
use livekit::options::TrackPublishOptions;
use livekit::participant::ParticipantKind;
use livekit::prelude::*;
use livekit::webrtc::audio_source::native::NativeAudioSource;
use livekit::webrtc::audio_stream::native::NativeAudioStream;
use livekit::webrtc::prelude::{AudioFrame, AudioSourceOptions, RtcAudioSource};
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

pub const UPLINK_RATE: u32 = 16000;
pub const DOWNLINK_RATE: u32 = 24000;
pub const FRAME_MS: u32 = 20;
pub const UPLINK_FRAME_SAMPLES: usize = (UPLINK_RATE * FRAME_MS / 1000) as usize;
pub const DOWNLINK_FRAME_SAMPLES: usize = (DOWNLINK_RATE * FRAME_MS / 1000) as usize;
/// Bytes in one uplink frame: 20 ms of PCM16 mono at 16 kHz.
pub const UPLINK_FRAME_BYTES: usize = UPLINK_FRAME_SAMPLES * 2;

pub const TOPICS: [&str; 2] = ["happy.text", "happy.context"];
pub const RPC_METHODS: [&str; 3] = ["happy.getConfig", "sendMessageToSession", "processPermissionRequest"];
pub const AGENT_STATES: [&str; 5] = ["initializing", "idle", "listening", "thinking", "speaking"];
pub const TOPIC_INTERRUPTED: &str = "happy.interrupted";

/// The agent's `happy.getConfig` call: the agent itself gives up after 10 s.
pub const GET_CONFIG_TIMEOUT: Duration = Duration::from_millis(10_000);
/// Tool calls use the agent's own deadline, within these bounds.
const TOOL_TIMEOUT_DEFAULT: Duration = Duration::from_millis(30_000);
const TOOL_TIMEOUT_MAX: Duration = Duration::from_millis(60_000);
/// How long an RPC from a not-yet-known participant waits for it to appear.
const AGENT_LOOKUP_TIMEOUT: Duration = Duration::from_millis(3000);
/// livekit-agents joins a dispatched job as `agent-<jobId>`.
const AGENT_IDENTITY_PREFIX: &str = "agent-";
/// Text sent before the agent joins waits here; the oldest is dropped past this.
pub const MAX_QUEUED_MESSAGES: usize = 100;
/// The microphone source can buffer this much. Frames are dropped while more
/// than `UPLINK_MAX_QUEUED_MS` is queued or a capture is still waiting for
/// room, so a burst after a network stall never leaves the agent hearing the
/// user late for the rest of the conversation.
const UPLINK_QUEUE_MS: u32 = 100;
const UPLINK_MAX_QUEUED_MS: f64 = 60.0;
const UPLINK_MAX_PENDING_FRAMES: usize = 2;
const AGENT_STATE_ATTRIBUTE: &str = "lk.agent.state";

/// What the bridge needs from the app's connection.
pub trait BridgeClient: Send + Sync + 'static {
    fn send(&self, message: Value);
    /// One downlink frame: exactly `DOWNLINK_FRAME_SAMPLES` samples.
    fn send_audio(&self, frame: Vec<u8>);
    /// The room went away on its own (agent ended it, LiveKit, network).
    fn on_room_closed(&self);
}

fn rpc_error(code: u32, message: &str) -> RpcError {
    RpcError::new(code, message.to_string(), None)
}

/// Cuts a stream of PCM16 samples into frames of exactly `frame_samples`,
/// whatever sizes it arrives in, as little-endian bytes.
pub struct PcmChunker {
    frame: Vec<i16>,
    frame_samples: usize,
}

impl PcmChunker {
    pub fn new(frame_samples: usize) -> PcmChunker {
        PcmChunker { frame: Vec::with_capacity(frame_samples), frame_samples }
    }

    pub fn push(&mut self, samples: &[i16], mut emit: impl FnMut(Vec<u8>)) {
        let mut offset = 0;
        while offset < samples.len() {
            let take = (self.frame_samples - self.frame.len()).min(samples.len() - offset);
            self.frame.extend_from_slice(&samples[offset..offset + take]);
            offset += take;
            if self.frame.len() == self.frame_samples {
                emit(self.frame.iter().flat_map(|s| s.to_le_bytes()).collect());
                self.frame.clear();
            }
        }
    }

    /// Drops a partial frame.
    pub fn reset(&mut self) {
        self.frame.clear();
    }
}

/// Little-endian PCM16 bytes to samples.
pub fn pcm16_from_bytes(bytes: &[u8]) -> Vec<i16> {
    bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
}

/// rtc-node's `AudioSource.queuedDuration`: how much of the captured audio
/// is still waiting to play out, kept as a virtual clock.
#[derive(Default)]
pub struct UplinkClock {
    /// When the last captured frame finishes playing, in ms.
    end_ms: f64,
}

impl UplinkClock {
    pub fn queued_ms(&self, now_ms: f64) -> f64 {
        (self.end_ms - now_ms).max(0.0)
    }

    pub fn captured(&mut self, now_ms: f64, frame_ms: f64) {
        self.end_ms = self.end_ms.max(now_ms) + frame_ms;
    }
}

/// Something the bridge must do after `Core` decided.
#[derive(Debug, PartialEq)]
pub enum Effect {
    Send(Value),
    Publish { topic: String, text: String },
}

/// The bridge's state and decisions, without LiveKit.
#[derive(Default)]
pub struct Core {
    pub closed: bool,
    agent: Option<String>,
    last_agent_message: String,
    queue: VecDeque<(String, String)>,
    pending: HashMap<String, oneshot::Sender<Result<String, RpcError>>>,
    seq: u64,
    uplink_dropped: u64,
}

/// The agent's state attribute, when it is one the app knows.
pub fn agent_state(attributes: &HashMap<String, String>) -> Option<&str> {
    attributes.get(AGENT_STATE_ATTRIBUTE).map(String::as_str).filter(|s| AGENT_STATES.contains(s))
}

impl Core {
    pub fn agent(&self) -> Option<&str> {
        self.agent.as_deref()
    }

    /// Text for the agent: published at once when the agent is known and the
    /// room is joined, else queued.
    pub fn send_text(&mut self, topic: &str, text: &str, joined: bool) -> Option<Effect> {
        if self.closed {
            return None;
        }
        if self.agent.is_none() || !joined {
            self.queue.push_back((topic.to_string(), text.to_string()));
            if self.queue.len() > MAX_QUEUED_MESSAGES {
                self.queue.pop_front();
            }
            return None;
        }
        Some(Effect::Publish { topic: topic.to_string(), text: text.to_string() })
    }

    /// A participant showed up; the first agent becomes the one the app hears.
    pub fn on_participant(&mut self, identity: &str, is_agent: bool, state: Option<&str>, joined: bool) -> Vec<Effect> {
        if !is_agent || self.agent.is_some() {
            return vec![];
        }
        tracing::info!(module = "voice-bridge", "Agent {} joined", identity);
        self.agent = Some(identity.to_string());
        let mut out: Vec<Effect> = self.agent_message(state).into_iter().collect();
        for (topic, text) in std::mem::take(&mut self.queue) {
            out.extend(self.send_text(&topic, &text, joined));
        }
        out
    }

    /// Whether `identity` is the agent; if so it is gone now.
    pub fn agent_left(&mut self, identity: &str) -> Option<Option<Effect>> {
        if self.agent.as_deref() != Some(identity) {
            return None;
        }
        self.agent = None;
        Some(self.agent_message(None))
    }

    /// `sendAgent`: tells the app about the agent, when what it would hear changed.
    pub fn agent_message(&mut self, state: Option<&str>) -> Option<Effect> {
        let present = self.agent.is_some();
        let message = match state.filter(|_| present) {
            Some(state) => json!({"type": "agent", "present": present, "state": state}),
            None => json!({"type": "agent", "present": present}),
        };
        let key = message.to_string();
        if key == self.last_agent_message {
            return None;
        }
        self.last_agent_message = key;
        Some(Effect::Send(message))
    }

    /// The app's answer to an `rpc` message. Unknown or late ids are ignored.
    pub fn rpc_result(&mut self, id: &str, result: Option<String>, error: Option<String>) {
        let Some(pending) = self.pending.remove(id) else { return };
        let _ = pending.send(match error {
            Some(e) => Err(rpc_error(1500, &e)),
            None => Ok(result.unwrap_or_default()),
        });
    }

    /// Registers an RPC for the app and returns its id, where its answer comes,
    /// and the message to send the app.
    pub fn forward_rpc(&mut self, method: &str, payload: &str) -> Result<(String, oneshot::Receiver<Result<String, RpcError>>, Value), RpcError> {
        if self.closed {
            return Err(rpc_error(1503, "the app disconnected"));
        }
        self.seq += 1;
        let id = self.seq.to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.insert(id.clone(), tx);
        let message = json!({"type": "rpc", "id": id, "method": method, "payload": payload});
        Ok((id, rx, message))
    }

    pub fn rpc_timed_out(&mut self, id: &str) {
        self.pending.remove(id);
    }

    /// Drops queued text, fails pending RPCs and forgets the agent.
    pub fn release(&mut self) {
        self.queue.clear();
        for (_, pending) in self.pending.drain() {
            let _ = pending.send(Err(rpc_error(1503, "the app disconnected")));
        }
        self.agent = None;
    }

    /// Whether an uplink frame may be captured now.
    pub fn uplink_admit(&mut self, pending: usize, queued_ms: f64) -> bool {
        if pending >= UPLINK_MAX_PENDING_FRAMES || queued_ms > UPLINK_MAX_QUEUED_MS {
            self.uplink_dropped += 1;
            if self.uplink_dropped == 1 || self.uplink_dropped % 500 == 0 {
                tracing::info!(module = "voice-bridge", "Uplink behind, dropped {} frames", self.uplink_dropped);
            }
            return false;
        }
        true
    }

    #[cfg(test)]
    fn queued(&self) -> Vec<(String, String)> {
        self.queue.iter().cloned().collect()
    }
}

/// How long the app has for an RPC.
pub fn rpc_timeout(method: &str, response_timeout: Duration) -> Duration {
    if method == "happy.getConfig" {
        return GET_CONFIG_TIMEOUT;
    }
    let t = if response_timeout > Duration::ZERO { response_timeout } else { TOOL_TIMEOUT_DEFAULT };
    t.min(TOOL_TIMEOUT_MAX)
}

fn now_ms() -> f64 {
    crate::util::now_ms() as f64
}

struct Inner {
    client: Arc<dyn BridgeClient>,
    closed: AtomicBool,
    core: Mutex<Core>,
    room: Mutex<Option<Arc<Room>>>,
    source: Mutex<Option<NativeAudioSource>>,
    /// Captures run one at a time, in order, on the uplink task.
    uplink: Mutex<Option<mpsc::UnboundedSender<Vec<i16>>>>,
    uplink_pending: Arc<AtomicUsize>,
    uplink_clock: Mutex<UplinkClock>,
    /// Data packets go out one at a time, in order, on the publish task.
    publish: Mutex<Option<mpsc::UnboundedSender<(String, String)>>>,
    downlink: Mutex<PcmChunker>,
    agent_audio: Mutex<Option<JoinHandle<()>>>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

/// One app's seat in a LiveKit voice room. Used once: `connect`, then `close`;
/// `close` may come at any time, also while `connect` is still running.
pub struct Bridge {
    inner: Arc<Inner>,
}

impl Bridge {
    pub fn new(client: Arc<dyn BridgeClient>) -> Bridge {
        Bridge {
            inner: Arc::new(Inner {
                client,
                closed: AtomicBool::new(false),
                core: Mutex::new(Core::default()),
                room: Mutex::new(None),
                source: Mutex::new(None),
                uplink: Mutex::new(None),
                uplink_pending: Arc::new(AtomicUsize::new(0)),
                uplink_clock: Mutex::new(UplinkClock::default()),
                publish: Mutex::new(None),
                downlink: Mutex::new(PcmChunker::new(DOWNLINK_FRAME_SAMPLES)),
                agent_audio: Mutex::new(None),
                tasks: Mutex::new(Vec::new()),
            }),
        }
    }

    /// Joins the room and publishes the microphone track. Fails if it cannot.
    pub async fn connect(&self, url: &str, token: &str) -> anyhow::Result<()> {
        let inner = &self.inner;
        inner.assert_open()?;
        let mut options = RoomOptions::default();
        options.auto_subscribe = true;
        options.dynacast = false;
        let (room, events) = Room::connect(url, token, options).await?;
        let room = Arc::new(room);
        *inner.room.lock().unwrap() = Some(room.clone());
        inner.spawn(events_task(Arc::downgrade(inner), room.clone(), events));
        inner.assert_open_or_release().await?;

        let source = NativeAudioSource::new(AudioSourceOptions::default(), UPLINK_RATE, 1, UPLINK_QUEUE_MS);
        *inner.source.lock().unwrap() = Some(source.clone());
        let track = LocalAudioTrack::create_audio_track("microphone", RtcAudioSource::Native(source.clone()));
        let local = room.local_participant();
        register_rpc(inner, &local);

        let (tx, rx) = mpsc::unbounded_channel();
        *inner.uplink.lock().unwrap() = Some(tx);
        inner.spawn(uplink_task(source, rx, inner.uplink_pending.clone()));
        let (tx, rx) = mpsc::unbounded_channel();
        *inner.publish.lock().unwrap() = Some(tx);
        inner.spawn(publish_task(room.clone(), rx));

        local
            .publish_track(LocalTrack::Audio(track), TrackPublishOptions { source: TrackSource::Microphone, ..Default::default() })
            .await?;
        inner.assert_open_or_release().await?;

        // The agent normally joins after us, but it may already be there.
        for participant in room.remote_participants().values() {
            inner.on_participant(participant);
        }
        // Text sent while joining waited for the publish task.
        let effects: Vec<Effect> = {
            let mut core = inner.core.lock().unwrap();
            if core.agent.is_some() && !core.closed {
                let queued = std::mem::take(&mut core.queue);
                queued.into_iter().filter_map(|(t, x)| core.send_text(&t, &x, true)).collect()
            } else {
                vec![]
            }
        };
        inner.apply(effects);
        Ok(())
    }

    /// One uplink frame from the app; the caller checks its size.
    pub fn push_audio(&self, bytes: &[u8]) {
        let inner = &self.inner;
        if inner.closed.load(Ordering::SeqCst) {
            return;
        }
        let Some(tx) = inner.uplink.lock().unwrap().clone() else { return };
        let now = now_ms();
        let mut clock = inner.uplink_clock.lock().unwrap();
        let pending = inner.uplink_pending.load(Ordering::SeqCst);
        if !inner.core.lock().unwrap().uplink_admit(pending, clock.queued_ms(now)) {
            return;
        }
        clock.captured(now, FRAME_MS as f64);
        inner.uplink_pending.fetch_add(1, Ordering::SeqCst);
        if tx.send(pcm16_from_bytes(bytes)).is_err() {
            inner.uplink_pending.fetch_sub(1, Ordering::SeqCst);
        }
    }

    /// Text for the agent, published once it is in the room.
    pub fn send_text(&self, topic: &str, text: &str) {
        let joined = self.inner.publish.lock().unwrap().is_some();
        let effect = self.inner.core.lock().unwrap().send_text(topic, text, joined);
        self.inner.apply(effect);
    }

    /// The app's answer to an `rpc` message.
    pub fn rpc_result(&self, id: &str, result: Option<String>, error: Option<String>) {
        self.inner.core.lock().unwrap().rpc_result(id, result, error);
    }

    /// Leaves the room and releases everything. Safe to call more than once.
    pub async fn close(&self) {
        if self.inner.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        self.inner.core.lock().unwrap().closed = true;
        self.inner.release().await;
    }
}

impl Drop for Bridge {
    fn drop(&mut self) {
        for t in self.inner.tasks.lock().unwrap().drain(..) {
            t.abort();
        }
        if let Some(t) = self.inner.agent_audio.lock().unwrap().take() {
            t.abort();
        }
    }
}

impl Inner {
    fn spawn(&self, f: impl std::future::Future<Output = ()> + Send + 'static) {
        self.tasks.lock().unwrap().push(tokio::spawn(f));
    }

    fn assert_open(&self) -> anyhow::Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            anyhow::bail!("Voice bridge closed");
        }
        Ok(())
    }

    async fn assert_open_or_release(&self) -> anyhow::Result<()> {
        if self.closed.load(Ordering::SeqCst) {
            self.release().await;
            anyhow::bail!("Voice bridge closed");
        }
        Ok(())
    }

    fn apply(&self, effects: impl IntoIterator<Item = Effect>) {
        for effect in effects {
            match effect {
                Effect::Send(message) => self.client.send(message),
                Effect::Publish { topic, text } => {
                    if let Some(tx) = self.publish.lock().unwrap().as_ref() {
                        let _ = tx.send((topic, text));
                    }
                }
            }
        }
    }

    fn joined(&self) -> bool {
        self.publish.lock().unwrap().is_some()
    }

    fn on_participant(&self, p: &RemoteParticipant) {
        let attributes = p.attributes();
        let is_agent = p.kind() == ParticipantKind::Agent;
        let effects = self.core.lock().unwrap().on_participant(&p.identity().0, is_agent, agent_state(&attributes), self.joined());
        self.apply(effects);
    }

    async fn release(&self) {
        self.core.lock().unwrap().release();
        self.stop_agent_audio();
        *self.publish.lock().unwrap() = None;
        *self.uplink.lock().unwrap() = None;
        let room = self.room.lock().unwrap().take();
        if let Some(room) = room {
            if let Err(e) = room.close().await {
                tracing::info!(module = "voice-bridge", "Room disconnect failed: {}", e);
            }
        }
        self.source.lock().unwrap().take();
        for t in self.tasks.lock().unwrap().drain(..) {
            t.abort();
        }
    }

    fn stop_agent_audio(&self) {
        if let Some(t) = self.agent_audio.lock().unwrap().take() {
            t.abort();
        }
        self.downlink.lock().unwrap().reset();
    }

    fn pump_agent_audio(self: &Arc<Self>, track: RemoteAudioTrack) {
        self.stop_agent_audio();
        let weak = Arc::downgrade(self);
        let task = tokio::spawn(async move {
            let mut stream = NativeAudioStream::new(track.rtc_track(), DOWNLINK_RATE as i32, 1);
            while let Some(frame) = stream.next().await {
                let Some(inner) = weak.upgrade() else { break };
                let client = inner.client.clone();
                inner.downlink.lock().unwrap().push(&frame.data, |f| client.send_audio(f));
            }
        });
        *self.agent_audio.lock().unwrap() = Some(task);
    }

    /// Only the dispatched agent may drive the app. Its first RPC arrives
    /// before the update that adds it to the room, so an unknown caller
    /// carrying the agent worker's identity is let through at once: only the
    /// server mints user tokens, and those are `user-<accountId>`. Any other
    /// unknown caller gets a moment to show up.
    async fn require_agent(&self, caller: &str) -> Result<(), RpcError> {
        let lookup = || {
            let room = self.room.lock().unwrap().clone();
            room.and_then(|r| r.remote_participants().get(&ParticipantIdentity(caller.to_string())).map(|p| p.kind()))
        };
        let mut kind = lookup();
        if kind.is_none() && caller.starts_with(AGENT_IDENTITY_PREFIX) {
            return Ok(());
        }
        let deadline = tokio::time::Instant::now() + AGENT_LOOKUP_TIMEOUT;
        while kind.is_none() && tokio::time::Instant::now() < deadline && !self.closed.load(Ordering::SeqCst) {
            tokio::time::sleep(Duration::from_millis(50)).await;
            kind = lookup();
        }
        if kind != Some(ParticipantKind::Agent) {
            return Err(rpc_error(2403, "caller is not the voice agent"));
        }
        Ok(())
    }

    async fn forward_rpc(&self, method: &str, payload: &str, timeout: Duration) -> Result<String, RpcError> {
        let (id, rx, message) = self.core.lock().unwrap().forward_rpc(method, payload)?;
        self.client.send(message);
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(rpc_error(1503, "the app disconnected")),
            Err(_) => {
                self.core.lock().unwrap().rpc_timed_out(&id);
                Err(rpc_error(1502, "the app did not answer in time"))
            }
        }
    }
}

fn register_rpc(inner: &Arc<Inner>, local: &LocalParticipant) {
    for method in RPC_METHODS {
        let weak: Weak<Inner> = Arc::downgrade(inner);
        local.register_rpc_method(method.to_string(), move |data| {
            let weak = weak.clone();
            Box::pin(async move {
                let Some(inner) = weak.upgrade() else { return Err(rpc_error(1503, "the app disconnected")) };
                inner.require_agent(&data.caller_identity.0).await?;
                inner.forward_rpc(method, &data.payload, rpc_timeout(method, data.response_timeout)).await
            })
        });
    }
}

async fn uplink_task(source: NativeAudioSource, mut rx: mpsc::UnboundedReceiver<Vec<i16>>, pending: Arc<AtomicUsize>) {
    while let Some(samples) = rx.recv().await {
        let frame = AudioFrame { data: samples.into(), sample_rate: UPLINK_RATE, num_channels: 1, samples_per_channel: UPLINK_FRAME_SAMPLES as u32 };
        // A failed capture means the source is closing.
        let _ = source.capture_frame(&frame).await;
        pending.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn publish_task(room: Arc<Room>, mut rx: mpsc::UnboundedReceiver<(String, String)>) {
    while let Some((topic, text)) = rx.recv().await {
        let packet = DataPacket { payload: text.into_bytes(), topic: Some(topic.clone()), reliable: true, ..Default::default() };
        if let Err(e) = room.local_participant().publish_data(packet).await {
            tracing::info!(module = "voice-bridge", "Failed to publish {}: {}", topic, e);
        }
    }
}

async fn events_task(weak: Weak<Inner>, room: Arc<Room>, mut events: mpsc::UnboundedReceiver<RoomEvent>) {
    let room_name = room.name();
    drop(room);
    while let Some(event) = events.recv().await {
        let Some(inner) = weak.upgrade() else { return };
        if inner.closed.load(Ordering::SeqCst) {
            return;
        }
        match event {
            RoomEvent::ParticipantConnected(p) => inner.on_participant(&p),
            RoomEvent::ParticipantDisconnected(p) => {
                let left = inner.core.lock().unwrap().agent_left(&p.identity().0);
                if let Some(effect) = left {
                    tracing::info!(module = "voice-bridge", "Agent left room {}", room_name);
                    inner.stop_agent_audio();
                    inner.apply(effect);
                }
            }
            RoomEvent::ParticipantAttributesChanged { participant: Participant::Remote(p), .. } => {
                if p.kind() != ParticipantKind::Agent {
                    continue;
                }
                let agent = inner.core.lock().unwrap().agent().map(str::to_string);
                match agent {
                    None => inner.on_participant(&p),
                    Some(a) if a == p.identity().0 => {
                        let attributes = p.attributes();
                        let effect = inner.core.lock().unwrap().agent_message(agent_state(&attributes));
                        inner.apply(effect);
                    }
                    Some(_) => {}
                }
            }
            RoomEvent::TrackSubscribed { track: RemoteTrack::Audio(track), participant, .. } => {
                if participant.kind() == ParticipantKind::Agent {
                    inner.pump_agent_audio(track);
                }
            }
            RoomEvent::TrackUnsubscribed { participant, .. } => {
                if participant.kind() == ParticipantKind::Agent {
                    inner.stop_agent_audio();
                }
            }
            RoomEvent::DataReceived { topic: Some(topic), participant: Some(p), .. } => {
                if topic == TOPIC_INTERRUPTED && p.kind() == ParticipantKind::Agent {
                    inner.downlink.lock().unwrap().reset();
                    inner.client.send(json!({"type": "flush"}));
                }
            }
            RoomEvent::Disconnected { reason } => {
                tracing::info!(module = "voice-bridge", "Room {} disconnected ({:?})", room_name, reason);
                inner.client.on_room_closed();
                return;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sent(e: &Option<Effect>) -> Value {
        match e {
            Some(Effect::Send(v)) => v.clone(),
            other => panic!("expected a message, got {:?}", other),
        }
    }

    #[test]
    fn chunker_cuts_any_sizes_into_whole_frames() {
        let mut c = PcmChunker::new(4);
        let mut out = vec![];
        c.push(&[1, 2, 3], |f| out.push(f));
        assert!(out.is_empty());
        c.push(&[4, 5, 6, 7, 8, 9], |f| out.push(f));
        assert_eq!(out.len(), 2);
        assert_eq!(pcm16_from_bytes(&out[0]), vec![1, 2, 3, 4]);
        assert_eq!(pcm16_from_bytes(&out[1]), vec![5, 6, 7, 8]);
        c.reset();
        c.push(&[10, 11, 12, 13], |f| out.push(f));
        assert_eq!(pcm16_from_bytes(&out[2]), vec![10, 11, 12, 13]);
    }

    #[test]
    fn pcm_round_trips_little_endian() {
        assert_eq!(pcm16_from_bytes(&[0x01, 0x00, 0xff, 0xff, 0x00, 0x80]), vec![1, -1, i16::MIN]);
        assert_eq!(UPLINK_FRAME_BYTES, 640);
        assert_eq!(DOWNLINK_FRAME_SAMPLES, 480);
    }

    #[test]
    fn text_waits_for_the_agent_and_keeps_the_newest_hundred() {
        let mut core = Core::default();
        for i in 0..105 {
            assert_eq!(core.send_text("happy.text", &i.to_string(), true), None);
        }
        assert_eq!(core.queued().len(), MAX_QUEUED_MESSAGES);
        assert_eq!(core.queued()[0].1, "5");
        let effects = core.on_participant("agent-1", true, None, true);
        assert_eq!(effects[0], Effect::Send(json!({"type": "agent", "present": true})));
        assert_eq!(effects.len(), 101);
        assert_eq!(effects[1], Effect::Publish { topic: "happy.text".into(), text: "5".into() });
        assert_eq!(core.send_text("happy.context", "x", true), Some(Effect::Publish { topic: "happy.context".into(), text: "x".into() }));
    }

    #[test]
    fn only_the_first_agent_is_heard() {
        let mut core = Core::default();
        assert!(core.on_participant("user-x", false, None, true).is_empty());
        assert_eq!(core.on_participant("agent-1", true, Some("listening"), true).len(), 1);
        assert!(core.on_participant("agent-2", true, None, true).is_empty());
        assert_eq!(core.agent(), Some("agent-1"));
        assert_eq!(core.agent_left("agent-2"), None);
        assert_eq!(sent(&core.agent_left("agent-1").unwrap()), json!({"type": "agent", "present": false}));
        assert_eq!(core.agent(), None);
    }

    #[test]
    fn agent_state_is_sent_only_when_it_changes() {
        let mut core = Core::default();
        let effects = core.on_participant("agent-1", true, Some("listening"), true);
        assert_eq!(effects, vec![Effect::Send(json!({"type": "agent", "present": true, "state": "listening"}))]);
        assert_eq!(core.agent_message(Some("listening")), None);
        assert_eq!(sent(&core.agent_message(Some("speaking"))), json!({"type": "agent", "present": true, "state": "speaking"}));
        assert_eq!(sent(&core.agent_message(None)), json!({"type": "agent", "present": true}));
        let attrs: HashMap<String, String> = [("lk.agent.state".to_string(), "dancing".to_string())].into();
        assert_eq!(agent_state(&attrs), None);
        let attrs: HashMap<String, String> = [("lk.agent.state".to_string(), "thinking".to_string())].into();
        assert_eq!(agent_state(&attrs), Some("thinking"));
    }

    #[tokio::test]
    async fn rpc_results_reach_the_waiting_call() {
        let mut core = Core::default();
        let (id, rx, msg) = core.forward_rpc("happy.getConfig", "{}").unwrap();
        assert_eq!(msg, json!({"type": "rpc", "id": "1", "method": "happy.getConfig", "payload": "{}"}));
        core.rpc_result("nope", Some("x".into()), None);
        core.rpc_result(&id, None, None);
        assert_eq!(rx.await.unwrap().unwrap(), "");

        let (id, rx, _) = core.forward_rpc("sendMessageToSession", "{}").unwrap();
        assert_eq!(id, "2");
        core.rpc_result(&id, Some("ok".into()), Some("boom".into()));
        let e = rx.await.unwrap().unwrap_err();
        assert_eq!((e.code, e.message.as_str()), (1500, "boom"));

        let (_, rx, _) = core.forward_rpc("processPermissionRequest", "{}").unwrap();
        core.release();
        let e = rx.await.unwrap().unwrap_err();
        assert_eq!((e.code, e.message.as_str()), (1503, "the app disconnected"));
        core.closed = true;
        assert_eq!(core.forward_rpc("happy.getConfig", "{}").unwrap_err().code, 1503);
        assert_eq!(core.send_text("happy.text", "x", true), None);
    }

    #[test]
    fn rpc_timeouts_follow_the_agent_within_bounds() {
        assert_eq!(rpc_timeout("happy.getConfig", Duration::from_secs(90)), Duration::from_secs(10));
        assert_eq!(rpc_timeout("sendMessageToSession", Duration::ZERO), Duration::from_secs(30));
        assert_eq!(rpc_timeout("sendMessageToSession", Duration::from_secs(5)), Duration::from_secs(5));
        assert_eq!(rpc_timeout("processPermissionRequest", Duration::from_secs(600)), Duration::from_secs(60));
    }

    #[test]
    fn uplink_drops_frames_while_behind() {
        let mut core = Core::default();
        let mut clock = UplinkClock::default();
        assert!(core.uplink_admit(0, clock.queued_ms(0.0)));
        clock.captured(0.0, 20.0);
        clock.captured(0.0, 20.0);
        clock.captured(0.0, 20.0);
        assert_eq!(clock.queued_ms(0.0), 60.0);
        assert!(core.uplink_admit(1, clock.queued_ms(0.0)));
        clock.captured(0.0, 20.0);
        assert!(!core.uplink_admit(0, clock.queued_ms(0.0)));
        assert!(!core.uplink_admit(2, 0.0));
        assert!(core.uplink_admit(1, clock.queued_ms(40.0)));
        assert_eq!(clock.queued_ms(500.0), 0.0);
        clock.captured(500.0, 20.0);
        assert_eq!(clock.queued_ms(500.0), 20.0);
    }
}
