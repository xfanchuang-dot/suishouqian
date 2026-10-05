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
# enclosure 用**钉在本次 tag 上**的地址，不是 /latest/：
#   · appcast.xml 本身走 /releases/latest/download/appcast.xml（SUFeedURL 就是它），
#     所以每次发版天然成为最新；而它内部的下载地址钉在自己那个 tag 上，
#     于是"声明某版本的地址"永远指向那个版本自己 —— 重跑旧 tag 也不会变成死链。
#   · 若用 /latest/ 前缀，appcast 里就会出现「版本号 2.16.0 + latest」这种组合：
#     发 v2.17.0 之后它会指向 v2.17.0 的 Release，而那里没有 2.16.0 的资产 → 404。
# 需要换托底仓库（如公开的 releases-only 仓库）时用 APPCAST_URL_PREFIX 覆盖。
URL_PREFIX="${APPCAST_URL_PREFIX:-https://github.com/$REPO_SLUG/releases/download/v$VERSION/}"

# ── 找 Sparkle 工具 ─────────────────────────────────────────────────────────
# 不要写成 `find … | head -1`：在 set -o pipefail 下，find 碰到不存在的目录会返回 1，
# 整条管道失败 → set -e 让脚本**在打印下面的友好错误之前**就退出（零输出）。
# 改为逐目录 -print -quit。
SCRATCH="${SUISHOUQIAN_SCRATCH:-$HOME/Library/Caches/suishouqian-scratch}"
GEN_APPCAST=""
for root in "$SCRATCH" "$PROJECT_DIR/.build"; do
    [ -d "$root" ] || continue
    GEN_APPCAST="$(find "$root" -name generate_appcast -type f -print -quit 2>/dev/null)"
    if [ -n "$GEN_APPCAST" ]; then break; fi
done
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
    # CI 上没有登录钥匙串、也没有本地导出的私钥文件：必须**当场说清原因**，
    # 否则 generate_appcast 会以一个看不懂的报错收场，整条发版流水线卡在 appcast 这一步。
    if [ -n "${CI:-}" ]; then
        echo "错误: CI 环境必须提供 SPARKLE_PRIVATE_KEY（runner 上没有登录钥匙串）"
        echo "      配置见 docs/RELEASING.md §1.3。私钥丢失 = 已发布版本再也收不到更新。"
        exit 1
    fi
    echo "私钥来源: 登录钥匙串（本地开发路径；若报找不到密钥，先跑 scripts/sparkle_keys.sh）"
fi

# ── 打包产物清单 ────────────────────────────────────────────────────────────
shopt -s nullglob
DMGS=("$DIST_DIR"/*.dmg)
if [ ${#DMGS[@]} -eq 0 ]; then
    echo "错误: dist/ 里没有 .dmg。先跑 bash scripts/package_dmg.sh"
    exit 1
fi

# appcast 里每个 enclosure 的下载地址都钉死在 v$VERSION 上，而 generate_appcast
# 会把目录里**所有**归档都收进去：dist 里残留旧版 DMG 时会生成指向不存在资产的
# item（用户端 404 / 签名错配）。与其静默产出坏 appcast，不如让用户先清干净 dist。
EXPECTED_DMG="$DIST_DIR/$(bash "$PROJECT_DIR/scripts/artifact_name.sh")"
for d in "${DMGS[@]}"; do
    if [ "$d" != "$EXPECTED_DMG" ]; then
        echo "错误: dist/ 里还有其它版本的 DMG：$(basename "$d")"
        echo "      appcast 的下载前缀是 v$VERSION，收录它会产生死链。"
        echo "      请先移走旧 DMG（重跑 bash build.sh --dist-only 会自动归档旧 dist）。"
        exit 1
    fi
done
if [ ! -f "$EXPECTED_DMG" ]; then
    echo "错误: 没找到本版本的 DMG（$EXPECTED_DMG）"
    exit 1
fi

echo "=== 生成 appcast · v$VERSION ==="
for d in "${DMGS[@]}"; do echo "  纳入: $(basename "$d")"; done

# KEY_ARGS 走「有则展开、无则完全省略」的写法：
# bash 3.2（本机 /bin/bash，GitHub runner 上也是同一个）在 set -u 下展开**空数组**
# 会直接报 unbound variable，而指定了私钥文件时要把它变成 --ed-key-file 两个参数，
# 所以两者都得兼顾。
#
# --embed-release-notes：把更新说明**内嵌**进 appcast（CDATA），而不是留一个
# `<sparkle:releaseNotesLink>` 指过去。不留链接就不会 404 —— 否则还得记得把
# 与安装包同名的 .md 一起上传为 Release 资产，漏了就"更新弹窗里没有说明"。
"$GEN_APPCAST" \
    ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
    --embed-release-notes \
    --download-url-prefix "$URL_PREFIX" \
    -o "$DIST_DIR/appcast.xml" \
    "$DIST_DIR"

# ── 产物自检 ────────────────────────────────────────────────────────────────
# ① 每个 enclosure 都必须带 edSignature：没有签名的 appcast 会被 Sparkle 直接拒绝，
#    而"私钥没生效"以前要到用户端才暴露。
if ! grep -q "edSignature" "$DIST_DIR/appcast.xml"; then
    echo "错误: appcast.xml 里没有任何 edSignature —— 私钥可能没生效，拒绝交付"
    exit 1
fi

# ② 公私钥一致性（能自动查的那部分）：仓库公钥必须与打进 App 的公钥一致。
#    真正的密码学校验需要验证 Ed25519 签名，Sparkle CLI 没有 verify 子命令；
#    换密钥后的手工自检步骤见 docs/RELEASING.md §1.1。
APP_PLIST="$DIST_DIR/随手迁.app/Contents/Info.plist"
REPO_KEY="$(tr -d ' \t\r\n' < "$PROJECT_DIR/sparkle_public_key.txt" 2>/dev/null || true)"
APP_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_PLIST" 2>/dev/null || true)"
if [ -z "$APP_KEY" ]; then
    echo "错误: dist/随手迁.app 的 Info.plist 里没有 SUPublicEDKey —— 用户端无法校验更新包"
    exit 1
fi
if [ -n "$REPO_KEY" ] && [ "$REPO_KEY" != "$APP_KEY" ]; then
    echo "错误: 打进 App 的 SUPublicEDKey 与仓库 sparkle_public_key.txt 不一致"
    echo "      app:  ${APP_KEY}"
    echo "      repo: ${REPO_KEY}"
    exit 1
fi

echo ""
echo "产物: $DIST_DIR/appcast.xml"
echo "下载前缀: $URL_PREFIX"
echo "公钥（人工核对用）: ${APP_KEY}"
