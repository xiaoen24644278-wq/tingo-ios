#!/usr/bin/env bash
# 一键：新建私有仓库 → 推送 → 触发 iOS Actions → 轮询下载 ipa
# 用法：GITHUB_TOKEN=ghp_xxx REPO=tingo-ios bash scripts-push-github.sh
set -euo pipefail

: "${GITHUB_TOKEN:?需要 GITHUB_TOKEN（classic: repo+workflow；fine-grained: Contents/Workflows/Administration 读写）}"
REPO="${REPO:-tingo-ios}"
VISIBILITY="${VISIBILITY:-private}"
OWNER="${OWNER:-$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" https://api.github.com/user | python3 -c 'import json,sys;print(json.load(sys.stdin)["login"])')}"
BRANCH="${BRANCH:-main}"

api() { curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

echo "== 账号：${OWNER}　仓库：${OWNER}/${REPO}（${VISIBILITY}）"
if api "https://api.github.com/repos/${OWNER}/${REPO}" | grep -q '"full_name"'; then
  echo "   仓库已存在，直接推送"
else
  api -X POST https://api.github.com/user/repos \
    -d "{\"name\":\"${REPO}\",\"private\":$([ "${VISIBILITY}" = private ] && echo true || echo false),\"description\":\"Tingo 听过 iOS 移植：本地会议纪要 App，Tauri+Rust，可出未签名 ipa\"}" >/dev/null
  echo "   已创建"
fi

cd "$(dirname "$0")"
echo "== 推送 ${BRANCH}"
git remote remove origin 2>/dev/null || true
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${OWNER}/${REPO}.git"
git add -A && git -c user.name=tingo-ios -c user.email=tingo@local commit -m "Tingo iOS 移植：进程内录音桥 + Tauri iOS 目标 + 一键出未签名 ipa" || echo "   没有新改动"
git push -u origin "HEAD:${BRANCH}" --force

echo "== 触发 iOS workflow"
# 新建的 workflow 有时还没被索引，workflow_dispatch 会 404；tag push 触发（on.push.tags）更可靠，两条都试
TAG="ios-$(date +%Y%m%d-%H%M%S)"
git -c user.name=tingo-ios -c user.email=tingo@local tag -f "$TAG" >/dev/null 2>&1 || true
if git push origin "refs/tags/${TAG}" --force >/dev/null 2>&1; then
  echo "   已推 tag ${TAG} 触发"
else
  echo "   tag 推送失败，改用 workflow_dispatch"
  api -X POST "https://api.github.com/repos/${OWNER}/${REPO}/actions/workflows/ios.yml/dispatches" -d "{\"ref\":\"${BRANCH}\"}" >/dev/null
fi
sleep 10
echo "== 等待构建（最多 60 分钟）"
for i in $(seq 1 120); do
  run="$(api "https://api.github.com/repos/${OWNER}/${REPO}/actions/runs?per_page=1")"
  status="$(printf '%s' "$run" | python3 -c 'import json,sys;r=json.load(sys.stdin)["workflow_runs"][0];print(r["status"],r["conclusion"] or "-",r["id"])')"
  echo "   [$i] $status"
  case "$status" in
    completed*success*) break ;;
    completed*) echo "   构建失败，日志："; echo "   https://github.com/${OWNER}/${REPO}/actions"; exit 1 ;;
  esac
  sleep 30
done
art="$(api "https://api.github.com/repos/${OWNER}/${REPO}/actions/artifacts" | python3 -c 'import json,sys;a=[x for x in json.load(sys.stdin)["artifacts"] if x["name"]=="Tingo-unsigned-ipa"];print(a[0]["archive_download_url"] if a else "")')"
[ -n "$art" ] || { echo "   没找到 artifact，去 Actions 页面看"; exit 1; }
echo "== 下载 ipa"
api -L "$art" -o Tingo-unsigned-ipa.zip
unzip -o -q Tingo-unsigned-ipa.zip -d ipa && ls -lh ipa/
echo "完成：$(pwd)/ipa/"
