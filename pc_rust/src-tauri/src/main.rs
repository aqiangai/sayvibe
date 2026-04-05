mod protocol;
mod relay;

use relay::{RelayConfig, RelayService, StatePayload};
use serde_json::json;
use std::sync::Arc;
use tauri::Emitter;

struct AppRelay {
    relay: Arc<RelayService>,
}

#[tauri::command]
async fn get_relay_config(state: tauri::State<'_, AppRelay>) -> Result<RelayConfig, String> {
    Ok(state.relay.config())
}

#[tauri::command]
async fn get_relay_state(state: tauri::State<'_, AppRelay>) -> Result<StatePayload, String> {
    Ok(state.relay.current_state().await)
}

#[tauri::command]
async fn set_auto_ime(enabled: bool, state: tauri::State<'_, AppRelay>) -> Result<bool, String> {
    Ok(state.relay.set_auto_ime(enabled).await)
}

#[tauri::command]
async fn set_auto_ime_mode(
    mode: String,
    state: tauri::State<'_, AppRelay>,
) -> Result<String, String> {
    Ok(state.relay.set_auto_ime_mode(&mode).await)
}

fn main() {
    tracing_subscriber::fmt()
        .with_target(false)
        .compact()
        .init();

    let relay = RelayService::new();
    let relay_for_manage = relay.clone();
    let relay_for_setup = relay.clone();

    tauri::Builder::default()
        .manage(AppRelay {
            relay: relay_for_manage,
        })
        .setup(move |app| {
            let app_handle = app.handle().clone();
            let relay_runner = relay_for_setup.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error) = relay_runner.run().await {
                    let message = format!("桌面端中继启动失败: {error}");
                    let _ = app_handle.emit(
                        "relay://event",
                        json!({
                            "type": "relay_error",
                            "message": message,
                        }),
                    );
                }
            });

            let app_handle = app.handle().clone();
            let relay_events = relay_for_setup.clone();
            tauri::async_runtime::spawn(async move {
                let mut receiver = relay_events.subscribe();
                while let Ok(event) = receiver.recv().await {
                    let _ = app_handle.emit("relay://event", &event.payload);
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_relay_config,
            get_relay_state,
            set_auto_ime,
            set_auto_ime_mode
        ])
        .run(tauri::generate_context!())
        .expect("error while running say vibe desktop");
}
