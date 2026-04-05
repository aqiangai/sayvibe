use crate::protocol::{parse_client_message, SyncTextMessage};
use arboard::Clipboard;
use axum::{
    body::Bytes,
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive},
        IntoResponse, Response, Sse,
    },
    routing::{get, post},
    Json, Router,
};
use futures_util::{stream, SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    convert::Infallible,
    env,
    net::IpAddr,
    process::Stdio,
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::TcpListener,
    process::Command,
    sync::{broadcast, Mutex, RwLock},
};
use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};
use tracing::{error, info, warn};

#[cfg(target_os = "macos")]
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, KeyCode};
#[cfg(target_os = "macos")]
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
#[cfg(target_os = "macos")]
use macos_accessibility_client::accessibility::{
    application_is_trusted as mac_application_is_trusted,
    application_is_trusted_with_prompt as mac_application_is_trusted_with_prompt,
};

const DEFAULT_PORT: u16 = 18700;
const AUTO_IME_DEBOUNCE_MS: u64 = 220;
#[cfg(target_os = "macos")]
const MAC_CLIPBOARD_SETTLE_DELAY_MS: u64 = 90;
#[cfg(target_os = "macos")]
const MAC_SHORTCUT_STEP_DELAY_MS: u64 = 90;
#[cfg(target_os = "macos")]
const MAC_KEY_EVENT_GAP_MS: u64 = 12;
#[cfg(target_os = "macos")]
const MAC_CLIPBOARD_POLL_DELAY_MS: u64 = 40;
#[cfg(target_os = "macos")]
const MAC_CLIPBOARD_TIMEOUT_MS: u64 = 1600;
#[cfg(target_os = "macos")]
const MAC_ACCESSIBILITY_SETTINGS_URL: &str =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

#[derive(Clone)]
pub struct RelayService {
    port: u16,
    runtime: AutoImeRuntime,
    shared: Arc<SharedState>,
}

struct SharedState {
    inner: RwLock<RuntimeState>,
    auto_ime_lock: Mutex<()>,
    events: broadcast::Sender<ServerEvent>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RelayConfig {
    #[serde(rename = "port")]
    pub port: u16,
    #[serde(rename = "baseUrl")]
    pub base_url: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ServerEvent {
    pub name: &'static str,
    pub payload: Value,
}

#[derive(Debug, Clone)]
struct RuntimeState {
    latest_text: String,
    latest_timestamp: i64,
    sync_count: u64,
    last_sync_length: usize,
    android_online_count: usize,
    last_push_source: Option<PushSource>,
    auto_ime_enabled: bool,
    auto_ime_mode: AutoImeMode,
    auto_ime_revision: u64,
}

#[derive(Debug, Clone)]
struct AutoImeRuntime {
    supported: bool,
    platform: String,
    platform_label: String,
    shortcut_label: String,
    hint: String,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum AutoImeMode {
    Review,
    Send,
}

impl AutoImeMode {
    fn from_raw(raw: &str) -> Self {
        match raw {
            "send" => Self::Send,
            _ => Self::Review,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Review => "review",
            Self::Send => "send",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum PushSource {
    Mobile,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatePayload {
    auto_ime_enabled: bool,
    auto_ime_supported: bool,
    auto_ime_mode: AutoImeMode,
    auto_ime_platform: String,
    auto_ime_platform_label: String,
    auto_ime_shortcut_label: String,
    auto_ime_hint: String,
    latest_text: String,
    latest_timestamp: i64,
    sync_count: u64,
    last_sync_length: usize,
    android_online_count: usize,
    last_push_source: Option<PushSource>,
    lan_ips: Vec<String>,
}

impl RelayService {
    pub fn new() -> Arc<Self> {
        let runtime = detect_auto_ime_runtime();
        let (events, _) = broadcast::channel(128);

        Arc::new(Self {
            port: resolve_server_port(),
            runtime: runtime.clone(),
            shared: Arc::new(SharedState {
                inner: RwLock::new(RuntimeState {
                    latest_text: String::new(),
                    latest_timestamp: 0,
                    sync_count: 0,
                    last_sync_length: 0,
                    android_online_count: 0,
                    last_push_source: None,
                    auto_ime_enabled: runtime.supported,
                    auto_ime_mode: AutoImeMode::Review,
                    auto_ime_revision: 0,
                }),
                auto_ime_lock: Mutex::new(()),
                events,
            }),
        })
    }

    pub fn config(&self) -> RelayConfig {
        RelayConfig {
            port: self.port,
            base_url: format!("http://127.0.0.1:{}", self.port),
        }
    }

    pub fn subscribe(&self) -> broadcast::Receiver<ServerEvent> {
        self.shared.events.subscribe()
    }

    pub async fn current_state(&self) -> StatePayload {
        let state = self.shared.inner.read().await;
        self.build_state_payload(&state)
    }

    pub async fn set_auto_ime(&self, enabled: bool) -> bool {
        self.set_auto_ime_enabled(enabled).await
    }

    pub async fn set_auto_ime_mode(&self, mode: &str) -> String {
        let actual = self
            .set_auto_ime_mode_inner(AutoImeMode::from_raw(mode))
            .await;
        actual.as_str().to_owned()
    }

    pub async fn trigger_pc_enter(&self) -> Result<String, String> {
        if !self.runtime.supported {
            return Err(self.runtime.hint.clone());
        }

        let _auto_ime_guard = self.shared.auto_ime_lock.lock().await;
        run_pc_enter(self.runtime.clone()).await
    }

    pub async fn run(self: Arc<Self>) -> std::io::Result<()> {
        let listener = TcpListener::bind(("0.0.0.0", self.port)).await?;

        let app = Router::new()
            .route("/health", get(health_handler))
            .route("/events", get(events_handler))
            .route("/dashboard", get(dashboard_ws_handler))
            .route("/android", get(android_ws_handler))
            .route("/api/state", get(state_handler))
            .route("/api/push_text", post(push_text_handler))
            .route("/api/control/auto-ime", post(control_auto_ime_handler))
            .route("/api/control/pc-enter", post(control_pc_enter_handler))
            .route(
                "/api/control/auto-ime-mode",
                post(control_auto_ime_mode_handler),
            )
            .with_state(self.clone());

        info!("say vibe relay started on {}", self.config().base_url);

        let lan_ips = detect_lan_ipv4_addresses();
        if lan_ips.is_empty() {
            info!("LAN IPv4: (none found)");
        } else {
            info!("LAN IPv4: {}", lan_ips.join(", "));
        }

        if self.runtime.supported {
            info!(
                "Auto-IME: {} ({})",
                self.runtime.platform_label, self.runtime.shortcut_label
            );
        } else {
            info!("Auto-IME: {}", self.runtime.hint);
        }

        axum::serve(listener, app).await
    }

    async fn update_android_online_count(&self, delta: isize) {
        let count = {
            let mut state = self.shared.inner.write().await;
            if delta >= 0 {
                state.android_online_count =
                    state.android_online_count.saturating_add(delta as usize);
            } else {
                state.android_online_count = state
                    .android_online_count
                    .saturating_sub(delta.unsigned_abs());
            }
            state.android_online_count
        };

        self.broadcast(
            "android_state",
            json!({
                "type": "android_state",
                "connected": count > 0,
                "count": count,
            }),
        );

        self.broadcast_state().await;
    }

    async fn on_sync_text(&self, message: SyncTextMessage, source: PushSource) {
        let (text, timestamp, sync_count, length, revision) = {
            let mut state = self.shared.inner.write().await;
            state.latest_text = message.text;
            state.latest_timestamp = message.timestamp;
            state.sync_count = state.sync_count.saturating_add(1);
            state.last_sync_length = state.latest_text.chars().count();
            state.last_push_source = Some(source);
            state.auto_ime_revision = state.auto_ime_revision.saturating_add(1);

            (
                state.latest_text.clone(),
                state.latest_timestamp,
                state.sync_count,
                state.last_sync_length,
                state.auto_ime_revision,
            )
        };

        info!(
            "sync_text source=mobile count={sync_count} len={length} cursor={}",
            message.cursor
        );

        self.broadcast(
            "sync_text",
            json!({
                "type": "sync_text",
                "source": source,
                "text": text.clone(),
                "timestamp": timestamp,
                "syncCount": sync_count,
                "length": length,
            }),
        );

        if let Err(error) = write_desktop_clipboard(text.clone()).await {
            warn!("failed to sync latest text to system clipboard: {error}");
        }

        self.maybe_run_auto_ime(revision).await;
    }

    async fn maybe_run_auto_ime(&self, revision: u64) {
        let auto_ime_enabled = {
            let state = self.shared.inner.read().await;
            state.auto_ime_enabled
        };

        if !auto_ime_enabled {
            return;
        }

        let runtime = self.runtime.clone();
        let sender = self.shared.events.clone();
        let shared = self.shared.clone();

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(AUTO_IME_DEBOUNCE_MS)).await;

            let _auto_ime_guard = shared.auto_ime_lock.lock().await;
            let (auto_ime_enabled, auto_ime_mode, text, current_revision) = {
                let state = shared.inner.read().await;
                (
                    state.auto_ime_enabled,
                    state.auto_ime_mode,
                    state.latest_text.clone(),
                    state.auto_ime_revision,
                )
            };

            if !auto_ime_enabled || text.is_empty() || current_revision != revision {
                return;
            }

            match run_auto_ime(runtime, text, auto_ime_mode).await {
                Ok(message) => {
                    let _ = sender.send(ServerEvent {
                        name: "auto_ime_info",
                        payload: json!({
                            "type": "auto_ime_info",
                            "message": message,
                        }),
                    });
                }
                Err(error_message) => {
                    let _ = sender.send(ServerEvent {
                        name: "auto_ime_error",
                        payload: json!({
                            "type": "auto_ime_error",
                            "message": error_message,
                        }),
                    });
                }
            }
        });
    }

    async fn set_auto_ime_enabled(&self, enabled: bool) -> bool {
        if !self.runtime.supported {
            {
                let mut state = self.shared.inner.write().await;
                state.auto_ime_enabled = false;
            }

            self.broadcast(
                "auto_ime_error",
                json!({
                    "type": "auto_ime_error",
                    "message": self.runtime.hint,
                }),
            );

            self.broadcast(
                "auto_ime_changed",
                json!({
                    "type": "auto_ime_changed",
                    "enabled": false,
                }),
            );

            self.broadcast_state().await;
            return false;
        }

        #[cfg(target_os = "macos")]
        if enabled {
            if let Err(message) = maybe_prompt_mac_accessibility_access().await {
                self.broadcast(
                    "auto_ime_error",
                    json!({
                        "type": "auto_ime_error",
                        "message": message,
                    }),
                );
            }
        }

        {
            let mut state = self.shared.inner.write().await;
            state.auto_ime_enabled = enabled;
        }

        self.broadcast(
            "auto_ime_changed",
            json!({
                "type": "auto_ime_changed",
                "enabled": enabled,
            }),
        );

        self.broadcast_state().await;
        enabled
    }

    async fn set_auto_ime_mode_inner(&self, mode: AutoImeMode) -> AutoImeMode {
        {
            let mut state = self.shared.inner.write().await;
            state.auto_ime_mode = mode;
        }

        self.broadcast(
            "auto_ime_mode_changed",
            json!({
                "type": "auto_ime_mode_changed",
                "mode": mode,
            }),
        );

        self.broadcast_state().await;
        mode
    }

    async fn broadcast_state(&self) {
        let payload = self.state_event_payload("state").await;
        let _ = self.shared.events.send(ServerEvent {
            name: "state",
            payload,
        });
    }

    async fn state_event_payload(&self, event_type: &'static str) -> Value {
        let state = self.current_state().await;
        let mut payload = serde_json::to_value(state).unwrap_or_else(|_| json!({}));

        if let Value::Object(map) = &mut payload {
            map.insert("type".to_owned(), Value::String(event_type.to_owned()));
        }

        payload
    }

    fn broadcast(&self, name: &'static str, payload: Value) {
        if let Err(error) = self.shared.events.send(ServerEvent { name, payload }) {
            error!("failed to broadcast {name}: {error}");
        }
    }

    fn build_state_payload(&self, state: &RuntimeState) -> StatePayload {
        StatePayload {
            auto_ime_enabled: state.auto_ime_enabled,
            auto_ime_supported: self.runtime.supported,
            auto_ime_mode: state.auto_ime_mode,
            auto_ime_platform: self.runtime.platform.clone(),
            auto_ime_platform_label: self.runtime.platform_label.clone(),
            auto_ime_shortcut_label: self.runtime.shortcut_label.clone(),
            auto_ime_hint: current_auto_ime_hint(&self.runtime),
            latest_text: state.latest_text.clone(),
            latest_timestamp: state.latest_timestamp,
            sync_count: state.sync_count,
            last_sync_length: state.last_sync_length,
            android_online_count: state.android_online_count,
            last_push_source: state.last_push_source,
            lan_ips: detect_lan_ipv4_addresses(),
        }
    }
}

async fn health_handler() -> &'static str {
    "ok"
}

async fn state_handler(State(relay): State<Arc<RelayService>>) -> Json<StatePayload> {
    Json(relay.current_state().await)
}

async fn push_text_handler(State(relay): State<Arc<RelayService>>, body: Bytes) -> Response {
    let raw = String::from_utf8_lossy(&body);
    let Some(message) = parse_client_message(&raw) else {
        return json_error(StatusCode::BAD_REQUEST, "invalid payload");
    };

    relay.on_sync_text(message, PushSource::Mobile).await;
    Json(json!({ "ok": true, "timestamp": now_millis() })).into_response()
}

async fn control_auto_ime_handler(State(relay): State<Arc<RelayService>>, body: Bytes) -> Response {
    let parsed: Value = match serde_json::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(_) => return json_error(StatusCode::BAD_REQUEST, "invalid json"),
    };

    let enabled = parsed
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let actual = relay.set_auto_ime_enabled(enabled).await;
    Json(json!({ "ok": true, "enabled": actual })).into_response()
}

async fn control_auto_ime_mode_handler(
    State(relay): State<Arc<RelayService>>,
    body: Bytes,
) -> Response {
    let parsed: Value = match serde_json::from_slice(&body) {
        Ok(parsed) => parsed,
        Err(_) => return json_error(StatusCode::BAD_REQUEST, "invalid json"),
    };

    let mode = parsed
        .get("mode")
        .and_then(Value::as_str)
        .unwrap_or("review");

    let actual = relay.set_auto_ime_mode(mode).await;
    Json(json!({ "ok": true, "mode": actual })).into_response()
}

async fn control_pc_enter_handler(State(relay): State<Arc<RelayService>>) -> Response {
    match relay.trigger_pc_enter().await {
        Ok(message) => {
            relay.broadcast(
                "auto_ime_info",
                json!({
                    "type": "auto_ime_info",
                    "message": message,
                }),
            );
            Json(json!({ "ok": true })).into_response()
        }
        Err(message) => {
            relay.broadcast(
                "auto_ime_error",
                json!({
                    "type": "auto_ime_error",
                    "message": message.clone(),
                }),
            );
            json_error(StatusCode::INTERNAL_SERVER_ERROR, &message)
        }
    }
}

async fn events_handler(
    State(relay): State<Arc<RelayService>>,
) -> Sse<impl futures_util::stream::Stream<Item = Result<Event, Infallible>>> {
    let init_payload = relay.state_event_payload("init").await;
    let init = stream::once(async move {
        Ok::<Event, Infallible>(
            Event::default()
                .event("init")
                .data(init_payload.to_string()),
        )
    });

    let updates = BroadcastStream::new(relay.subscribe()).filter_map(|event| async move {
        match event {
            Ok(event) => Some(Ok(Event::default()
                .event(event.name)
                .data(event.payload.to_string()))),
            Err(BroadcastStreamRecvError::Lagged(skipped)) => {
                warn!("sse receiver lagged, skipped {skipped} events");
                None
            }
        }
    });

    Sse::new(init.chain(updates)).keep_alive(
        KeepAlive::new()
            .interval(Duration::from_secs(15))
            .text("keepalive"),
    )
}

async fn dashboard_ws_handler(
    ws: WebSocketUpgrade,
    State(relay): State<Arc<RelayService>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_dashboard_socket(socket, relay))
}

async fn handle_dashboard_socket(socket: WebSocket, relay: Arc<RelayService>) {
    let (mut sender, mut receiver) = socket.split();

    let init_payload = relay.state_event_payload("init").await;
    if sender
        .send(Message::Text(init_payload.to_string().into()))
        .await
        .is_err()
    {
        return;
    }

    let mut updates = relay.subscribe();

    loop {
        tokio::select! {
            incoming = receiver.next() => {
                let Some(incoming) = incoming else {
                    break;
                };

                match incoming {
                    Ok(Message::Text(text)) => {
                        handle_dashboard_control(&relay, text.as_ref()).await;
                    }
                    Ok(Message::Ping(payload)) => {
                        if sender.send(Message::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    Ok(Message::Close(_)) => break,
                    Ok(_) => {}
                    Err(error) => {
                        warn!("dashboard websocket closed with error: {error}");
                        break;
                    }
                }
            }
            outgoing = updates.recv() => {
                match outgoing {
                    Ok(event) => {
                        if sender.send(Message::Text(event.payload.to_string().into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        warn!("dashboard websocket lagged, skipped {skipped} events");
                        let payload = relay.state_event_payload("state").await;
                        if sender.send(Message::Text(payload.to_string().into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
}

async fn handle_dashboard_control(relay: &RelayService, raw: &str) {
    let Ok(payload) = serde_json::from_str::<Value>(raw) else {
        return;
    };

    match payload.get("type").and_then(Value::as_str) {
        Some("set_auto_ime") => {
            let enabled = payload
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let _ = relay.set_auto_ime_enabled(enabled).await;
        }
        Some("set_auto_ime_mode") => {
            let mode = payload
                .get("mode")
                .and_then(Value::as_str)
                .unwrap_or("review");
            let _ = relay.set_auto_ime_mode(mode).await;
        }
        _ => {}
    }
}

async fn android_ws_handler(
    ws: WebSocketUpgrade,
    State(relay): State<Arc<RelayService>>,
) -> impl IntoResponse {
    ws.on_upgrade(move |socket| handle_android_socket(socket, relay))
}

async fn handle_android_socket(mut socket: WebSocket, relay: Arc<RelayService>) {
    relay.update_android_online_count(1).await;

    let ack = json!({
        "type": "ack",
        "message": "android connected",
    })
    .to_string();

    if socket.send(Message::Text(ack.into())).await.is_err() {
        relay.update_android_online_count(-1).await;
        return;
    }

    while let Some(incoming) = socket.next().await {
        match incoming {
            Ok(Message::Text(text)) => {
                let Some(message) = parse_client_message(text.as_ref()) else {
                    let payload = json!({
                        "type": "error",
                        "message": "invalid payload",
                    })
                    .to_string();

                    if socket.send(Message::Text(payload.into())).await.is_err() {
                        break;
                    }
                    continue;
                };

                let request_id = message.request_id.clone().unwrap_or_default();
                relay.on_sync_text(message, PushSource::Mobile).await;

                let payload = json!({
                    "type": "sync_ack",
                    "requestId": request_id,
                    "timestamp": now_millis(),
                })
                .to_string();

                if socket.send(Message::Text(payload.into())).await.is_err() {
                    break;
                }
            }
            Ok(Message::Ping(payload)) => {
                if socket.send(Message::Pong(payload)).await.is_err() {
                    break;
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(error) => {
                warn!("android websocket closed with error: {error}");
                break;
            }
        }
    }

    relay.update_android_online_count(-1).await;
}

async fn run_auto_ime(
    runtime: AutoImeRuntime,
    text: String,
    mode: AutoImeMode,
) -> Result<String, String> {
    match runtime.platform.as_str() {
        "win32" => run_windows_auto_ime(text, mode).await,
        "darwin" => run_mac_auto_ime(text, mode).await,
        _ => Ok("当前平台未执行自动输出".to_owned()),
    }
}

async fn run_pc_enter(runtime: AutoImeRuntime) -> Result<String, String> {
    match runtime.platform.as_str() {
        "win32" => run_windows_enter().await,
        "darwin" => run_mac_enter().await,
        _ => Err("当前平台暂不支持 PC Enter".to_owned()),
    }
}

async fn run_windows_enter() -> Result<String, String> {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.SendKeys]::SendWait(\"{ENTER}\")",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|error| format!("PC Enter 失败，请确认目标输入框有焦点: {error}"))?;

    if output.status.success() {
        Ok("PC Enter 已执行".to_owned())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if stderr.is_empty() {
            Err("PC Enter 失败，请确认目标输入框有焦点".to_owned())
        } else {
            Err(format!("PC Enter 失败，请确认目标输入框有焦点: {stderr}"))
        }
    }
}

async fn run_windows_auto_ime(text: String, mode: AutoImeMode) -> Result<String, String> {
    let escaped = text.replace('\'', "''");
    let enter_step = if mode == AutoImeMode::Send {
        r#" Start-Sleep -Milliseconds 30; [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")"#
    } else {
        ""
    };
    let script = format!(
        "Add-Type -AssemblyName System.Windows.Forms; \
         $t = '{escaped}'; \
         Set-Clipboard -Value $t; \
         Start-Sleep -Milliseconds 30; \
         [System.Windows.Forms.SendKeys]::SendWait(\"^a\"); \
         Start-Sleep -Milliseconds 30; \
         [System.Windows.Forms.SendKeys]::SendWait(\"^v\");\
         {enter_step}"
    );

    let output = Command::new("powershell")
        .args(["-NoProfile", "-Command", &script])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|error| format!("自动输出失败，请确认目标输入框有焦点: {error}"))?;

    if output.status.success() {
        Ok("Windows 自动输出已执行".to_owned())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if stderr.is_empty() {
            Err("自动输出失败，请确认目标输入框有焦点".to_owned())
        } else {
            Err(format!("自动输出失败，请确认目标输入框有焦点: {stderr}"))
        }
    }
}

async fn run_mac_auto_ime(text: String, mode: AutoImeMode) -> Result<String, String> {
    write_desktop_clipboard(text.clone()).await?;
    wait_for_mac_clipboard(&text).await?;
    tokio::time::sleep(Duration::from_millis(MAC_CLIPBOARD_SETTLE_DELAY_MS)).await;
    match run_mac_keystroke_sequence(mode).await {
        Ok(()) => return Ok("macOS 自动输出已执行，引擎：native".to_owned()),
        Err(native_error) => {
            tokio::time::sleep(Duration::from_millis(MAC_SHORTCUT_STEP_DELAY_MS)).await;

            match run_mac_system_events_sequence(mode).await {
                Ok(()) => return Ok("macOS 自动输出已执行，引擎：system_events".to_owned()),
                Err(system_events_error) => {
                    return Err(format!(
                        "自动输出失败，原生按键与 System Events 都未生效。native: {native_error}；system_events: {system_events_error}"
                    ));
                }
            }
        }
    }
}

async fn run_mac_enter() -> Result<String, String> {
    ensure_mac_accessibility_ready(false).await?;

    match tap_mac_key(KeyCode::RETURN) {
        Ok(()) => Ok("PC Enter 已执行".to_owned()),
        Err(native_error) => run_mac_system_events_enter().await.map_err(|system_events_error| {
            format!(
                "PC Enter 失败，原生回车失败（{native_error}），System Events 回车也失败（{system_events_error}）"
            )
        }),
    }
}

#[cfg(target_os = "macos")]
async fn wait_for_mac_clipboard(expected_text: &str) -> Result<(), String> {
    let mut waited_ms = 0;

    while waited_ms <= MAC_CLIPBOARD_TIMEOUT_MS {
        if let Ok(current) = read_desktop_clipboard().await {
            if current == expected_text {
                return Ok(());
            }
        }

        tokio::time::sleep(Duration::from_millis(MAC_CLIPBOARD_POLL_DELAY_MS)).await;
        waited_ms += MAC_CLIPBOARD_POLL_DELAY_MS;
    }

    Err("写入剪贴板超时，系统尚未切换到最新同步文本。".to_owned())
}

#[cfg(target_os = "macos")]
async fn run_mac_keystroke_sequence(mode: AutoImeMode) -> Result<(), String> {
    ensure_mac_accessibility_ready(false).await?;
    tap_mac_modified_key(
        KeyCode::ANSI_A,
        KeyCode::COMMAND,
        CGEventFlags::CGEventFlagCommand,
    )?;
    tokio::time::sleep(Duration::from_millis(MAC_SHORTCUT_STEP_DELAY_MS)).await;
    tap_mac_modified_key(
        KeyCode::ANSI_V,
        KeyCode::COMMAND,
        CGEventFlags::CGEventFlagCommand,
    )?;

    if mode == AutoImeMode::Send {
        tokio::time::sleep(Duration::from_millis(MAC_SHORTCUT_STEP_DELAY_MS)).await;
        tap_mac_key(KeyCode::RETURN)?;
    }

    Ok(())
}

#[cfg(not(target_os = "macos"))]
async fn run_mac_keystroke_sequence(_: AutoImeMode) -> Result<(), String> {
    Err("自动输出失败，当前系统不支持 macOS 自动输出".to_owned())
}

#[cfg(target_os = "macos")]
async fn run_mac_system_events_sequence(mode: AutoImeMode) -> Result<(), String> {
    let mut command = Command::new("/usr/bin/osascript");
    command
        .args([
            "-e",
            r#"tell application "System Events""#,
            "-e",
            r#"keystroke "a" using {command down}"#,
            "-e",
            "delay 0.09",
            "-e",
            r#"keystroke "v" using {command down}"#,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());

    if mode == AutoImeMode::Send {
        command.args(["-e", "delay 0.09", "-e", "key code 36"]);
    }

    let output = command
        .args(["-e", "end tell"])
        .output()
        .await
        .map_err(|error| {
            format!(
                "System Events 自动输出失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点: {error}"
            )
        })?;

    if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if stderr.contains("1743")
            || stderr.contains("not authorized")
            || stderr.contains("不允许")
            || stderr.contains("未获得授权")
        {
            return Err(
                "System Events 自动输出失败，请在“系统设置 -> 隐私与安全性 -> 自动化”里允许 say vibe 控制 System Events。"
                    .to_owned(),
            );
        }

        if stderr.is_empty() {
            Err(
                "System Events 自动输出失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点"
                    .to_owned(),
            )
        } else {
            Err(format!(
                "System Events 自动输出失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点: {stderr}"
            ))
        }
    }
}

#[cfg(target_os = "macos")]
async fn run_mac_system_events_enter() -> Result<String, String> {
    let output = Command::new("/usr/bin/osascript")
        .args([
            "-e",
            r#"tell application "System Events""#,
            "-e",
            "key code 36",
            "-e",
            "end tell",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|error| {
            format!(
                "System Events 回车失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点: {error}"
            )
        })?;

    if output.status.success() {
        Ok("PC Enter 已执行".to_owned())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        if stderr.contains("1743")
            || stderr.contains("not authorized")
            || stderr.contains("不允许")
            || stderr.contains("未获得授权")
        {
            return Err(
                "System Events 回车失败，请在“系统设置 -> 隐私与安全性 -> 自动化”里允许 say vibe 控制 System Events。"
                    .to_owned(),
            );
        }

        if stderr.is_empty() {
            Err(
                "System Events 回车失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点"
                    .to_owned(),
            )
        } else {
            Err(format!(
                "System Events 回车失败，请给 say vibe 开启辅助功能和自动化权限，并确认目标输入框有焦点: {stderr}"
            ))
        }
    }
}

#[cfg(not(target_os = "macos"))]
async fn run_mac_system_events_sequence(_: AutoImeMode) -> Result<(), String> {
    Err("自动输出失败，当前系统不支持 macOS System Events 输出".to_owned())
}

#[cfg(not(target_os = "macos"))]
async fn run_mac_system_events_enter() -> Result<String, String> {
    Err("当前系统不支持 macOS System Events 回车".to_owned())
}

#[cfg(target_os = "macos")]
fn tap_mac_key(keycode: u16) -> Result<(), String> {
    let source = create_mac_event_source()?;
    let key_down = build_mac_key_event(&source, keycode, true, CGEventFlags::empty())?;
    let key_up = build_mac_key_event(&source, keycode, false, CGEventFlags::empty())?;

    key_down.post(CGEventTapLocation::HID);
    std::thread::sleep(Duration::from_millis(MAC_KEY_EVENT_GAP_MS));
    key_up.post(CGEventTapLocation::HID);
    Ok(())
}

#[cfg(target_os = "macos")]
fn tap_mac_modified_key(
    keycode: u16,
    modifier_keycode: u16,
    flags: CGEventFlags,
) -> Result<(), String> {
    let source = create_mac_event_source()?;
    let modifier_down = build_mac_key_event(&source, modifier_keycode, true, flags)?;
    let key_down = build_mac_key_event(&source, keycode, true, flags)?;
    let key_up = build_mac_key_event(&source, keycode, false, flags)?;
    let modifier_up = build_mac_key_event(&source, modifier_keycode, false, CGEventFlags::empty())?;

    modifier_down.post(CGEventTapLocation::HID);
    std::thread::sleep(Duration::from_millis(MAC_KEY_EVENT_GAP_MS));
    key_down.post(CGEventTapLocation::HID);
    std::thread::sleep(Duration::from_millis(MAC_KEY_EVENT_GAP_MS));
    key_up.post(CGEventTapLocation::HID);
    std::thread::sleep(Duration::from_millis(MAC_KEY_EVENT_GAP_MS));
    modifier_up.post(CGEventTapLocation::HID);
    Ok(())
}

#[cfg(target_os = "macos")]
fn create_mac_event_source() -> Result<CGEventSource, String> {
    CGEventSource::new(CGEventSourceStateID::CombinedSessionState).map_err(|_| {
        "自动输出失败，请给 say vibe 开启辅助功能权限，并确认目标输入框有焦点".to_owned()
    })
}

#[cfg(target_os = "macos")]
fn build_mac_key_event(
    source: &CGEventSource,
    keycode: u16,
    keydown: bool,
    flags: CGEventFlags,
) -> Result<CGEvent, String> {
    let event = CGEvent::new_keyboard_event(source.clone(), keycode, keydown).map_err(|_| {
        "自动输出失败，请给 say vibe 开启辅助功能权限，并确认目标输入框有焦点".to_owned()
    })?;
    event.set_flags(flags);
    Ok(event)
}

fn current_auto_ime_hint(runtime: &AutoImeRuntime) -> String {
    match runtime.platform.as_str() {
        "darwin" => mac_accessibility_hint(),
        _ => runtime.hint.clone(),
    }
}

async fn write_desktop_clipboard(text: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut clipboard =
            Clipboard::new().map_err(|error| format!("初始化系统剪贴板失败: {error}"))?;
        clipboard
            .set_text(text)
            .map_err(|error| format!("写入系统剪贴板失败: {error}"))
    })
    .await
    .map_err(|error| format!("写入系统剪贴板任务失败: {error}"))?
}

async fn read_desktop_clipboard() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let mut clipboard =
            Clipboard::new().map_err(|error| format!("初始化系统剪贴板失败: {error}"))?;
        clipboard
            .get_text()
            .map_err(|error| format!("读取系统剪贴板失败: {error}"))
    })
    .await
    .map_err(|error| format!("读取系统剪贴板任务失败: {error}"))?
}

#[cfg(target_os = "macos")]
fn mac_accessibility_hint() -> String {
    if mac_application_is_trusted() {
        "输入前请把目标应用输入框置于焦点。若使用 build 版，请确认授权对象是 say vibe.app。"
            .to_owned()
    } else {
        "当前 say vibe 还没有辅助功能权限。请在“系统设置 -> 隐私与安全性 -> 辅助功能”里允许 say vibe.app；如果是 tauri dev，授权对象则是 Terminal / iTerm。"
            .to_owned()
    }
}

#[cfg(not(target_os = "macos"))]
fn mac_accessibility_hint() -> String {
    "输入前请把目标应用输入框置于焦点。".to_owned()
}

#[cfg(target_os = "macos")]
fn mac_accessibility_permission_message() -> String {
    "自动输出失败，当前 say vibe 还没有辅助功能权限。请在“系统设置 -> 隐私与安全性 -> 辅助功能”里允许 say vibe.app；如果是 tauri dev，授权对象则是 Terminal / iTerm。"
        .to_owned()
}

#[cfg(target_os = "macos")]
async fn ensure_mac_accessibility_ready(prompt: bool) -> Result<(), String> {
    let trusted = if prompt {
        if mac_application_is_trusted() {
            true
        } else {
            mac_application_is_trusted_with_prompt()
        }
    } else {
        mac_application_is_trusted()
    };

    if trusted {
        return Ok(());
    }

    Err(mac_accessibility_permission_message())
}

#[cfg(target_os = "macos")]
async fn maybe_prompt_mac_accessibility_access() -> Result<(), String> {
    if ensure_mac_accessibility_ready(true).await.is_ok() {
        return Ok(());
    }

    let _ = Command::new("/usr/bin/open")
        .arg(MAC_ACCESSIBILITY_SETTINGS_URL)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    Err(format!(
        "{} 已尝试打开系统设置。",
        mac_accessibility_permission_message()
    ))
}

fn detect_auto_ime_runtime() -> AutoImeRuntime {
    match env::consts::OS {
        "windows" => AutoImeRuntime {
            supported: true,
            platform: "win32".to_owned(),
            platform_label: "Windows".to_owned(),
            shortcut_label: "Ctrl+A, Ctrl+V".to_owned(),
            hint: "输入前请把目标应用输入框置于焦点。".to_owned(),
        },
        "macos" => AutoImeRuntime {
            supported: true,
            platform: "darwin".to_owned(),
            platform_label: "macOS".to_owned(),
            shortcut_label: "Command+A, Command+V".to_owned(),
            hint: "输入前请把目标应用输入框置于焦点。首次使用需允许 say vibe 的辅助功能权限。"
                .to_owned(),
        },
        other => AutoImeRuntime {
            supported: false,
            platform: other.to_owned(),
            platform_label: other.to_owned(),
            shortcut_label: "不支持".to_owned(),
            hint: format!("当前系统 ({other}) 暂不支持自动输出，仅可查看同步文本。"),
        },
    }
}

fn detect_lan_ipv4_addresses() -> Vec<String> {
    let interfaces = match if_addrs::get_if_addrs() {
        Ok(interfaces) => interfaces,
        Err(error) => {
            warn!("failed to enumerate network interfaces: {error}");
            return Vec::new();
        }
    };

    let mut ips: Vec<String> = interfaces
        .into_iter()
        .filter_map(|interface| match interface.ip() {
            IpAddr::V4(address) if !address.is_loopback() => Some(address.to_string()),
            _ => None,
        })
        .collect();

    ips.sort();
    ips.dedup();
    ips
}

fn resolve_server_port() -> u16 {
    let Ok(raw) = env::var("PORT") else {
        return DEFAULT_PORT;
    };

    match raw.parse::<u16>() {
        Ok(port) if port > 0 => port,
        _ => {
            warn!("invalid PORT={raw}, fallback to {DEFAULT_PORT}");
            DEFAULT_PORT
        }
    }
}

fn json_error(status: StatusCode, error_message: &str) -> Response {
    (
        status,
        Json(json!({
            "ok": false,
            "error": error_message,
        })),
    )
        .into_response()
}

fn now_millis() -> i64 {
    let delta = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_millis(0));
    i64::try_from(delta.as_millis()).unwrap_or(i64::MAX)
}
