# Tingo 听过 · iOS 移植版

**一句话现状**：这是 [Tingo](https://github.com/tancheng33/tingo) 的 iOS 移植分支，能在 macOS 本机或 GitHub Actions 上打出**未签名 ipa**，用 Sideloadly / AltStore 自签之后就能装到 iPhone 上，录音 → 转写 → 声纹分人 → 纪要这条主链在手机上完整可用。

- 上游：Tauri 2 + Rust（`tingo-engine`）+ 手写 TS 前端，原生 macOS 会议纪要 App（MIT）
- 本分支：Rust 引擎仍跑在 App 进程里，`axum` 仍只监听 `127.0.0.1`，界面还是那个 WKWebView 前端；macOS 里那个 `tingo-recorder` Swift 子进程换成进程内 Swift 桥 `app/ios/TingoAudio.swift`
- 最低系统：**iOS 16.0**（`app/vite.config.ts` 的 `build.target` 是 `safari16`，前端按 iOS 16 的语法降级，`tauri.conf.json` 的 `bundle.iOS.minimumSystemVersion` 与之一致）
- 产物没有签名，不进 App Store，自己签自己装

---

## 怎么产出 ipa

### A. 本机 macOS，一条命令

前置：Xcode（含 Command Line Tools）、Node ≥ 20、`corepack enable`（装 pnpm）、[rustup](https://rustup.rs)、`brew install xcodegen`。

```sh
git clone https://github.com/tancheng33/tingo
cd tingo
bash app/scripts/build-ios.sh
# 产物：build/ios/Tingo-unsigned.ipa
```

有开发者账号、想走 Xcode 自动签名：

```sh
TEAM_ID=ABCDE12345 bash app/scripts/build-ios.sh
```

可覆盖的开关：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `TEAM_ID` | 空 | 空 = 不签名；有值 = `export APPLE_DEVELOPMENT_TEAM`，走 Xcode 自动签名 |
| `CONFIG` | `release` | `debug` 也行（体积大、跑得慢，排错用） |
| `SCHEME` | 自动探测 | 通常就是 `tingo_iOS` |
| `IPA_NAME` | `Tingo-unsigned.ipa` | 产物文件名 |
| `EXPORT_METHOD` | `release-testing`（仅 `TEAM_ID` 有值时） | 传给 `tauri ios build --export-method` |
| `DEPLOYMENT_TARGET` | `16.0` | `IPHONEOS_DEPLOYMENT_TARGET` 与 Info.plist 的 `MinimumOSVersion` |
| `IOS_TARGET` | `auto` | 传给 `tauri ios build --target`；`auto` 时按 CLI 支持的取值自动挑 |
| `ALLOW_MISSING_AUDIO_BRIDGE` | `0` | 置 `1` 时允许缺 `app/ios/TingoAudio.swift`（只调前端时用） |

脚本干的事，按顺序：检查 `xcodebuild` / `pnpm` / `cargo` / `rustup` / `zip` → `rustup target add aarch64-apple-ios aarch64-apple-ios-sim` → `pnpm install --frozen-lockfile`（失败退回 `pnpm install`）+ `pnpm build`（产物到仓库根 `src/tingo/web`）→ `gen/apple` 不存在就 `pnpm tauri ios init` → 注入 iOS `Info.plist`（幂等，打完还打印 `plutil -p` 片段）→ 把 `TingoAudio.swift` 拷进 `gen/apple/*_iOS/` 并 `xcodegen generate` 重新生成工程 → `pnpm tauri ios build --target …`（CLI 没这个参数就退到不带 `--target`）→ 找 `.app`、塞进 `Payload/`、`zip -qry` 出 ipa。

### B. GitHub Actions，点一下

- 仓库 **Actions → 「iOS 未签名 ipa」→ Run workflow**；也可以 push 一个 `v*` tag 触发
- runner：`macos-15`，`timeout-minutes: 120`
- 产出 artifact：**`Tingo-unsigned-ipa`**（保留 14 天），里面是 `Tingo-unsigned.ipa`
- CI 上不签名（没有证书），也别配 `TEAM_ID`

```sh
git tag v0.5.5-ios && git push origin v0.5.5-ios   # 触发一次构建
```

Actions 里同样是 `corepack enable` 装 pnpm、`dtolnay/rust-toolchain@stable` 装 Rust（额外加 `aarch64-apple-ios` target）、`brew install xcodegen`，然后直接 `bash app/scripts/build-ios.sh`。

---

## 产物

| 项 | 内容 |
| --- | --- |
| ipa 路径 | `build/ios/Tingo-unsigned.ipa`（CI 里由 upload-artifact 上传） |
| 解包参考 | `build/ios/Payload/Tingo.app`（脚本保留一份，方便检查 Info.plist、Frameworks） |
| 结构 | 标准 ipa（`Payload/Tingo.app`），**没有 `_CodeSignature`**，未越狱设备装不上，必须先自签 |
| 版本 | 跟随 `app/src-tauri/tauri.conf.json` 的 `version`（当前 0.5.5）与 `identifier`（`io.github.tancheng33.tingo`） |
| 体积 | 几十 MB 量级；识别模型**不**打进 ipa，首次使用时在 App 内下载（约 330 MB） |
| 最低系统 | iOS 16.0（`Info.plist` 的 `MinimumOSVersion` = 16.0） |

自己核对一下：

```sh
unzip -l build/ios/Tingo-unsigned.ipa | head
plutil -p build/ios/Payload/Tingo.app/Info.plist
ls build/ios/Payload/Tingo.app/Frameworks    # 这里应当能看到 sherpa-onnx.framework
```

`Info.plist` 里应当有这些 key（构建脚本会打印 `plutil -p` 片段，CI 日志里也能看到）：

| key | 值 | 用途 |
| --- | --- | --- |
| `NSMicrophoneUsageDescription` | Tingo 需要麦克风来录下会议里你自己的声音，录音只保存在这台手机上。 | 没这条 iOS 会直接杀掉 App |
| `UIBackgroundModes` | `[audio]` | 切后台、锁屏时录音不被立刻掐断 |
| `NSAppTransportSecurity` | `NSAllowsLocalNetworking = true`、`NSAllowsArbitraryLoads = false` | 只放开 `127.0.0.1` 的本地 HTTP，其它照旧走 ATS |
| `UIFileSharingEnabled` | `true` | 会议文件在「文件」App 里可见 |
| `LSSupportsOpeningDocumentsInPlace` | `true` | 支持原地打开文档 |
| `ITSAppUsesNonExemptEncryption` | `false` | 只用系统自带加密，省掉出口合规申报 |
| `MinimumOSVersion` | `16.0` | 和 `bundle.iOS.minimumSystemVersion` 对齐 |

---

## 怎么装到 iPhone

### Sideloadly（Windows / Mac 都行）

1. 装 [Sideloadly](https://sideloadly.io/)，iPhone 用数据线连电脑，手机上点「信任」
2. 把 `Tingo-unsigned.ipa` 拖进窗口，Apple ID 填自己的，点 Start
3. 手机「设置 → 通用 → VPN 与设备管理」里信任那条开发者证书
4. 首次打开 App 时允许麦克风权限

### AltStore / SideStore（自动续签）

- 电脑装 AltServer，手机上装 AltStore，登录同一个 Apple ID
- AltStore 用你的 Apple ID 给 Tingo 重签安装，之后每 7 天内自动/手动续签一次；保持同一 Wi-Fi 或插着线
- SideStore 走同一套思路，不需要常开电脑

### 期限

- **免费 Apple ID**：签名 7 天有效，到期 App 打不开，重签一次就好
- **99 美元/年开发者账号**：签名 1 年有效（也可以走 TestFlight 派发给别人）
- **TrollStore**：在它支持的 iOS 版本上可以永久签名，装上直接跑，不用 7 天续一遍

重签是同名覆盖安装，App 沙盒里的会议数据一般还在；删掉 App 则数据跟着一起没。稳一点的做法：重要会议先导出 PDF。

---

## 功能对照

### iOS 版能用的

| 功能 | 说明 |
| --- | --- |
| 本地录音（麦克风） | `AVAudioEngine` 录 16 kHz 单声道，`libsherpa-onnx` 全本地跑，不出网 |
| 语音转写 | sherpa-onnx Paraformer（默认）/ SenseVoice / Fun-ASR-Nano，中文断句、标点、热词都保留 |
| 声纹分人 | 3D-Speaker CAM++ 声纹 + 聚类，多人会议照样分「说话人 1/2/3」 |
| 试录与音量检测 | 录几秒看音量条，判断麦克风有没有被别的东西占住 |
| 自动停止 | 静音一段时间自动停录（`autostop` 逻辑与 macOS 一致） |
| 纪要生成 | 接自己的 LLM 接口（OpenAI 兼容 / Anthropic 风格），key 存在 `Library/Application Support/tingo/config.toml` |
| PDF 导出 | `UIMarkupTextPrintFormatter` 渲染 A4 PDF，排版与 macOS 版一致 |
| 图片分享 | 系统分享面板：存到「照片」、发微信/飞书都行 |
| 搜索 / 标签 / 历史版本 | 会议目录、全文检索、标签、纪要历史版本都在本地 |
| Webhook 推送 | 纪要生成后 POST 到你自己的地址（`reqwest`，iOS 上照常工作） |

### iOS 版做不到的

| 功能 | 情况 | 替代 |
| --- | --- | --- |
| 录其它 App 的系统声音 | iOS 给第三方 App 的音频隔离是硬边界，别的 App 的声音拿不到（macOS 版走 ScreenCaptureKit） | 线上会议用免提/外放，让麦克风把对方声音一起收进去；或者干脆手机录音、电脑开会 |
| 导出 Word（`.docx`） | iOS 上没有 `textutil`，也没内置 docx 生成器，界面会明确提示改用 PDF / 复制 Markdown | 导出 PDF，或在电脑版里导出 Word |
| Obsidian 写本地仓库 | 沙盒里写不了仓库外的路径 | 导出 Markdown 后手动放进库，或用「文件」App 拖过去 |
| 应用内自动更新 | iOS 只能通过 App Store 或重新签名安装，Tauri 的 updater 在 iOS 上不参与 | 重新下载 ipa 覆盖安装（同名覆盖，数据保留） |
| Finder「在访达中显示」 | 没有访达 | 导出后走系统分享面板；会议文件夹在「文件 → 我的 iPhone → Tingo」里能看到 |

---

## 技术改动清单

| 位置 | macOS 版 | iOS 移植版 |
| --- | --- | --- |
| 录音 | 子进程 `tingo-recorder`（Swift，ScreenCaptureKit + AVFoundation） | 进程内 Swift 桥 `app/ios/TingoAudio.swift`，`AVAudioEngine` + `AVAudioSession`，用 `@_cdecl` 导出 `tingo_ios_*` 给 Rust |
| Rust 录音后端 | `record.rs` 的 `Recorder` 起子进程、读它 stdout 的 `READY` | `record_ios.rs` 同名同签名的 `Recorder`，直接调桥；`server.rs` / `probe()` / `spawn_watcher` 一行没改 |
| 音频解码 | `/usr/bin/afconvert` | `AVAssetReader` + `AVAudioConverter`（任意音视频 → 16 kHz 单声道 16 bit wav） |
| 压缩 | `afconvert` 出 AAC 48 kbps m4a | `AVAssetWriter` 出同样的 m4a |
| HTML → PDF | 打包的排版组件 | `UIMarkupTextPrintFormatter`（A4） |
| HTML → Word | `/usr/bin/textutil` | 函数保留，返回明确提示「改用 PDF 或 Markdown」 |
| 打开文件 / 在访达中显示 / 打开 URL | `/usr/bin/open` | `app/engine/src/platform.rs` 收敛：iOS 上返回 `false`，由界面弹系统分享面板 |
| 系统版本判断 | `/usr/bin/sw_vers` | iOS 上用不到（系统声音永远没有），固定返回 `None` |
| 删除 | `FileManager.trashItem`（真废纸篓） | 挪到同级 `.tingo-trash/` 目录，仍可恢复，界面语义不变 |
| 配置目录 | `~/.config/tingo/config.toml` | `Library/Application Support/tingo/config.toml`（不进「文件」App、不进 iCloud 备份） |
| 会议目录 | `~/Documents/Tingo` | 沙盒 `<容器>/Documents/Tingo`，配合 `UIFileSharingEnabled` 在「文件」App 里可见 |
| 识别模型 | App 数据目录 `models/`，界面里下载 | 同样在 App 内下载到 App 数据目录 `models/`，约 330 MB，不进 ipa |
| 本地服务 | axum 只听 `127.0.0.1` | 不变；ATS 只放开 `NSAllowsLocalNetworking` |
| 打包 | `tauri build` 出 `.app` / `.dmg`，Developer ID 签名 + 公证 | `tauri ios init` 生成 `gen/apple`，`tauri ios build --target …`，未签名 ipa 自己签 |

---

## 识别引擎的交叉编译

引擎是纯 Rust（`app/engine`，crate `tingo-engine`），识别/断句/VAD/声纹都靠 `sherpa-onnx`。交叉编译到 iOS 有几个关键点：

1. **Rust target**：`aarch64-apple-ios`（真机）和 `aarch64-apple-ios-sim`（Apple Silicon 上的模拟器）。构建脚本会 `rustup target add`，并且在 `app/src-tauri/` 里执行，让 rustup 读到 `rust-toolchain.toml` 钉住的工具链版本（当前 1.95.0）。
2. **iOS 上只能动态链接**：`sherpa-onnx-sys` 的 `build.rs` 在 `CARGO_CFG_TARGET_OS=ios` 时强制走 shared 模式（即使开了 `static` feature），链接 `libsherpa-onnx-c-api.dylib`；onnxruntime 是静态打进这个 dylib 里的，所以不用再单独链接 onnxruntime。
3. **xcframework 会自动下载**：同一个 `build.rs` 会去 GitHub releases 拉 `sherpa-onnx-v2.0.1-ios-shared-onnxruntime-static`（首次编译需要网络，几十 MB），解包到 cargo 的 `OUT_DIR` 下，然后复制成 `app/src-tauri/sherpa-onnx.xcframework`。
4. **必须让 Xcode 引用它**：`app/src-tauri/tauri.conf.json` 的 `bundle.iOS.frameworks` 里要有 `"sherpa-onnx.xcframework"`，`tauri ios init` 才会把它写进 `gen/apple/project.yml`，Xcode 才会 embed。缺这一步的表现是：编译一切正常、ipa 也打出来了，但真机一启动就闪退（dyld 找不到 `libsherpa-onnx-c-api`）。
   **这一步构建脚本自动做了，不用手动改**：脚本在 `tauri ios init` 之前检查 `app/src-tauri/sherpa-onnx.xcframework`，存在且 conf 里没写就自动 append 并重跑 init；首次构建时 xcframework 是 cargo 阶段才下载的，所以文件不存在时先只提示，构建完自检 `project.yml` 缺引用会自动补 conf + 重跑 init + 增量重建一次。打包前还会检查 `Payload/Tingo.app/Frameworks` 里有没有 sherpa，没有就 warn 出来。
5. **其余依赖**：`faer`、`reqwest`（rustls）、`bzip2`、`tar`、`chrono` 等都是纯 Rust 或自带构建，不需要额外系统库；不需要 ffmpeg，也不需要 Python。
6. **时间成本**：首次交叉编译（含下载 xcframework）通常十几到三十几分钟，CI 冷启动更慢，所以 workflow 的超时给到 120 分钟；重复构建有 `target/` 缓存会快很多。
7. **模拟器 vs 真机**：`--target aarch64-sim` 出的是模拟器包，只跑模拟器；脚本默认只做真机（`aarch64`）。Tauri 2 的 `--target` 取值是 cargo-mobile2 的简写（`aarch64` / `x86_64` / `aarch64-sim` / `x86_64-sim`），脚本会先读 `tauri ios build --help` 再决定传什么，版本对不上会自动降级。

---

## 已知风险

- **长时间录音可能被挂起**：iOS 靠 `UIBackgroundModes=audio` 续命，但低电量模式、内存压力、来电、其它 App 抢音频会话都可能打断录音；`TingoAudio.swift` 会处理中断通知并尝试恢复，仍建议长会时别锁屏、别开低电量模式，隔一阵瞄一眼录音状态。
- **发热与耗电**：转写是 CPU 密集活，A 系列芯片长时间跑会明显发热、掉电快；边充边录更烫，能接受的话优先录完再转写。
- **jetsam 内存上限**：iOS 对单 App 内存有硬上限，`Fun-ASR-Nano` 这类大模型（约 2 GB 内存）在旧机型上更容易被系统杀掉；默认的 Paraformer 更稳。
- **首次使用要联网下模型**：约 330 MB、走 Hugging Face / ModelScope 镜像，下载中断得重来；下好之后转写全程离线。
- **免费签名 7 天到期**：到期后 App 图标点不开，重签一次即可；会议数据在 App 沙盒里，重签是同名覆盖安装，一般不会丢；**删掉 App 则数据一起没**。
- **未签名 ipa 直接装不上**：必须先自签；自签环境里部分需要 entitlement 的系统能力（推送、iCloud 容器等）用不了，Tingo 本身不依赖它们。
- **录不到对方声音**：见功能对照表，线上会议只能录到你自己这一侧，靠外放让麦克风把对方声音收进来。

---

## 二次开发

**引擎（Rust）**

- 新接口加在 `app/engine/src/server.rs`（axum 路由 + JSON），业务逻辑放同 crate 的模块；前端调用走 `app/src/api.ts`。
- 平台差异集中在两处：`record.rs` 顶部的 `#[cfg(target_os = "ios")]` 分叉，和 `platform.rs`（打开文件 / 在访达里显示 / 系统版本）。iOS 沙盒里别直接 `Command::new("/usr/bin/...")`，一律走 `platform.rs` 或 Swift 桥。
- 加 Swift 能力：写在 `app/ios/TingoAudio.swift`，用 `@_cdecl("tingo_ios_xxx")` 导出；Rust 侧在 `app/engine/src/ios.rs` 里 `extern "C"` 声明并包一层安全函数。构建脚本会把文件拷进 `gen/apple/tingo_iOS/` 并重新 `xcodegen generate`，所以不用手动改 Xcode 工程。

**前端（TS）**

- 页面在 `app/src/views/`，工具与状态在 `app/src/`（`api.ts`、`state.ts`、`dom.ts`、`style.css`），`i18n.ts` 里有中英两套文案。
- 构建产物落在仓库根 `src/tingo/web`（`app/vite.config.ts` 的 `build.outDir`），`tauri.conf.json` 的 `frontendDist` 指向它；`target: "safari16"` 与最低 iOS 16 对应。

**跑起来**

```sh
# 只调界面
cd app && pnpm dev

# 真机调试（需要签名与已配对设备）
cd app && pnpm tauri ios dev

# 出 ipa
bash app/scripts/build-ios.sh
```

`app/src-tauri/gen/` 是生成物，已在 `app/.gitignore` 里忽略，别提交。

---

## 许可

与上游一致，MIT。本项目只做本地录音与本地转写，会议数据留在设备上。
