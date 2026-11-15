#!/usr/bin/env bash
#
# Tingo iOS 构建（只在 macOS + Xcode 上跑；CI 无人值守，全程不读 stdin、不询问任何东西）
#
#   bash app/scripts/build-ios.sh                       # 真机 arm64，未签名 ipa
#   IOS_TARGET=aarch64-sim bash app/scripts/build-ios.sh  # 模拟器
#   SHERPA_ONNX_IOS=0 bash app/scripts/build-ios.sh       # 跳过识别引擎，只验壳体+界面
#   SHERPA_ONNX_STATIC_BUILD=1 SHERPA_ONNX_SRC=/path/to/sherpa-onnx bash app/scripts/build-ios.sh
#
# 每一步为什么这么做，见 docs/ios-port.md。这里只写「必须按顺序做」的硬要求。
#
# 注意：macOS 自带的 /bin/bash 是 3.2，本脚本刻意避开 4.x 语法（关联数组、mapfile、
# 空数组展开等），保证 `bash app/scripts/build-ios.sh` 直接可用。

set -euo pipefail

step() { printf '\n\033[1m== [%s] %s ==\033[0m\n' "$1" "$2"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m[注意]\033[0m %s\n' "$*"; }
die() {
  printf '\n\033[31m[中止]\033[0m %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- 1. 默认值
# 所有变量都有默认值；CI 里一个都不设也能跑到底。
step 1/9 "解析路径与默认值（全部有默认值，不读 stdin）"

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"

export CI="${CI:-1}"                                       # 让 tauri / vite 走非交互分支
IOS_TARGET="${IOS_TARGET:-aarch64}"                        # aarch64 | aarch64-sim | x86_64
IOS_SIGN="${IOS_SIGN:-0}"                                  # 0 = --no-sign（默认，产未签名 ipa）；1 = 走签名
DEBUG_BUILD="${DEBUG_BUILD:-0}"                            # 1 = cargo debug（慢但编译快）
SKIP_PNPM_INSTALL="${SKIP_PNPM_INSTALL:-0}"
SKIP_WEB_BUILD="${SKIP_WEB_BUILD:-0}"                      # 1 = 不跑 pnpm build，只检查产物

SHERPA_ONNX_IOS="${SHERPA_ONNX_IOS:-1}"                    # 0 = 不准备识别引擎的 iOS 库
SHERPA_ONNX_STATIC_BUILD="${SHERPA_ONNX_STATIC_BUILD:-0}"  # 1 = 自己用 CMake 编静态库
SHERPA_ONNX_SKIP_DOWNLOAD="${SHERPA_ONNX_SKIP_DOWNLOAD:-0}"
SHERPA_ONNX_ONNXRUNTIME_VERSION="${SHERPA_ONNX_ONNXRUNTIME_VERSION:-1.28.2}"

# 版本号以 engine/Cargo.toml 为准，拿不到才退回内置默认
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-$(sed -n 's/^sherpa-onnx *= *{[^}]*version *= *"\([^"]*\)".*/\1/p' "$APP_DIR/engine/Cargo.toml" 2>/dev/null | head -1)}"
SHERPA_ONNX_VERSION="${SHERPA_ONNX_VERSION:-2.0.1}"

DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-15.0}"             # 与 tauri.conf.json 的 bundle.iOS 一致
ENABLE_BITCODE="${ENABLE_BITCODE:-NO}"
IOS_CMAKE_URL="${IOS_CMAKE_URL:-https://raw.githubusercontent.com/leetal/ios-cmake/master/ios.toolchain.cmake}"
ORT_RELEASE_URL="${ORT_RELEASE_URL:-https://github.com/csukuangfj/onnxruntime-libs/releases/download}"
SHERPA_XCF_RELEASE_URL="${SHERPA_XCF_RELEASE_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework}"
TINGO_TAURI_ARGS="${TINGO_TAURI_ARGS:-}"                   # 追加给 tauri ios build 的参数
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/ios}"

case "$IOS_TARGET" in
  aarch64) RUST_TRIPLE="aarch64-apple-ios" ;;
  aarch64-sim) RUST_TRIPLE="aarch64-apple-ios-sim" ;;
  x86_64) RUST_TRIPLE="x86_64-apple-ios" ;;
  *) die "IOS_TARGET 只能是 aarch64 / aarch64-sim / x86_64，拿到：$IOS_TARGET" ;;
esac

note "仓库根      : $REPO_ROOT"
note "App 目录    : $APP_DIR"
note "目标        : $IOS_TARGET（rust: $RUST_TRIPLE）"
note "签名        : $([ "$IOS_SIGN" = "1" ] && echo '开启' || echo '关闭（--no-sign）')"
note "识别引擎    : $([ "$SHERPA_ONNX_IOS" = "0" ] && echo '跳过（只验壳体+界面）' || echo "准备中，sherpa-onnx v$SHERPA_ONNX_VERSION")"
note "部署目标    : iOS $DEPLOYMENT_TARGET"

# ------------------------------------------------------------ 2. 环境检查
step 2/9 "检查 macOS / Xcode / node / cargo"

[ "$(uname -s)" = "Darwin" ] || die "iOS 只能在 macOS 上构建：xcodebuild、iOS SDK、codesign 只有 macOS 才有。当前是 $(uname -s)。"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild：先装 Xcode 并执行 sudo xcode-select -s /Applications/Xcode.app"
command -v xcrun >/dev/null 2>&1 || die "找不到 xcrun（Xcode Command Line Tools 没装好）"
command -v pnpm >/dev/null 2>&1 || die "找不到 pnpm（package.json 要求 pnpm@11）"
command -v node >/dev/null 2>&1 || die "找不到 node"
command -v cargo >/dev/null 2>&1 || die "找不到 cargo（Rust 工具链没装）"
command -v unzip >/dev/null 2>&1 || die "找不到 unzip"

xcodebuild -version | sed 's/^/   /'
note "iOS SDK: $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '查不到')"
note "node $(node -v)，pnpm $(pnpm -v)，$(cargo --version)"

# ------------------------------------------- 3. 录音器打包占位（硬要求 1）
# tauri.conf.json 的 bundle.resources 里声明了 "bin/tingo-recorder"（macOS 的录音子进程）。
# 这个文件只有 macOS release 流程（src-tauri/build.rs 里的 swiftc）才会生成，iOS 构建时
# 不存在 → Tauri 打包直接以 "resource not found" 失败。iOS 上不会执行它，只是打包占位。
# 占位文件比 src/tingo/recorder.swift 新，还能让 build.rs 的 swiftc 判断命中"已是最新"而跳过，
# 免得在 iOS 构建里编出一个 arm64-apple-macos 的二进制。
step 3/9 "创建打包占位 src-tauri/bin/tingo-recorder"

RECORDER_BIN="$APP_DIR/src-tauri/bin/tingo-recorder"
mkdir -p "$APP_DIR/src-tauri/bin"
if [ -f "$RECORDER_BIN" ]; then
  note "已存在，保留原文件（$(wc -c <"$RECORDER_BIN" | tr -d ' ') 字节）"
else
  printf '#!/bin/sh\nexit 0\n' >"$RECORDER_BIN"
  note "已写入占位脚本"
fi
chmod +x "$RECORDER_BIN"
touch "$RECORDER_BIN" # 让 mtime 比 recorder.swift 新，build.rs 不会去跑 swiftc
[ -x "$RECORDER_BIN" ] || die "$RECORDER_BIN 不可执行"
note "$(ls -l "$RECORDER_BIN")"

# ----------------------------------------------- 4. 前端产物（硬要求 2）
# vite 的 outDir 是 ../src/tingo/web，即仓库根的 src/tingo/web（tauri.conf.json 的
# frontendDist 也是 ../../src/tingo/web）。跑 `pnpm tauri ios build` 之前它必须非空。
step 4/9 "构建/校验前端产物 src/tingo/web"

FRONTEND_DIR="$REPO_ROOT/src/tingo/web"
if [ "$SKIP_PNPM_INSTALL" != "1" ]; then
  note "pnpm install --frozen-lockfile"
  (cd "$APP_DIR" && pnpm install --frozen-lockfile)
else
  note "SKIP_PNPM_INSTALL=1：跳过依赖安装"
fi

if [ "$SKIP_WEB_BUILD" != "1" ]; then
  note "pnpm build（tsc --noEmit && vite build）"
  (cd "$APP_DIR" && pnpm build)
else
  note "SKIP_WEB_BUILD=1：跳过前端构建"
fi

if [ ! -d "$FRONTEND_DIR" ] || [ -z "$(ls -A "$FRONTEND_DIR" 2>/dev/null)" ]; then
  die "前端产物目录 $FRONTEND_DIR 是空的。先执行：cd app && pnpm build（vite 的 outDir 是 ../src/tingo/web）"
fi
[ -f "$FRONTEND_DIR/index.html" ] || die "$FRONTEND_DIR 里没有 index.html，前端构建不完整"
note "ok：$(ls -A "$FRONTEND_DIR" | wc -l | tr -d ' ') 个条目，$(du -sh "$FRONTEND_DIR" 2>/dev/null | cut -f1)"

# ------------------------------------------------ 5. 打包资源清单冒烟
step 5/9 "校验 bundle.resources 声明的资源都在"

CONF="$APP_DIR/src-tauri/tauri.conf.json"
[ -f "$CONF" ] || die "找不到 $CONF"
grep -q '"bin/tingo-recorder"' "$CONF" || warn "tauri.conf.json 里没有 bin/tingo-recorder 资源声明（占位文件就白建了）"
[ -d "$REPO_ROOT/src/tingo/sample" ] || die "缺少 $REPO_ROOT/src/tingo/sample——tauri.conf.json 的第二个资源，缺了同样会 resource not found"
if [ "$SHERPA_ONNX_IOS" = "1" ] && ! grep -q '"frameworks"' "$CONF"; then
  warn 'tauri.conf.json 的 bundle.iOS 里没有 "frameworks": ["sherpa-onnx.xcframework"]，动态库不会被嵌入，App 启动时会 dyld 找不到 sherpa-onnx'
fi
note "资源声明 ok"

# --------------------------------------- 6. 识别引擎的 iOS 库（硬要求 3）
step 6/9 "准备识别引擎（sherpa-onnx）的 iOS 依赖"

if [ "$SHERPA_ONNX_IOS" = "0" ]; then
  note "SHERPA_ONNX_IOS=0：跳过 toolchain / onnxruntime / xcframework 的全部准备"
  warn "本次构建只能验证壳体 + 界面能编过：App 内识别、标点、声纹不可用"
  export TINGO_ASR_DISABLED=1
else
  # 6a. 探测 CMake toolchain（ios-cmake）；没有就下载到 build/ios-cmake/
  TOOLCHAIN=""
  for cand in \
    "$APP_DIR/src-tauri/gen/apple/ios.toolchain.cmake" \
    "$APP_DIR/src-tauri/gen/apple/toolchains/ios.toolchain.cmake" \
    "$APP_DIR/ios/toolchains/ios.toolchain.cmake" \
    "$REPO_ROOT/build/ios-cmake/ios.toolchain.cmake"; do
    if [ -f "$cand" ]; then
      TOOLCHAIN="$cand"
      break
    fi
  done
  if [ -z "$TOOLCHAIN" ]; then
    mkdir -p "$REPO_ROOT/build/ios-cmake"
    note "本地没有 toolchain，下载 $IOS_CMAKE_URL"
    curl -fL --retry 3 --connect-timeout 20 --max-time 300 \
      -o "$REPO_ROOT/build/ios-cmake/ios.toolchain.cmake" "$IOS_CMAKE_URL" \
      || die "下载 ios.toolchain.cmake 失败（CI 里检查一下出网策略）"
    TOOLCHAIN="$REPO_ROOT/build/ios-cmake/ios.toolchain.cmake"
  fi
  export CMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"

  if [ "${IOS_TARGET#*-sim}" != "$IOS_TARGET" ]; then
    export PLATFORM="${PLATFORM:-SIMULATORARM64}"
  else
    export PLATFORM="${PLATFORM:-OS64}"
  fi
  export DEPLOYMENT_TARGET ENABLE_BITCODE
  export ENABLE_ARC=1 ENABLE_VISIBILITY=0 CMAKE_BUILD_TYPE=Release BUILD_SHARED_LIBS=OFF
  export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

  note "CMAKE_TOOLCHAIN_FILE : $CMAKE_TOOLCHAIN_FILE"
  note "PLATFORM             : $PLATFORM"
  note "DEPLOYMENT_TARGET    : $DEPLOYMENT_TARGET"
  note "ENABLE_BITCODE       : $ENABLE_BITCODE"

  if [ "$SHERPA_ONNX_STATIC_BUILD" = "1" ]; then
    # 6b. 自建静态库路线：需要 sherpa-onnx 源码 + onnxruntime 的 iOS 静态库。
    #     注意：sherpa-onnx-sys 2.0.1 的 build.rs 在 iOS 上强制走 shared，
    #     想真正静态链接还必须打 docs/ios-port.md 里那几行 patch。
    [ -n "${SHERPA_ONNX_SRC:-}" ] || die "SHERPA_ONNX_STATIC_BUILD=1 需要 SHERPA_ONNX_SRC=/path/to/sherpa-onnx（源码目录）"
    [ -d "$SHERPA_ONNX_SRC" ] || die "SHERPA_ONNX_SRC 指向的目录不存在：$SHERPA_ONNX_SRC"
    command -v cmake >/dev/null 2>&1 || die "SHERPA_ONNX_STATIC_BUILD=1 需要 cmake"

    ORT_ROOT="$REPO_ROOT/build/ios-onnxruntime/$SHERPA_ONNX_ONNXRUNTIME_VERSION"
    if [ ! -d "$ORT_ROOT/onnxruntime.xcframework" ]; then
      mkdir -p "$ORT_ROOT"
      ORT_ZIP="$ORT_ROOT/onnxruntime-ios-static-xcframework-$SHERPA_ONNX_ONNXRUNTIME_VERSION.xcframework.zip"
      note "下载 onnxruntime iOS 静态 xcframework v$SHERPA_ONNX_ONNXRUNTIME_VERSION"
      curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$ORT_ZIP" \
        "$ORT_RELEASE_URL/v$SHERPA_ONNX_ONNXRUNTIME_VERSION/onnxruntime-ios-static-xcframework-$SHERPA_ONNX_ONNXRUNTIME_VERSION.xcframework.zip" \
        || die "下载 onnxruntime iOS 静态库失败"
      unzip -q -o "$ORT_ZIP" -d "$ORT_ROOT"
    fi
    [ -d "$ORT_ROOT/onnxruntime.xcframework" ] || die "解压后没找到 $ORT_ROOT/onnxruntime.xcframework"
    export SHERPA_ONNXRUNTIME_LIB_DIR="$ORT_ROOT/onnxruntime.xcframework/ios-arm64"
    export SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ORT_ROOT/onnxruntime.xcframework/ios-arm64/onnxruntime.framework/Headers"
    note "SHERPA_ONNXRUNTIME_LIB_DIR: $SHERPA_ONNXRUNTIME_LIB_DIR"

    SB="$SHERPA_ONNX_SRC/build-ios"
    mkdir -p "$SB"
    note "cmake 配置 sherpa-onnx（$PLATFORM，静态库）"
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
    note "SHERPA_ONNX_LIB_DIR: $SHERPA_ONNX_LIB_DIR"
    warn "静态路线还需要给 sherpa-onnx-sys 打 patch（去掉 iOS 强制 shared），见 docs/ios-port.md"
  else
    # 6c. 默认路线：sherpa-onnx 2.0.1 在 iOS 上只支持 shared，用官方
    #     ios-shared-onnxruntime-static.xcframework（onnxruntime 已静态链进 dylib）。
    #     必须在 build 之前就放到 src-tauri/，因为 Xcode 在跑任何 build phase 之前
    #     就检查 xcframework 是否存在，build.rs 里再下载已经来不及。
    XCF="$APP_DIR/src-tauri/sherpa-onnx.xcframework"
    if [ -d "$XCF" ]; then
      note "xcframework 已存在：$XCF"
    elif [ "$SHERPA_ONNX_SKIP_DOWNLOAD" = "1" ]; then
      warn "SHERPA_ONNX_SKIP_DOWNLOAD=1 且没有 $XCF，链接阶段大概率报 framework not found"
    else
      XCF_ZIP="$BUILD_DIR/sherpa-onnx-v$SHERPA_ONNX_VERSION-ios-shared-onnxruntime-static.xcframework.zip"
      mkdir -p "$BUILD_DIR"
      if [ ! -f "$XCF_ZIP" ]; then
        note "下载 sherpa-onnx v$SHERPA_ONNX_VERSION 的 iOS xcframework（约 30 MB）"
        curl -fL --retry 3 --connect-timeout 20 --max-time 1200 -o "$XCF_ZIP" \
          "$SHERPA_XCF_RELEASE_URL/sherpa-onnx-v$SHERPA_ONNX_VERSION-ios-shared-onnxruntime-static.xcframework.zip" \
          || die "下载 sherpa-onnx xcframework 失败"
      fi
      unzip -q -o "$XCF_ZIP" -d "$APP_DIR/src-tauri"
      # 压缩包里偶尔叫 SherpaOnnxC.xcframework，统一改成 bundle.iOS.frameworks 里的名字
      if [ -d "$APP_DIR/src-tauri/SherpaOnnxC.xcframework" ] && [ ! -d "$XCF" ]; then
        mv "$APP_DIR/src-tauri/SherpaOnnxC.xcframework" "$XCF"
      fi
      [ -d "$XCF" ] || die "解压后没找到 sherpa-onnx.xcframework，检查 $XCF_ZIP 的内容"
      note "已放入：$XCF"
    fi
  fi
fi

# ------------------------------------------- 7. Rust target / Xcode 工程
step 7/9 "安装 Rust 目标并生成 Xcode 工程（gen/apple）"

if command -v rustup >/dev/null 2>&1; then
  rustup target add "$RUST_TRIPLE" || die "rustup target add $RUST_TRIPLE 失败"
else
  warn "没有 rustup：请自行确认 $RUST_TRIPLE 已安装"
fi

if [ ! -d "$APP_DIR/src-tauri/gen/apple" ]; then
  note "gen/apple 不存在，跑一次 tauri ios init（CI 非交互）"
  (cd "$APP_DIR" && pnpm tauri ios init)
else
  note "gen/apple 已存在，跳过 init"
fi

# ------------------------------------------------------- 8. 真正编译
step 8/9 "pnpm tauri ios build"

cd "$APP_DIR"
set -- --target "$IOS_TARGET"
if [ "$IOS_SIGN" != "1" ]; then
  set -- "$@" --no-sign
fi
if [ "$DEBUG_BUILD" = "1" ]; then
  set -- "$@" --debug
fi
if [ -n "$TINGO_TAURI_ARGS" ]; then
  # shellcheck disable=SC2086 # 这里就是要按空格拆参数
  set -- "$@" $TINGO_TAURI_ARGS
fi
note "pnpm tauri ios build $*"
pnpm tauri ios build "$@"

# -------------------------------------------------- 9. 收集并校验产物
step 9/9 "收集 ipa 并校验结构"

IPA_SRC="$(find "$APP_DIR/src-tauri/gen/apple" -type f -name '*.ipa' 2>/dev/null | sort | tail -1)"
[ -n "$IPA_SRC" ] || die "构建结束但没在 src-tauri/gen/apple 下找到 ipa"
mkdir -p "$BUILD_DIR"
IPA_OUT="$BUILD_DIR/Tingo-$IOS_TARGET-unsigned.ipa"
if [ "$IOS_SIGN" = "1" ]; then
  IPA_OUT="$BUILD_DIR/Tingo-$IOS_TARGET.ipa"
fi
cp -f "$IPA_SRC" "$IPA_OUT"
note "来源：$IPA_SRC"
note "输出：$IPA_OUT"

unzip -l "$IPA_OUT" | grep -q 'Payload/' || die "$IPA_OUT 不是合法 ipa（没有 Payload/ 目录）"
APP_ENTRY="$(unzip -l "$IPA_OUT" | grep -oE 'Payload/[^/]+\.app/' | head -1)"
note "App 包：$APP_ENTRY"
if [ "$SHERPA_ONNX_IOS" = "1" ]; then
  if unzip -l "$IPA_OUT" | grep -q 'Frameworks/'; then
    note "已嵌入 Frameworks/"
  else
    warn "ipa 里没有 Frameworks/：sherpa-onnx 的动态库可能没被嵌入，App 启动会 dyld 失败"
  fi
else
  note "识别引擎已跳过（SHERPA_ONNX_IOS=0），不检查 Frameworks/"
fi

note "sha256: $(shasum -a 256 "$IPA_OUT" | cut -d' ' -f1)"
note "大小  : $(du -h "$IPA_OUT" | cut -f1)"

printf '\n\033[1m完成。\033[0m产物：%s（未签名，重签名/安装见 docs/ios-port.md）\n' "$IPA_OUT"
