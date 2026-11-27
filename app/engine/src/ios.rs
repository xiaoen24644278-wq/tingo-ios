//! iOS 专用桥：录音、解码、AAC 压缩、HTML→PDF 全部由 Swift 侧（`TingoAudio.swift`）在进程内完成。
//!
//! iOS 不允许 fork/exec 第三方可执行文件，macOS 版里那个 `tingo-recorder` Swift 子进程在这里
//! 换成了一组 `@_cdecl` 的 C 函数：Swift 编进同一个 App 二进制，Rust 静态库直接链接它们。
//! 系统声音在 iOS 上拿不到（第三方 App 看不到别的 App 的音频），所以这里只录麦克风。

#![cfg(target_os = "ios")]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::Path;

extern "C" {
    /// 配置 AVAudioSession（.playAndRecord / 外放 / 与其它音频混音），可重复调用。
    fn tingo_ios_setup_session() -> c_int;
    /// 在 dir 下新建 mic.wav（16 kHz 单声道 16 bit）并开始录音，返回 0 表示成功。
    fn tingo_ios_rec_start(dir: *const c_char) -> c_int;
    /// 麦克风授权状态：0=已允许，1=被拒绝，2=还没问过
    fn tingo_ios_mic_status() -> c_int;
    /// 主动请求麦克风权限（会弹系统框），0=允许
    fn tingo_ios_request_mic() -> c_int;
    /// 停止录音并把 wav 文件头写完整。
    fn tingo_ios_rec_stop() -> c_int;
    /// 本次录音已经录了多少秒。
    fn tingo_ios_rec_elapsed() -> f64;
    /// 最近一次错误（UTF-8），调用方负责用 `tingo_ios_free` 释放。
    fn tingo_ios_last_error() -> *mut c_char;
    fn tingo_ios_free(p: *mut c_char);
    /// 任意音视频 → 16 kHz 单声道 16 bit wav（AVAssetReader + AVAudioConverter）。
    fn tingo_ios_decode(input: *const c_char, out_wav: *const c_char) -> c_int;
    /// 16 kHz wav → AAC m4a（AVAssetWriter，48 kbps）。
    fn tingo_ios_encode_aac(input_wav: *const c_char, out_m4a: *const c_char) -> c_int;
    /// 排好版的 HTML 文件 → A4 PDF（UIMarkupTextPrintFormatter）。
    fn tingo_ios_html_to_pdf(html_path: *const c_char, out_pdf: *const c_char) -> c_int;
    /// 后台任务保活与前台防自动息屏（1=开启，0=释放）。
    fn tingo_ios_keep_alive(active: c_int) -> c_int;
    /// 更新灵动岛与锁屏实时状态（progress 0..=1，负值表示无进度条）。
    fn tingo_ios_set_live_status(title: *const c_char, subtitle: *const c_char, progress: f64, active: c_int) -> c_int;
}

fn err() -> String {
    unsafe {
        let p = tingo_ios_last_error();
        if p.is_null() {
            return "iOS 音频桥返回失败但没有错误信息".into();
        }
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        tingo_ios_free(p);
        s
    }
}

fn cstr(p: &Path) -> Result<CString, String> {
    CString::new(p.to_string_lossy().as_bytes())
        .map_err(|_| format!("路径里有非法字符：{}", p.display()))
}

pub fn setup_session() -> Result<(), String> {
    match unsafe { tingo_ios_setup_session() } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

/// 主动请求权限（会弹系统授权框）
pub fn request_mic() -> Result<(), String> {
    match unsafe { tingo_ios_request_mic() } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

/// 麦克风授权状态："granted" / "denied" / "undetermined"
pub fn mic_status() -> &'static str {
    match unsafe { tingo_ios_mic_status() } {
        0 => "granted",
        1 => "denied",
        _ => "undetermined",
    }
}

pub fn rec_start(dir: &Path) -> Result<(), String> {
    let d = cstr(dir)?;
    match unsafe { tingo_ios_rec_start(d.as_ptr()) } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

pub fn rec_stop() {
    unsafe {
        tingo_ios_rec_stop();
    }
}

pub fn rec_elapsed() -> f64 {
    let v = unsafe { tingo_ios_rec_elapsed() };
    if v.is_finite() && v >= 0.0 {
        v
    } else {
        0.0
    }
}

/// 录音过程中 Swift 侧记下的错误（会话被抢占、中断、写盘失败…），取一次就清空。
pub fn take_error() -> Option<String> {
    unsafe {
        let p = tingo_ios_last_error();
        if p.is_null() {
            return None;
        }
        let s = CStr::from_ptr(p).to_string_lossy().into_owned();
        tingo_ios_free(p);
        (!s.is_empty()).then_some(s)
    }
}

pub fn decode(input: &Path, out: &Path) -> Result<(), String> {
    let (i, o) = (cstr(input)?, cstr(out)?);
    match unsafe { tingo_ios_decode(i.as_ptr(), o.as_ptr()) } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

pub fn encode_aac(input: &Path, out: &Path) -> Result<(), String> {
    let (i, o) = (cstr(input)?, cstr(out)?);
    match unsafe { tingo_ios_encode_aac(i.as_ptr(), o.as_ptr()) } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

pub fn html_to_pdf(html: &Path, out: &Path) -> Result<(), String> {
    let (i, o) = (cstr(html)?, cstr(out)?);
    match unsafe { tingo_ios_html_to_pdf(i.as_ptr(), o.as_ptr()) } {
        0 => Ok(()),
        _ => Err(err()),
    }
}

pub fn set_keep_alive(active: bool) {
    unsafe {
        tingo_ios_keep_alive(if active { 1 } else { 0 });
    }
}

pub fn set_live_status(title: &str, subtitle: &str, progress: f64, active: bool) {
    let Ok(t) = CString::new(title) else { return };
    let Ok(s) = CString::new(subtitle) else { return };
    unsafe {
        tingo_ios_set_live_status(t.as_ptr(), s.as_ptr(), progress, if active { 1 } else { 0 });
    }
}
