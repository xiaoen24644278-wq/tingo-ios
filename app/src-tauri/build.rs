use std::path::Path;
use std::process::Command;

fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();

    // iOS：Rust 侧的录音/解码/PDF 全部通过 `tingo_ios_*` 这组 C 函数调用 Swift（见 app/ios/TingoAudio.swift）。
    // 但 Tauri 构建 iOS 的顺序是「先 cargo build 出 Rust 库，再编译 Swift，最后 Xcode 链接成 App」，
    // 所以 Rust 的 cdylib 在这一步还看不到 Swift 的符号。默认策略下 iOS 不允许未定义符号，链接直接失败：
    //   Undefined symbols: _tingo_ios_rec_start, _tingo_ios_decode, ...
    // 让链接器把这些符号留到最终 App 链接时再解析；Swift 编译产物会把它们补齐。
    if target_os == "ios" {
        println!("cargo:rustc-link-arg=-Wl,-undefined,dynamic_lookup");
    }

    // macOS 才需要把 Swift 录音组件编成可执行文件；iOS 上录音是进程内的 TingoAudio.swift，
    // 这里生成的 bin/tingo-recorder 只是满足 bundle.resources 清单的空壳占位（由构建脚本创建）。
    if target_os == "ios" || target_os == "android" {
        // 手机上录音是进程内的（iOS: TingoAudio.swift / Android: TingoAudio.kt），
        // 不需要也不应该在这里调 swiftc 编 macOS 二进制（Linux 的 Android 构建机上根本没有 macOS SDK）。
        tauri_build::build();
        return;
    }

    // 把 Swift 录音组件（录系统声音、麦克风，解码音视频）编译好，作为资源打进 App
    let src = Path::new("../../src/tingo/recorder.swift");
    let out = Path::new("bin/tingo-recorder");
    println!("cargo:rerun-if-changed={}", src.display());
    std::fs::create_dir_all("bin").unwrap();
    let fresh = out.exists()
        && out.metadata().and_then(|m| m.modified()).ok()
            >= src.metadata().and_then(|m| m.modified()).ok();
    if !fresh {
        let status = Command::new("swiftc")
            // 最低系统和 App 一致（tauri.conf.json 的 minimumSystemVersion）。不写的话 swiftc 默认按本机 SDK 的最新版本，
            // 在别人较老的系统上录音组件根本起不来（"录音组件意外退出"）
            .args(["-O", "-target", "arm64-apple-macos13.0", src.to_str().unwrap(), "-o", out.to_str().unwrap()])
            .status()
            .expect("需要 Xcode Command Line Tools（swiftc）来编译录音组件");
        assert!(status.success(), "录音组件编译失败");
    }
    // 公证也检查 Resources 中的 Swift 可执行文件，因此必须在封装 App 前签名。
    println!("cargo:rerun-if-env-changed=APPLE_SIGNING_IDENTITY");
    println!("cargo:rerun-if-changed=Entitlements.plist");
    if let Ok(identity) = std::env::var("APPLE_SIGNING_IDENTITY") {
        if !identity.is_empty() && identity != "-" {
            let status = Command::new("codesign")
                .args(["--force", "--sign", &identity, "--timestamp", "--options", "runtime",
                    "--identifier", "io.github.tancheng33.tingo.recorder",
                    "--entitlements", "Entitlements.plist", out.to_str().unwrap()])
                .status()
                .expect("无法启动 codesign");
            assert!(status.success(), "录音组件正式签名失败");
        }
    }
    tauri_build::build()
}
