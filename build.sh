#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
APP_NAME="随手迁"
BUNDLE="$DIST_DIR/$APP_NAME.app"
MACOS_DIR="$BUNDLE/Contents/MacOS"
FW_DIR="$BUNDLE/Contents/Frameworks"
RESOURCES_DIR="$BUNDLE/Contents/Resources"

echo "=== 随手迁 构建脚本 ==="

# 1. Clean
rm -rf "$DIST_DIR"
mkdir -p "$MACOS_DIR" "$FW_DIR" "$RESOURCES_DIR"

# 2. Build
# 构建缓存放内置盘：SwiftPM 的 build.db（SQLite）在这块 USB 外置盘上收尾落盘
# 必报 disk I/O error（直接 sqlite3 写同盘正常，纯 SwiftPM 触发，2026-09-23 实测），
# 内置盘无此问题且顺带更快。属构建产物，随删随建。
SCRATCH_DIR="$HOME/Library/Caches/suishouqian-scratch"
echo "[1/5] 编译..."
swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$SCRATCH_DIR"

# 3. Copy binary
BIN=$(find "$SCRATCH_DIR" -name "$APP_NAME" -type f -not -path "*/DerivedData/*" | head -1)
if [ -z "$BIN" ]; then
    echo "错误: 找不到编译产物"
    exit 1
fi
cp "$BIN" "$MACOS_DIR/"

# 4. Copy Sparkle
echo "[2/5] 复制 Sparkle 框架..."
SPARKLE_SRC=$(find "$SCRATCH_DIR" -path "*/Sparkle.framework" -type d -not -path "*/DerivedData/*" | head -1)
if [ -z "$SPARKLE_SRC" ]; then
    echo "警告: 找不到 Sparkle，跳过"
else
    cp -R "$SPARKLE_SRC" "$FW_DIR/"
    # Strip unnecessary archs and dSYMs from Sparkle to reduce size
    find "$FW_DIR/Sparkle.framework" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
fi

# 5. Copy icon
echo "[3/5] 拷贝图标..."
cp "$PROJECT_DIR/icon.icns" "$RESOURCES_DIR/"

# 6. Create Info.plist
echo "[4/5] 生成 Info.plist..."
cat > "$BUNDLE/Contents/Info.plist" << 'EOF'
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
    <string>2.15.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.15.0</string>
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
    <key>SUFeedURL</key>
    <string>https://github.com/xfanchuang-dot/suishouqian/releases/latest/download/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <false/>
</dict>
</plist>
EOF

# 6b. Sparkle 公钥（可选）：设置 SPARKLE_PUBLIC_KEY 环境变量时写入。
# 未设置时 App 内的「检查更新」会明确提示"通道尚未配置"，而不是抛原始错误。
if [ -n "${SPARKLE_PUBLIC_KEY:-}" ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" \
        "$BUNDLE/Contents/Info.plist"
    echo "  已写入 SUPublicEDKey"
fi

# 6. Fix rpath (Sparkle in Frameworks/)
echo "[5/7] 修正 rpath..."
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

# 7. Sign
# v2.3.2: 用自签证书稳定签名身份——ad-hoc 签名每次构建哈希都变，
# 系统 App Management/文件夹授权全部作废，导致反复弹授权框；
# 换稳定证书后授权只需授予一次，更新重装也不失效
# v2.6.0: 去掉已废弃的 `codesign --deep`，改为由内向外分层签名——
# --deep 是 Apple 明确不推荐用于签名的做法，对带 XPC/Helper 的框架可能漏签或错签
echo "[6/7] 签名..."
SIGN_IDENTITY="Suishouqian CodeSign"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "  ⚠️ 找不到签名证书 $SIGN_IDENTITY，退回 ad-hoc（授权将无法持久化）"
    SIGN_IDENTITY="-"
fi

if [ -d "$FW_DIR/Sparkle.framework" ]; then
    # 最内层：XPC 服务与内嵌 App（先签它们，否则外层签名会失效）
    while IFS= read -r -d '' nested; do
        codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$nested"
    done < <(find "$FW_DIR/Sparkle.framework" -depth \
                \( -name "*.xpc" -o -name "*.app" \) -print0)
    # 框架本体
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$FW_DIR/Sparkle.framework"
fi

# 最外层：主 App（不带 --deep，嵌套代码已在上面各自签好）
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$BUNDLE"

# 8. Install (overwrite, no rm to avoid permission dialogs)
echo ""
echo "构建完成: $BUNDLE"
echo "二进制大小: $(du -sh "$BUNDLE" | cut -f1)"
echo ""

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

# 9. 清理 dist 副本并启动正式版（避免启动台出现"双胞胎"应用）
rm -rf "$BUNDLE"
open "/Applications/$APP_NAME.app"
