#!/usr/bin/env bash
# 会听 HuiT · Android 构建：产出可直接安装的 APK（debug 签名，允许未知来源安装）
#
# 用法：
#   bash app/scripts/build-apk.sh                 # 默认 arm64 + armeabi-v7a
#   ABIS=arm64 bash app/scripts/build-apk.sh      # 只出 arm64（体积小、构建快）
#   RELEASE=1 bash app/scripts/build-apk.sh       # release 构建（体积更小）
#
# 需要：JDK 17、Android SDK（含 NDK 27）、pnpm、cargo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_DIR="${REPO_ROOT}/app"
TAURI_DIR="${APP_DIR}/src-tauri"
GEN_ANDROID="${TAURI_DIR}/gen/android"
WEB_DIST="${REPO_ROOT}/src/tingo/web"
KT_SRC="${APP_DIR}/android/TingoAudio.kt"
OUT_DIR="${REPO_ROOT}/build/android"
ABIS="${ABIS:-arm64,armv7}"
RELEASE="${RELEASE:-0}"
PKG_PATH="com/hui/ting"

log()  { printf '\033[1;34m[apk]\033[0m %s\n' "$*"; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[apk] 警告：\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[apk] 失败：\033[0m %s\n' "$*" >&2; exit 1; }

step "检查构建环境"
command -v pnpm >/dev/null || die "没有 pnpm：先 corepack enable 或 npm i -g pnpm"
command -v cargo >/dev/null || die "没有 cargo：先装 Rust（rustup）"
[[ -n "${JAVA_HOME:-}" ]] || die "没有 JAVA_HOME：需要 JDK 17（Android Gradle Plugin 要求）"
[[ -n "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" ]] || die "没有 ANDROID_HOME：需要安装 Android SDK + NDK"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[[ -d "${SDK}/ndk" ]] || warn "SDK 里没有 ndk 目录：Tauri 构建 Rust 库时需要 NDK"
log "JDK: $(java -version 2>&1 | head -1)"
log "SDK: ${SDK}"

step "安装 Android 的 Rust target"
for t in aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android; do
  rustup target add "$t" >/dev/null 2>&1 || warn "rustup target add $t 失败（可能已装）"
done
log "Rust targets 就绪"

step "构建前端"
( cd "${APP_DIR}" && pnpm install --frozen-lockfile 2>/dev/null || pnpm install )
( cd "${APP_DIR}" && pnpm build )
[[ -f "${WEB_DIST}/index.html" ]] || die "前端产物没生成：${WEB_DIST}/index.html"
log "前端产物就绪"

# tauri.conf.json 的 bundle.resources 声明了 bin/tingo-recorder（macOS 的 Swift 录音子进程）。
# Android 上根本不会执行它，但资源清单里有这一项，文件不存在时构建会直接失败：
#   resource path `bin/tingo-recorder` doesn't exist
RECORDER_PLACEHOLDER="${TAURI_DIR}/bin/tingo-recorder"
if [[ ! -f "${RECORDER_PLACEHOLDER}" ]]; then
  mkdir -p "$(dirname "${RECORDER_PLACEHOLDER}")"
  printf '#!/bin/sh\nexit 0\n' > "${RECORDER_PLACEHOLDER}"
  chmod +x "${RECORDER_PLACEHOLDER}"
  log "已创建 bin/tingo-recorder 占位（Android 不使用，只为满足资源清单）"
fi
[[ -x "${RECORDER_PLACEHOLDER}" ]] || chmod +x "${RECORDER_PLACEHOLDER}"
touch "${RECORDER_PLACEHOLDER}"

step "准备 Tauri Android 工程（gen/android）"
if [[ ! -d "${GEN_ANDROID}" ]]; then
  ( cd "${APP_DIR}" && pnpm exec tauri android init --ci ) || die "pnpm tauri android init 失败"
else
  log "已存在：${GEN_ANDROID}"
fi

step "接入 Kotlin 音频桥 TingoAudio.kt"
JAVA_DIR="${GEN_ANDROID}/app/src/main/java/${PKG_PATH}"
mkdir -p "${JAVA_DIR}"
cp -f "${KT_SRC}" "${JAVA_DIR}/TingoAudio.kt"
log "已拷贝：${JAVA_DIR}/TingoAudio.kt"

step "注入 AndroidManifest 权限"
MANIFEST="${GEN_ANDROID}/app/src/main/AndroidManifest.xml"
[[ -f "${MANIFEST}" ]] || die "找不到 ${MANIFEST}"
python3 - "${MANIFEST}" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
wanted = [
    ("android.permission.RECORD_AUDIO", None),
    ("android.permission.POST_NOTIFICATIONS", None),
    ("android.permission.FOREGROUND_SERVICE", None),
    ("android.permission.FOREGROUND_SERVICE_MICROPHONE", None),
    ("android.permission.WAKE_LOCK", None),
    ("android.permission.MODIFY_AUDIO_SETTINGS", None),
]
added = []
for name, _ in wanted:
    short = name.split(".")[-1]
    if short in s:
        continue
    line = f'    <uses-permission android:name="{name}" />\n'
    if "</manifest>" in s:
        s = s.replace("</manifest>", line + "</manifest>", 1)
        added.append(short)
open(p, "w", encoding="utf-8").write(s)
print("added:", added if added else "(all present)")
PY

step "构建 APK"
mkdir -p "${OUT_DIR}"
ARGS=( android build )
if [[ "${RELEASE}" == "1" ]]; then
  ARGS+=( --apk )
else
  ARGS+=( --apk --debug )
fi
for abi in ${ABIS//,/ }; do
  case "$abi" in
    arm64) ARGS+=( --target aarch64 ) ;;
    armv7) ARGS+=( --target armv7 ) ;;
    x86_64) ARGS+=( --target x86_64 ) ;;
    *) warn "未知 ABI：$abi（跳过）" ;;
  esac
done
log "构建命令：pnpm exec tauri ${ARGS[*]}"
( cd "${APP_DIR}" && pnpm exec tauri "${ARGS[@]}" ) || die "tauri android build 失败：看上面的 Gradle / Rust 报错"

step "收集 APK"
found=0
while IFS= read -r apk; do
  cp -f "$apk" "${OUT_DIR}/" && found=1
done < <(find "${GEN_ANDROID}" -name "*.apk" -type f 2>/dev/null)

if [[ "$found" == "0" ]]; then
  die "没找到 APK：检查 ${GEN_ANDROID}/app/build/outputs/apk"
fi

ls -lh "${OUT_DIR}"/*.apk
for f in "${OUT_DIR}"/*.apk; do
  printf 'sha256 %s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(basename "$f")"
done

cat <<'EOF'

下一步（安装到 Android 手机）：
  1. 手机打开「设置 → 关于手机 → 连点版本号」开启开发者选项，再打开「USB 调试」
  2. 数据线连电脑，adb install -r build/android/app-universal-debug.apk
     （或把 apk 传到手机，用文件管理器点击安装，需允许「安装未知来源应用」）
  3. 首次打开会要麦克风权限，允许即可；进设置下载识别模型（约 330MB）
EOF
