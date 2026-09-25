# 快捷方式集合。**build.sh 是唯一的构建/打包入口**。
#
# 这里不再自己实现打包。此前本文件自带一套「release」recipe——写死 CFBundleShortVersionString
# 2.0.0、用 Apple 已废弃的 `codesign --deep`、`rm -rf /Applications/随手迁.app` 后再 cp——
# 与 build.sh 形成两套入口互相打架，`make release` 产出的还是个版本号假的包。
# 现在全部转发给 build.sh / scripts/，只有一处实现。
#
# 版本号来自 ./VERSION（见 build.sh 顶部的说明）。

.PHONY: help build test install dist dmg appcast release-keys clean

APP_NAME := 随手迁
VERSION  := $(shell tr -d ' \t\r\n' < VERSION 2>/dev/null)

help:
	@echo "随手迁 v$(VERSION) —— 可用目标:"
	@echo "  make build         调试编译 (swift build)"
	@echo "  make test          跑全部单元测试"
	@echo "  make install       编译+签名+装进 /Applications 并启动  ← 日常"
	@echo "  make dist          编译+签名，产物只留在 dist/"
	@echo "  make dmg           在 dist/ 里打包 DMG"
	@echo "  make appcast       生成 dist/appcast.xml（需 Sparkle 私钥）"
	@echo "  make release-keys  一次性：生成 Sparkle 更新签名密钥"
	@echo "  make clean         清理 SwiftPM 构建缓存"

build:
	swift build

test:
	swift test

install:
	bash build.sh

dist:
	bash build.sh --dist-only

dmg: dist
	bash scripts/package_dmg.sh --no-build

appcast: dmg
	bash scripts/make_appcast.sh

release-keys:
	bash scripts/sparkle_keys.sh

clean:
	swift package clean 2>/dev/null || true
