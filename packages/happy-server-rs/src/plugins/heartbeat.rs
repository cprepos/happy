//! A session resumed right after it stopped reads as alive from its new
//! owner's first beat (`sessionCache.ts`, `sessionUpdateHandler.ts`).
//!
//! A stop keeps heartbeats out for a minute so a beat still on its way from the
//! stopped owner cannot revive the session. That window now holds only for
//! sockets connected by the time of the stop: the owner a Resume starts
//! connects later, and its beats count at once. `ActivityCache` asks
//! `stop_applies`; the socket handlers report each socket through `seen`.

use crate::events::SocketHandle;
use dashmap::DashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Weak};

/// When each live socket was first seen, by socket id.
static CONNECTED: LazyLock<DashMap<String, (Weak<SocketHandle>, i64)>> = LazyLock::new(DashMap::new);
static INSERTS: AtomicUsize = AtomicUsize::new(0);
/// Entries of closed sockets are dropped once every this many new sockets.
const PRUNE_EVERY: usize = 256;

/// Called first for every event a socket sends. The first call stands for the
/// connect time: the handshake is the only thing that comes before it.
pub fn seen(s: &Arc<SocketHandle>) {
    if CONNECTED.contains_key(&s.id) {
        return;
    }
    CONNECTED.entry(s.id.clone()).or_insert_with(|| (Arc::downgrade(s), crate::util::now_ms()));
    if INSERTS.fetch_add(1, Ordering::Relaxed) % PRUNE_EVERY == PRUNE_EVERY - 1 {
        CONNECTED.retain(|_, (w, _)| w.strong_count() > 0);
    }
}

/// When the socket was first seen; `None` for one never seen.
pub fn connected_at(s: &SocketHandle) -> Option<i64> {
    CONNECTED.get(&s.id).map(|e| e.1)
}

/// Whether a stop at `stopped_at` keeps out a heartbeat from a socket that
/// connected at `connected_at` (`None`: unknown, so it does). The stop's own
/// millisecond counts as before it.
pub fn stop_applies(stopped_at: i64, connected_at: Option<i64>) -> bool {
    connected_at.is_none_or(|c| c <= stopped_at)
}

/// A session's first beat after the server saw it inactive is written at once,
/// not after the update threshold.
pub fn should_queue(active: bool, time_diff: i64, threshold: i64) -> bool {
    !active || time_diff > threshold
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_holds_only_for_sockets_connected_by_then() {
        assert!(stop_applies(1000, None));
        assert!(stop_applies(1000, Some(999)));
        assert!(stop_applies(1000, Some(1000)));
        assert!(!stop_applies(1000, Some(1001)));
    }

    #[test]
    fn an_inactive_session_queues_its_first_beat() {
        assert!(should_queue(false, 0, 30_000));
        assert!(!should_queue(true, 2_000, 30_000));
        assert!(should_queue(true, 30_001, 30_000));
    }
}
