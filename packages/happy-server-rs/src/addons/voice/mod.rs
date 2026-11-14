//! Self-hosted voice (`voiceRoutes.ts`, `app/voice`, `api/voiceStream.ts`).
//!
//! The REST routes replace upstream's ElevenLabs-only ones: without `agentId`
//! a conversation is a LiveKit room the `happy-voice` agent is dispatched to;
//! with it, the ElevenLabs grant under a 5 h cap. `VOICE_BACKENDS`, the LiveKit
//! keys and the ElevenLabs key decide which of the two the server offers.

pub mod backends;
pub mod bridge;
pub mod conversations;
pub mod elevenlabs;
pub mod livekit_token;
pub mod stream;
pub mod usage;

use crate::app::App;
use crate::h;
use crate::http::{HResult, Reply, Req, Router};
use crate::js;
use elevenlabs::{conversation_token, eleven_user_id, Token};
use crate::zod::{array, enumeration, literal, number, object, string, union, S};
use backends::Resolved;
use hyper::Method;
use livekit_token::LiveKitConfig;
use serde_json::json;
use std::sync::{Arc, LazyLock};
use usage::{VOICE_HARD_LIMIT_SECONDS, VOICE_UNLIMITED, VOICE_USAGE_PAGE_SIZE};

/// An environment variable, empty counting as unset (compose passes empties).
pub(crate) fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

static LIVEKIT: LazyLock<Option<LiveKitConfig>> = LazyLock::new(|| livekit_token::config_from_env(env));
static BACKENDS: LazyLock<Resolved> = LazyLock::new(|| backends::from_env(env));

/// The LiveKit settings, `None` when the key or secret is missing.
pub fn livekit() -> Option<&'static LiveKitConfig> {
    LIVEKIT.as_ref()
}

/// The backends this server offers.
pub fn backends() -> &'static Resolved {
    &BACKENDS
}

/// The error for LiveKit keys set without `LIVEKIT_PUBLIC_URL`, which has no
/// default: apps would otherwise be handed a URL for some other host.
fn missing_public_url(livekit: &LiveKitConfig) -> Option<&'static str> {
    livekit.public_url.is_none().then_some(
        "LIVEKIT_PUBLIC_URL is not set: LiveKit grants on POST /v1/voice/conversations answer 500 until it is \
         (set it to the wss:// URL apps reach LiveKit on; the /v1/voice/stream bridge does not need it)",
    )
}

fn error_schema() -> S {
    object(vec![("error", string())])
}

pub fn register(r: &mut Router) {
    for warning in &backends().warnings {
        tracing::warn!(module = "voice", "{}", warning);
    }
    if let Some(problem) = livekit().and_then(missing_public_url) {
        tracing::error!(module = "voice", "{}", problem);
    }
    crate::addons::remove_route(r, &Method::POST, "/v1/voice/conversations");
    crate::addons::remove_route(r, &Method::GET, "/v1/voice/usage");

    let backend = || enumeration(&[backends::STREAM, backends::ELEVENLABS]);
    r.get("/v1/voice/config")
        .auth()
        .response(200, object(vec![("backends", array(backend())), ("defaultBackend", backend().nullable())]))
        .handle(h!(config));

    let livekit_grant = object(vec![
        ("allowed", literal(json!(true))),
        ("conversationId", string()),
        ("roomName", string()),
        ("token", string()),
        ("url", string()),
    ]);
    let elevenlabs_grant = object(vec![
        ("allowed", literal(json!(true))),
        ("conversationToken", string()),
        ("conversationId", string()),
        ("agentId", string()),
        ("elevenUserId", string()),
        ("usedSeconds", number()),
        ("limitSeconds", number()),
    ]);
    let denied = object(vec![
        ("allowed", literal(json!(false))),
        ("reason", enumeration(&["voice_hard_limit_reached", "subscription_required", "voice_conversation_limit_reached"])),
        ("usedSeconds", number()),
        ("limitSeconds", number()),
        ("agentId", string()),
    ]);
    r.post("/v1/voice/conversations")
        .auth()
        .body(
            object(vec![
                ("sessionId", string().optional()),
                ("language", string().optional()),
                ("agentId", string().optional()),
            ])
            .nullish(),
        )
        .response(200, union(vec![livekit_grant, elevenlabs_grant, denied]))
        .response(500, error_schema())
        .response(503, error_schema())
        .handle(h!(conversations));

    r.get("/v1/voice/usage")
        .auth()
        .response(
            200,
            object(vec![
                ("usedSeconds", number()),
                ("limitSeconds", number()),
                ("conversationCount", number()),
                ("conversationLimit", number()),
                ("elevenUserId", string()),
            ]),
        )
        .response(500, error_schema())
        .handle(h!(usage_get));
}

async fn config(_app: Arc<App>, _req: Req) -> HResult {
    Reply::json(backends().config_json())
}

async fn conversations(app: Arc<App>, req: Req) -> HResult {
    let uid = req.user_id.clone();
    let session_id = req.body_str("sessionId");
    let language = req.body_str("language");

    if let Some(agent_id) = req.body_str("agentId") {
        tracing::info!(module = "voice", "Voice token request from user {}", uid);
        let Some(key) = app.config.elevenlabs_api_key.clone() else {
            return Reply::error(500, "ELEVENLABS_API_KEY not configured");
        };
        if !backends().offers(backends::ELEVENLABS) {
            return Reply::error(503, "ElevenLabs is not offered by this server");
        }
        return elevenlabs_grant(&app, &key, &uid, &agent_id).await;
    }

    let Some(livekit) = livekit() else {
        tracing::info!(module = "voice", "LIVEKIT_API_KEY / LIVEKIT_API_SECRET not configured");
        return Reply::error(500, "LiveKit is not configured");
    };
    if !backends().offers(backends::STREAM) {
        return Reply::error(503, "Voice stream is not offered by this server");
    }
    let Some(public_url) = livekit.public_url.as_deref() else {
        tracing::error!(module = "voice", "{}", missing_public_url(livekit).unwrap_or_default());
        return Reply::error(500, "LIVEKIT_PUBLIC_URL is not configured");
    };
    match conversations::create(&app.pool, &uid, session_id.as_deref(), language.as_deref()).await {
        Ok((conversation_id, room_name)) => {
            let token = livekit_token::create(livekit, &uid, &room_name);
            tracing::info!(module = "voice", "Voice room {} issued for user {}", room_name, uid);
            Reply::json(json!({
                "allowed": true,
                "conversationId": conversation_id,
                "roomName": room_name,
                "token": token,
                "url": public_url,
            }))
        }
        Err(e) => {
            tracing::info!(module = "voice", "Failed to start voice conversation for user {}: {:#}", uid, e);
            Reply::error(500, "Failed to start voice conversation")
        }
    }
}

/// `voiceElevenLabsGrantCreate`: past the hard limit voice is denied; otherwise
/// the conversation token, whose LiveKit room name carries the conversation id.
async fn elevenlabs_grant(app: &App, key: &str, uid: &str, agent_id: &str) -> HResult {
    let eleven = eleven_user_id(app, uid);
    let (used, count) = match usage::elevenlabs_usage(app, key, &eleven).await {
        Ok(u) => u,
        Err(e) => {
            tracing::info!(module = "voice", "Failed to get voice usage for user {}: {:#}", uid, e);
            return Reply::error(500, "Failed to get voice usage");
        }
    };
    tracing::info!(module = "voice", "User {}: {}s used, {} convos (hard={}s)", uid, js::format_number(used), count, VOICE_HARD_LIMIT_SECONDS);
    if used >= VOICE_HARD_LIMIT_SECONDS {
        return Reply::json(json!({
            "allowed": false,
            "reason": "voice_hard_limit_reached",
            "usedSeconds": js::num(used),
            "limitSeconds": js::num(VOICE_HARD_LIMIT_SECONDS),
            "agentId": agent_id,
        }));
    }
    // Encoded, a client's `agentId` cannot add query parameters (such as a
    // second participant_name to dodge the usage count).
    let url = format!(
        "{}/conversation/token?agent_id={}&participant_name={}",
        app.config.elevenlabs_api,
        js::encode_uri_component(agent_id),
        eleven
    );
    match conversation_token(&url, key).await {
        Ok(Token::Failed(status)) => {
            tracing::info!(module = "voice", "Failed to get conversation token for user {}: {}", uid, status);
            Reply::error(500, "Failed to get voice credentials")
        }
        Ok(Token::NoConversation) => {
            tracing::info!(module = "voice", "No conversation_id in JWT for user {}", uid);
            Reply::error(500, "Failed to get conversation ID")
        }
        Ok(Token::Granted(token, conversation_id)) => {
            tracing::info!(module = "voice", "Voice token issued for user {}, conv={}", uid, conversation_id);
            Reply::json(json!({
                "allowed": true,
                "conversationToken": token,
                "conversationId": conversation_id,
                "agentId": agent_id,
                "elevenUserId": eleven,
                "usedSeconds": js::num(used),
                "limitSeconds": js::num(VOICE_HARD_LIMIT_SECONDS),
            }))
        }
        Err(e) => {
            tracing::info!(module = "voice", "ElevenLabs request error for user {}: {:#}", uid, e);
            Reply::error(500, "Failed to get voice credentials")
        }
    }
}

/// With ElevenLabs offered, its usage and limits; otherwise the recorded
/// conversations, unlimited, `elevenUserId` carrying the LiveKit identity.
async fn usage_get(app: Arc<App>, req: Req) -> HResult {
    let uid = req.user_id.clone();
    if let (Some(key), true) = (app.config.elevenlabs_api_key.clone(), backends().offers(backends::ELEVENLABS)) {
        let eleven = eleven_user_id(&app, &uid);
        return match usage::elevenlabs_usage(&app, &key, &eleven).await {
            Ok((used, count)) => Reply::json(json!({
                "usedSeconds": js::num(used),
                "limitSeconds": js::num(VOICE_HARD_LIMIT_SECONDS),
                "conversationCount": count,
                "conversationLimit": VOICE_USAGE_PAGE_SIZE,
                "elevenUserId": eleven,
            })),
            Err(e) => {
                tracing::info!(module = "voice", "Failed to get voice usage for user {}: {:#}", uid, e);
                Reply::error(500, "Failed to get voice usage")
            }
        };
    }
    match conversations::usage(&app.pool, &uid).await {
        Ok((used, count)) => Reply::json(json!({
            "usedSeconds": used,
            "limitSeconds": VOICE_UNLIMITED,
            "conversationCount": count,
            "conversationLimit": VOICE_UNLIMITED,
            "elevenUserId": format!("user-{}", uid),
        })),
        Err(e) => {
            tracing::info!(module = "voice", "Failed to get voice usage for user {}: {:#}", uid, e);
            Reply::error(500, "Failed to get voice usage")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn patterns(r: &Router) -> Vec<(String, &'static str)> {
        r.routes.iter().map(|x| (x.method.to_string(), x.pattern)).collect()
    }

    #[test]
    fn replaces_the_upstream_voice_routes() {
        let mut r = Router::default();
        crate::routes::voice::register(&mut r);
        let upstream: Vec<_> = r.routes.iter().map(|x| x.handler as usize).collect();
        register(&mut r);
        let p = patterns(&r);
        assert_eq!(p.iter().filter(|(m, x)| m == "POST" && *x == "/v1/voice/conversations").count(), 1);
        assert_eq!(p.iter().filter(|(m, x)| m == "GET" && *x == "/v1/voice/usage").count(), 1);
        assert_eq!(p.iter().filter(|(m, x)| m == "GET" && *x == "/v1/voice/config").count(), 1);
        assert!(r.routes.iter().all(|x| !upstream.contains(&(x.handler as usize))));
    }

    #[test]
    fn a_missing_public_url_is_an_error() {
        let mut c = LiveKitConfig { api_key: "k".into(), api_secret: "s".into(), url: "ws://lk".into(), public_url: None };
        assert!(missing_public_url(&c).unwrap().starts_with("LIVEKIT_PUBLIC_URL is not set"));
        c.public_url = Some("wss://lk.example".into());
        assert_eq!(missing_public_url(&c), None);
    }

    #[test]
    fn conversation_response_schema_takes_both_grants_and_denial() {
        let mut r = Router::default();
        register(&mut r);
        let route = r.routes.iter().find(|x| x.pattern == "/v1/voice/conversations").unwrap();
        let ok = &route.responses.iter().find(|(s, _)| *s == 200).unwrap().1;
        let lk = json!({"allowed": true, "conversationId": "c", "roomName": "happy-voice-c", "token": "t", "url": "wss://x"});
        assert_eq!(ok.parse(Some(&lk)).unwrap(), Some(lk.clone()));
        let el = json!({"allowed": true, "conversationToken": "t", "conversationId": "conv_1", "agentId": "a", "elevenUserId": "u_x", "usedSeconds": 1, "limitSeconds": 18000});
        let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();
        assert_eq!(keys(&ok.parse(Some(&el)).unwrap().unwrap()), keys(&el));
        let denied = json!({"allowed": false, "reason": "voice_hard_limit_reached", "usedSeconds": 18000, "limitSeconds": 18000, "agentId": "a"});
        assert_eq!(keys(&ok.parse(Some(&denied)).unwrap().unwrap()), keys(&denied));
        let body = route.body.as_ref().unwrap();
        assert!(body.parse(None).is_ok());
        assert!(body.parse(Some(&json!(null))).is_ok());
        assert!(body.parse(Some(&json!({"agentId": 5}))).is_err());
    }
}
