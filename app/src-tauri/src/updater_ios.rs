//! iOS 的更新占位：App Store / 重签名安装的包里没有自更新通道，界面照旧会调这四个命令，
//! 这里给出「去 App Store 或重新签名安装」的结果，而不是让前端报接口 404。

use serde::Serialize;
use std::sync::Arc;
use tauri::{AppHandle, State};

#[derive(Clone, Default, Serialize)]
pub struct Status {
    current: String,
    latest: Option<String>,
    newer: bool,
    notes: String,
    url: String,
    native: bool,
    phase: String,
    downloaded: u64,
    total: Option<u64>,
    error: Option<String>,
}

#[derive(Default)]
pub struct NativeUpdater;

const HINT: &str = "iOS 版没有应用内更新：新版请重新签名安装，或在 App Store / TestFlight 里更新。";

impl NativeUpdater {
    fn status(&self, app: &AppHandle) -> Status {
        Status {
            current: app.package_info().version.to_string(),
            latest: None,
            newer: false,
            notes: HINT.into(),
            url: "https://github.com/tancheng33/tingo/releases".into(),
            native: true,
            phase: "idle".into(),
            ..Default::default()
        }
    }
}

#[tauri::command]
pub fn native_update_status(app: AppHandle, state: State<'_, Arc<NativeUpdater>>) -> Status {
    state.status(&app)
}

#[tauri::command]
pub async fn native_update_check(app: AppHandle, state: State<'_, Arc<NativeUpdater>>) -> Result<Status, String> {
    Ok(state.status(&app))
}

#[tauri::command]
pub async fn native_update_download(_state: State<'_, Arc<NativeUpdater>>) -> Result<Status, String> {
    Err(HINT.into())
}

#[tauri::command]
pub async fn native_update_install(_state: State<'_, Arc<NativeUpdater>>) -> Result<(), String> {
    Err(HINT.into())
}
