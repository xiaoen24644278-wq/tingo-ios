//! iOS 录音后端：直接用 Swift 侧的 AVAudioEngine 录麦克风，和 macOS 版 `Recorder` 保持同样的接口，
//! 这样 `server.rs`、`probe()`、`spawn_watcher` 一行都不用改。

use std::path::{Path, PathBuf};
use std::time::Instant;

use crate::i18n::tr;
use crate::ios;

pub struct Recorder {
    pub dir: PathBuf,
    pub sources: Vec<String>,
    pub started: Instant,
}

impl Recorder {
    /// `bin`（macOS 的 tingo-recorder 路径）在 iOS 上不参与任何事，保留参数只为接口一致。
    /// `system` 在 iOS 上拿不到，传 true 会退化成只录麦克风。
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
                "iOS 上只能录麦克风：系统里别的 App 的声音录不到",
                "On iOS only the microphone can be recorded — other apps' audio isn't accessible",
            )
            .into());
        }
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        ios::setup_session()?;
        ios::rec_start(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
            sources: vec!["mic".into()],
            started: Instant::now(),
        })
    }

    pub fn elapsed(&self) -> f64 {
        let by_clock = self.started.elapsed().as_secs_f64();
        let by_bridge = ios::rec_elapsed();
        // 两边都取较大值：切后台、被电话打断时 Swift 侧的时钟更准
        by_clock.max(by_bridge)
    }

    /// 录音中途出错（权限被收回、音频会话被抢占）；出错时返回原因。
    pub fn exited(&mut self) -> Option<String> {
        ios::take_error()
    }

    pub fn stop(&mut self) {
        ios::rec_stop();
    }
}

impl Drop for Recorder {
    fn drop(&mut self) {
        ios::rec_stop();
    }
}
