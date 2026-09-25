#!/bin/bash
# 为 dist/ 里的 DMG 生成 Sparkle 的 appcast.xml
#
# Sparkle 的更新校验是 EdDSA 签名的：appcast 里每个 enclosure 都带签名，
# App 用 Info.plist 的 SUPublicEDKey 验签。所以生成 appcast 时**必须**拿到私钥。
#
# 私钥来源（优先级）：
#   1) 环境变量 SPARKLE_PRIVATE_KEY（内容为私钥文本，CI 用 GitHub Secret 注入）
#   2) 环境变量 SPARKLE_PRIVATE_KEY_FILE 指向的路径
#   3) scripts/sparkle_keys.sh 导出的本地私钥文件（本地跑最省事，
#      而且**绕开钥匙串** —— 钥匙串那条路在自动化环境里会卡住不返回）
#   4) 登录钥匙串（最后兜底）
#
# 用法:
#   bash scripts/make_appcast.sh
#   SPARKLE_PRIVATE_KEY="$(cat key.txt)" bash scripts/make_appcast.sh
#
# 产物: dist/appcast.xml
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
VERSION="$(tr -d ' \t\r\n' < "$PROJECT_DIR/VERSION")"

REPO_SLUG="${REPO_SLUG:-xfanchuang-dot/suishouqian}"
# SUFeedURL 指向 releases/latest/download/appcast.xml，所以 enclosure 也走同一前缀，
# 保证"feed 里声明的下载地址"永远解析得到（不依赖具体 tag）。
URL_PREFIX="https://github.com/$REPO_SLUG/releases/latest/download/"

# ── 找 Sparkle 工具 ─────────────────────────────────────────────────────────
SCRATCH="${SUISHOUQIAN_SCRATCH:-$HOME/Library/Caches/suishouqian-scratch}"
GEN_APPCAST="$(find "$SCRATCH" "$PROJECT_DIR/.build" -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -z "$GEN_APPCAST" ]; then
    echo "错误: 找不到 generate_appcast。先跑一次构建（bash build.sh --dist-only）把 Sparkle 工具拉下来。"
    exit 1
fi

# ── 私钥 ────────────────────────────────────────────────────────────────────
KEY_ARGS=()
TMPKEY=""
cleanup() { [ -n "$TMPKEY" ] && rm -f "$TMPKEY" 2>/dev/null || true; }
trap cleanup EXIT

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    TMPKEY="$(mktemp "${TMPDIR:-/tmp}/sparkle-key.XXXXXX")"
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$TMPKEY"
    chmod 600 "$TMPKEY"
    KEY_ARGS=(--ed-key-file "$TMPKEY")
    echo "私钥来源: 环境变量 SPARKLE_PRIVATE_KEY"
elif [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ] && [ -f "${SPARKLE_PRIVATE_KEY_FILE}" ]; then
    KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
    echo "私钥来源: $SPARKLE_PRIVATE_KEY_FILE"
elif [ -f "$HOME/Library/Caches/suishouqian-sparkle/private_key.txt" ]; then
    KEY_ARGS=(--ed-key-file "$HOME/Library/Caches/suishouqian-sparkle/private_key.txt")
    echo "私钥来源: ~/Library/Caches/suishouqian-sparkle/private_key.txt（sparkle_keys.sh 导出）"
else
    echo "私钥来源: 登录钥匙串（若报找不到密钥，先跑 scripts/sparkle_keys.sh）"
fi

# ── 打包产物清单 ────────────────────────────────────────────────────────────
shopt -s nullglob
DMGS=("$DIST_DIR"/*.dmg)
if [ ${#DMGS[@]} -eq 0 ]; then
    echo "错误: dist/ 里没有 .dmg。先跑 bash scripts/package_dmg.sh"
    exit 1
fi

echo "=== 生成 appcast · v$VERSION ==="
for d in "${DMGS[@]}"; do echo "  纳入: $(basename "$d")"; done

# KEY_ARGS 走「有则展开、无则完全省略」的写法：
# bash 3.2（本机 /bin/bash）在 set -u 下展开**空数组**会直接报 unbound variable，
# 而指定了私钥文件时要把它变成 --ed-key-file 两个参数，所以两者都得兼顾。
"$GEN_APPCAST" \
    ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
    --download-url-prefix "$URL_PREFIX" \
    -o "$DIST_DIR/appcast.xml" \
    "$DIST_DIR"

echo ""
echo "产物: $DIST_DIR/appcast.xml"
echo "下载前缀: $URL_PREFIX"
