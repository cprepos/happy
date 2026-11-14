//! `voiceConversationCreate.ts` and the recorded-conversation queries of
//! `voiceRoutes.ts` / `voiceStream.ts`.

use sqlx::PgPool;

/// 30 days, the usage window.
pub const USAGE_WINDOW_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// The LiveKit room of a conversation.
pub fn room_name(conversation_id: &str) -> String {
    format!("happy-voice-{}", conversation_id)
}

/// Records a new conversation with a fresh room (`happy-voice-<id>`), so a
/// client retry gets its own room and never joins one minted for someone else.
/// Returns the conversation id and room name. There is no quota.
pub async fn create(pool: &PgPool, account_id: &str, session_id: Option<&str>, language: Option<&str>) -> anyhow::Result<(String, String)> {
    let id = crate::util::uuid_v4();
    let room = room_name(&id);
    sqlx::query(r#"INSERT INTO "VoiceConversation" ("id","accountId","roomName","sessionId","language","createdAt") VALUES ($1,$2,$3,$4,$5,$6)"#)
        .bind(&id)
        .bind(account_id)
        .bind(&room)
        .bind(session_id)
        .bind(language)
        .bind(crate::db::now())
        .execute(pool)
        .await?;
    Ok((id, room))
}

/// Seconds used and conversations started over the last 30 days.
pub async fn usage(pool: &PgPool, account_id: &str) -> anyhow::Result<(i64, i64)> {
    let since = crate::util::ms_to_naive(crate::util::now_ms() - USAGE_WINDOW_MS);
    let (count, sum): (i64, Option<i64>) =
        sqlx::query_as(r#"SELECT COUNT(*), SUM("durationSecs") FROM "VoiceConversation" WHERE "accountId" = $1 AND "createdAt" >= $2"#)
            .bind(account_id)
            .bind(since)
            .fetch_one(pool)
            .await?;
    Ok((sum.unwrap_or(0), count))
}

/// Whether `session_id` is one of the account's sessions.
pub async fn session_owned(pool: &PgPool, account_id: &str, session_id: &str) -> anyhow::Result<bool> {
    let row: Option<(String,)> = sqlx::query_as(r#"SELECT "id" FROM "Session" WHERE "id" = $1 AND "accountId" = $2 LIMIT 1"#)
        .bind(session_id)
        .bind(account_id)
        .fetch_optional(pool)
        .await?;
    Ok(row.is_some())
}

/// Stores how long a stream was ready. Prisma's `update` throws when the row is gone.
pub async fn record_duration(pool: &PgPool, conversation_id: &str, secs: i64) -> anyhow::Result<()> {
    let r = sqlx::query(r#"UPDATE "VoiceConversation" SET "durationSecs" = $2 WHERE "id" = $1"#)
        .bind(conversation_id)
        .bind(secs as i32)
        .execute(pool)
        .await?;
    crate::db::expect_row(r)
}

/// `Math.round(ms / 1000)` for a non-negative duration.
pub fn duration_secs(ready_at_ms: i64, now_ms: i64) -> i64 {
    ((now_ms - ready_at_ms) as f64 / 1000.0 + 0.5).floor() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn room_is_named_after_the_conversation() {
        assert_eq!(room_name("abc"), "happy-voice-abc");
    }

    #[test]
    fn duration_rounds_like_math_round() {
        assert_eq!(duration_secs(0, 499), 0);
        assert_eq!(duration_secs(0, 500), 1);
        assert_eq!(duration_secs(1000, 3400), 2);
        assert_eq!(duration_secs(1000, 3500), 3);
    }
}
