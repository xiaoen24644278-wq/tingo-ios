//! Android 录音后端：调 Kotlin 的 `AudioRecord` 录麦克风，接口与 macOS / iOS 版完全一致，
//! 因此 `server.rs`、`probe()`、`spawn_watcher` 都不需要平台分支。
//!
//! 与 iOS 一样的系统限制：拿不到别的 App 的音频（Android 10+ 虽然能用 AudioPlaybackCapture，
//! 但需要 MediaProjection 授权、且目标 App 必须允许被捕获），所以只录麦克风。

use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::android;
use crate::i18n::tr;

pub struct Recorder {
    pub dir: PathBuf,
    pub sources: Vec<String>,
    pub started: Instant,
}

impl Recorder {
    /// `bin`（macOS 的 tingo-recorder 路径）在 Android 上不参与任何事，保留参数只为接口一致。
    pub fn start(_bin: &Path, dir: &Path, system: bool, mic: bool) -> Result<Self, String> {
        if !system && !mic {
            return Err(tr(
                "系统声音和麦克风至少开一个",
                "Turn on at least one of system audio and microphone",
            )
            .into());
        }
        if !mic {
            return Err(tr(
                "Android 上只录麦克风：别的 App 的音频拿不到",
                "On Android only the microphone can be recorded — other apps' audio isn't accessible",
            )
            .into());
        }
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        android::setup()?;
        android::rec_start(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
            sources: vec!["mic".into()],
            started: Instant::now(),
        })
    }

    pub fn elapsed(&self) -> f64 {
        self.started.elapsed().as_secs_f64().max(android::rec_elapsed())
    }

    /// 录音中途出错（麦克风被占用、权限被收回）。
    pub fn exited(&mut self) -> Option<String> {
        android::take_error()
    }

    pub fn stop(&mut self) {
        android::rec_stop();
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        android::rec_stop();
    }
}
