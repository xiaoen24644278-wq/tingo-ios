//! Tingo 听过 外壳（macOS + iOS）。
//!
//! 后端（识别、录音、纪要、本地接口）由 tingo-engine 提供，直接在 App 进程里起一个只监听
//! 127.0.0.1 的 HTTP 服务，界面通过 `backend_url` 拿到地址。不需要 Python 和 ffmpeg。
//!
//! 两个平台共用同一套 engine 和同一份前端产物，差别只在系统集成：
//!
//! | | macOS | iOS |
//! |---|---|---|
//! | 录音 | 打包的 `tingo-recorder` 子进程（ScreenCaptureKit + AVFoundation） | 进程内 `TingoAudio.swift`（AVAudioEngine），只能录麦克风 |
//! | 会议目录 | `~/Documents/Tingo` | 沙盒 `Documents/Tingo`（「文件」App 里可见） |
//! | 配置 | `~/.config/tingo/config.toml` | 沙盒 `~/.config/tingo/config.toml` |
//! | 识别模型 | App 数据目录 `models/`，首次在界面里下载 | 同上 |
//! | 更新 | tauri-plugin-updater 自更新 | 不适用（重签名安装 / App Store） |

#[cfg(not(any(target_os = "ios", target_os = "android")))]
mod updater;
#[cfg(any(target_os = "ios", target_os = "android"))]
#[path = "updater_ios.rs"]
mod updater;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tingo_engine::{config, meetings, server};
use tauri::{Manager, State};

#[derive(Default)]
struct Backend {
    engine: Mutex<Option<Arc<server::AppState>>>,
    url: Mutex<Option<String>>,
    error: Mutex<Option<String>>,
    rebind_lock: Mutex<()>,
}

fn spawn_server_on(engine: Arc<server::AppState>, state: Arc<Backend>) {
    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
        {
            Ok(rt) => rt,
            Err(e) => {
                *state.error.lock().unwrap() = Some(format!("启动本地服务失败：{e}"));
                return;
            }
        };
        rt.block_on(async move {
            match server::serve_state(engine, 0).await {
                Ok((port, serve)) => {
                    *state.url.lock().unwrap() = Some(format!("http://127.0.0.1:{port}"));
                    serve.await;
                }
                Err(e) => *state.error.lock().unwrap() = Some(format!("启动本地服务失败：{e}")),
            }
        });
    });
}

fn url_alive(url: &str) -> bool {
    let Some(addr) = url.strip_prefix("http://") else { return false };
    let Ok(sock) = addr.parse::<std::net::SocketAddr>() else { return false };
    std::net::TcpStream::connect_timeout(&sock, Duration::from_millis(250)).is_ok()
}

/// 界面启动或从后台恢复时调用：等后端起来，若 iOS 挂起期间回收了监听端口则原地重绑，返回最新地址。
#[tauri::command]
async fn backend_url(state: State<'_, Arc<Backend>>) -> Result<String, String> {
    if let Some(url) = state.url.lock().unwrap().clone() {
        let check_url = url.clone();
        let alive = tauri::async_runtime::spawn_blocking(move || url_alive(&check_url))
            .await
            .unwrap_or(false);
        if alive {
            return Ok(url);
        }
        // iOS 长时间锁屏挂起后可能回收了旧的监听 socket：保留同一个 AppState 重绑端口
        let _guard = state.rebind_lock.lock().unwrap();
        let current = state.url.lock().unwrap().clone();
        if current.as_deref() == Some(url.as_str()) {
            if let Some(engine) = state.engine.lock().unwrap().clone() {
                *state.url.lock().unwrap() = None;
                spawn_server_on(engine, state.inner().clone());
            }
        }
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(url) = state.url.lock().unwrap().clone() {
            return Ok(url);
        }
        if let Some(err) = state.error.lock().unwrap().clone() {
            return Err(err);
        }
        if Instant::now() > deadline {
            return Err("本地服务 20 秒内没有启动".into());
        }
        tauri::async_runtime::spawn_blocking(|| std::thread::sleep(Duration::from_millis(30)))
            .await
            .ok();
    }
}

/// 改名前（bundle id 是 io.github.tancheng33.jiyao）下载的识别模型有三百多 MB，搬到新的数据目录，不用重新下载
#[cfg(not(target_os = "ios"))]
fn migrate_models(data: &std::path::Path) {
    let new = data.join("models");
    let Some(old) = data.parent().map(|d| d.join("io.github.tancheng33.jiyao/models")) else { return };
    if !new.exists() && old.is_dir() {
        let _ = std::fs::create_dir_all(data);
        if let Err(e) = std::fs::rename(&old, &new) {
            eprintln!("搬迁旧版识别模型失败：{e}");
        }
    }
}

fn start_backend(app: &tauri::App, state: Arc<Backend>) -> Result<(), String> {
    let data = app.path().app_data_dir().map_err(|e| e.to_string())?;

    // Android 的 Java 层没有 HOME 环境变量，而 engine 用 HOME 拼「会议目录 / 配置目录」。
    // 这里把 HOME 指到 App 私有目录，engine 里所有路径逻辑就都不用改。
    #[cfg(target_os = "android")]
    {
        let _ = std::fs::create_dir_all(&data);
        std::env::set_var("HOME", &data);
    }
    #[cfg(not(target_os = "ios"))]
    migrate_models(&data);
    let resources = app.path().resource_dir().map_err(|e| e.to_string())?;
    // iOS 上没有子进程录音组件：路径给一个不存在的文件，engine 会据此把「系统声音」判为不可用，
    // 界面自动隐藏那个开关（/api/env 的 system_audio）。
    let recorder_bin = if cfg!(any(target_os = "ios", target_os = "android")) {
        data.join("tingo-recorder")
    } else {
        resources.join("tingo-recorder")
    };
    let opt = server::Options {
        root: meetings::default_root(),
        config_path: config::default_path(),
        models_dir: data.join("models"),
        recorder_bin,
        version: app.package_info().version.to_string(),
        // 内置示例会议（打包时从 src/tingo/sample 拷进资源）
        sample_dir: resources.join("sample"),
    };
    let engine = server::AppState::new(opt);
    *state.engine.lock().unwrap() = Some(engine.clone());
    spawn_server_on(engine, state);
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let backend = Arc::new(Backend::default());
    let builder = tauri::Builder::default()
        .manage(backend.clone())
        .manage(Arc::new(updater::NativeUpdater::default()));
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let builder = builder.plugin(tauri_plugin_updater::Builder::new().build());
    builder
        .invoke_handler(tauri::generate_handler![
            backend_url,
            updater::native_update_check,
            updater::native_update_status,
            updater::native_update_download,
            updater::native_update_install
        ])
        .setup(move |app| {
            if let Err(e) = start_backend(app, backend.clone()) {
                *backend.error.lock().unwrap() = Some(e);
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("启动纪要失败");
}
