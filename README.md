# 随手迁 Suishouqian

> 把 Mac 内置盘上的大应用，安全地搬到外置硬盘，释放空间。
> Move large Mac apps to external drives safely, free up internal storage.

[![Tests](https://github.com/xfanchuang-dot/suishouqian/actions/workflows/tests.yml/badge.svg)](https://github.com/xfanchuang-dot/suishouqian/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 为什么是随手迁？

256GB 的 MacBook，装个 Xcode 就没了一半。随手迁把不常用的大应用搬到外置盘，
在原位置留一个符号链接——应用以为自己还在老地方，双击照常用。

**核心承诺：数据安全优先。** 迁移前自动备份，任何一步失败都回滚，绝不丢数据。
200+ 自动化测试覆盖每一条安全红线。

## 安全设计（代码可审计）

- ✅ 迁移前完整备份，失败自动回滚
- ✅ 取消/中断走回滚语义，绝不删源数据
- ✅ exFAT 硬拦截（不支持符号链接的文件系统直接拒绝）
- ✅ 备份盘空间预检，跨盘备份防单点故障
- ✅ 操作日志完整可查（`~/Library/Application Support/随手迁/`）

详见 [CHANGELOG.md](CHANGELOG.md) 里的每一次安全修复记录。

## 功能

| 免费版 | Pro 版 |
|---|---|
| 应用迁移 / 回迁 | 智能迁移建议 |
| 健康体检（断链/备份/残留） | 版本化备份 |
| 磁盘测速 / SMART 监控 | 多 Mac 配置同步 |
| 迁移历史时间线 | 优先支持 |

> **Pro 现状说明（诚实版）**：Pro 的三项功能（智能迁移建议 / 版本化备份 / 多 Mac 配置同步）
> **仍在开发中**，当前版本激活 Pro 并不会扩大或限制免费功能的使用范围。
> ¥29 为**买断制**：一次付费，后续所有 Pro 功能上线后自动解锁，并优先获得支持。
> 许可证离线 Ed25519 校验，不联网、不上传任何数据。
> 签发机制与运维手册见 [docs/LICENSE_ISSUING.md](docs/LICENSE_ISSUING.md)。

购买入口：[爱发电](https://afdian.com/a/suishouqian)（⏳ 购买页筹备中，上线后才会收款）

## 安装

> ⚠️ **当前只有方式三可用。** Releases 尚无二进制，Homebrew cask 也未上架
> （`brew install --cask suishouqian` 会 404）。方式一、方式二随首个 Release 生效。

### 方式一：下载已编译版（待首个 Release）

从 [Releases](https://github.com/xfanchuang-dot/suishouqian/releases) 下载最新 `.dmg`。

> ⚠️ 未签名版本：首次打开时按住 Control 键点击 → 选择"打开"，之后即可正常使用。

### 方式二：Homebrew（待 cask 上架）

```bash
brew install --cask suishouqian
```

### 方式三：从源码编译（当前可用）

```bash
git clone https://github.com/xfanchuang-dot/suishouqian.git
cd suishouqian
bash build.sh
```

**编译**需要 Xcode 26+（macOS 26 SDK，代码里用了 Liquid Glass 的 `Glass`/`glassEffect`，
旧 SDK 里连类型都没有）；**运行**需要 macOS 14+；**架构**为 Apple Silicon（arm64），
默认只编 arm64，要出 Intel 包：`SUISHOUQIAN_ARCHS="arm64 x86_64" bash build.sh`。

## 截图

（待补充）

## 支持开发者

随手迁是个人独立开发，0 成本运营。如果它帮你省下了买大容量 Mac 的钱：

- ⭐ 给个 Star，让更多人看到
- 💰 [爱发电赞助](https://afdian.com/a/suishouqian)（¥29 解锁 Pro）
- 🐛 [提 Issue](https://github.com/xfanchuang-dot/suishouqian/issues) 帮我改进

## 许可证

MIT，详见 [LICENSE](LICENSE)。

---

## Why Suishouqian?

Your 256GB MacBook is half gone after installing Xcode. Suishouqian moves
infrequently-used large apps to an external drive, leaving a symlink behind —
apps think they're still home, double-click and they just work.

**Core promise: data safety first.** Automatic backup before every migration,
rollback on any failure, never lose data. 200+ automated tests guard every
safety invariant.

## Safety Design (Auditable)

- ✅ Full backup before migration, auto-rollback on failure
- ✅ Cancel/interrupt follows rollback semantics, never deletes source data
- ✅ exFAT hard block (filesystems without symlink support are refused)
- ✅ Backup volume space pre-check, cross-volume backup against single-point failure
- ✅ Complete operation journal (`~/Library/Application Support/随手迁/`)

See [CHANGELOG.md](CHANGELOG.md) for every safety fix on record.

## Install

> ⚠️ **Only option 3 works today.** There are no binaries in Releases yet and the
> Homebrew cask is not published (`brew install --cask suishouqian` returns 404).
> Options 1 and 2 will go live with the first release.

Download the latest `.dmg` from [Releases](https://github.com/xfanchuang-dot/suishouqian/releases).

> ⚠️ Unsigned build: on first launch, Control-click → "Open", then it works normally.

Or via Homebrew (once the cask lands):

```bash
brew install --cask suishouqian
```

Or build from source — works today. **Building** requires Xcode 26+ (macOS 26 SDK:
the code uses Liquid Glass `Glass`/`glassEffect`, which older SDKs do not declare);
**running** requires macOS 14+; and builds are Apple Silicon (arm64) only by
default. For an Intel binary: `SUISHOUQIAN_ARCHS="arm64 x86_64" bash build.sh`.

```bash
git clone https://github.com/xfanchuang-dot/suishouqian.git
cd suishouqian
bash build.sh
```

## Support

> **Honest note on Pro:** the three Pro features (migration advice, versioned
> backups, multi-Mac config sync) are **still in development**. Activating Pro
> today does not restrict or expand any free feature. ¥29 is a **one-time
> purchase** that unlocks every future Pro feature once shipped, plus priority
> support. Licenses verify offline via Ed25519 — no network calls, no telemetry.

- ⭐ Star this repo to help others discover it
- 💰 [Sponsor](https://afdian.com/a/suishouqian) (¥29 one-time for Pro — ⏳ page in preparation, no charges collected yet)
- 🐛 [File issues](https://github.com/xfanchuang-dot/suishouqian/issues)

## License

MIT, see [LICENSE](LICENSE).
