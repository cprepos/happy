//! `voiceElevenLabsUsageGet.ts`: a user's ElevenLabs usage over 30 days.
//!
//! Upstream's `routes::voice::voice_usage` stops paging at its own 2 h limit, so
//! its totals are lower bounds above that; here the stop is the 5 h limit the
//! grant checks against, so it is not reused.

use crate::app::App;
use crate::fetch;
use crate::js;
use serde_json::Value;
use std::collections::HashSet;
use std::time::Duration;

/// 5 hours absolute cap per 30 days for every account; a cost safety net.
pub const VOICE_HARD_LIMIT_SECONDS: f64 = 18000.0;
/// ElevenLabs' maximum page size, not a conversation quota.
pub const VOICE_USAGE_PAGE_SIZE: u32 = 100;
/// `VOICE_UNLIMITED` (`Number.MAX_SAFE_INTEGER`).
pub const VOICE_UNLIMITED: i64 = 9007199254740991;

/// Pages through the history under one 15 s deadline, stopping once the hard
/// limit is reached. `Err` on a failed request or malformed history, so a caller
/// never acts on partial usage. Returns `(usedSeconds, conversationCount)`.
pub async fn elevenlabs_usage(app: &App, key: &str, eleven_user_id: &str) -> anyhow::Result<(f64, usize)> {
    let since = crate::util::now_ms().div_euclid(1000) - 30 * 86400;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(15);
    let (mut used, mut count) = (0.0f64, 0usize);
    let mut cursor: Option<String> = None;
    let mut seen = HashSet::new();
    loop {
        let mut query = vec![
            ("user_id", eleven_user_id.to_string()),
            ("call_start_after_unix", since.to_string()),
            ("page_size", VOICE_USAGE_PAGE_SIZE.to_string()),
        ];
        if let Some(c) = &cursor {
            query.push(("cursor", c.clone()));
        }
        let qs: Vec<String> = query.iter().map(|(k, v)| format!("{}={}", k, js::form_urlencode(v))).collect();
        let url = format!("{}/conversations?{}", app.config.elevenlabs_api, qs.join("&"));
        let data = tokio::time::timeout_at(deadline, async {
            let res = fetch::CLIENT.get(url).header("xi-api-key", fetch::header_value(key)?).send().await?;
            if !res.status().is_success() {
                anyhow::bail!("ElevenLabs conversations query failed: {}", res.status().as_u16());
            }
            fetch::json(res).await
        })
        .await
        .map_err(|_| anyhow::anyhow!("The operation was aborted due to timeout"))??;
        let (used_page, count_page, has_more) = page(&data)?;
        used += used_page;
        count += count_page;
        if used >= VOICE_HARD_LIMIT_SECONDS || !has_more {
            break;
        }
        match js::get(Some(&data), "next_cursor") {
            Some(Value::String(c)) if !c.is_empty() && !seen.contains(c) => {
                seen.insert(c.clone());
                cursor = Some(c.clone());
            }
            _ => anyhow::bail!("Invalid ElevenLabs conversation history cursor"),
        }
    }
    Ok((used, count))
}

/// One history page: its seconds, its conversation count and `has_more`.
fn page(data: &Value) -> anyhow::Result<(f64, usize, bool)> {
    let (Some(Value::Array(conversations)), Some(Value::Bool(has_more))) = (js::get(Some(data), "conversations"), js::get(Some(data), "has_more")) else {
        anyhow::bail!("Invalid ElevenLabs conversation history");
    };
    let mut used = 0.0;
    for c in conversations {
        if c.is_null() {
            anyhow::bail!("Cannot read properties of null (reading 'call_duration_secs')");
        }
        let duration = match js::get(Some(c), "call_duration_secs") {
            None | Some(Value::Null) => 0.0,
            Some(Value::Number(n)) => js::number_f64(n),
            Some(_) => f64::NAN,
        };
        if !duration.is_finite() || duration < 0.0 {
            anyhow::bail!("Invalid ElevenLabs conversation duration");
        }
        used += duration;
    }
    Ok((used, conversations.len(), *has_more))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sums_a_page_and_treats_missing_durations_as_zero() {
        let (used, n, more) = page(&json!({"conversations": [{"call_duration_secs": 10}, {}, {"call_duration_secs": null}, {"call_duration_secs": 2.5}], "has_more": false})).unwrap();
        assert_eq!((used, n, more), (12.5, 4, false));
    }

    #[test]
    fn rejects_malformed_history() {
        assert!(page(&json!({"conversations": [], "has_more": "no"})).is_err());
        assert!(page(&json!({"has_more": false})).is_err());
        assert!(page(&json!({"conversations": [{"call_duration_secs": -1}], "has_more": false})).is_err());
        assert!(page(&json!({"conversations": [{"call_duration_secs": "5"}], "has_more": false})).is_err());
        assert!(page(&json!({"conversations": [null], "has_more": false})).is_err());
    }
}
