.PHONY: build release package install clean test

APP_NAME := 随手迁
BUILD_DIR := .build/arm64-apple-macosx/release
DIST_DIR := dist
APP_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
SOURCES := Sources/Suishouqian

build:
	swift build -c release 2>&1

release: build
	@echo "=== 打包 $(APP_NAME) ==="
	rm -rf $(DIST_DIR)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	mkdir -p $(APP_BUNDLE)/Contents/Frameworks
	# 复制二进制
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	# 复制Sparkle框架
	cp -R $(BUILD_DIR)/Sparkle.framework $(APP_BUNDLE)/Contents/Frameworks/
	# 添加rpath
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME) 2>/dev/null || true
	# 创建Info.plist
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > $(APP_BUNDLE)/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>$(APP_NAME)</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>com.suishouqian.app</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>$(APP_NAME)</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleDisplayName</key><string>$(APP_NAME)</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>1</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>2.0.0</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>CFBundlePackageType</key><string>APPL</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>15.0</string>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '<key>NSHighResolutionCapable</key><true/>' >> $(APP_BUNDLE)/Contents/Info.plist
	@echo '</dict></plist>' >> $(APP_BUNDLE)/Contents/Info.plist
	# 代码签名
	codesign --force --deep --sign - $(APP_BUNDLE) 2>&1
	@echo "=== 打包完成: $(APP_BUNDLE) ==="
	@du -sh $(APP_BUNDLE)

install: release
	@echo "=== 安装到 /Applications ==="
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_BUNDLE) /Applications/
	@echo "=== 安装完成 ==="

clean:
	rm -rf $(DIST_DIR)
	swift package clean 2>/dev/null || true
