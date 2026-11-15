# Tingo iOS 移植说明

Tingo 的 iOS 版是"同一套 engine + 同一份前端，换一套系统集成"：`tingo-engine`（识别、标点、声纹、会议存储、本地 HTTP 服务）原样编进 App，界面还是 `src/tingo/web` 那一份 vite 产物，差异只在录音、平台调用和更新三处。

**只能在 macOS + Xcode 上构建。** Linux 上没有 iOS SDK、没有 `xcodebuild`、没有 `codesign`，产不出能装的 ipa——详见「7. 产物」。

---

## 1. 结论速览

| 项目 | macOS | iOS |
|---|---|---|
| 录音 | 打包的 `bin/tingo-recorder` 子进程（ScreenCaptureKit + AVFoundation） | 进程内 `app/ios/TingoAudio.swift`（AVAudioEngine），只能录麦克风 |
| 系统声音 | 有 | 没有（第三方 App 拿不到别的 App 的音频） |
| 会议目录 | `~/Documents/Tingo` | 沙盒 `Documents/Tingo`（「文件」App 可见） |
| 配置 | `~/.config/tingo/config.toml` | 沙盒内同名路径 |
| 更新 | `tauri-plugin-updater` 自更新 | 无（App Store / 重签名安装） |
| 识别 | sherpa-onnx 静态库 | sherpa-onnx **动态** xcframework（见第 7 节） |
| 前端 | `src/tingo/web` | 同一份 `src/tingo/web` |

关键文件：

- `app/ios/TingoAudio.swift`：录音、解码、AAC、HTML→PDF，全部以 `@_cdecl` 导出
- `app/engine/src/ios.rs`：Rust 侧对接上面那些 C 函数（`#![cfg(target_os = "ios")]`）
- `app/engine/src/record_ios.rs`：录音后端，接口与 macOS 的 `Recorder` 一致
- `app/engine/src/platform.rs`：`open_path` / `reveal_path` / `open_url` 在 iOS 上退化成空操作
- `app/src-tauri/src/updater_ios.rs`：iOS 侧的"更新"占位（不自更新）
- `app/scripts/build-ios.sh`：本文档第 4 节的构建脚本

---

## 2. 前置条件

- macOS + Xcode（含 Command Line Tools），`xcode-select -p` 指向完整的 Xcode
- Rust 工具链（`rustup`），目标 `aarch64-apple-ios`（模拟器再用 `aarch64-apple-ios-sim`）
- node + pnpm（`package.json` 锁 `pnpm@11`）
- 首次 `cargo build` 需要 `swiftc`（`app/src-tauri/build.rs` 用它编 `recorder.swift`）

---

## 3. 构建脚本 `app/scripts/build-ios.sh`

```bash
bash app/scripts/build-ios.sh                            # 真机 arm64，未签名 ipa
IOS_TARGET=aarch64-sim bash app/scripts/build-ios.sh     # 模拟器
SHERPA_ONNX_IOS=0 bash app/scripts/build-ios.sh          # 跳过识别引擎，只验壳体+界面
```

脚本面向 CI：**全程不读 stdin、不弹确认、所有变量都有默认值**，任何一个前置条件不满足就直接非零退出并打印原因。

### 3.1 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `IOS_TARGET` | `aarch64` | `aarch64` / `aarch64-sim` / `x86_64` |
| `IOS_SIGN` | `0` | `0` 传 `--no-sign`，产未签名 ipa；`1` 走签名 |
| `DEBUG_BUILD` | `0` | `1` 用 cargo debug 编（验证壳体时快很多） |
| `SKIP_PNPM_INSTALL` | `0` | `1` 跳过 `pnpm install --frozen-lockfile` |
| `SKIP_WEB_BUILD` | `0` | `1` 跳过 `pnpm build`，只校验产物非空 |
| `SHERPA_ONNX_IOS` | `1` | **`0` = 完全不准备识别引擎**，只验证壳体+界面能编过 |
| `SHERPA_ONNX_STATIC_BUILD` | `0` | `1` = 用 CMake 自建 sherpa-onnx 静态库（需 `SHERPA_ONNX_SRC`） |
| `SHERPA_ONNX_SRC` | 空 | sherpa-onnx 源码目录（仅静态路线需要） |
| `SHERPA_ONNX_SKIP_DOWNLOAD` | `0` | `1` 不预取 xcframework |
| `SHERPA_ONNX_VERSION` | 读 `engine/Cargo.toml` | 目前解析出 `2.0.1` |
| `SHERPA_ONNX_ONNXRUNTIME_VERSION` | `1.28.2` | 静态路线用的 onnxruntime iOS 静态库版本 |
| `DEPLOYMENT_TARGET` | `15.0` | 与 `tauri.conf.json` 的 `bundle.iOS.minimumSystemVersion` 一致 |
| `ENABLE_BITCODE` | `NO` | 现代 Xcode 一律 NO |
| `TINGO_TAURI_ARGS` | 空 | 追加给 `pnpm tauri ios build` 的参数 |
| `BUILD_DIR` | `<repo>/build/ios` | 下载缓存与产物目录 |

### 3.2 九步流程

| # | 步骤 | 关键动作 |
|---|---|---|
| 1 | 解析路径与默认值 | 算出 `APP_DIR` / `REPO_ROOT`，给全部变量填默认值，`export CI=1` |
| 2 | 环境检查 | `uname -s == Darwin`、`xcodebuild` / `xcrun` / `pnpm` / `node` / `cargo` / `unzip` 逐个点名 |
| 3 | **创建打包占位** | 写 `app/src-tauri/bin/tingo-recorder`（`#!/bin/sh` + `exit 0`）并 `chmod +x`、`touch` 刷新 mtime |
| 4 | **前端产物** | `pnpm install --frozen-lockfile` → `pnpm build` → 校验 `src/tingo/web` 非空且含 `index.html`，空则中止并提示先 `cd app && pnpm build` |
| 5 | 资源清单冒烟 | `tauri.conf.json` 里有 `bin/tingo-recorder` 声明、`src/tingo/sample` 存在；缺 `"frameworks"` 时警告 |
| 6 | **识别引擎依赖** | `SHERPA_ONNX_IOS=0` 跳过；否则探测/下载 `ios.toolchain.cmake`，导出 `CMAKE_TOOLCHAIN_FILE` / `PLATFORM=OS64` / `DEPLOYMENT_TARGET=15.0` / `ENABLE_BITCODE=NO`；静态路线走 cmake 自建，默认路线预取 `sherpa-onnx.xcframework` |
| 7 | Rust 目标 + Xcode 工程 | `rustup target add`；`gen/apple` 不存在就跑 `pnpm tauri ios init` |
| 8 | 编译 | `pnpm tauri ios build --target <IOS_TARGET> --no-sign` |
| 9 | 收集校验产物 | 找 `*.ipa` → 复制到 `build/ios/Tingo-<target>-unsigned.ipa` → 校验 `Payload/`、`Frameworks/` → 打印 sha256 |

---

## 4. 打包资源与 `tingo-recorder` 占位（硬要求，别删）

`app/src-tauri/tauri.conf.json` 的 `bundle.resources` 声明了两个资源：

```json
"resources": {
  "bin/tingo-recorder": "tingo-recorder",
  "../../src/tingo/sample": "sample"
}
```

其中 `bin/tingo-recorder` **只有 macOS 构建流程才会生成**——`app/src-tauri/build.rs` 里用 `swiftc -target arm64-apple-macos13.0` 现场编 `src/tingo/recorder.swift` 出来。iOS 构建时这个文件不存在，Tauri 打包阶段会直接以 `resource not found` 失败。

所以脚本第 3 步在**任何 tauri 命令之前**先造一个占位：

```sh
#!/bin/sh
exit 0
```

并且 `chmod +x`、`touch` 刷新 mtime。两个副作用都是想要的：

1. iOS 上根本不会执行它——`engine/src/record_ios.rs` 走的是 `ios::rec_start()`（Swift 侧 AVAudioEngine），`Recorder::start()` 的 `_bin` 参数被明确忽略。它纯粹是打包占位。
2. `build.rs` 的"是否需要重编"判断是 `out.mtime >= src.mtime`，占位文件比 `recorder.swift` 新 → `swiftc` 那一支被跳过，免得在 iOS 构建里编出一个 macOS target 的二进制。**如果哪天 `recorder.swift` 被改动，mtime 会反超占位文件**，脚本每次运行都会重新 `touch`，所以不用担心。

脚本对已存在的文件只补 `chmod +x`、不覆盖：在 macOS 上跑过 release 的机器上，`bin/tingo-recorder` 是真的录音器，不能被踩。

---

## 5. 前端产物 `src/tingo/web`

vite 的 `outDir` 是 `../src/tingo/web`（`app/vite.config.ts`），也就是**仓库根**的 `src/tingo/web`；`tauri.conf.json` 的 `frontendDist` 指向同一处。它是 gitignored 的构建产物。

`pnpm tauri ios build` 之前必须非空，否则 Xcode 拷进去的是一个空目录，界面白屏。脚本第 4 步：

1. 默认自己跑 `pnpm build`（`tsc --noEmit && vite build`）；
2. 跑完再检查 `src/tingo/web` 是否非空、有没有 `index.html`；
3. 空 → 非零退出，提示 `cd app && pnpm build`。

`SKIP_WEB_BUILD=1` 时只做检查不构建，适合"前端产物由上一条流水线产出"的 CI 编排。

---

## 6. 识别引擎的交叉编译

这是整个 iOS 化最大的不确定项，先把事实摆清楚（结论：**默认路线能编过，但走的是动态库，不是静态库**）。

### 6.1 现状事实（有据可查）

- `app/engine/Cargo.toml` 里写的是 `sherpa-onnx = { version = "2.0.1", default-features = false, features = ["static"] }`。
- 但 `sherpa-onnx-sys 2.0.1` 的 `build.rs` 里 `resolve_link_mode()` 是这么写的：

  ```rust
  if shared_enabled {
      Ok(LinkMode::Shared)
  } else if target_os == "android" || target_os == "ios" {
      // Android and iOS only support shared linking.
      Ok(LinkMode::Shared)
  } else {
      Ok(LinkMode::Static)
  }
  ```

  也就是说 **iOS 目标上 `features = ["static"]` 被无声忽略**，只会走 shared。
- shared 路线的预编译库只有一种：`sherpa-onnx-v{ver}-ios-shared-onnxruntime-static.xcframework.zip`，发布在 `k2-fsa/sherpa-onnx` 的 `xcframework` tag 下。**onnxruntime 已经静态链进那个 dylib**，不需要另外找 `libonnxruntime.a`。（`emit_shared_link_directives()` 里 `if target_os != "ios" { link onnxruntime }` 就是这个意思。）
- 官方 Tauri iOS 指引也是这套：`features = ["shared"]` + `bundle.iOS.frameworks: ["sherpa-onnx.xcframework"]` + 先跑 `setup-ios.sh` 把 xcframework 下下来。
- **为什么必须先下**：`build.rs` 自己也会下 xcframework 并复制到 `src-tauri/`，但那发生在 Xcode 的 "Build Rust Code" 阶段——Xcode 在这之前就已经检查过 xcframework 是否存在了。第一次构建必然失败。所以脚本第 6 步无条件预取（`setup-ios.sh` 就是干这个的，我们不依赖它存在，自己实现同样逻辑）。
- xcframework 包体约 30 MB（`content-length: 31577060`），CI 预取一次即可，缓存在 `build/ios/`。

### 6.2 脚本做的三件事

1. **CMake toolchain 探测**：依次找

   ```
   app/src-tauri/gen/apple/ios.toolchain.cmake
   app/src-tauri/gen/apple/toolchains/ios.toolchain.cmake
   app/ios/toolchains/ios.toolchain.cmake
   build/ios-cmake/ios.toolchain.cmake
   ```

   都没有就从 <https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake> 下到 `build/ios-cmake/ios.toolchain.cmake`，然后

   ```sh
   export CMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
   export PLATFORM=OS64            # 模拟器自动切 SIMULATORARM64
   export DEPLOYMENT_TARGET=15.0
   export ENABLE_BITCODE=NO
   ```

   这几个变量**只对"自己用 CMake 编 sherpa-onnx / onnxruntime"起作用**；走 crates.io 预编译库那条路时它们不参与，留着是为了让自建路线和官方 `build-ios.sh` 用同一套参数。

2. **静态路线可选**（`SHERPA_ONNX_STATIC_BUILD=1`）：下载 onnxruntime 的 iOS 静态 xcframework，导出 `SHERPA_ONNXRUNTIME_LIB_DIR` / `SHERPA_ONNXRUNTIME_INCLUDE_DIR`，用上面的 toolchain 按官方 `build-ios.sh` 的参数（`-DBUILD_SHARED_LIBS=OFF`、`-DENABLE_ARC=1`、关掉 Python/Binary/Tests/Portaudio/JNI/WebSocket、`-DSHERPA_ONNX_ENABLE_C_API=ON`）配置并 `cmake --build`，再 `--target install`，最后把 `SHERPA_ONNX_LIB_DIR` 指向 `libsherpa-onnx-c-api.a` 所在目录。

   但注意：**光有静态库还不够**，`sherpa-onnx-sys` 的 iOS 强制 shared 分支还在，需要打个小 patch（见 6.3）。

3. **默认路线：预取 shared xcframework** 到 `app/src-tauri/sherpa-onnx.xcframework`（压缩包里若叫 `SherpaOnnxC.xcframework` 会改名）。

还有一件事是 `bundle.iOS.frameworks` 里必须有 `"sherpa-onnx.xcframework"`，否则 dylib 不会被嵌进 App：编译能过，启动时 dyld 找不到库直接崩。**这一步构建脚本自动做**：它在 `tauri ios init` 之前先把 xcframework 预取到 `app/src-tauri/`，文件存在且配置里没写就自动 append 并重跑 init（幂等，重复跑不会重复加）；`SHERPA_ONNX_IOS=0` 时不预取、也就不写，避免让 Xcode 报 `framework not found`。打包前还会检查 `Payload/Tingo.app/Frameworks` 里有没有 sherpa，没有就 warn。

### 6.3 真要静态链接时需要的 patch（未验证）

给 `sherpa-onnx-sys` 打个 vendored patch，让 iOS 也认 static：

```rust
// src-tauri Cargo.toml
[patch.crates-io]
sherpa-onnx-sys = { path = "vendor/sherpa-onnx-sys" }
sherpa-onnx = { path = "vendor/sherpa-onnx" }
```

```rust
// vendor/sherpa-onnx-sys/build.rs，resolve_link_mode() 里
} else if target_os == "android" || target_os == "ios" {
    // iOS 上若显式要求 static 且给了自建库，就别强制 shared
    if target_os == "ios" && static_enabled { Ok(LinkMode::Static) } else { Ok(LinkMode::Shared) }
}
```

`emit_static_link_directives()` 里 `"macos" | "ios"` 分支已经补了 `-lc++ -framework Foundation`，静态路线在链接层面是有人走过的；剩下的是把 sherpa-onnx 自己和它的第三方静态库（kaldi-decoder、kaldi-native-fbank、kissfft、utf8proc、ssentencepiece 等）都链进来——这正是官方 `build-ios.sh` 最后生成 xcframework 时干的事。这条路可行但工作量明显大于使用官方 xcframework，**没有实证过**。

### 6.4 如果卡住，两条退路

**(a) 用官方 xcframework 的 C API，engine 侧改 FFI。** `SherpaOnnxC.framework` 导出的是完整 C API（`SherpaOnnxCreateOfflineRecognizer`、`SherpaOnnxCreateOfflineStream`、`SherpaOnnxDecodeOfflineStream`、`SherpaOnnxGetOfflineStreamResult`…）。做法是把 `app/engine/src/asr.rs` 里的 `OfflineRecognizer` / `OfflineRecognizerConfig` 换成本地 `extern "C"` 声明，`SpeakerEmbeddingExtractor` / `VoiceActivityDetector` / `OfflinePunctuation` 同理（它们都在同一个 C API 里）。工作量集中在一个文件，但要把 `asr.rs`、`chunked.rs`、`audio.rs`（`LinearResampler`）三处 sherpa 调用都包一层。好处：脱离 Rust 绑定，版本升级不再受 `sherpa-onnx-sys` 的 iOS 策略影响。

**(b) 换系统 Speech 框架。** iOS 26 的 `SpeechAnalyzer`（配合 `SpeechTranscriber`）或老一点的 `SFSpeechRecognizer`，中文识别质量对会议场景够用。代价明确：**模型与热词能力下降**（用不了 Paraformer / SenseVoice / Fun-ASR-Nano 的自定义词表和声纹，CAM++ 说话人区分也没了），而且要么需要联网，要么依赖系统下发的本地模型（`DCSDictionaryAsset` 之类，首次要下载、体积不可控）。engine 侧 `AsrKind::AppleSpeech` 已经留了枚举位，macOS 上的 `apple_speech.rs` 是走 `tingo-recorder` 子进程的，iOS 上得改成进程内 Swift 调用。

### 6.5 我的判断

**能编过的概率：高（默认路线）；静态链接：不确定，需要 patch + 自建库，未验证。**

依据：

1. sherpa-onnx 官方仓库里有 `tauri-examples/README-iOS.md`，明确写了 Tauri v2 + iOS 的用法，且 `sherpa-onnx-sys 2.0.1` 的 `build.rs` 里专门有 `copy_xcframework_to_tauri_project()`——说明"Tauri iOS + sherpa-onnx"是一条被维护的路径，不是我们硬凑。
2. 2.0.1 的 xcframework 是**预编译、onnxruntime 已静态链进去**的，不需要我们在 CI 里从源码编 onnx（那才是最脏的一步）。
3. 我们的 engine 用到的 `OfflineRecognizer` / `OfflinePunctuation` / `SpeakerEmbeddingExtractor` / `VoiceActivityDetector` / `LinearResampler` 都在 C API 覆盖面内（`sherpa-onnx` Rust crate 本身就是 C API 的薄封装），所以动态库路线下 Rust 侧代码零改动。
4. 未验证的部分：真机链接时的符号可见性、`ENABLE_VISIBILITY=0` 之外的编译参数、ipa 里嵌入 framework 后的签名（`--no-sign` 阶段看不出来）——这些都要在 macOS 上实跑一次才能确认。**本仓库当前环境是 Linux，一行 iOS 代码都没编过，上面的"高"是代码与文档层面的推断，不是实测结论。**

---

## 7. 产物

### 7.1 未签名 ipa 的结构

ipa 就是个 zip，未签名时结构如下（`unzip -l` 视角）：

```
Payload/
Payload/Tingo.app/
Payload/Tingo.app/Tingo                      ← 主二进制（arm64 Mach-O，含 tauri + engine + Swift 录音桥）
Payload/Tingo.app/Info.plist
Payload/Tingo.app/_CodeSignature/…           ← 未签名时为「无」或空壳
Payload/Tingo.app/Frameworks/SherpaOnnxC.framework/SherpaOnnxC
Payload/Tingo.app/Frameworks/…               ← 其它动态库（若有）
Payload/Tingo.app/sample/…                   ← bundle.resources：../../src/tingo/sample
Payload/Tingo.app/tingo-recorder             ← bundle.resources：占位脚本（iOS 上不执行）
Payload/Tingo.app/assets/…                   ← 前端产物 src/tingo/web
```

要点：

- **顶层必须是 `Payload/`**，里面一个 `.app` 目录，`.app` 名与 `productName`（`Tingo`）一致。少了 `Payload/` 就不是 ipa，`xcrun altool` / `ios-deploy` 都不认。脚本第 9 步会 grep 这个前缀。
- 未签名 ipa 不能直接装到真机：设备要求 `codesign` 签名 + 对应 team 的 provisioning profile。`--no-sign` 的产物用途是 **CI 里验证"能编过、结构对"**，以及给后续签名流水线当输入。
- 重签名/安装的常规做法：`codesign --force --deep --sign "Apple Development: …" Payload/Tingo.app`（或用 `ios-deploy` / Xcode 的 Devices 窗口 / `xcrun devicectl`），或者干脆在有 team 的机器上不传 `--no-sign`（`IOS_SIGN=1`）。

### 7.2 为什么必须 macOS 构建

iOS 的可执行文件是 **arm64 Mach-O，链接的是 iOS SDK 里的 libSystem/libobjc/CoreFoundation**，而把它拼出来的工具链只在 macOS 上存在：

| 必需组件 | 为什么 Linux 上不行 |
|---|---|
| `xcodebuild` / `xcrun` | 苹果只在 Xcode 里发布，闭源；没有 Linux 版 |
| iOS SDK（`iPhoneOS.sdk`） | 随 Xcode 分发，受苹果许可约束，不能单独下载到 Linux |
| `ld64`（Apple 链接器）/ `clang` 的 Darwin target 支持 | 交叉编译工具链能做（`aarch64-apple-ios` target 本身存在），但**链接**需要 Apple 的 `ld` 和 SDK 里的 tbd/库 |
| `codesign` / `security` | 苹果签名体系，只在 macOS |
| `actool` / `ibtool` / `swiftc`（编 `TingoAudio.swift`） | 同属 Xcode 工具链 |
| Rust 的 `aarch64-apple-ios` 目标 | 编译（`rustc --emit=obj`）理论可行，但最终 link 仍要 `ld64` + SDK |

所以：Linux 上最多能到"前端产物 + Rust 的 obj 文件"，产不出能装、甚至产不出能链接完成的 ipa。CI 必须用 macOS runner（GitHub Actions 的 `macos-14`/`macos-15`，Xcode 26 需要较新的 runner 镜像）。

---

## 8. 已知限制

- **录不到系统声音**：iOS 沙盒不允许，只能麦克风。`record_ios.rs` 在 `system && !mic` 时直接返回错误。
- **不自更新**：`updater_ios.rs` 只是占位，`tauri-plugin-updater` 在 iOS target 上根本没作为依赖引入（`src-tauri/Cargo.toml` 的 `cfg(not(target_os = "ios"))`）。
- **模型体积**：识别模型（Paraformer-large int8 约 330 MB）首次在界面里下载，iOS 上要注意蜂窝网络与后台被杀。
- **后台录音**：需要 `UIBackgroundModes: audio` + AVAudioSession 正确配置，锁屏/切后台的行为要在真机上验。
- **`tauri ios init` 的 team**：`tauri.conf.json` 里 `bundle.iOS.developmentTeam` 目前是空串，签名构建前必须填上；`--no-sign` 构建不需要。

## 9. 验证清单（真机/模拟器上按顺序点）

1. App 启动不闪退（`Frameworks/SherpaOnnxC.framework` 嵌入成功，dyld 不报错）
2. 界面正常渲染（`src/tingo/web` 拷进去了）
3. 开始录音 → 有麦克风权限弹窗 → `Documents/Tingo/<会议>/mic.wav` 有内容
4. 录音停止 → wav 头写完整（`tingo_ios_rec_stop`），时长正确
5. 导入一个已有音频文件 → 解码成 16k 单声道（`tingo_ios_decode`）
6. 首次识别 → 模型下载 → 识别出文字（这条只有在 `SHERPA_ONNX_IOS=1` 且 xcframework 正常时才期望通过）
7. 导出 PDF / m4a → 走 `tingo_ios_html_to_pdf` / `tingo_ios_encode_aac`
8. 「在访达中显示」类按钮 → iOS 上不该崩（`platform.rs` 返回 false，界面自己弹分享面板）

## 10. 排错

| 现象 | 原因 / 处理 |
|---|---|
| `resource not found: bin/tingo-recorder` | 第 4 节的占位文件没建，或建在了 `app/src-tauri/bin/` 之外 |
| `Unable to find module dependency: 'sherpa-onnx'` / `framework not found SherpaOnnxC` | xcframework 没预取到 `app/src-tauri/`；或 `bundle.iOS.frameworks` 没写 |
| 启动即闪退，Console 里 `dyld: Library not loaded` | dylib 没被 embed（同上），或签名没覆盖 `Frameworks/` |
| 界面白屏 | `src/tingo/web` 是空的（第 5 节） |
| `error: linker command failed` + 一堆 `undefined symbol: SherpaOnnx…` | 走成了"半静态"：`SHERPA_ONNX_LIB_DIR` 指向静态库但 crate 还在 shared 模式（6.3 的 patch 没打） |
| `swiftc` 报 `arm64-apple-macos13.0` 相关错误 | `bin/tingo-recorder` 的 mtime 比 `recorder.swift` 旧，build.rs 又去编 macOS 录音器了；重跑脚本即可（会 `touch`） |

参考链接：

- [sherpa-onnx：Using sherpa-onnx with Tauri on iOS](https://github.com/k2-fsa/sherpa-onnx/blob/master/tauri-examples/README-iOS.md)
- [sherpa-onnx-sys 2.0.1 的 build.rs 源码](https://docs.rs/crate/sherpa-onnx-sys/2.0.1/source/build.rs)
- [sherpa-onnx 官方 build-ios.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/build-ios.sh)
- [官方 Tauri 示例里的 setup-ios.sh](https://github.com/k2-fsa/sherpa-onnx/blob/master/tauri-examples/hello_world/src-tauri/setup-ios.sh)
- [leetal/ios-cmake 的 ios.toolchain.cmake](https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake)
- [onnxruntime iOS 静态 xcframework 发布页](https://github.com/csukuangfj/onnxruntime-libs/releases)
