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
echo "[1/5] 编译..."
swift build -c release --package-path "$PROJECT_DIR"

# 3. Copy binary
BIN=$(find "$PROJECT_DIR/.build" -name "$APP_NAME" -type f -not -path "*/DerivedData/*" | head -1)
if [ -z "$BIN" ]; then
    echo "错误: 找不到编译产物"
    exit 1
fi
cp "$BIN" "$MACOS_DIR/"

# 4. Copy Sparkle
echo "[2/5] 复制 Sparkle 框架..."
SPARKLE_SRC=$(find "$PROJECT_DIR/.build" -path "*/Sparkle.framework" -type d -not -path "*/DerivedData/*" | head -1)
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
    <string>2.2.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.2.0</string>
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
</dict>
</plist>
EOF

# 6. Fix rpath (Sparkle in Frameworks/)
echo "[5/7] 修正 rpath..."
install_name_tool -add_rpath @executable_path/../Frameworks "$MACOS_DIR/$APP_NAME" 2>/dev/null || true

# 7. Sign
echo "[6/7] 签名..."
codesign --force --sign - --timestamp=none --deep "$BUNDLE"

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
