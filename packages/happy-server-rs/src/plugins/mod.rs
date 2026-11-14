//! Plugins: server features that live outside the upstream port.
//!
//! - `voice`: self-hosted voice. LiveKit grants and recorded usage on the REST
//!   routes, `GET /v1/voice/config`, and the `/v1/voice/stream` WebSocket that
//!   bridges an app's audio into a LiveKit room.
//! - `webapp`: serves a static web app from `HAPPY_STATIC_DIR`, with the server
//!   check on `/` the apps rely on.
//! - `heartbeat`: when a session's socket connected, so a session resumed right
//!   after a stop counts from its new owner's first beat.
//!
//! Upstream code calls in at a handful of places, each listed in
//! docs/plugins.md. Settings come from the environment on first use and shared
//! state lives in statics, so `Config` and `App` stay as upstream has them.

pub mod heartbeat;
pub mod voice;
pub mod webapp;

use crate::app::App;
use crate::config::Config;
use crate::http::{HttpResponse, Router};
use std::sync::Arc;

/// Called last from `routes::register`. Replaces the upstream routes the plugins
/// answer differently and adds the rest.
pub fn register(r: &mut Router, c: &Config) {
    voice::register(r);
    webapp::register(r, c);
}

/// Whether a plugin answers this request: an upgrade on a plugin's path.
pub fn owns_upgrade(path: &str, headers: &hyper::HeaderMap) -> bool {
    path == voice::stream::PATH && crate::engine::is_upgrade(headers)
}

/// Answers an upgrade request on a path `owns_upgrade` claimed.
pub async fn upgrade(app: Arc<App>, req: hyper::Request<hyper::body::Incoming>) -> Result<HttpResponse, crate::engine::Destroy> {
    voice::stream::upgrade(app, req).await
}

/// Drops the routes registered so far for `method` and `pattern`, so the
/// plugin's own registration is the one `Router::find` picks.
pub(crate) fn remove_route(r: &mut Router, method: &hyper::Method, pattern: &str) {
    r.routes.retain(|route| !(route.method == *method && route.pattern == pattern));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owns_only_the_voice_stream_path() {
        let mut up = hyper::HeaderMap::new();
        up.insert("connection", "Upgrade".parse().unwrap());
        up.insert("upgrade", "websocket".parse().unwrap());
        assert!(owns_upgrade("/v1/voice/stream", &up));
        assert!(!owns_upgrade("/v1/voice/stream", &hyper::HeaderMap::new()));
        assert!(!owns_upgrade("/v1/voice/stream/", &up));
        assert!(!owns_upgrade("/v1/updates", &up));
        assert!(!owns_upgrade("/", &up));
    }
}
