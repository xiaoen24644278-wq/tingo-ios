#!/usr/bin/env bash
# Tingo 听过 iOS 一键构建：产出未签名 ipa（Tingo-unsigned.ipa），自签后装到 iPhone。
#
# 用法（仓库任意位置执行）：
#   bash app/scripts/build-ios.sh                        # 不签名，纯未签名 ipa
#   TEAM_ID=ABCDE12345 bash app/scripts/build-ios.sh     # 走 Xcode 自动签名
#   CONFIG=debug bash app/scripts/build-ios.sh           # Debug 配置
#
# 可覆盖的环境变量：TEAM_ID / CONFIG / SCHEME / IPA_NAME / EXPORT_METHOD / IOS_TARGET /
#                   DEPLOYMENT_TARGET / ALLOW_MISSING_AUDIO_BRIDGE
#
# 产物：<仓库>/build/ios/Tingo-unsigned.ipa（另有 build/ios/Payload/Tingo.app 便于检查）
#
# 兼容 macOS 自带的 bash 3.2（GitHub Actions 的 macos runner 与新版 macOS 都是它），
# 不用关联数组、不用 readarray、不依赖空数组在 set -u 下的行为。
set -euo pipefail

# ---------------------------------------------------------------- 基本路径与参数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_DIR="${REPO_ROOT}/app"
TAURI_DIR="${APP_DIR}/src-tauri"
GEN_DIR="${TAURI_DIR}/gen/apple"
WEB_DIST="${REPO_ROOT}/src/tingo/web"
SAMPLE_DIST="${REPO_ROOT}/src/tingo/sample"
AUDIO_SWIFT_SRC="${APP_DIR}/ios/TingoAudio.swift"

OUT_DIR="${REPO_ROOT}/build/ios"
PAYLOAD_DIR="${OUT_DIR}/Payload"

CONFIG="${CONFIG:-release}"
TEAM_ID="${TEAM_ID:-}"
SCHEME="${SCHEME:-}"
IPA_NAME="${IPA_NAME:-Tingo-unsigned.ipa}"
EXPORT_METHOD="${EXPORT_METHOD:-}"
IOS_TARGET="${IOS_TARGET:-auto}"
ALLOW_MISSING_AUDIO_BRIDGE="${ALLOW_MISSING_AUDIO_BRIDGE:-0}"
# 最低系统版本：和 tauri.conf.json 的 bundle.iOS.minimumSystemVersion 以及
# app/vite.config.ts 的 build.target "safari16" 对齐，统一 iOS 16.0
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-16.0}"

# 识别引擎的 iOS 依赖（默认在线预取官方 xcframework；SHERPA_ONNX_IOS=0 只验壳体与界面）
SHERPA_ONNX_IOS="${SHERPA_ONNX_IOS:-1}"
SHERPA_ONNX_STATIC_BUILD="${SHERPA_ONNX_STATIC_BUILD:-0}"
SHERPA_ONNX_SKIP_DOWNLOAD="${SHERPA_ONNX_SKIP_DOWNLOAD:-0}"
SHERPA_ONNX_ONNXRUNTIME_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.28.2}"
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-2.0.1}"
SHERPA_ONNX_SRC="${SHERPA_ONNX_SRC:-}"
ENABLE_BITCODE="${ENABLE_BITCODE:-NO}"
IOS_CMAKE_URL="${IOS_CMAKE_URL:-https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake}"
SHERPA_XCF_RELEASE_URL="${SHERPA_XCF_RELEASE_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework}"
ORT_RELEASE_URL="${ORT_RELEASE_URL:-https://github.com/csukuangfj/onnxruntime-libs/releases/download}"

PBUDDY="/usr/libexec/PlistBuddy"
MIC_USAGE_TEXT="会听HuiT 需要麦克风来录下会议里你自己的声音，录音只保存在这台手机上。"

log()  { printf '\033[1;34m[ios]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[ios] 警告：\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ios] 失败：\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 环境检查
step "检查构建环境"
[[ "$(uname -s || true)" == "Darwin" ]] || die "这个脚本只能在 macOS 上跑（需要 Xcode 和 iOS SDK）：Linux 上请用 GitHub Actions，见 .github/workflows/ios.yml。"

if ! command -v xcodebuild >/dev/null 2>&1; then
  die "找不到 xcodebuild：先装好 Xcode（App Store 或 developer.apple.com），然后执行
      sudo xcode-select --switch /Applications/Xcode.app
      sudo xcodebuild -license accept"
fi
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode 命令行工具没选好：执行 sudo xcode-select --switch /Applications/Xcode.app"
fi
if ! command -v pnpm >/dev/null 2>&1; then
  die "找不到 pnpm：先执行 corepack enable（或 npm install -g pnpm），再重跑本脚本。"
fi
if ! command -v cargo >/dev/null 2>&1; then
  die "找不到 cargo：先装 Rust（https://rustup.rs），再重跑本脚本。"
fi
if ! command -v rustup >/dev/null 2>&1; then
  die "找不到 rustup：iOS 交叉编译要用 rustup 装 target，请用 rustup 装的 Rust。"
fi
if ! command -v zip >/dev/null 2>&1; then
  die "找不到 zip：打 ipa 用的是 macOS 自带的 /usr/bin/zip，检查 PATH。"
fi

log "Xcode：$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || true)"
log "pnpm：$(pnpm --version || true)   cargo：$(cargo --version || true)   配置：${CONFIG}   最低系统：iOS ${DEPLOYMENT_TARGET}"
log "前端按 safari16 降级（app/vite.config.ts），所以最低系统定为 iOS 16.0"

if [[ -n "${TEAM_ID}" ]]; then
  log "TEAM_ID=${TEAM_ID}：走 Xcode 自动签名"
  APPLE_DEVELOPMENT_TEAM="${TEAM_ID}"
  export APPLE_DEVELOPMENT_TEAM
else
  log "TEAM_ID 为空：构建未签名 ipa（之后用 Sideloadly / AltStore / TrollStore 自签安装）"
fi

# ---------------------------------------------------------------- Rust target
step "安装 iOS Rust target（aarch64-apple-ios / aarch64-apple-ios-sim）"
# 在 src-tauri 里执行，让 rustup 读到 rust-toolchain.toml 钉住的工具链版本
if ! ( cd "${TAURI_DIR}" && rustup target add aarch64-apple-ios aarch64-apple-ios-sim ); then
  die "rustup target add 失败：检查网络，或手动执行
      cd app/src-tauri && rustup target add aarch64-apple-ios aarch64-apple-ios-sim"
fi
log "Rust target 就绪"

# ---------------------------------------------------------------- 前端产物
step "安装前端依赖并构建（产物：src/tingo/web）"
if ! ( cd "${APP_DIR}" && pnpm install --frozen-lockfile ); then
  warn "pnpm install --frozen-lockfile 失败（lockfile 和 package.json 不一致？），改用 pnpm install"
  ( cd "${APP_DIR}" && pnpm install )
fi
( cd "${APP_DIR}" && pnpm build )

if [[ ! -f "${WEB_DIST}/index.html" ]]; then
  die "前端产物没生成：${WEB_DIST}/index.html 不存在。
      tauri.conf.json 的 frontendDist 是 ../../src/tingo/web（仓库根的 src/tingo/web），
      检查 app/vite.config.ts 的 build.outDir 和 pnpm build 的报错。"
fi
log "前端产物就绪：${WEB_DIST}"

# tauri.conf.json 的 bundle.resources 引用了 ../../src/tingo/sample，缺目录会让 iOS 打包失败
if [[ ! -d "${SAMPLE_DIST}" ]]; then
  warn "仓库里没有 ${SAMPLE_DIST}（tauri.conf.json 的 bundle.resources 引用了它），先建空目录占位"
  mkdir -p "${SAMPLE_DIST}"
  : > "${SAMPLE_DIST}/.gitkeep"
fi

# tauri.conf.json 的 bundle.resources 声明了 bin/tingo-recorder（macOS 的 Swift 录音子进程）。
# iOS 上根本不会执行它，但资源清单里有这一项，文件不存在时 `tauri ios build` 会直接报
#   failed to get resource: resource path `bin/tingo-recorder` doesn't exist
# 所以先放一个可执行的空壳占位。touch 一下让 src-tauri/build.rs 的 mtime 判断认为它是最新的，
# 避免它在这里用 swiftc 编出一个 macOS 二进制塞进 iOS 包里。
RECORDER_PLACEHOLDER="${TAURI_DIR}/bin/tingo-recorder"
if [[ ! -f "${RECORDER_PLACEHOLDER}" ]]; then
  mkdir -p "$(dirname "${RECORDER_PLACEHOLDER}")"
  printf '#!/bin/sh\nexit 0\n' > "${RECORDER_PLACEHOLDER}"
  chmod +x "${RECORDER_PLACEHOLDER}"
  log "已创建 bin/tingo-recorder 占位（iOS 不使用，只为满足资源清单）"
fi
[[ -x "${RECORDER_PLACEHOLDER}" ]] || chmod +x "${RECORDER_PLACEHOLDER}"
touch "${RECORDER_PLACEHOLDER}"

# ---------------------------------------------------------------- Tauri iOS 工程
step "准备 Tauri iOS 工程（gen/apple）"

# `tauri ios init` 内部就是调 xcodegen 生成 .xcodeproj，所以它得先有
XCODEGEN_OK=0
if command -v xcodegen >/dev/null 2>&1; then
  XCODEGEN_OK=1
  log "xcodegen：$(xcodegen --version 2>/dev/null | head -1 || true)"
elif command -v brew >/dev/null 2>&1; then
  warn "没装 xcodegen，尝试 brew install xcodegen"
  if brew install xcodegen && command -v xcodegen >/dev/null 2>&1; then
    XCODEGEN_OK=1
  fi
fi
if [[ "${XCODEGEN_OK}" != "1" ]]; then
  warn "没有 xcodegen：执行 brew install xcodegen 后重跑本脚本。"
  if [[ ! -d "${GEN_DIR}" ]]; then
    die "gen/apple 还不存在，而 pnpm tauri ios init 必须有 xcodegen 才能生成 Xcode 工程。先 brew install xcodegen。"
  fi
fi

# --------------------------------------- 6. 识别引擎的 iOS 库（硬要求 3）
step "准备识别引擎（sherpa-onnx）的 iOS 依赖"

if [[ "${SHERPA_ONNX_IOS}" = "0" ]]; then
  log "SHERPA_ONNX_IOS=0：跳过 toolchain / onnxruntime / xcframework 的全部准备"
  warn "本次构建只能验证壳体 + 界面能编过：App 内识别、标点、声纹不可用"
  export TINGO_ASR_DISABLED=1
else
  # 6a. 探测 CMake toolchain（ios-cmake）。只有自建静态库那条路线（SHERPA_ONNX_STATIC_BUILD=1）
  #     真的需要它；默认路线用官方预编译 xcframework，不需要 cmake，所以下载失败不致命。
  TOOLCHAIN_DIR="${OUT_DIR}/ios-cmake"
  TOOLCHAIN=""
  for cand in \
    "${TAURI_DIR}/gen/apple/ios.toolchain.cmake" \
    "${TAURI_DIR}/gen/apple/toolchains/ios.toolchain.cmake" \
    "${APP_DIR}/ios/toolchains/ios.toolchain.cmake" \
    "${TOOLCHAIN_DIR}/ios.toolchain.cmake"; do
    if [[ -f "${cand}" ]]; then
      TOOLCHAIN="${cand}"
      break
    fi
  done
  if [[ -z "${TOOLCHAIN}" ]]; then
    mkdir -p "${TOOLCHAIN_DIR}"
    log "本地没有 toolchain，下载 ${IOS_CMAKE_URL} → ${TOOLCHAIN_DIR}/ios.toolchain.cmake"
    if curl -fL --retry 3 --connect-timeout 20 --max-time 300 \
        -o "${TOOLCHAIN_DIR}/ios.toolchain.cmake" "${IOS_CMAKE_URL}"; then
      TOOLCHAIN="${TOOLCHAIN_DIR}/ios.toolchain.cmake"
    elif [[ "${SHERPA_ONNX_STATIC_BUILD}" = "1" ]]; then
      die "下载 ios.toolchain.cmake 失败，而自建静态库路线必须有它（CI 里检查出网策略）"
    else
      warn "下载 ios.toolchain.cmake 失败：默认路线用预编译 xcframework，不需要 cmake toolchain，继续构建"
      TOOLCHAIN=""
    fi
  fi
  if [[ -n "${TOOLCHAIN}" ]]; then
    export CMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}"
  fi

  if [ "${IOS_TARGET#*-sim}" != "$IOS_TARGET" ]; then
    export PLATFORM="${PLATFORM:-SIMULATORARM64}"
  else
    export PLATFORM="${PLATFORM:-OS64}"
  fi
  export DEPLOYMENT_TARGET ENABLE_BITCODE
  export ENABLE_ARC=1 ENABLE_VISIBILITY=0 CMAKE_BUILD_TYPE=Release BUILD_SHARED_LIBS=OFF
  export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

  log "CMAKE_TOOLCHAIN_FILE : ${CMAKE_TOOLCHAIN_FILE:-（默认路线不需要，未设置）}"
  log "PLATFORM             : $PLATFORM"
  log "DEPLOYMENT_TARGET    : $DEPLOYMENT_TARGET"
  log "ENABLE_BITCODE       : $ENABLE_BITCODE"

  if [[ "${SHERPA_ONNX_STATIC_BUILD}" = "1" ]]; then
    # 6b. 自建静态库路线：需要 sherpa-onnx 源码 + onnxruntime 的 iOS 静态库。
    #     注意：sherpa-onnx-sys 2.0.1 的 build.rs 在 iOS 上强制走 shared，
    #     想真正静态链接还必须打 docs/ios-port.md 里那几行 patch。
    [[ -n "${SHERPA_ONNX_SRC:-}" ]] || die "SHERPA_ONNX_STATIC_BUILD=1 需要 SHERPA_ONNX_SRC=/path/to/sherpa-onnx（源码目录）"
    [[ -d "${SHERPA_ONNX_SRC}" ]] || die "SHERPA_ONNX_SRC 指向的目录不存在：$SHERPA_ONNX_SRC"
    command -v cmake >/dev/null 2>&1 || die "SHERPA_ONNX_STATIC_BUILD=1 需要 cmake"

    ORT_ROOT="${OUT_DIR}/ios-onnxruntime/${SHERPA_ONNX_ONNXRUNTIME_VERSION}"
    if [[ ! -d "${ORT_ROOT}/onnxruntime.xcframework" ]]; then
      mkdir -p "$ORT_ROOT"
      ORT_ZIP="$ORT_ROOT/onnxruntime-ios-static-xcframework-$SHERPA_ONNX_ONNXRUNTIME_VERSION.xcframework.zip"
      log "下载 onnxruntime iOS 静态 xcframework v$SHERPA_ONNX_ONNXRUNTIME_VERSION"
      curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$ORT_ZIP" \
        "$ORT_RELEASE_URL/v$SHERPA_ONNX_ONNXRUNTIME_VERSION/onnxruntime-ios-static-xcframework-$SHERPA_ONNX_ONNXRUNTIME_VERSION.xcframework.zip" \
        || die "下载 onnxruntime iOS 静态库失败"
      unzip -q -o "$ORT_ZIP" -d "$ORT_ROOT" || die "解压 onnxruntime 静态库失败：$ORT_ZIP"
    fi
    [[ -d "${ORT_ROOT}/onnxruntime.xcframework" ]] || die "解压后没找到 $ORT_ROOT/onnxruntime.xcframework"
    export SHERPA_ONNXRUNTIME_LIB_DIR="$ORT_ROOT/onnxruntime.xcframework/ios-arm64"
    export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ORT_ROOT/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Headers"
    log "SHERPA_ONNXRUNTIME_LIB_DIR: $SHERPA_ONNXRUNTIME_LIB_DIR"

    SB="$SHERPA_ONNX_SRC/build-ios"
    mkdir -p "$SB"
    log "cmake 配置 sherpa-onnx（$PLATFORM，静态库）"
    cmake -S "$SHERPA_ONNX_SRC" -B "$SB/$PLATFORM" \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
      -DPLATFORM="$PLATFORM" \
      -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
      -DENABLE_BITCODE=OFF \
      -DENABLE_ARC=1 \
      -DENABLE_VISIBILITY=0 \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$SB/install" \
      -DBUILD_SHARED_LIBS=OFF \
      -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
      -DSHERPA_ONNX_ENABLE_BINARY=OFF \
      -DSHERPA_ONNX_ENABLE_TESTS=OFF \
      -DSHERPA_ONNX_ENABLE_CHECK=OFF \
      -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
      -DSHERPA_ONNX_ENABLE_JNI=OFF \
      -DSHERPA_ONNX_ENABLE_C_API=ON \
      -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
    cmake --build "$SB/$PLATFORM" -j "$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    cmake --build "$SB/$PLATFORM" --target install

    C_API_A="$(find "$SB/$PLATFORM" -name 'libsherpa-onnx-c-api.a' -type f 2>/dev/null | head -1)"
    [ -n "$C_API_A" ] || die "自建静态库失败：没找到 libsherpa-onnx-c-api.a"
    export SHERPA_ONNX_LIB_DIR="$(dirname "$C_API_A")"
    log "SHERPA_ONNX_LIB_DIR: $SHERPA_ONNX_LIB_DIR"
    warn "静态路线还需要给 sherpa-onnx-sys 打 patch（去掉 iOS 强制 shared），见 docs/ios-port.md"
  else
    # 6c. 默认路线：sherpa-onnx 2.0.1 在 iOS 上只支持 shared，用官方
    #     ios-shared-onnxruntime-static.xcframework（onnxruntime 已静态链进 dylib）。
    #     必须在 build 之前就放到 src-tauri/，因为 Xcode 在跑任何 build phase 之前
    #     就检查 xcframework 是否存在，build.rs 里再下载已经来不及。
    XCFF="$APP_DIR/src-tauri/sherpa-onnx.xcframework"
    if [ -d "${XCFF}" ]; then
      log "xcframework 已存在：${XCFF}"
    elif [[ "${SHERPA_ONNX_SKIP_DOWNLOAD}" = "1" ]]; then
      warn "SHERPA_ONNX_SKIP_DOWNLOAD=1 且没有 ${XCFF}，链接阶段大概率报 framework not found"
    else
      XCFF_ZIP=""${OUT_DIR}/"sherpa-onnx-v$SHERPA_ONNX_VERSION-ios-shared-onnxruntime-static.xcframework.zip"
      mkdir -p "${OUT_DIR}"
      if [ ! -f "$XCFF_ZIP" ]; then
        log "下载 sherpa-onnx v$SHERPA_ONNX_VERSION 的 iOS xcframework（约 30 MB）"
        curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$XCFF_ZIP" \
          "$SHERPA_XCF_RELEASE_URL/sherpa-onnx-v$SHERPA_ONNX_VERSION-ios-shared-onnxruntime-static.xcframework.zip" \
          || die "下载 sherpa-onnx xcframework 失败"
      fi
      unzip -q -o "$XCFF_ZIP" -d "${TAURI_DIR}" || die "解压 sherpa-onnx xcframework 失败：$XCFF_ZIP"
      # 压缩包里偶尔叫 SherpaOnnxC.xcframework，统一改成 bundle.iOS.frameworks 里的名字
      if [ -d "${TAURI_DIR}/SherpaOnnxC.xcframework" ] && [ ! -d "${XCFF}" ]; then
        mv "${TAURI_DIR}/SherpaOnnxC.xcframework" "${XCFF}"
      fi
      [ -d "${XCFF}" ] || die "解压后没找到 sherpa-onnx.xcframework，检查 $XCFF_ZIP 的内容"
      log "已放入：${XCFF}"
    fi
  fi
fi


# ------------------------------------------------- 识别引擎 xcframework → tauri.conf.json
# iOS 上 sherpa-onnx 只能动态链接：sherpa-onnx-sys 的 build.rs 会下载官方 xcframework 并复制到
# app/src-tauri/sherpa-onnx.xcframework。这个 xcframework 必须写进 tauri.conf.json 的
# bundle.iOS.frameworks，Xcode 才会 embed；缺了的表现是编译一切正常、ipa 也能打出来，但真机
# 一启动就 dyld 找不到 libsherpa-onnx-c-api 闪退。
#
# 为什么放在 init 之前：`tauri ios init` 用 bundle.iOS.frameworks 渲染 gen/apple/project.yml，
# 只有先写 conf 再 init，frameworks 才会进 Xcode 工程。
# 为什么先判断文件存在：xcframework 在第一次 cargo 编译（tauri ios build 内部）时才下载，
# 引用一个还不存在的路径会让 xcodegen 生成工程失败。文件不存在时保持只提示，不写 conf；
# 等 build 之后自检发现工程里没有它，再补写 + 重跑 init + 重建一次（见构建后的 self-heal）。
# 幂等：条目已在数组里就不再写文件（python 打印 present），重复跑不会重复 append。
XCFF="${TAURI_DIR}/sherpa-onnx.xcframework"
FRAMEWORKS_INJECTED=0

# --------------------------------------- developmentTeam（tauri ios init 的硬要求）
# `tauri ios init` 会校验 bundle.iOS.developmentTeam：为空直接报
#   failed to create Apple configuration: `apple.development-team` is empty
# 然后中止。CI 上没有证书，这里写占位（真正签名是使用者拿 ipa 去 Sideloadly / Xcode 做的）；
# 有 TEAM_ID 时用真的，后续 `tauri ios build` 走自动签名。
ensure_development_team() {
  python3 - "${TAURI_DIR}/tauri.conf.json" "${TEAM_ID:-ABCDE12345}" <<'PY'
import json, sys
conf_path, team = sys.argv[1], sys.argv[2]
with open(conf_path, encoding="utf-8") as f:
    conf = json.load(f)
ios = conf.setdefault("bundle", {}).setdefault("iOS", {})
if ios.get("developmentTeam") == team:
    print("present")
    raise SystemExit(0)
ios["developmentTeam"] = team
with open(conf_path, "w", encoding="utf-8") as f:
    json.dump(conf, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("written")
PY
}

ensure_development_team \
  && log "bundle.iOS.developmentTeam 已就绪：${TEAM_ID:-ABCDE12345}（占位，只用于 init 校验）" \
  || warn "写 developmentTeam 失败：pnpm tauri ios init 可能因 team 为空中止"

inject_sherpa_framework() {
  [[ -d "${XCFF}" ]] || return 1
  sherpa_result="$(python3 - "${TAURI_DIR}/tauri.conf.json" "sherpa-onnx.xcframework" <<'PY'
import json
import sys

conf_path, entry = sys.argv[1], sys.argv[2]
with open(conf_path, encoding="utf-8") as f:
    conf = json.load(f)

bundle = conf.setdefault("bundle", {})
ios = bundle.setdefault("iOS", {})
frameworks = ios.get("frameworks")
if not isinstance(frameworks, list):
    frameworks = []
    ios["frameworks"] = frameworks

if entry in frameworks:
    print("present")
    raise SystemExit(0)

frameworks.append(entry)
with open(conf_path, "w", encoding="utf-8") as f:
    json.dump(conf, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("added")
PY
)" || { warn "写入 tauri.conf.json 的 bundle.iOS.frameworks 失败（python3 报错见上）"; return 1; }

  case "${sherpa_result}" in
    added)
      FRAMEWORKS_INJECTED=1
      log "已写入 bundle.iOS.frameworks：sherpa-onnx.xcframework"
      return 0
      ;;
    present)
      log "bundle.iOS.frameworks 里已经有 sherpa-onnx.xcframework（不重复写）"
      return 0
      ;;
    *)
      warn "识别不到 tauri.conf.json 的处理结果：${sherpa_result}"
      return 1
      ;;
  esac
}

if [[ -d "${XCFF}" ]]; then
  # shellcheck disable=SC2310  # 故意放在 || 后：函数内部自己处理失败并返回状态
  inject_sherpa_framework || true
  # gen/apple 已经生成过：project.yml 是按旧 conf 渲染的，改完 conf 必须重新 init 才会带上 frameworks
  if [[ "${FRAMEWORKS_INJECTED}" == "1" && -d "${GEN_DIR}" ]]; then
    log "gen/apple 已存在：重跑 pnpm tauri ios init 重新渲染 project.yml（frameworks 才会进 Xcode 工程）"
    if ! ( cd "${APP_DIR}" && pnpm exec tauri ios init --ci ); then
      warn "重跑 pnpm tauri ios init 失败：删掉 ${GEN_DIR} 后重跑本脚本，frameworks 才会进工程。"
    fi
  fi
else
  log "还没有 ${XCFF}：第一次编译引擎时（cargo 阶段）会自动下载，需要网络；本轮先不写 bundle.iOS.frameworks"
fi

if [[ ! -d "${GEN_DIR}" ]]; then
  log "首次运行：执行 pnpm tauri ios init 生成 Xcode 工程"
  if ! ( cd "${APP_DIR}" && pnpm exec tauri ios init --ci ); then
    die "pnpm tauri ios init 失败：看上面的日志；常见原因是 identifier 冲突、Xcode 版本太旧、拿不到模板。"
  fi
else
  log "已存在 iOS 工程，跳过 init：${GEN_DIR}"
fi

IOS_DIR=""
for d in "${GEN_DIR}"/*_iOS; do
  if [[ -d "${d}" ]]; then
    IOS_DIR="${d}"
    break
  fi
done
[[ -n "${IOS_DIR}" ]] || die "没找到 gen/apple/*_iOS 目录，iOS 工程不完整：删掉 ${GEN_DIR} 后重跑，或手动 pnpm tauri ios init。"
log "App 源码目录：${IOS_DIR}"

# Scheme：优先环境变量，其次 gen/apple/*_iOS 目录名，最后用 xcodebuild -list 探测
if [[ -z "${SCHEME}" ]]; then
  SCHEME="$(basename "${IOS_DIR}")"
fi
if [[ -z "${SCHEME}" ]]; then
  for proj in "${GEN_DIR}"/*.xcodeproj; do
    if [[ -d "${proj}" ]]; then
      SCHEME="$( cd "${GEN_DIR}" && xcodebuild -list -project "$(basename "${proj}")" 2>/dev/null \
        | awk '/Schemes:/{flag=1; next} flag && NF {gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}' )"
      break
    fi
  done
fi
[[ -n "${SCHEME}" ]] || die "探测不到 Xcode scheme：用 SCHEME=tingo_iOS 显式指定。"
log "使用 scheme：${SCHEME}"

# 最低系统版本一致性：gen/apple/project.yml 里的 deploymentTarget 要和 DEPLOYMENT_TARGET 对齐
if [[ -f "${GEN_DIR}/project.yml" ]]; then
  yml_line="$(grep -m1 -E 'deploymentTarget|IPHONEOS_DEPLOYMENT_TARGET' "${GEN_DIR}/project.yml" || true)"
  if [[ -n "${yml_line}" ]]; then
    yml_ver="$(sed -n 's/[^0-9]*\([0-9][0-9.]*\).*/\1/p' <<<"${yml_line}" | head -1)"
    if [[ -n "${yml_ver}" && "${yml_ver}" != "${DEPLOYMENT_TARGET}" ]]; then
      warn "gen/apple/project.yml 里的最低系统是 ${yml_ver}，脚本按 iOS ${DEPLOYMENT_TARGET} 构建：
      把 project.yml 的 deploymentTarget 改成 ${DEPLOYMENT_TARGET} 后重跑，
      或删掉 ${GEN_DIR} 让 pnpm tauri ios init 用 tauri.conf.json 的 bundle.iOS.minimumSystemVersion 重新生成。"
    fi
  fi
fi

# ---------------------------------------------------------------- Info.plist
# 幂等注入：每个 key 先 Delete（失败忽略）再 Add，重复跑结果一致
plist_apply() {
  plist_file="$1"
  if [[ ! -f "${plist_file}" ]]; then
    warn "没有 ${plist_file}，跳过 Info.plist 注入"
    return 0
  fi
  [[ -x "${PBUDDY}" ]] || die "找不到 ${PBUDDY}：需要 Xcode 命令行工具（xcode-select --install）。"

  pb_del() { "${PBUDDY}" -c "Delete $1" "${plist_file}" >/dev/null 2>&1 || true; }
  pb_add() {
    if ! "${PBUDDY}" -c "Add $1 $2" "${plist_file}" >/dev/null 2>&1; then
      warn "PlistBuddy 写入失败：Add $1 $2（${plist_file}）"
    fi
  }

  # 麦克风：没有这条 iOS 直接把 App 杀掉
  pb_del ":NSMicrophoneUsageDescription"
  pb_add ":NSMicrophoneUsageDescription" "string ${MIC_USAGE_TEXT}"

  # 后台音频：切到别的 App、锁屏时录音不被立刻掐断
  pb_del ":UIBackgroundModes"
  pb_add ":UIBackgroundModes" "array"
  pb_add ":UIBackgroundModes:0" "string audio"

  # 本地 127.0.0.1 的 HTTP：只放开本地网络，不整体放开 ATS
  pb_del ":NSAppTransportSecurity"
  pb_add ":NSAppTransportSecurity" "dict"
  pb_add ":NSAppTransportSecurity:NSAllowsLocalNetworking" "bool true"
  pb_add ":NSAppTransportSecurity:NSAllowsArbitraryLoads" "bool false"

  # 会议文件能在「文件」App 里看到并原地打开
  pb_del ":UIFileSharingEnabled"
  pb_add ":UIFileSharingEnabled" "bool true"
  pb_del ":LSSupportsOpeningDocumentsInPlace"
  pb_add ":LSSupportsOpeningDocumentsInPlace" "bool true"

  # 只用系统自带加密，不做出口合规申报
  pb_del ":ITSAppUsesNonExemptEncryption"
  pb_add ":ITSAppUsesNonExemptEncryption" "bool false"

  # 最低系统版本：和 tauri.conf.json 的 bundle.iOS.minimumSystemVersion 对齐
  # （xcodebuild 自己会写一条，这里覆盖成同一个值，避免产物里两个数字不一致）
  pb_del ":MinimumOSVersion"
  pb_add ":MinimumOSVersion" "string ${DEPLOYMENT_TARGET}"

  # 主屏显示名用中文（CFBundleName 保持 ASCII 的 HuiT，避免 Xcode 工程/路径出问题）
  pb_del ":CFBundleDisplayName"
  pb_add ":CFBundleDisplayName" "string 会听HuiT"

  for key in NSMicrophoneUsageDescription UIBackgroundModes NSAppTransportSecurity \
             UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace \
             ITSAppUsesNonExemptEncryption MinimumOSVersion; do
    if ! "${PBUDDY}" -c "Print :${key}" "${plist_file}" >/dev/null 2>&1; then
      die "Info.plist 里 ${key} 仍然不存在：${plist_file}"
    fi
  done

  # 打印注入结果，方便肉眼核对（也进 CI 日志）
  if command -v plutil >/dev/null 2>&1; then
    printf '\n--- plutil -p %s（只看注入的 key）---\n' "${plist_file}"
    plutil -p "${plist_file}" 2>/dev/null | grep -E \
      '"(NSMicrophoneUsageDescription|UIBackgroundModes|NSAppTransportSecurity|NSAllowsLocalNetworking|NSAllowsArbitraryLoads|UIFileSharingEnabled|LSSupportsOpeningDocumentsInPlace|ITSAppUsesNonExemptEncryption|MinimumOSVersion)"|^\s*"(audio|true|false)"|^\s*[0-9]+\s*=>' \
      || true
    printf -- '---\n\n'
  fi
}

# ------------------------------------------------- iOS AppIcon 覆盖
# `tauri ios init` 生成的 AppIcon.appiconset 里放的是 Tauri CLI 自带的默认图标，
# 不会自动用 tauri.conf.json 的 bundle.icon（真机上装出来还是 Tauri 的黄青色 logo）。
# 这里按 Contents.json 的尺寸清单，用我们的 1024 图标逐个重新生成。
ICON_1024="${TAURI_DIR}/icons/icon-1024.png"
ICON_SET="$(ls -d "${GEN_DIR}"/*_iOS/Assets.xcassets/AppIcon.appiconset 2>/dev/null | head -1)"
if [[ -f "${ICON_1024}" && -d "${ICON_SET}" ]]; then
  log "覆盖 AppIcon：${ICON_SET}"
  python3 "${TAURI_DIR}/scripts-appicon.py" "${ICON_SET}" > /tmp/tingo-icon-sizes.txt
  while IFS=$'\t' read -r fn px; do
    [[ -n "${fn}" && -n "${px}" ]] || continue
    sips -z "${px}" "${px}" "${ICON_1024}" --out "${ICON_SET}/${fn}" >/dev/null 2>&1 \
      || warn "生成图标失败：${fn} (${px}px)"
  done < /tmp/tingo-icon-sizes.txt
  log "AppIcon 共处理 $(wc -l < /tmp/tingo-icon-sizes.txt) 个尺寸"
else
  warn "没有 AppIcon.appiconset（${ICON_SET}）或缺少 icon-1024.png，跳过图标覆盖"
fi

step "注入 iOS Info.plist（麦克风 / 后台音频 / 本地网络 / 文件共享）"
plist_apply "${IOS_DIR}/Info.plist"
log "Info.plist 已就绪：${IOS_DIR}/Info.plist"

# ---------------------------------------------------------------- Swift 录音桥
step "接入 Swift 录音桥 TingoAudio.swift"
if [[ -f "${AUDIO_SWIFT_SRC}" ]]; then
  cp -f "${AUDIO_SWIFT_SRC}" "${IOS_DIR}/TingoAudio.swift"
  log "已拷贝：${IOS_DIR}/TingoAudio.swift"
elif [[ "${ALLOW_MISSING_AUDIO_BRIDGE}" == "1" ]]; then
  warn "缺少 ${AUDIO_SWIFT_SRC}（ALLOW_MISSING_AUDIO_BRIDGE=1，继续）"
else
  die "缺少 ${AUDIO_SWIFT_SRC}：引擎里 tingo_ios_* 这组 C 符号由它提供，没有它链接会失败。
      把 TingoAudio.swift 放进 app/ios/ 后重跑；只调前端、不关心录音时可以 ALLOW_MISSING_AUDIO_BRIDGE=1 跳过。"
fi

# xcodegen 按 project.yml 重新生成工程，新加的 .swift 才会进 compile sources
if [[ -f "${GEN_DIR}/project.yml" && "${XCODEGEN_OK}" == "1" ]]; then
  log "用 xcodegen 重新生成 Xcode 工程"
  if ! ( cd "${GEN_DIR}" && xcodegen generate --spec project.yml ); then
    die "xcodegen generate 失败：看上面的日志，顺手检查 ${GEN_DIR}/project.yml。"
  fi
elif [[ -f "${GEN_DIR}/project.yml" ]]; then
  warn "没有 xcodegen，跳过重新生成：新加的 .swift 不会自动进 compile sources，先靠目录自动包含继续。"
fi

pbx_checked=0
for pbx in "${GEN_DIR}"/*.xcodeproj/project.pbxproj; do
  if [[ -f "${pbx}" ]]; then
    pbx_checked=1
    if grep -q "TingoAudio.swift" "${pbx}"; then
      log "TingoAudio.swift 已在 compile sources 里"
    else
      warn "TingoAudio.swift 还没进 compile sources（${pbx}）：
      执行 cd app/src-tauri/gen/apple && xcodegen generate --spec project.yml 重新生成，
      或在 Xcode 里手动 Add Files。否则链接时会缺 tingo_ios_* 符号。"
    fi
    break
  fi
done
[[ "${pbx_checked}" == "1" ]] || warn "没找到 project.pbxproj，确认不了 TingoAudio.swift 是否参与编译"

# ---------------------------------------------------------------- 识别引擎（sherpa-onnx）
# xcframework 的 conf 注入已在「准备 Tauri iOS 工程」那一步完成（见 inject_sherpa_framework），
# 这里只确认它确实被工程引用了；第一次下载的情况由构建后的 self-heal 处理。
if [[ -d "${XCFF}" ]]; then
  log "sherpa-onnx xcframework：${XCFF}"
fi

# ---------------------------------------------------------------- 构建
step "探测 tauri ios build 支持的参数"
help_text="$( ( cd "${APP_DIR}" && pnpm exec tauri ios build --help ) 2>&1 || true )"
[[ -n "${help_text}" ]] || warn "拿不到 tauri ios build --help：按最保守的参数构建"

has_no_sign=0
has_export_method=0
if grep -q -- "--no-sign" <<<"${help_text}"; then has_no_sign=1; fi
if grep -q -- "--export-method" <<<"${help_text}"; then has_export_method=1; fi

target_arg=""
if [[ "${IOS_TARGET}" != "auto" ]]; then
  target_arg="${IOS_TARGET}"
elif grep -q -- "aarch64-apple-ios" <<<"${help_text}"; then
  target_arg="aarch64-apple-ios"
elif grep -q -- "--target" <<<"${help_text}"; then
  # Tauri 2 的 --target 取 cargo-mobile2 的简写：aarch64 / x86_64 / aarch64-sim / x86_64-sim
  target_arg="aarch64"
fi

build_args=( ios build )
if [[ -n "${target_arg}" ]]; then
  build_args+=( --target "${target_arg}" )
fi
if [[ -z "${TEAM_ID}" && "${has_no_sign}" == "1" ]]; then
  build_args+=( --no-sign )
elif [[ -n "${TEAM_ID}" && "${has_export_method}" == "1" ]]; then
  build_args+=( --export-method "${EXPORT_METHOD:-release-testing}" )
fi
if grep -q -- "--ci" <<<"${help_text}"; then
  build_args+=( --ci )
fi

log "构建命令：pnpm exec tauri ${build_args[*]}"

step "构建 iOS App（${CONFIG}）"
mkdir -p "${OUT_DIR}"
build_ok=0
# 第一次失败常见于 crates.io 抖动（runner 上偶发 DNS 失败）：重试一次，依赖已下到本地时基本必过
if ( cd "${APP_DIR}" && pnpm exec tauri "${build_args[@]}" ); then
  build_ok=1
elif { warn "第一次构建失败，10 秒后重试一次（crates.io 抖动）"; sleep 10; } && ( cd "${APP_DIR}" && pnpm exec tauri "${build_args[@]}" ); then
  build_ok=1
else
  # 不用裸 xcodebuild 兜底：Xcode 里的 "Build Rust Code" 阶段会跑 `tauri ios xcode-script`，
  # 它要从 gen/apple/.tauri/cli-options-server.json 读参数，那个文件只有 tauri ios build 在跑时才有，
  # 所以裸 xcodebuild 必定以
  #   failed to read .../cli-options-server.json; the `tauri ios dev` or `tauri ios build` command must be running
  # 失败。这里直接给出可读的诊断。
  die "pnpm tauri ios build 失败（见上面的错误）。
     常见原因按出现频率排序：
       1) bundle.resources 里的文件不存在（bin/tingo-recorder、src/tingo/sample）
       2) sherpa-onnx.xcframework 没被工程引用（看 gen/apple/project.yml 里有没有它）
       3) Rust 编译错误：cd app/src-tauri && cargo build --target aarch64-apple-ios 单独跑一遍看得更清楚"
fi

# 第一次构建的 self-heal：xcframework 是这一轮 cargo 阶段才下载的，而 tauri.conf.json 那会儿
# 还没写 frameworks，工程里自然没有引用它。这里补写 conf → 重跑 init 重新渲染 project.yml →
# 重新放 Swift 桥 + xcodegen → 增量重建一次（Rust 产物已缓存，只是重新链接和打包）。
# 只在「这轮刚下载到 xcframework 且 conf 是我们这轮才补的」时跑，最多一次，不会循环。
if [[ "${build_ok}" == "1" && "${FRAMEWORKS_INJECTED}" == "0" && -d "${XCFF}" ]]; then
  if [[ -f "${GEN_DIR}/project.yml" ]] && ! grep -q "sherpa-onnx" "${GEN_DIR}/project.yml"; then
    warn "工程里还没有引用 sherpa-onnx.xcframework（它刚在本轮 cargo 阶段下载完）：补写 conf 后重建一次"
    # shellcheck disable=SC2310  # 同上：按返回值决定要不要重建
    if inject_sherpa_framework; then
      log "重新渲染 Xcode 工程（pnpm tauri ios init）"
      if ( cd "${APP_DIR}" && pnpm exec tauri ios init --ci ); then
        if [[ -f "${AUDIO_SWIFT_SRC}" ]]; then
          cp -f "${AUDIO_SWIFT_SRC}" "${IOS_DIR}/TingoAudio.swift"
        fi
        if [[ "${XCODEGEN_OK}" == "1" && -f "${GEN_DIR}/project.yml" ]]; then
          ( cd "${GEN_DIR}" && xcodegen generate --spec project.yml ) \
            || warn "xcodegen generate 失败，第二轮可能缺 Swift 桥"
        fi
        if ( cd "${APP_DIR}" && pnpm exec tauri "${build_args[@]}" ); then
          log "第二轮构建完成（带上了 sherpa-onnx.xcframework）"
        else
          warn "第二轮构建失败：打包第一轮的产物，但启动时很可能 dyld 崩"
        fi
      else
        warn "重跑 pnpm tauri ios init 失败：打包出来的 App 启动时很可能 dyld 崩，删掉 ${GEN_DIR} 后重跑本脚本"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------- 找 .app
step "定位构建出来的 .app"
app_list="$(find "${GEN_DIR}" "${OUT_DIR}" -maxdepth 9 -type d -name "*.app" -print 2>/dev/null || true)"

# 优先 xcarchive 里的 Products/Applications/*.app，其次任意完整 .app；同一档里取最新的
APP_BUNDLE=""
best_score=-1
best_mtime=-1
while IFS= read -r candidate; do
  [[ -n "${candidate}" ]] || continue
  [[ -f "${candidate}/Info.plist" ]] || continue
  score=0
  case "${candidate}" in
    */Products/Applications/*.app) score=10 ;;
    */build/*.app) score=5 ;;
    *) ;;
  esac
  mtime="$(stat -f%m "${candidate}" 2>/dev/null || echo 0)"
  if [[ "${score}" -gt "${best_score}" ]] \
     || { [[ "${score}" -eq "${best_score}" ]] && [[ "${mtime}" -gt "${best_mtime}" ]]; }; then
    APP_BUNDLE="${candidate}"
    best_score="${score}"
    best_mtime="${mtime}"
  fi
done <<<"${app_list}"

if [[ -z "${APP_BUNDLE}" ]]; then
  die "构建没产出 .app。检查：
      - gen/apple/build/${SCHEME}.xcarchive/Products/Applications/ 下有没有产物
      - Xcode 日志里 Rust 阶段（cargo build --target aarch64-apple-ios）是否报错"
fi
log "使用 App bundle：${APP_BUNDLE}"

# ---------------------------------------------------------------- 打包 ipa
step "打包未签名 ipa"
rm -rf "${PAYLOAD_DIR}"
mkdir -p "${PAYLOAD_DIR}"
APP_BASENAME="$(basename "${APP_BUNDLE}")"

ditto "${APP_BUNDLE}" "${PAYLOAD_DIR}/${APP_BASENAME}"

# tauri ios build 会用 src-tauri/Info.plist 合并重写工程里的 Info.plist，
# 所以打包前对最终 bundle 再注入一次（幂等），保证出货的 ipa 带齐这些 key
plist_apply "${PAYLOAD_DIR}/${APP_BASENAME}/Info.plist"
log "已放入 Payload：${PAYLOAD_DIR}/${APP_BASENAME}"

# 引擎的 sherpa-onnx 在 iOS 上是动态库，必须真的在 Frameworks 里，否则装上去一启动就崩
sherpa_embedded=0
for candidate in "${PAYLOAD_DIR}/${APP_BASENAME}"/Frameworks/*sherpa*; do
  if [[ -e "${candidate}" ]]; then
    sherpa_embedded=1
    log "已嵌入选别引擎动态库：$(basename "${candidate}")"
    break
  fi
done
if [[ "${sherpa_embedded}" != "1" ]]; then
  warn "App 的 Frameworks/ 里没有 sherpa-onnx：这个 ipa 装上后很可能一启动就退出（dyld 找不到库）。
      在 app/src-tauri/tauri.conf.json 的 bundle.iOS 里加 \"frameworks\": [\"sherpa-onnx.xcframework\"]，
      删掉 app/src-tauri/gen/apple 后重跑本脚本。"
fi

rm -f "${OUT_DIR}/${IPA_NAME}"
if ! ( cd "${OUT_DIR}" && zip -qry "${IPA_NAME}" Payload ); then
  die "zip 打包失败：${OUT_DIR}/${IPA_NAME}"
fi

IPA_PATH="${OUT_DIR}/${IPA_NAME}"
[[ -f "${IPA_PATH}" ]] || die "ipa 没生成：${IPA_PATH}"
IPA_BYTES="$(stat -f%z "${IPA_PATH}")"
IPA_HUMAN="$(du -h "${IPA_PATH}" | cut -f1)"

# tauri 自己可能也留了一份 ipa，提一下方便对照
for tauri_ipa in "${GEN_DIR}"/build/*/*.ipa; do
  if [[ -f "${tauri_ipa}" ]]; then
    log "tauri 自己也留了一份 ipa：${tauri_ipa}"
    break
  fi
done

printf '\n\033[1;32m构建完成\033[0m\n'
printf '  ipa：%s\n' "${IPA_PATH}"
printf '  大小：%s（%s 字节）\n' "${IPA_HUMAN}" "${IPA_BYTES}"
printf '  App：%s\n' "${PAYLOAD_DIR}/${APP_BASENAME}"

cat <<'EOF'

后续步骤
--------
1) 签名安装（未签名 ipa 直接装不上，必须先签）：
   - Sideloadly（Windows / macOS 都能用）：拖入 ipa，填自己的 Apple ID，Start
   - AltStore / SideStore：装到手机上后可自动续签，到期前重签一次
   - TrollStore：支持的 iOS 版本上可永久签名，免续签
2) 免费 Apple ID 签名有效期 7 天，到期 App 打不开，重签一次即可；会议数据在 App 沙盒里，
   重签是同名覆盖安装，数据一般还在，想稳就先在 App 里导出纪要
3) 99 美元开发者账号签名有效期 1 年
4) TEAM_ID 有值时会走 Xcode 自动签名（需要本机登录了对应账号的证书）
EOF
