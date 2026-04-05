use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct SyncTextMessage {
    pub text: String,
    pub cursor: i64,
    pub timestamp: i64,
    #[serde(rename = "requestId")]
    pub request_id: Option<String>,
}

pub fn parse_client_message(raw: &str) -> Option<SyncTextMessage> {
    let parsed: Value = serde_json::from_str(raw).ok()?;
    let kind = parsed.get("type").and_then(Value::as_str)?;
    if kind != "sync_text" {
        return None;
    }

    let request_id = parsed
        .get("requestId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);

    Some(SyncTextMessage {
        text: stringify_value(parsed.get("text")),
        cursor: number_value(parsed.get("cursor")).unwrap_or(0),
        timestamp: number_value(parsed.get("timestamp")).unwrap_or_else(now_millis),
        request_id,
    })
}

fn stringify_value(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Null) | None => String::new(),
        Some(other) => other.to_string(),
    }
}

fn number_value(value: Option<&Value>) -> Option<i64> {
    match value {
        Some(Value::Number(number)) => {
            if let Some(value) = number.as_i64() {
                Some(value)
            } else {
                number.as_u64().and_then(|value| i64::try_from(value).ok())
            }
        }
        Some(Value::String(text)) => text.trim().parse().ok(),
        _ => None,
    }
}

fn now_millis() -> i64 {
    let now = std::time::SystemTime::now();
    let delta = now
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_else(|_| std::time::Duration::from_millis(0));
    i64::try_from(delta.as_millis()).unwrap_or(i64::MAX)
}
