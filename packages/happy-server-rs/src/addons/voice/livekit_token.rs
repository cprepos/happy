//! `voiceTokenCreate.ts`: the LiveKit settings and the room access token.

use base64::Engine;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;

/// Agent name the voice worker registers with; the token dispatches it into the room.
pub const VOICE_AGENT_NAME: &str = "happy-voice";
/// Lifetime of a voice room token. It only needs to outlive the join.
pub const VOICE_TOKEN_TTL_SECONDS: i64 = 15 * 60;
/// Where the server itself reaches LiveKit (the stream bridge joins rooms there).
pub const DEFAULT_LIVEKIT_URL: &str = "ws://livekit:7880";

#[derive(Debug, Clone, PartialEq)]
pub struct LiveKitConfig {
    pub api_key: String,
    pub api_secret: String,
    /// Internal URL the server joins rooms on.
    pub url: String,
    /// URL handed to clients by the REST route (`LIVEKIT_PUBLIC_URL`). It has
    /// no default: without it, LiveKit grants answer an error.
    pub public_url: Option<String>,
}

/// `voiceLiveKitConfig` over an environment lookup that treats empty as unset:
/// `None` when the key or secret is missing. `LIVEKIT_PUBLIC_URL` is not
/// defaulted (the TypeScript server's default is one particular host); the
/// stream does not need it, only the grants on the REST route.
pub fn config_from_env(var: impl Fn(&str) -> Option<String>) -> Option<LiveKitConfig> {
    Some(LiveKitConfig {
        api_key: var("LIVEKIT_API_KEY")?,
        api_secret: var("LIVEKIT_API_SECRET")?,
        url: var("LIVEKIT_URL").unwrap_or_else(|| DEFAULT_LIVEKIT_URL.into()),
        public_url: var("LIVEKIT_PUBLIC_URL"),
    })
}

/// The claims livekit-server-sdk's `AccessToken` signs, in its order: the grant,
/// the room configuration (protobuf JSON with default values), then jose's
/// `iss`, `exp`, `nbf` and `sub`.
pub fn claims(config: &LiveKitConfig, account_id: &str, room_name: &str, now_s: i64) -> Value {
    json!({
        "video": {
            "room": room_name,
            "roomJoin": true,
            "canPublish": true,
            "canSubscribe": true,
            "canPublishData": true,
        },
        "roomConfig": {
            "name": "",
            "emptyTimeout": 0,
            "departureTimeout": 0,
            "maxParticipants": 0,
            "minPlayoutDelay": 0,
            "maxPlayoutDelay": 0,
            "syncStreams": false,
            "agents": [{
                "agentName": VOICE_AGENT_NAME,
                "metadata": "",
                "restartPolicy": "JRP_ON_FAILURE",
                "deployment": "",
                "attributes": {},
            }],
            "metadata": "",
            "tags": {},
        },
        "iss": config.api_key,
        "exp": now_s + VOICE_TOKEN_TTL_SECONDS,
        "nbf": now_s,
        "sub": format!("user-{}", account_id),
    })
}

/// Mints the access token for an account to join one voice room as
/// `user-<accountId>`; joining the room dispatches the `happy-voice` agent.
pub fn create(config: &LiveKitConfig, account_id: &str, room_name: &str) -> String {
    sign(&claims(config, account_id, room_name, crate::util::now_ms().div_euclid(1000)), &config.api_secret)
}

/// An HS256 JWT over `claims`.
pub fn sign(claims: &Value, secret: &str) -> String {
    let b64 = |b: &[u8]| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(b);
    let input = format!("{}.{}", b64(br#"{"alg":"HS256"}"#), b64(serde_json::to_string(claims).expect("claims").as_bytes()));
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("hmac key");
    mac.update(input.as_bytes());
    format!("{}.{}", input, b64(&mac.finalize().into_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> LiveKitConfig {
        LiveKitConfig { api_key: "APIkey".into(), api_secret: "secret-secret-secret-secret-secret".into(), url: "ws://lk:7880".into(), public_url: Some("wss://pub".into()) }
    }

    #[test]
    fn reads_settings_with_defaults_and_requires_key_and_secret() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(n, v)| *n == k && !v.is_empty()).map(|(_, v)| v.to_string())
        };
        assert_eq!(config_from_env(env(&[("LIVEKIT_API_KEY", "k")])), None);
        assert_eq!(config_from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "")])), None);
        let c = config_from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "s"), ("LIVEKIT_URL", "")])).unwrap();
        assert_eq!((c.url.as_str(), c.public_url.as_deref()), (DEFAULT_LIVEKIT_URL, None));
        let c = config_from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "s"), ("LIVEKIT_URL", "ws://a"), ("LIVEKIT_PUBLIC_URL", "wss://b")])).unwrap();
        assert_eq!((c.url.as_str(), c.public_url.as_deref()), ("ws://a", Some("wss://b")));
    }

    #[test]
    fn token_is_hs256_over_the_sdk_claims() {
        let token = sign(&claims(&config(), "acc1", "happy-voice-c1", 1_700_000_000), &config().api_secret);
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        let dec = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s).unwrap();
        assert_eq!(dec(parts[0]), br#"{"alg":"HS256"}"#);
        let payload = String::from_utf8(dec(parts[1])).unwrap();
        assert!(payload.starts_with(r#"{"video":{"room":"happy-voice-c1","roomJoin":true"#), "{}", payload);
        let v: Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(v["sub"], "user-acc1");
        assert_eq!(v["iss"], "APIkey");
        assert_eq!(v["nbf"], 1_700_000_000);
        assert_eq!(v["exp"], 1_700_000_900);
        assert_eq!(v["roomConfig"]["agents"][0]["agentName"], "happy-voice");
        let mut mac = Hmac::<Sha256>::new_from_slice(config().api_secret.as_bytes()).unwrap();
        mac.update(format!("{}.{}", parts[0], parts[1]).as_bytes());
        mac.verify_slice(&dec(parts[2])).expect("signature");
    }
}
