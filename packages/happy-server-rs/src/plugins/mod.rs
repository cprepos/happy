//! Plugins: server features that live outside the upstream port.
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

/// Whether a plugin answers upgrades on this path.
pub fn owns_upgrade(_path: &str) -> bool {
    false
}

/// Answers an upgrade request on a path `owns_upgrade` claimed.
pub async fn upgrade(_app: Arc<App>, req: hyper::Request<hyper::body::Incoming>) -> Result<HttpResponse, crate::engine::Destroy> {
    unreachable!("no plugin owns upgrades on {}", req.uri().path())
}

/// Drops the routes registered so far for `method` and `pattern`, so the
/// plugin's own registration is the one `Router::find` picks.
pub(crate) fn remove_route(r: &mut Router, method: &hyper::Method, pattern: &str) {
    r.routes.retain(|route| !(route.method == *method && route.pattern == pattern));
}
