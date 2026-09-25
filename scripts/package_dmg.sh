#!/bin/bash
# 把 dist/随手迁.app 打成 DMG（拖拽安装惯例：镜像里 .app + Applications 软链）
#
# 用法:
#   bash scripts/package_dmg.sh              # dist 里没有 .app 就先构建
#   bash scripts/package_dmg.sh --no-build   # 只用 dist 里现有的 .app
#   SIGN_IDENTITY="Developer ID Application: ..." bash scripts/package_dmg.sh
#
# 产物: dist/随手迁-<version>.dmg
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="随手迁"
DIST_DIR="$PROJECT_DIR/dist"
BUNDLE="$DIST_DIR/$APP_NAME.app"

VERSION="$(tr -d ' \t\r\n' < "$PROJECT_DIR/VERSION")"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

NO_BUILD=0
for arg in "$@"; do
    case "$arg" in
        --no-build) NO_BUILD=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "错误: 未知参数 $arg"; exit 1 ;;
    esac
done

if [ ! -d "$BUNDLE" ]; then
    if [ "$NO_BUILD" = "1" ]; then
        echo "错误: $BUNDLE 不存在，且指定了 --no-build"
        exit 1
    fi
    echo "dist 里没有 $APP_NAME.app，先构建..."
    bash "$PROJECT_DIR/build.sh" --dist-only
fi

# 护栏：绝不把签名坏掉的包发出去（同项目姊妹工程的教训——
# `codesign ... || true` 吞错会让"构建成功"变成谎话）
if ! codesign --verify --strict "$BUNDLE"; then
    echo "错误: $APP_NAME.app 签名校验未通过，拒绝打包"
    exit 1
fi

echo "=== 打包 DMG · v$VERSION ==="

# staging：镜像根目录里放 .app + 指向 /Applications 的软链，用户拖一下即安装。
# 用系统临时目录且不主动清理 —— 本机 safe-delete 钩子会拦批量删除（.app 近百个文件），
# 而 $TMPDIR 由系统自己回收。
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/suishouqian-dmg.XXXXXX")"

# ditto 而非 cp -R：保留全部元数据与扩展属性（签名/隔离属性都依赖它）
ditto "$BUNDLE" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

# DMG 本身也可以签名（有 Developer ID 时签上，公证才认）
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -n "$SIGN_IDENTITY" ] && [ "$SIGN_IDENTITY" != "-" ] \
   && security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    echo "  DMG 已签名（${SIGN_IDENTITY}）"
fi

echo ""
echo "产物: $DMG"
echo "大小: $(du -sh "$DMG" | cut -f1)"
echo "SHA256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
