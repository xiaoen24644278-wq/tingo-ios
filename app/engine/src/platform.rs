//! 平台差异集中地。
//!
//! macOS 版习惯直接调系统命令（`/usr/bin/open`、`sw_vers` 等）。iOS 沙盒里既没有这些命令行
//! 工具，也不允许 fork/exec，所以这层把「打开文件/在访达里显示」这类动作收敛成一个函数：
//! macOS 上照旧交给 `open`，iOS 上变成空操作，由界面自己用分享面板处理（导出后的文件就在
//! 沙盒 Documents 里，「文件」App 也能看到）。

use std::path::Path;

/// 用系统默认方式打开文件或目录（macOS: `open`）。返回是否真的交给了系统。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn open_path(p: &Path) -> bool {
    std::process::Command::new("/usr/bin/open")
        .arg(p)
        .spawn()
        .is_ok()
}

/// 在文件管理器里定位并选中（macOS: `open -R`）。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn reveal_path(p: &Path) -> bool {
    std::process::Command::new("/usr/bin/open")
        .arg("-R")
        .arg(p)
        .spawn()
        .is_ok()
}

/// 打开一个 URL（http(s)/obsidian(excalidraw) 等 scheme）。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn open_url(u: &str) -> bool {
    std::process::Command::new("/usr/bin/open")
        .arg(u)
        .spawn()
        .is_ok()
}

#[cfg(any(target_os = "ios", target_os = "android"))]
pub fn open_path(_p: &Path) -> bool {
    false
}

#[cfg(any(target_os = "ios", target_os = "android"))]
pub fn reveal_path(_p: &Path) -> bool {
    false
}

#[cfg(any(target_os = "ios", target_os = "android"))]
pub fn open_url(_u: &str) -> bool {
    // iOS 上要打开外部 App 得走 Swift 的 UIApplication.open，导出结果也统一用系统分享面板，
    // 这里不做动作，界面会拿到 ok:true + path，自己决定弹不弹分享。
    false
}

/// 系统版本号（主版本）。iOS 上系统声音永远不可用，用不到这个值，固定返回 0。
#[cfg(not(any(target_os = "ios", target_os = "android")))]
pub fn os_major_version() -> Option<u32> {
    let out = std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .ok()?;
    let v = String::from_utf8(out.stdout).ok()?;
    v.trim().split('.').next()?.parse::<u32>().ok()
}

#[cfg(any(target_os = "ios", target_os = "android"))]
pub fn os_major_version() -> Option<u32> {
    None
}
