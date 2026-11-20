//! 录音与音频文件：启停录音、解码任意音视频、录完后混音并压成 m4a。
//!
//! 两个平台走两套系统能力，接口完全一样：
//!
//! - **macOS**：交给打包在 App 里的 Swift 命令行组件 `tingo-recorder`（ScreenCaptureKit 录系统
//!   声音 + AVFoundation 录麦克风），压缩用系统自带的 `/usr/bin/afconvert`，都不需要 ffmpeg。
//! - **iOS**：不允许 fork/exec 第三方可执行文件，改成进程内调用 `TingoAudio.swift`（见 `ios.rs` /
//!   `record_ios.rs`）。系统声音拿不到，只录麦克风；压缩用 AVAssetWriter 出 AAC。
//!
//! 平台无关的部分（WAV 读写、试录、错误分类）两个平台共用。

#[cfg(target_os = "ios")]
#[path = "record_ios.rs"]
mod ios_backend;
#[cfg(target_os = "ios")]
pub use ios_backend::Recorder;

#[cfg(target_os = "android")]
#[path = "record_android.rs"]
mod android_backend;
#[cfg(target_os = "android")]
pub use android_backend::Recorder;

use std::path::Path;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::path::PathBuf;

use crate::asr::SR;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use crate::audio::duck_mix_default;
use crate::audio::read_wav16k;
use crate::i18n::tr;

#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::io::{BufRead, BufReader};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::process::{Child, ChildStdout, Command, Stdio};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::time::{Duration, Instant};

// ============ macOS：tingo-recorder 子进程 ============

#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub struct Recorder {
    child: Child,
    stdout: Option<BufReader<ChildStdout>>,
    pub dir: PathBuf,
    pub sources: Vec<String>,
    pub started: Instant,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl Recorder {
    /// 启动录音组件，等它报告 READY（或出错）。
    pub fn start(bin: &Path, dir: &Path, system: bool, mic: bool) -> Result<Self, String> {
        if !system && !mic {
            return Err(tr(
                "系统声音和麦克风至少开一个",
                "Turn on at least one of system audio and microphone",
            )
            .into());
        }
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        let mut cmd = Command::new(bin);
        cmd.arg(dir);
        if !mic {
            cmd.arg("--no-mic");
        }
        if !system {
            cmd.arg("--no-system");
        }
        let mut child = cmd
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                tr(&format!("启动录音组件失败：{e}"), &format!("Couldn't start the recorder: {e}")).to_string()
            })?;
        let mut stdout = BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        stdout.read_line(&mut line).map_err(|e| e.to_string())?;
        let line = line.trim();
        if line != "READY" {
            let _ = child.wait();
            return Err(line
                .strip_prefix("ERROR: ")
                .unwrap_or(tr("录音组件意外退出", "The recorder exited unexpectedly"))
                .to_string());
        }
        let sources = [("system", system), ("mic", mic)]
            .iter()
            .filter(|(_, on)| *on)
            .map(|(s, _)| s.to_string())
            .collect();
        Ok(Self {
            child,
            stdout: Some(stdout),
            dir: dir.to_path_buf(),
            sources,
            started: Instant::now(),
        })
    }

    pub fn elapsed(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// 录音组件是否中途退出了（比如权限被收回）；退出时返回它最后报的错。
    pub fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(_)) => {
                let mut rest = String::new();
                if let Some(mut out) = self.stdout.take() {
                    let _ = std::io::Read::read_to_string(&mut out, &mut rest);
                }
                Some(
                    rest.lines()
                        .find_map(|l| l.strip_prefix("ERROR: "))
                        .unwrap_or(tr("录音组件意外退出", "The recorder exited unexpectedly"))
                        .to_string(),
                )
            }
            _ => None,
        }
    }

    /// 停止录音：发 SIGINT 让它写完文件头，15 秒内没退出就强杀。原始音轨留着。
    pub fn stop(&mut self) {
        if self.child.try_wait().ok().flatten().is_some() {
            return;
        }
        unsafe {
            libc::kill(self.child.id() as i32, libc::SIGINT);
        }
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if self.child.try_wait().ok().flatten().is_some() {
                return;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl Drop for Recorder {
    fn drop(&mut self) {
        self.stop();
    }
}

// ============ HTML → PDF ============

/// 已经排好版的 HTML → A4 PDF。
/// macOS 交给录音组件用系统 WebKit 排版；iOS 用进程内的 UIPrintPageRenderer。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn html_to_pdf(bin: &Path, html: &str, out: &Path) -> Result<(), String> {
    let tmp = std::env::temp_dir().join(format!("tingo-pdf-{}-{}.html", std::process::id(), rand_suffix()));
    std::fs::write(&tmp, html).map_err(|e| e.to_string())?;
    let res = Command::new(bin).arg("pdf").arg(&tmp).arg(out).output();
    let _ = std::fs::remove_file(&tmp);
    let res = res.map_err(|e| {
        tr(&format!("启动排版失败：{e}"), &format!("Couldn't start the PDF renderer: {e}")).to_string()
    })?;
    if res.status.success() && out.is_file() {
        return Ok(());
    }
    let msg = String::from_utf8_lossy(&res.stdout);
    Err(msg
        .lines()
        .find_map(|l| l.strip_prefix("ERROR: "))
        .unwrap_or(tr("导出 PDF 失败", "PDF export failed"))
        .to_string())
}

#[cfg(target_os = "ios")]
pub fn html_to_pdf(_bin: &Path, html: &str, out: &Path) -> Result<(), String> {
    let tmp = std::env::temp_dir().join(format!("tingo-pdf-{}-{}.html", std::process::id(), rand_suffix()));
    std::fs::write(&tmp, html).map_err(|e| e.to_string())?;
    let res = crate::ios::html_to_pdf(&tmp, out).map_err(|e| {
        tr(&format!("导出 PDF 失败：{e}"), &format!("PDF export failed: {e}")).to_string()
    });
    let _ = std::fs::remove_file(&tmp);
    res
}

// ============ Android 版实现（调 Kotlin） ============

#[cfg(target_os = "android")]
pub fn html_to_pdf(_bin: &Path, html: &str, out: &Path) -> Result<(), String> {
    let tmp = std::env::temp_dir().join(format!("tingo-pdf-{}-{}.html", std::process::id(), rand_suffix()));
    std::fs::write(&tmp, html).map_err(|e| e.to_string())?;
    let res = crate::android::html_to_pdf(&tmp, out).map_err(|e| {
        tr(&format!("导出 PDF 失败：{e}"), &format!("PDF export failed: {e}")).to_string()
    });
    let _ = std::fs::remove_file(&tmp);
    res
}

#[cfg(target_os = "android")]
pub fn html_to_docx(_html: &str, _out: &Path) -> Result<(), String> {
    Err(tr(
        "Android 版暂不支持导出 Word，可以导出 PDF 或复制 Markdown",
        "Word export isn't available on Android yet — export PDF or copy Markdown",
    )
    .into())
}

#[cfg(target_os = "android")]
pub fn decode(_bin: &Path, input: &Path) -> Result<Vec<f32>, String> {
    if input.extension().is_some_and(|e| e.eq_ignore_ascii_case("wav")) {
        if let Some(x) = read_wav16k(input) {
            return Ok(x);
        }
    }
    let tmp = std::env::temp_dir().join(format!("tingo-decode-{}-{}.wav", std::process::id(), rand_suffix()));
    let result = match crate::android::decode(input, &tmp) {
        Ok(()) => read_wav16k(&tmp).ok_or_else(|| tr("解码结果读不出来", "Couldn't read the decoded audio").to_string()),
        Err(e) => Err(tr(&format!("解码失败：{e}"), &format!("Decoding failed: {e}")).to_string()),
    };
    let _ = std::fs::remove_file(&tmp);
    result
}

#[cfg(target_os = "android")]
pub fn mixdown(dir: &Path, dest: &Path) -> Result<(), String> {
    let (sys, mic) = (dir.join("system.wav"), dir.join("mic.wav"));
    let source = if mic.is_file() { mic.clone() } else if sys.is_file() { sys.clone() } else {
        return Err(tr("没有录到任何声音", "Nothing was recorded").into());
    };
    crate::android::encode_aac(&source, dest).map_err(|e| {
        tr(&format!("压缩录音失败：{e}"), &format!("Compressing the recording failed: {e}")).to_string()
    })?;
    for p in [&sys, &mic] {
        let _ = std::fs::remove_file(p);
    }
    Ok(())
}

// ============ 删除 → 废纸篓 ============

/// 移到废纸篓（不是彻底删除）。macOS 上交给录音组件的 `trash <路径>`（FileManager.trashItem，
/// 成功打印 OK，失败打印 ERROR: …）；其它系统有 gio 就用 `gio trash`，否则报不支持。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn trash(bin: &Path, path: &Path) -> Result<(), String> {
    let failed = |e: &str| tr(&format!("没能移到废纸篓：{e}"), &format!("Couldn't move to the Trash: {e}")).to_string();
    if cfg!(target_os = "macos") || bin.is_file() {
        let out = Command::new(bin).arg("trash").arg(path).stdin(Stdio::null()).output().map_err(|e| failed(&e.to_string()))?;
        let text = String::from_utf8_lossy(&out.stdout);
        if out.status.success() && text.lines().any(|l| l.trim() == "OK") {
            return Ok(());
        }
        return Err(match text.lines().find_map(|l| l.trim().strip_prefix("ERROR: ")) {
            Some(e) => e.to_string(), // 录音组件报的错已经说了是"移到废纸篓失败"
            None => failed(String::from_utf8_lossy(&out.stderr).trim()),
        });
    }
    let Some(gio) = find_in_path("gio") else {
        return Err(tr("这个系统上没法移到废纸篓", "Moving to the Trash isn't supported on this system").into());
    };
    let out = Command::new(gio).arg("trash").arg(path).stdin(Stdio::null()).output().map_err(|e| failed(&e.to_string()))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(failed(String::from_utf8_lossy(&out.stderr).trim()))
    }
}

/// iOS 沙盒里没有废纸篓：删掉的东西挪到 `.tingo-trash/`，同样能拿出来恢复，
/// 界面上的「移到废纸篓 + 可恢复」语义保持不变。
#[cfg(target_os = "ios")]
pub fn trash(_bin: &Path, path: &Path) -> Result<(), String> {
    let failed = |e: &str| tr(&format!("没能删掉：{e}"), &format!("Couldn't delete: {e}")).to_string();
    let Some(name) = path.file_name() else {
        return Err(failed("路径没有文件名"));
    };
    let Some(parent) = path.parent() else {
        return Err(failed("路径没有上级目录"));
    };
    let box_dir = parent.join(".tingo-trash");
    std::fs::create_dir_all(&box_dir).map_err(|e| failed(&e.to_string()))?;
    let dest = box_dir.join(format!("{}-{}", rand_suffix(), name.to_string_lossy()));
    std::fs::rename(path, &dest).map_err(|e| failed(&e.to_string()))?;
    Ok(())
}

/// Android 沙盒同样没有系统废纸篓：删掉的东西挪到 `.tingo-trash/`，界面上「可恢复」的语义不变。
#[cfg(target_os = "android")]
pub fn trash(_bin: &Path, path: &Path) -> Result<(), String> {
    let failed = |e: &str| tr(&format!("没能删掉：{e}"), &format!("Couldn't delete: {e}")).to_string();
    let Some(name) = path.file_name() else {
        return Err(failed("路径没有文件名"));
    };
    let Some(parent) = path.parent() else {
        return Err(failed("路径没有上级目录"));
    };
    let box_dir = parent.join(".tingo-trash");
    std::fs::create_dir_all(&box_dir).map_err(|e| failed(&e.to_string()))?;
    let dest = box_dir.join(format!("{}-{}", rand_suffix(), name.to_string_lossy()));
    std::fs::rename(path, &dest).map_err(|e| failed(&e.to_string()))?;
    Ok(())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn find_in_path(name: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?).map(|d| d.join(name)).find(|p| p.is_file())
}

// ============ HTML → Word ============

#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub const TEXTUTIL: &str = "/usr/bin/textutil";

/// HTML → Word：macOS 自带的 textutil。没有 textutil（非 macOS）时报错。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn html_to_docx(html: &str, out: &Path) -> Result<(), String> {
    if !Path::new(TEXTUTIL).is_file() {
        return Err(tr("导出 Word 只支持 macOS", "Word export is only available on macOS").into());
    }
    let tmp = std::env::temp_dir().join(format!("tingo-docx-{}-{}.html", std::process::id(), rand_suffix()));
    std::fs::write(&tmp, html).map_err(|e| e.to_string())?;
    // 不指定输入编码时，HTML 里没写 charset 的话中文会变成乱码
    let res = Command::new(TEXTUTIL)
        .args(["-inputencoding", "UTF-8", "-convert", "docx", "-output"])
        .arg(out)
        .arg(&tmp)
        .output();
    let _ = std::fs::remove_file(&tmp);
    let res = res.map_err(|e| {
        tr(&format!("启动 textutil 失败：{e}"), &format!("Couldn't start textutil: {e}")).to_string()
    })?;
    if res.status.success() && out.is_file() {
        return Ok(());
    }
    let err = String::from_utf8_lossy(&res.stderr).trim().to_string();
    Err(tr(&format!("导出 Word 失败：{err}"), &format!("Word export failed: {err}")).into())
}

/// iOS 上没有 textutil，也没带 docx 生成器：直接给出可执行的替代路径（PDF / Markdown）。
#[cfg(target_os = "ios")]
pub fn html_to_docx(_html: &str, _out: &Path) -> Result<(), String> {
    Err(tr(
        "iOS 版暂不支持导出 Word，可以导出 PDF 或复制 Markdown",
        "Word export isn't available on iOS yet — export PDF or copy Markdown",
    )
    .into())
}

/// 麦克风授权状态："granted" / "denied" / "undetermined"
/// 桌面版不涉及运行时授权，恒为 granted。
#[cfg(target_os = "ios")]
pub fn mic_status() -> &'static str { crate::ios::mic_status() }
#[cfg(target_os = "android")]
pub fn mic_status() -> &'static str { crate::android::mic_status() }
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn mic_status() -> &'static str { "granted" }

/// 主动请求麦克风权限（会弹系统授权框）。桌面版直接成功。
#[cfg(target_os = "ios")]
pub fn request_mic() -> Result<(), String> { crate::ios::request_mic() }
#[cfg(target_os = "android")]
pub fn request_mic() -> Result<(), String> { crate::android::setup() }
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn request_mic() -> Result<(), String> { Ok(()) }

// ============ 试录与错误分类（两个平台共用） ============

/// 试录 `secs` 秒（录进临时目录，录完就删），返回每条音轨（system / mic）最响那段的音量（0～1）；
/// 音轨没录出来时是 None。录音组件起不来或中途退出时返回它报的错。
pub fn probe(bin: &Path, system: bool, mic: bool, secs: u64) -> Result<Vec<(String, Option<f32>)>, String> {
    let dir = std::env::temp_dir().join(format!("tingo-rectest-{}-{}", std::process::id(), rand_suffix()));
    let result = (|| {
        #[cfg(any(target_os = "ios", target_os = "android"))]
        let (system, mic) = (false, mic || !system); // 手机上只录麦克风
        let mut rec = Recorder::start(bin, &dir, system, mic)?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
        while std::time::Instant::now() < deadline {
            if let Some(e) = rec.exited() {
                return Err(e);
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        rec.stop();
        Ok(rec
            .sources
            .iter()
            .map(|s| (s.clone(), crate::audio::max_level(&dir.join(format!("{s}.wav")), 0.15)))
            .collect())
    })();
    let _ = std::fs::remove_dir_all(&dir);
    result
}

/// 录音组件报的错是不是没有权限（录屏与系统录音、麦克风）
pub fn is_permission_error(msg: &str) -> bool {
    let m = msg.to_lowercase();
    ["权限", "permission", "declined", "not authorized", "not permitted", "tcc"].iter().any(|k| m.contains(k))
}

// ============ 解码 ============

#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn decode(bin: &Path, input: &Path) -> Result<Vec<f32>, String> {
    if input
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("wav"))
    {
        if let Some(x) = read_wav16k(input) {
            return Ok(x);
        }
    }
    let tmp = std::env::temp_dir().join(format!(
        "tingo-decode-{}-{}.wav",
        std::process::id(),
        rand_suffix()
    ));
    let out = Command::new(bin)
        .arg("decode")
        .arg(input)
        .arg(&tmp)
        .output()
        .map_err(|e| tr(&format!("启动解码失败：{e}"), &format!("Couldn't start the decoder: {e}")).to_string())?;
    let result = if out.status.success() {
        read_wav16k(&tmp).ok_or_else(|| tr("解码结果读不出来", "Couldn't read the decoded audio").to_string())
    } else {
        let msg = String::from_utf8_lossy(&out.stdout);
        Err(msg
            .lines()
            .find_map(|l| l.strip_prefix("ERROR: "))
            .unwrap_or(tr("解码失败", "Decoding failed"))
            .to_string())
    };
    let _ = std::fs::remove_file(&tmp);
    result
}

/// iOS：AVAssetReader 直接解出 16 kHz 单声道 PCM（m4a/mp3/mp4/mov/aac/flac 都吃）。
#[cfg(target_os = "ios")]
pub fn decode(_bin: &Path, input: &Path) -> Result<Vec<f32>, String> {
    if input
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("wav"))
    {
        if let Some(x) = read_wav16k(input) {
            return Ok(x);
        }
    }
    let tmp = std::env::temp_dir().join(format!(
        "tingo-decode-{}-{}.wav",
        std::process::id(),
        rand_suffix()
    ));
    let result = match crate::ios::decode(input, &tmp) {
        Ok(()) => read_wav16k(&tmp).ok_or_else(|| tr("解码结果读不出来", "Couldn't read the decoded audio").to_string()),
        Err(e) => Err(tr(&format!("解码失败：{e}"), &format!("Decoding failed: {e}")).to_string()),
    };
    let _ = std::fs::remove_file(&tmp);
    result
}

fn rand_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// ============ WAV 写入 ============

/// 16 kHz 单声道 16 位 wav。
pub fn write_wav16(path: &Path, samples: &[f32]) -> std::io::Result<()> {
    let data: Vec<u8> = samples
        .iter()
        .flat_map(|s| ((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes())
        .collect();
    let mut v = Vec::with_capacity(44 + data.len());
    v.extend(b"RIFF");
    v.extend((36 + data.len() as u32).to_le_bytes());
    v.extend(b"WAVEfmt ");
    v.extend(16u32.to_le_bytes());
    v.extend(1u16.to_le_bytes());
    v.extend(1u16.to_le_bytes());
    v.extend((SR as u32).to_le_bytes());
    v.extend((SR as u32 * 2).to_le_bytes());
    v.extend(2u16.to_le_bytes());
    v.extend(16u16.to_le_bytes());
    v.extend(b"data");
    v.extend((data.len() as u32).to_le_bytes());
    v.extend(data);
    std::fs::write(path, v)
}

// ============ 录完后：混音 + 压成 m4a ============

/// macOS：系统声音和麦克风按"让路"规则合成一条，压成 m4a（afconvert，AAC 48 kbps），删掉原始音轨。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn mixdown(dir: &Path, dest: &Path) -> Result<(), String> {
    let (sys, mic) = (dir.join("system.wav"), dir.join("mic.wav"));
    let read = |p: &Path| if p.is_file() { read_wav16k(p) } else { None };
    let mixed = match (read(&sys), read(&mic)) {
        (Some(s), Some(m)) => duck_mix_default(&s, &m),
        (Some(x), None) | (None, Some(x)) => x,
        (None, None) => return Err(tr("没有录到任何声音", "Nothing was recorded").into()),
    };
    let wav = dir.join("mixed.wav");
    write_wav16(&wav, &mixed).map_err(|e| e.to_string())?;
    let out = Command::new("/usr/bin/afconvert")
        .args(["-f", "m4af", "-d", "aac", "-b", "48000"]) // 16 kHz 单声道 AAC 最高 48 kbps
        .arg(&wav)
        .arg(dest)
        .output()
        .map_err(|e| tr(&format!("压缩录音失败：{e}"), &format!("Compressing the recording failed: {e}")).to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(tr(
            &format!("压缩录音失败：{err}"),
            &format!("Compressing the recording failed: {err}"),
        )
        .into());
    }
    for p in [&wav, &sys, &mic] {
        let _ = std::fs::remove_file(p);
    }
    Ok(())
}

/// iOS：只有麦克风一条音轨，不需要"让路"混音，直接 AVAssetWriter 编成 AAC m4a。
#[cfg(target_os = "ios")]
pub fn mixdown(dir: &Path, dest: &Path) -> Result<(), String> {
    let (sys, mic) = (dir.join("system.wav"), dir.join("mic.wav"));
    let source = if mic.is_file() { mic.clone() } else if sys.is_file() { sys.clone() } else {
        return Err(tr("没有录到任何声音", "Nothing was recorded").into());
    };
    crate::ios::encode_aac(&source, dest).map_err(|e| {
        tr(&format!("压缩录音失败：{e}"), &format!("Compressing the recording failed: {e}")).to_string()
    })?;
    for p in [&sys, &mic] {
        let _ = std::fs::remove_file(p);
    }
    Ok(())
}

#[cfg(all(test, not(target_os = "ios")))]
mod tests {
    use super::*;

    #[test]
    fn mixdown_writes_m4a_and_cleans_tracks() {
        let dir = std::env::temp_dir().join(format!("tingo-mix-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tone: Vec<f32> = (0..SR).map(|i| 0.3 * (i as f32 * 0.05).sin()).collect();
        write_wav16(&dir.join("system.wav"), &tone).unwrap();
        write_wav16(&dir.join("mic.wav"), &vec![0.0; SR / 2]).unwrap();
        let dest = dir.join("录音.m4a");
        mixdown(&dir, &dest).unwrap();
        assert!(std::fs::metadata(&dest).unwrap().len() > 1000);
        assert!(!dir.join("system.wav").exists() && !dir.join("mixed.wav").exists());
        std::fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn mixdown_without_audio_fails() {
        let dir = std::env::temp_dir().join(format!("tingo-mix-empty-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        assert!(mixdown(&dir, &dir.join("录音.m4a")).is_err());
        std::fs::remove_dir_all(dir).ok();
    }
}
