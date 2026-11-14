//! A session resumed right after it stopped reads as alive from its new
//! owner's first beat (`sessionCache.ts`, `sessionUpdateHandler.ts`).
//!
//! A stop keeps heartbeats out for a minute so a beat still on its way from the
//! stopped owner cannot revive the session. Upstream lifts that early only on
//! `POST /v1/sessions` (`ActivityCache::resume_session_updates`); a resumed
//! owner reattaches without that call. Here the window holds only for sockets
//! that were beating by the time of the stop: a socket that starts beating
//! later is the new owner, so its first beat lifts the stop through upstream's
//! own `resume_session_updates` and is written at once. Beats from the sockets
//! that were stopped stay ignored until the window ends.
//!
//! Upstream calls in at three places: `ActivityCache::clear_session_updates`
//! (`stopped`), `ActivityCache::resume_session_updates` (`resumed`) and the
//! `session-alive` handler (`alive`).

use crate::app::App;
use crate::events::SocketHandle;
use crate::util::{ms_to_naive, now_ms};
use dashmap::DashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Weak};

/// How long a stop keeps heartbeats out: upstream's `STOPPED_TTL` (activity.rs).
const STOPPED_TTL: i64 = 60_000;
/// Entries of closed sockets are dropped once every this many new sockets.
const PRUNE_EVERY: usize = 256;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Stop {
    at: i64,
    /// Whether a new owner's beat has already lifted upstream's stop.
    lifted: bool,
}

/// When each live socket first sent `session-alive`, by socket id.
static FIRST_BEAT: LazyLock<DashMap<String, (Weak<SocketHandle>, i64)>> = LazyLock::new(DashMap::new);
static INSERTS: AtomicUsize = AtomicUsize::new(0);
/// Sessions stopped within the last `STOPPED_TTL`.
static STOPS: LazyLock<DashMap<String, Stop>> = LazyLock::new(DashMap::new);

/// A session was stopped, archived or deleted (`clear_session_updates`).
pub fn stopped(session_id: &str) {
    let now = now_ms();
    STOPS.retain(|_, s| s.at + STOPPED_TTL > now);
    STOPS.insert(session_id.to_string(), Stop { at: now, lifted: false });
}

/// Upstream lifted the stop (`resume_session_updates`): every beat counts again.
pub fn resumed(session_id: &str) {
    STOPS.remove(session_id);
}

/// What `alive` does with a beat, from the socket's first beat and the stop.
#[derive(Debug, PartialEq)]
enum Verdict {
    /// No stop in force here: upstream decides.
    Pass,
    /// A beat from a socket that was beating before the stop.
    Ignore,
    /// The new owner's first beat after the stop: lift it and write the beat.
    Lift,
}

fn verdict(stop: Option<Stop>, first_beat: i64, now: i64) -> Verdict {
    match stop {
        Some(s) if s.at + STOPPED_TTL > now => {
            if first_beat <= s.at {
                Verdict::Ignore
            } else if s.lifted {
                Verdict::Pass
            } else {
                Verdict::Lift
            }
        }
        _ => Verdict::Pass,
    }
}

/// Called from the `session-alive` handler before upstream checks the session.
/// `false` drops the beat.
pub async fn alive(app: &App, s: &Arc<SocketHandle>, sid: &str, time: i64) -> bool {
    let now = now_ms();
    let first = first_beat(s, now);
    match verdict(STOPS.get(sid).map(|e| *e), first, now) {
        Verdict::Pass => true,
        Verdict::Ignore => false,
        Verdict::Lift => {
            // Upstream's lift also clears our record (`resumed`); put it back
            // so the stopped owner's sockets stay ignored for the window.
            let at = STOPS.get(sid).map(|e| e.at);
            app.activity.resume_session_updates(sid);
            if let Some(at) = at {
                STOPS.insert(sid.to_string(), Stop { at, lifted: true });
            }
            // The session went inactive at the stop, within upstream's update
            // threshold of this beat, which upstream would therefore not write.
            let r = sqlx::query(r#"UPDATE "Session" SET "lastActiveAt" = $1, "active" = true, "updatedAt" = $2 WHERE "id" = $3 AND "accountId" = $4 AND "active" = false"#)
                .bind(ms_to_naive(time))
                .bind(crate::db::now())
                .bind(sid)
                .bind(&s.user_id)
                .execute(&app.pool)
                .await;
            if let Err(e) = r {
                tracing::error!(module = "session-cache", "Error updating resumed session {}: {}", sid, e);
            }
            true
        }
    }
}

/// When the socket first sent a beat, recording `now` for its first.
fn first_beat(s: &Arc<SocketHandle>, now: i64) -> i64 {
    if let Some(e) = FIRST_BEAT.get(&s.id) {
        return e.1;
    }
    let t = FIRST_BEAT.entry(s.id.clone()).or_insert_with(|| (Arc::downgrade(s), now)).1;
    if INSERTS.fetch_add(1, Ordering::Relaxed) % PRUNE_EVERY == PRUNE_EVERY - 1 {
        FIRST_BEAT.retain(|_, (w, _)| w.strong_count() > 0);
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stop_holds_only_for_sockets_beating_by_then() {
        let stop = Some(Stop { at: 1000, lifted: false });
        assert_eq!(verdict(None, 0, 2000), Verdict::Pass);
        assert_eq!(verdict(stop, 999, 2000), Verdict::Ignore);
        assert_eq!(verdict(stop, 1000, 2000), Verdict::Ignore);
        assert_eq!(verdict(stop, 1001, 2000), Verdict::Lift);
    }

    #[test]
    fn a_lifted_stop_still_ignores_the_stopped_owner() {
        let stop = Some(Stop { at: 1000, lifted: true });
        assert_eq!(verdict(stop, 1001, 2000), Verdict::Pass);
        assert_eq!(verdict(stop, 999, 2000), Verdict::Ignore);
    }

    #[test]
    fn a_stop_ends_after_the_window() {
        let stop = Some(Stop { at: 1000, lifted: false });
        assert_eq!(verdict(stop, 0, 1000 + STOPPED_TTL), Verdict::Pass);
        assert_eq!(verdict(stop, 0, 1000 + STOPPED_TTL - 1), Verdict::Ignore);
    }
}
