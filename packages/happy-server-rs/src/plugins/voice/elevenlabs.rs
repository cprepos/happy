//! ElevenLabs helpers copied from upstream's `routes/voice.rs`, which keeps
//! them private. Each copy names its original and the hash of the original's
//! text when it was copied; `scripts/plugins/upstream-check.sh` warns once
//! upstream's version no longer matches, so the copy can follow it.

use crate::app::App;
use crate::fetch;
use crate::js;
use base64::Engine;
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
use std::sync::LazyLock;

// upstream-copy: src/routes/voice.rs CONVERSATION_ID b6397e5c0f020b5d
static CONVERSATION_ID: LazyLock<regex::Regex> = LazyLock::new(|| regex::Regex::new(r"conv_[a-zA-Z0-9]+").unwrap());

/// `u_` + base64url(HMAC-SHA256(master secret, user id)).
// upstream-copy: src/routes/voice.rs eleven_user_id d0bd104774f330a1
pub fn eleven_user_id(app: &App, user_id: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(app.config.master_secret.as_bytes()).expect("hmac key");
    mac.update(user_id.as_bytes());
    format!("u_{}", base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

// upstream-copy: src/routes/voice.rs Token c13c4141c94633d0
pub enum Token {
    Failed(u16),
    NoConversation,
    Granted(String, String),
}

/// The token request; `Err` wherever the TS code throws.
// upstream-copy: src/routes/voice.rs conversation_token 92c48cd856f2f341
pub async fn conversation_token(url: &str, key: &str) -> anyhow::Result<Token> {
    let res = fetch::CLIENT.get(url).header("xi-api-key", fetch::header_value(key)?).send().await?;
    if !res.status().is_success() {
        return Ok(Token::Failed(res.status().as_u16()));
    }
    let data = fetch::json(res).await?;
    if js::destructure_throws(Some(&data)) {
        anyhow::bail!("Cannot destructure property 'token'");
    }
    let Some(Value::String(token)) = js::get(Some(&data), "token") else {
        anyhow::bail!("conversationToken.split is not a function");
    };
    // `Buffer.from(token.split('.')[1], 'base64')` throws on undefined.
    let Some(part) = token.split('.').nth(1) else { anyhow::bail!("The first argument must be of type string") };
    let decoded = crate::util::node_b64_decode(part);
    let payload = js::parse(&String::from_utf8_lossy(&decoded)).map_err(|e| anyhow::anyhow!(e.message))?;
    if payload.is_null() {
        anyhow::bail!("Cannot read properties of null (reading 'video')");
    }
    // `(jwtPayload.video?.room || '').match(...)`: only strings have `match`.
    let room = js::get(js::get(Some(&payload), "video"), "room");
    let room = if js::truthy(room) { room.cloned().unwrap_or(Value::Null) } else { json!("") };
    let Value::String(room) = room else { anyhow::bail!("match is not a function") };
    Ok(match CONVERSATION_ID.find(&room) {
        Some(m) => Token::Granted(token.clone(), m.as_str().to_string()),
        None => Token::NoConversation,
    })
}
