# Tingo 听过 · iOS 移植分支

把 [tancheng33/tingo](https://github.com/tancheng33/tingo)（macOS 本地会议纪要 App）改造成 **能在 iPhone 上独立运行的 App**：录音、转写、区分说话人、生成纪要、搜索、导出全部在手机上完成，不连电脑、不上传录音。许可证沿用上游 MIT。

> 上游只发布 Apple 芯片的 macOS 版。这个分支保留了完整的 macOS 目标（原代码路径一行没删），新增 iOS 目标。

---

## 1. 现在是什么状态

| 项目 | 状态 |
|---|---|
| 代码改造 | 完成（Rust 引擎 + Tauri 外壳 + Swift 音频桥 + 前端移动端适配） |
| 编译验证 | **未在本机跑过**：本仓库是在 Linux（飞牛 NAS）上改的，没有 Xcode、没有 iOS SDK、没有 Rust 工具链 |
| 产出 ipa | 必须在 macOS 上构建；本分支附了一条命令的脚本和 GitHub Actions 流水线 |
| 签名安装 | 自己做（Sideloadly / AltStore / TrollStore），产物是未签名 ipa |

iOS 的编译器、链接器、SDK、codesign 只存在于 macOS，Linux 上无法产出任何可安装的 ipa —— 这不是代码问题，是苹果工具链的发行方式。所以这里给的是"源码 + 一键构建链"，落地两步：

```
git clone <你的仓库>   →  macOS 上跑一条命令  →  得到 Tingo-unsigned.ipa  →  Sideloadly 签进 iPhone
```

没有 Mac 也行：把仓库推到你自己的 GitHub，点 Actions → iOS Unsigned IPA → 下载 artifact（用 macOS runner 白嫖编译）。

---

## 2. 三步出 ipa

### 路线 A：本机 macOS（需要 Xcode 16+，约 20 分钟）

```bash
cd tingo-ios
bash app/scripts/build-ios.sh
# 产物：build/ios/Tingo-unsigned.ipa
```

第一次会自动做：`rustup target add aarch64-apple-ios` → `pnpm install` + 前端构建 → `tauri ios init`（生成 Xcode 工程）→ 拷入 Swift 音频桥 → 往 Info.plist 注入麦克风/后台音频/ATS 声明 → `tauri ios build` → 打包成未签名 ipa。

想用自己的开发者账号直接出可安装包：

```bash
TEAM_ID=ABCDE12345 bash app/scripts/build-ios.sh
```

### 路线 B：GitHub Actions（不用 Mac）

推到 GitHub → Actions 里手动运行 `iOS Unsigned IPA`，或者打一个 `v*` tag → 跑完在 Artifacts 里下载 `Tingo-unsigned-ipa`。

### 装进 iPhone

- **Sideloadly**（Windows/Mac 都有）：拖入 ipa + Apple ID，填 bundle id 后缀，装完在「设置 → 通用 → VPN 与设备管理」里信任。
- **AltStore / SideStore**：装一次后每 7 天自动续签，省得反复插线。
- **TrollStore**（仅部分 iOS 版本）：可直接装未签名包，永久有效。
- 免费 Apple ID 签名 **7 天到期**，App 会打不开，需要重签；$99/年的开发者账号是 1 年。到期重签不会丢数据（同一个 bundle id 覆盖安装）。

---

## 3. 功能对照

| 功能 | iOS 版 | 说明 |
|---|---|---|
| 本地录音（麦克风） | ✅ | AVAudioEngine，16 kHz 单声道，后台继续录 |
| 录到会议软件里对方的声音 | ❌ | iOS 沙盒不允许 App 拿别的 App 的音频（没有 ScreenCaptureKit），只能录麦克风；开免提时对方声音会经麦克风录进来 |
| 本地转写（Paraformer / SenseVoice / Fun-ASR-Nano） | ✅ | 与 macOS 同一套 sherpa-onnx + FunASR 模型，纯本地 |
| 声纹区分说话人 | ✅ | CAM++ + 谱聚类，接口和算法未改 |
| 边录边转、自动结束录音 | ✅（部分） | "连续 N 分钟没人说话"生效；"会议软件退出就结束"无进程列表，已自动关闭 |
| 生成纪要（DeepSeek / 通义 / Ollama / 任意 OpenAI 兼容） | ✅ | 只上传转写文字；接 Ollama 可全程离线 |
| 鱼骨图 + 原话核实 | ✅ | 纯计算 + 前端渲染 |
| 搜索、标签、归档、批量操作、历史版本 | ✅ | |
| 导出 PDF | ✅ | 进程内 UIPrintPageRenderer，A4 |
| 导出 SRT / Markdown / 复制 | ✅ | |
| 导出 Word（.docx） | ❌ | 原来靠 macOS 的 textutil；iOS 上返回提示，建议导 PDF |
| 存 Obsidian / 推送到飞书钉钉群 | ⚠️ | webhook 推送可用；Obsidian 需要外部仓库目录，iOS 沙盒外不可写，该入口会报错 |
| 应用内自动更新 | ❌ | 改为重签名安装 / TestFlight |
| 会议文件在「文件」App 里可见 | ✅ | 沙盒 `Documents/Tingo/`，Info.plist 已开 UIFileSharingEnabled |
| 拖拽导入 | ⚠️ | 桌面拖拽换成「导入」按钮（iOS 上从文件 App / 相册选） |

---

## 4. 改了哪些东西

### 新增文件

| 文件 | 作用 |
|---|---|
| `app/ios/TingoAudio.swift` | **核心**：进程内替代 macOS 的 `tingo-recorder`。AVAudioEngine 录音写 16 kHz wav、AVAssetReader 解码任意音视频、AVAssetWriter 压 AAC m4a、UIPrintPageRenderer 出 A4 PDF，全部 `@_cdecl` 暴露给 Rust |
| `app/engine/src/ios.rs` | Rust 侧的 FFI 声明与错误传递（`tingo_ios_*`） |
| `app/engine/src/record_ios.rs` | iOS 的 `Recorder`，接口与 macOS 版一致（`start/elapsed/exited/stop`） |
| `app/engine/src/platform.rs` | 平台差异收敛：`open_path` / `reveal_path` / `open_url` / `os_major_version`，iOS 上是空操作 |
| `app/src-tauri/src/updater_ios.rs` | iOS 的更新占位（四个命令均返回"请重签名安装"） |
| `app/scripts/build-ios.sh` | macOS 一键构建未签名 ipa |
| `.github/workflows/ios.yml` | macOS runner 上出 ipa artifact |
| `docs/ios-port.md` | 完整的移植与排错文档 |

### 改动文件（都为 `#[cfg(target_os = "ios")]` 分叉，macOS 行为不变）

- `app/engine/src/record.rs`：每个平台相关函数拆成同名的两个 cfg 版本（录音、PDF、Word、解码、混音、删除），平台无关部分共用
- `app/engine/src/server.rs`：9 处 `/usr/bin/open` → `platform::*`；`system_audio_supported` 走 `platform::os_major_version`（iOS 恒 false，界面自动隐藏系统声音开关）；`choose_storage` / `download_update` 在 iOS 上直接返回可读提示
- `app/engine/src/autostop.rs`：iOS 没有 `ps`，`running_meeting_apps()` 返回空
- `app/engine/src/config.rs`：iOS 配置落 `Library/Application Support/tingo/config.toml`
- `app/engine/src/models.rs`：`catalog()` 在 iOS 上过滤掉 Apple Speech（它依赖子进程）
- `app/engine/src/lib.rs`：挂上 `ios` / `platform` 模块
- `app/src-tauri/src/lib.rs`：recorder 路径按平台给；updater 插件与命令按平台编
- `app/src-tauri/Cargo.toml`：`tauri-plugin-updater` 只在非 iOS 目标
- `app/src-tauri/tauri.conf.json`：新增 `bundle.iOS`（最低 iOS 16.0）
- `app/src-tauri/capabilities/default.json`：声明 `platforms: ["macOS","iOS"]`
- `app/index.html` + `app/src/style.css`：iPhone 适配（安全区、抽屉式侧栏、44pt 触摸目标、16px 输入框防放大、横屏图标栏）

### 关键设计说明

**为什么用「本地 HTTP 服务 + WKWebView」而不是纯原生界面？** 上游本来就是这个形态（Rust 起 axum 只监听 127.0.0.1，前端是同一份 vite 产物），iOS 上照搬最省事，也意味着界面、i18n、路由、样式全部复用，不用重写一份 SwiftUI。代价是需要 ATS 的 `NSAllowsLocalNetworking`，构建脚本已注入。

**录音为什么必须换实现？** iOS 禁止 fork/exec 第三方可执行文件，macOS 版那个 `tingo-recorder` 二进制在 iOS 上既不能打包也不能运行，只能把同样的 AVFoundation 逻辑搬进 App 进程。

**内存与发热**：Paraformer-large int8 常驻约 300–600 MB 峰值，A14 及以后可用；1 小时会议音频按段流式处理，不会把整场 PCM 读进内存（`chunked.rs` 原逻辑）。长时间录音建议插电，iOS 会因温度降频。

---

## 5. 真机上如果出问题，按这个顺序查

1. **白屏 / 一直"本地服务没有启动"**：看 Xcode 控制台的 Rust 日志，多半是端口绑定或模型目录权限；`/api/env` 在 Safari 里直接访问 `http://127.0.0.1:端口/api/env` 能看出服务是否活着。
2. **界面报 `Failed to fetch`**：跨源被拒。用 Safari 的 Web Inspector 看当前页面 origin，把准确的那个加进 `app/engine/src/server.rs` 的 `router()` → `origins` 数组（现在已放了 `tauri://localhost`、`http://tauri.localhost`、`https://tauri.localhost` 三种）。
3. **点录音没反应**：先确认 `设置 → Tingo → 麦克风` 已开；`/api/env` 的 `system_audio` 必须是 `false`（iOS 上永远 false）。
4. **录到一半断了**：来电或其它 App 抢音频会话，日志里有"录音被系统中断"；已实现中断恢复，但通话结束前录不到。
5. **识别模型下载卡住**：模型 330 MB，来自 ModelScope / GitHub，前台下载；切后台会中断（会续传）。
6. **ipa 装不上 / 装完闪退**：免费证书 7 天到期、bundle id 冲突、或设备没信任证书；用 Xcode 的 Devices 窗口看崩溃日志，最常见是 `sherpa-onnx` 静态库架构不匹配（要 `arm64`，不是 `arm64-simulator`）。

---

## 6. 许可

上游 MIT，本分支同样 MIT。二次分发请保留 `LICENSE` 与作者署名。
