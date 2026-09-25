#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="随手迁"
BUNDLE="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
FW_DIR="$BUNDLE/Contents/Frameworks"
RESOURCES_DIR="$BUNDLE/Contents/Resources"

usage() {
    cat <<'USAGE'
用法: bash build.sh [选项]

  （无选项）     编译 + 签名 + 安装到 /Applications + 启动   ← 日常开发
  --dist-only   编译 + 签名，产物只留在 dist/               ← CI / 发版
  --no-open     安装但不启动
  -h, --help    显示本帮助

环境变量:
  VERSION 由同目录 VERSION 文件提供（不要再写进脚本）。
  SIGN_IDENTITY      覆盖签名身份，默认 "Suishouqian CodeSign"（找不到则退回 ad-hoc）
  SPARKLE_PUBLIC_KEY 设置后写入 Info.plist 的 SUPublicEDKey
  SUISHOUQIAN_SCRATCH 覆盖 SwiftPM scratch 目录（默认内置盘 ~/Library/Caches/suishouqian-scratch）
USAGE
}

# ── 参数 ────────────────────────────────────────────────────────────────────
INSTALL=1
OPEN_APP=1
for arg in "$@"; do
    case "$arg" in
        --dist-only) INSTALL=0; OPEN_APP=0 ;;
        --no-open)   OPEN_APP=0 ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "错误: 未知参数 ${arg}（--dist-only / --no-open / --help）"; exit 1 ;;
    esac
done

# ── 版本：唯一机器可读来源是 VERSION（v3.0 工程化）────────────────────────────
# 此前 build.sh 写死 2.15.0、Makefile 写死 2.0.0、根 Info.plist 写 2.0——
# 三处各写各的，发版时必有一处忘记改。现在只有 VERSION 一处要改。
VERSION_FILE="$PROJECT_DIR/VERSION"
[ -f "$VERSION_FILE" ] || { echo "错误: 缺少 VERSION 文件"; exit 1; }
VERSION="$(tr -d ' \t\r\n' < "$VERSION_FILE")"
[ -n "$VERSION" ] || { echo "错误: VERSION 文件为空"; exit 1; }

# 防漂移：CHANGELOG 顶部版本必须与 VERSION 一致，否则发出去的包与更新日志对不上号
CHANGELOG_VER="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' "$PROJECT_DIR/CHANGELOG.md" \
                 | sed -E 's/^## ([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
if [ -n "$CHANGELOG_VER" ] && [ "$CHANGELOG_VER" != "$VERSION" ]; then
    echo "错误: 版本漂移 —— VERSION=${VERSION}，但 CHANGELOG 顶部=$CHANGELOG_VER"
    echo "      VERSION 是机器可读来源、CHANGELOG 是人读记录，改版本时两处要一起改。"
    exit 1
fi

echo "=== 随手迁 构建脚本 · v$VERSION ==="

# 1. Clean
# 不用 rm -rf：本机 safe-delete 钩子会拦批量删除（一个带 Sparkle 的 .app 就近百个文件，
# 必然越过阈值），脚本里配了 set -e 会直接在打包中途中断，症状是"构建莫名其妙只做了一半"。
# 改成把旧 dist 挪进 _bak/ —— 同卷 rename、瞬间完成。_bak/ 已进 .gitignore，
# 攒多了在 Finder 里拖进废纸篓即可（走废纸篓是为了可反悔）。
BAK_ROOT="$PROJECT_DIR/_bak"
if [ -e "$DIST_DIR" ]; then
    mkdir -p "$BAK_ROOT"
    mv "$DIST_DIR" "$BAK_ROOT/dist-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RESOURCES_DIR"

# 2. Build
# 构建缓存放内置盘：SwiftPM 的 build.db（SQLite）在这块 USB 外置盘上收尾落盘
# 必报 disk I/O error（直接 sqlite3 写同盘正常，纯 SwiftPM 触发，2026-09-23 实测），
# 内置盘无此问题且顺带更快。属构建产物，随删随建。
SCRATCH_DIR="${SUISHOUQIAN_SCRATCH:-$HOME/Library/Caches/suishouqian-scratch}"

# 架构：默认出**通用二进制**（arm64 + x86_64），与 README 声明的「Apple Silicon / Intel」一致。
# 此前只出本机架构 arm64，发出去的包 Intel 用户根本装不了，而 appcast 里还老实写着 arm64。
# 只想要本机架构、图快：SUISHOUQIAN_ARCHS=arm64 bash build.sh
ARCHS="${SUISHOUQIAN_ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

SWIFT_ARGS=(-c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_DIR" --disable-sandbox)
SWIFT_ARGS+=(${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})

echo "[1/6] 编译（${ARCHS}）..."
# --disable-sandbox：SwiftPM 会给自己套一层 sandbox-exec，在受限执行环境（本机是
# 自动化沙箱，外置盘上也复现过）里直接报 `sandbox-exec: sandbox_apply: Operation
# not permitted`，manifest 编译阶段就挂。关掉的是 SwiftPM 自己那层，不是系统沙箱。
swift build "${SWIFT_ARGS[@]}"

# 3. Copy binary
# 产物定位用 SwiftPM 自己报的 bin-path，不用 `find | head -1`——多架构构建时 .build 下
# 会有 per-arch 目录和 apple/Products 各一份，find 的顺序不确定，可能把单架构那份
# 拷进通用包里（症状："本机跑得好好的，Intel 用户说打不开"）。
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "错误: 找不到编译产物 $BIN"
    exit 1
fi
cp "$BIN" "$MACOS_DIR/"
echo "  二进制架构: $(lipo -archs "$MACOS_DIR/$APP_NAME")"

# 4. Copy Sparkle
echo "[2/6] 复制 Sparkle 框架..."
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "警告: 找不到 Sparkle（${SPARKLE_SRC}），跳过"
else
    cp -R "$SPARKLE_SRC" "$FW_DIR/"
    # Strip unnecessary archs and dSYMs from Sparkle to reduce size
    find "$FW_DIR/Sparkle.framework" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
fi

# 5. Copy icon
echo "[3/6] 拷贝图标..."
cp "$PROJECT_DIR/icon.icns" "$RESOURCES_DIR/"

# 6. Create Info.plist（版本号来自 VERSION，不再写死）
echo "[4/6] 生成 Info.plist（v${VERSION}）..."
cat > "$BUNDLE/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>随手迁</string>
    <key>CFBundleDisplayName</key>
    <string>随手迁</string>
    <key>CFBundleIdentifier</key>
    <string>com.suishouqian.app</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>随手迁</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>SUFeedURL</key>
    <string>https://github.com/xfanchuang-dot/suishouqian/releases/latest/download/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
</dict>
</plist>
EOF

# 6b. Sparkle 公钥（可选）：优先用环境变量 SPARKLE_PUBLIC_KEY，其次读仓库里的
# sparkle_public_key.txt（公钥不是秘密，提交进仓库；由 scripts/sparkle_keys.sh 生成）。
# 两者都没有时，App 内的「检查更新」会明确提示"通道尚未配置"，而不是抛原始错误。
PUBKEY="${SPARKLE_PUBLIC_KEY:-}"
if [ -z "$PUBKEY" ] && [ -f "$PROJECT_DIR/sparkle_public_key.txt" ]; then
    PUBKEY="$(tr -d ' \t\r\n' < "$PROJECT_DIR/sparkle_public_key.txt")"
fi
if [ -n "$PUBKEY" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBKEY" \
        "$BUNDLE/Contents/Info.plist"
    echo "  已写入 SUPublicEDKey"
fi

# 6c. Fix rpath (Sparkle in Frameworks/)
echo "[5/6] 修正 rpath..."
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

# 7. Sign
# v2.3.2: 用自签证书稳定签名身份——ad-hoc 签名每次构建哈希都变，
# 系统 App Management/文件夹授权全部作废，导致反复弹授权框；
# 换稳定证书后授权只需授予一次，更新重装也不失效
# v2.6.0: 去掉已废弃的 `codesign --deep`，改为由内向外分层签名——
# --deep 是 Apple 明确不推荐用于签名的做法，对带 XPC/Helper 的框架可能漏签或错签
# v3.0: 签名身份可用 SIGN_IDENTITY 覆盖（CI 里传 Developer ID）；
#       Developer ID 必须带安全时间戳（公证硬要求），自签/ad-hoc 用 none 更快
echo "[6/6] 签名..."
SIGN_IDENTITY="${SIGN_IDENTITY:-Suishouqian CodeSign}"
if [ "$SIGN_IDENTITY" != "-" ] \
   && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "  ⚠️ 找不到签名证书「${SIGN_IDENTITY}」，退回 ad-hoc（授权无法持久化，且无法公证）"
    SIGN_IDENTITY="-"
fi
case "$SIGN_IDENTITY" in
    "Developer ID Application"*) TS="--timestamp" ;;
    *)                           TS="--timestamp=none" ;;
esac

if [ -d "$FW_DIR/Sparkle.framework" ]; then
    # 最内层：XPC 服务与内嵌 App（先签它们，否则外层签名会失效）
    while IFS= read -r -d '' nested; do
        codesign --force --sign "$SIGN_IDENTITY" "$TS" "$nested"
    done < <(find "$FW_DIR/Sparkle.framework" -depth \
                \( -name "*.xpc" -o -name "*.app" \) -print0)
    # 框架本体
    codesign --force --sign "$SIGN_IDENTITY" "$TS" "$FW_DIR/Sparkle.framework"
fi

# 最外层：主 App（不带 --deep，嵌套代码已在上面各自签好）
codesign --force --sign "$SIGN_IDENTITY" "$TS" "$BUNDLE"

# 验签：只信 codesign 自己的结论。`|| true` 吞错会让"构建成功"变成谎话，
# 产物启动时被 SIGKILL 而终端里一句错都没有（同项目姊妹工程的教训）。
if ! codesign --verify --strict "$BUNDLE"; then
    echo "错误: 签名校验未通过，拒绝交付"
    exit 1
fi
echo "  签名已校验（${SIGN_IDENTITY}）"

echo ""
echo "构建完成: $BUNDLE"
echo "版本: $VERSION    大小: $(du -sh "$BUNDLE" | cut -f1)"
echo ""

# ── 安装（--dist-only 时跳过）──────────────────────────────────────────────
if [ "$INSTALL" = "0" ]; then
    echo "（--dist-only：跳过安装，产物留在 dist/）"
    exit 0
fi

# 杀掉旧版再覆盖安装（避免 cp 失败）
INSTALLED="/Applications/$APP_NAME.app"
if [ -d "$INSTALLED" ]; then
    pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    sleep 1
    # 旧版移到废纸篓（通过 osascript，不弹权限确认）
    osascript -e "tell application \"Finder\" to delete POSIX file \"$INSTALLED\"" 2>/dev/null || true
    sleep 0.5
fi
# 覆盖安装
cp -R "$BUNDLE" "/Applications/"
echo "已安装到 /Applications/"

# 清理 dist 副本并启动正式版（避免启动台出现"双胞胎"应用）。
# 同样不用 rm（见第 1 步的说明），挪进 _bak/。
mv "$BUNDLE" "$BAK_ROOT/app-installed-$(date +%Y%m%d-%H%M%S)"
if [ "$OPEN_APP" = "1" ]; then
    open "/Applications/$APP_NAME.app"
fi
