#!/bin/bash
# 发布产物文件名（**纯 ASCII**）的唯一来源。
#
# 为什么必须 ASCII —— v3.1.0 首发踩过的坑，代价是"全体用户自动更新 404"：
#   GitHub 会剥掉 Release 资产名里的非 ASCII 字符。本地叫 `随手迁-3.1.0.dmg`，
#   上传后资产变成 `-3.1.0.dmg`；而 appcast 里的下载 URL 是按**本地文件名**
#   生成的（.../%E9%9A%8F%E6%89%8B%E8%BF%81-3.1.0.dmg）→ 资产名与 URL 不一致
#   → Sparkle 拉得到 appcast、却下不到包。流水线自身的资产自检当场拦下了它。
#
# 单一来源的理由：这个文件名被四处消费（打包 / appcast 校验 / 公证 / 上传自检），
# 各写各的必然漂移 —— 与 build.sh 里 VERSION 只有一处来源是同一个道理。
#
# 注意：只约束**发布产物**的文件名。App bundle 仍叫 `随手迁.app`、
# DMG 卷名仍叫「随手迁」，中文只出现在用户看得见的界面上，不出现在 URL 里。
#
# 用法:
#   bash scripts/artifact_name.sh          # → Suishouqian-3.1.0.dmg
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \t\r\n' < "$PROJECT_DIR/VERSION")"
[ -n "$VERSION" ] || { echo "错误: VERSION 文件为空" >&2; exit 1; }

# ASCII slug：与 App 名对应，但不含任何非 ASCII 字符
echo "Suishouqian-${VERSION}.dmg"
