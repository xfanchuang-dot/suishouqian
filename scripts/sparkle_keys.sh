#!/bin/bash
# 一次性（或换密钥时）：生成 Sparkle 的 EdDSA 更新签名密钥对
#
# 生成物:
#   sparkle_public_key.txt   公钥（**不是秘密**，提交进仓库，构建时自动写进 Info.plist）
#   <私钥导出文件>           私钥（**绝密**，见下方"私钥去哪了"）
#
# Sparkle 2 的 generate_keys 默认把私钥存进**登录钥匙串**；
# 但 CI 里拿不到钥匙串，所以这里同时导出一份到文件，用于配置 GitHub Secret。
#
# 用法: bash scripts/sparkle_keys.sh [私钥导出路径]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PUB_FILE="$PROJECT_DIR/sparkle_public_key.txt"
KEY_OUT="${1:-$HOME/Library/Caches/suishouqian-sparkle/private_key.txt}"

SCRATCH="${SUISHOUQIAN_SCRATCH:-$HOME/Library/Caches/suishouqian-scratch}"
# 不要写成 `find … | head -1`：set -o pipefail 下 find 遇到不存在的目录返回 1，
# 脚本会在打印下面的友好提示之前就退出（零输出）。新机器第一次跑本脚本时
# 两个目录都还不存在，正是踩这个坑的场景（docs/RELEASING.md §1.1 的首条命令）。
GEN_KEYS=""
for root in "$SCRATCH" "$PROJECT_DIR/.build"; do
    [ -d "$root" ] || continue
    GEN_KEYS="$(find "$root" -name generate_keys -type f -print -quit 2>/dev/null)"
    if [ -n "$GEN_KEYS" ]; then break; fi
done
if [ -z "$GEN_KEYS" ]; then
    echo "错误: 找不到 generate_keys。先跑一次构建（bash build.sh --dist-only）把 Sparkle 工具拉下来。"
    exit 1
fi

if [ -f "$PUB_FILE" ]; then
    echo "⚠️  仓库里已经有 ${PUB_FILE}："
    echo "    $(cat "$PUB_FILE")"
    echo "    密钥对是**一个应用一辈子只用一把**——换掉它，已发布版本就再也升不了级。"
    echo "    如非必要请勿继续。"
    read -r -p "    确定要重新生成吗？输入 yes 继续: " ans
    [ "$ans" = "yes" ] || { echo "已取消。"; exit 0; }
fi

echo "=== 生成 / 读取 Sparkle 密钥对 ==="
# 无参数运行：钥匙串里已有则复用，没有则新建，公钥随即打印出来。
# 输出形如：
#     <key>SUPublicEDKey</key>
#     <string>NnrL8NNcqoc5vuWF4if9cxAf5tJkDyimJO5Ho5fWav0=</string>
# 所以按 <string> 标签精确抠，别用 tail -1（结尾有空行，会取到空串）。
RAW="$("$GEN_KEYS" 2>&1)"
PUBLIC="$(printf '%s\n' "$RAW" | grep -oE '<string>[A-Za-z0-9+/=]{40,}</string>' \
          | head -1 | sed -E 's#</?string>##g')"
if [ -z "$PUBLIC" ]; then
    # 兜底：任意位置出现的 44 字符 base64（Ed25519 公钥固定 32 字节 → 44 字符带一个 =）
    PUBLIC="$(printf '%s\n' "$RAW" | grep -oE '[A-Za-z0-9+/]{43}=' | head -1)"
fi

if [ -z "$PUBLIC" ] || [ ${#PUBLIC} -lt 40 ]; then
    echo "错误: 没能解析出公钥，generate_keys 的原始输出如下："
    printf '%s\n' "$RAW"
    exit 1
fi

printf '%s\n' "$PUBLIC" > "$PUB_FILE"
echo "公钥已写入: $PUB_FILE"
echo "  $PUBLIC"

# 导出私钥（钥匙串会弹一次授权）
mkdir -p "$(dirname "$KEY_OUT")"
"$GEN_KEYS" -x "$KEY_OUT"
chmod 600 "$KEY_OUT"
echo "私钥已导出: $KEY_OUT"

cat <<EOF

────────────────────────────────────────────────────────────
私钥去哪了（三处，缺一不可）:
  1) 登录钥匙串        —— 本地 generate_appcast 直接取用，无需额外操作
  2) $KEY_OUT
                       —— CI 用，见下一步
  3) **离线备份**      —— 换电脑 / 重装系统后没有它就无法再发布更新。
                          私钥丢了 = 只能换新密钥 = 所有已发布版本从此升不了级。

配置 GitHub Secret（仓库 Settings → Secrets and variables → Actions）:
  名称: SPARKLE_PRIVATE_KEY
  值:   上面这个私钥文件的全部内容

公钥随仓库提交（${PUB_FILE}），build.sh 会自动写进 Info.plist 的 SUPublicEDKey。
────────────────────────────────────────────────────────────
EOF
