//! `voiceBackendsResolve.ts`: which voice backends the server offers.

use serde_json::{json, Value};

/// The backends in the wire's `VoiceBackendSchema` order.
pub const STREAM: &str = "stream";
pub const ELEVENLABS: &str = "elevenlabs";
const ALL: [&str; 2] = [STREAM, ELEVENLABS];

#[derive(Debug, Clone, PartialEq)]
pub struct Resolved {
    pub backends: Vec<&'static str>,
    pub default_backend: Option<&'static str>,
    /// One message for each listed name that was dropped.
    pub warnings: Vec<String>,
}

impl Resolved {
    pub fn offers(&self, backend: &str) -> bool {
        self.backends.contains(&backend)
    }

    /// The `GET /v1/voice/config` body.
    pub fn config_json(&self) -> Value {
        json!({ "backends": self.backends, "defaultBackend": self.default_backend })
    }
}

/// A non-empty `VOICE_BACKENDS` decides the list and its order, the first entry
/// being the default; a listed backend that is unknown or not configured is
/// dropped with a warning and never replaced by another. Otherwise the list is
/// whatever is configured, `stream` first.
pub fn resolve(voice_backends: Option<&str>, livekit_configured: bool, elevenlabs_configured: bool) -> Resolved {
    let configured = |b: &str| if b == STREAM { livekit_configured } else { elevenlabs_configured };
    let mut listed: Vec<&str> = Vec::new();
    for name in voice_backends.unwrap_or("").split(',') {
        let name = name.trim_matches(crate::js::is_js_whitespace);
        // `new Set(listed)`: first occurrence wins, order kept.
        if !name.is_empty() && !listed.contains(&name) {
            listed.push(name);
        }
    }
    let mut backends = Vec::new();
    let mut warnings = Vec::new();
    if listed.is_empty() {
        backends.extend(ALL.iter().copied().filter(|b| configured(b)));
    }
    for name in listed {
        match ALL.iter().find(|b| **b == name) {
            None => warnings.push(format!("VOICE_BACKENDS lists unknown backend \"{}\"; dropped", name)),
            Some(b) if !configured(b) => warnings.push(format!("VOICE_BACKENDS lists \"{}\" but it is not configured; dropped", name)),
            Some(b) => backends.push(*b),
        }
    }
    Resolved { default_backend: backends.first().copied(), backends, warnings }
}

/// `voiceBackendsCurrent` over an environment lookup that treats empty as unset.
pub fn from_env(var: impl Fn(&str) -> Option<String>) -> Resolved {
    let livekit = var("LIVEKIT_API_KEY").is_some() && var("LIVEKIT_API_SECRET").is_some();
    resolve(var("VOICE_BACKENDS").as_deref(), livekit, var("ELEVENLABS_API_KEY").is_some())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(list: Option<&str>, lk: bool, el: bool) -> Resolved {
        resolve(list, lk, el)
    }

    fn ok(backends: &[&'static str]) -> Resolved {
        Resolved { backends: backends.to_vec(), default_backend: backends.first().copied(), warnings: vec![] }
    }

    #[test]
    fn detects_what_is_configured_when_unset() {
        for list in [None, Some(""), Some("   "), Some(","), Some(" , ")] {
            assert_eq!(r(list, true, true), ok(&["stream", "elevenlabs"]));
            assert_eq!(r(list, true, false), ok(&["stream"]));
            assert_eq!(r(list, false, true), ok(&["elevenlabs"]));
            assert_eq!(r(list, false, false), ok(&[]));
        }
    }

    #[test]
    fn takes_the_list_order_and_only_what_is_listed() {
        assert_eq!(r(Some("elevenlabs,stream"), true, true), ok(&["elevenlabs", "stream"]));
        assert_eq!(r(Some("stream"), true, true), ok(&["stream"]));
        assert_eq!(r(Some("elevenlabs"), true, true), ok(&["elevenlabs"]));
    }

    #[test]
    fn ignores_spaces_empty_entries_and_repeats() {
        assert_eq!(r(Some(" stream , ,elevenlabs,stream,"), true, true), ok(&["stream", "elevenlabs"]));
    }

    #[test]
    fn drops_unconfigured_and_unknown_with_warnings() {
        let a = r(Some("stream,elevenlabs"), true, false);
        assert_eq!(a.backends, vec!["stream"]);
        assert_eq!(a.warnings, vec!["VOICE_BACKENDS lists \"elevenlabs\" but it is not configured; dropped"]);
        let b = r(Some("stream,elevenlabs"), false, true);
        assert_eq!(b.backends, vec!["elevenlabs"]);
        assert_eq!(b.warnings, vec!["VOICE_BACKENDS lists \"stream\" but it is not configured; dropped"]);
        let c = r(Some("livekit,stream"), true, true);
        assert_eq!(c.backends, vec!["stream"]);
        assert_eq!(c.warnings, vec!["VOICE_BACKENDS lists unknown backend \"livekit\"; dropped"]);
        assert_eq!(r(Some("livekit,livekit,stream"), true, true).warnings.len(), 1);
    }

    #[test]
    fn offers_nothing_when_everything_listed_is_dropped() {
        let a = r(Some("livekit"), true, true);
        assert_eq!((a.backends.len(), a.default_backend), (0, None));
        assert_eq!(a.config_json(), json!({"backends": [], "defaultBackend": null}));
        let b = r(Some("elevenlabs"), true, false);
        assert_eq!((b.backends.len(), b.default_backend), (0, None));
    }

    #[test]
    fn reads_the_environment_with_empty_as_unset() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| pairs.iter().find(|(n, v)| *n == k && !v.is_empty()).map(|(_, v)| v.to_string())
        };
        assert_eq!(from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "s"), ("ELEVENLABS_API_KEY", "x")])), ok(&["stream", "elevenlabs"]));
        assert_eq!(from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "s"), ("ELEVENLABS_API_KEY", ""), ("VOICE_BACKENDS", "")])), ok(&["stream"]));
        assert_eq!(from_env(env(&[("LIVEKIT_API_KEY", "k")])), ok(&[]));
        assert_eq!(
            from_env(env(&[("LIVEKIT_API_KEY", "k"), ("LIVEKIT_API_SECRET", "s"), ("ELEVENLABS_API_KEY", "x"), ("VOICE_BACKENDS", "elevenlabs")])),
            ok(&["elevenlabs"])
        );
    }
}
