# 发布手册

> 本文覆盖「从代码到用户手上」的全链路：打包 → 签名 → 公证 → 更新通道 → 分发。
> 对应 README 路线图里的 **v3.0 工程化收官**。

## 0. 版本号纪律（先看这条）

**版本号只有一个来源：仓库根目录的 `VERSION` 文件。**

| 曾经 | 现在 |
|---|---|
| `build.sh` 写死 2.15.0 / `Makefile` 写死 2.0.0 / 根 `Info.plist` 写 2.0 / `build.sh` 的 Info.plist 又写一遍 | 只改 `VERSION`，其余全部由它派生 |

发版时改**两处**，且必须一致：

1. `VERSION` → `2.16.0`
2. `CHANGELOG.md` 顶部新增 `## 2.16.0 — YYYY-MM-DD`

`build.sh` 会校验两处是否一致，不一致直接报错退出（防止"发出去的包版本号和更新日志对不上"）。
CI 还会额外校验 **git tag** 与 `VERSION` 一致。

## 1. 一次性准备

### 1.1 Sparkle 更新签名密钥（不花钱，但**必须备份**）

```bash
bash scripts/sparkle_keys.sh
```

产出：

- `sparkle_public_key.txt` —— 公钥，**提交进仓库**；`build.sh` 会自动写进 `Info.plist` 的 `SUPublicEDKey`
- 私钥 —— 存进**登录钥匙串**（本地 `generate_appcast` 直接用），同时导出到
  `~/Library/Caches/suishouqian-sparkle/private_key.txt` 供 CI 用

> ⚠️ **一个应用一辈子只用一把密钥。** 私钥丢了，就只能换新密钥，而所有已发布版本
> 都拿的是旧公钥 —— **它们从此再也收不到更新**，只能让用户手动下载新版。
> 所以：私钥必须做**离线备份**（密码管理器 / 加密 U 盘 / 纸质抄写都行）。

私钥要配到 GitHub Secret `SPARKLE_PRIVATE_KEY`（见 2.2）。

### 1.2 Apple Developer 账号（**唯一需要花钱的一项**）

Developer ID 签名与公证都要求付费账号（Apple Developer Program，**$99/年**）。

**没有账号也能发布**，只是用户体验降级（见第 3 节）。有账号后按下面配置，流水线会自动升级。

拿不到 Developer ID 证书时，`build.sh` 会退回自签证书 `Suishouqian CodeSign`
（本地已有，用于让 App Management / 文件夹授权能持久化），再找不到才退回 ad-hoc。

### 1.3 需要的 Secrets 一览

| Secret | 必填？ | 说明 |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | **发布正式版必填** | Sparkle 私钥全文。不配则 CI 上生成不了 appcast |
| `APPLE_CERTIFICATE_P12` | 可选 | Developer ID Application 证书（`.p12` 转 base64） |
| `APPLE_CERTIFICATE_PASSWORD` | 可选 | `.p12` 的密码 |
| `APPLE_ID` | 可选 | Apple 开发者账号邮箱 |
| `APPLE_TEAM_ID` | 可选 | 团队 ID |
| `APPLE_APP_PASSWORD` | 可选 | App 专用密码（[appleid.apple.com](https://appleid.apple.com) 生成，**不是**登录密码） |

导出证书给 CI：

```bash
# 钥匙串里导出 Developer ID Application 证书为 .p12 后：
base64 -i cert.p12 | pbcopy   # 粘贴到 APPLE_CERTIFICATE_P12
```

### 1.4 更新通道的前提：feed 必须**匿名**可达 ⚠️

这一条比签名、公证都更容易被忽略，而且**失败是静默的**。

Sparkle 拉 appcast 时**不带任何凭证**（`UpdateManager` 里就是一个 `SPUStandardUpdaterController`，
没有 token、没有认证）。而 `SUFeedURL` 指向的是：

```
https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml
```

于是：

| 仓库可见性 | 匿名拉 appcast | 结果 |
|---|---|---|
| **Public** | 200 | ✅ 更新通道可用 |
| **Private** | **404** | ❌ 已安装的用户**永远收不到更新**，且 App 端只会弹一个看不懂的错误 |

**本仓库当前是 Private**（2026-09-26 实测：匿名 `GET https://api.github.com/repos/xfanchuang-dot/suishouqian` → `404`）。
所以：**在改公开之前，更新通道是纸面上的。** 这不影响 DMG 分发，只影响自动更新。

两条出路，选一条即可：

**A. 把源码仓库改成 Public**（最省事）

GitHub → 仓库 → Settings → General → 最下方 Danger Zone → Change visibility → Public。
之后 `releases/latest/download/appcast.xml` 匿名可读，**不用改任何代码或配置**。
代价：源码公开。

**B. 另建一个**只放发布物的 Public 仓库（源码保持私有）

1. 新建公开仓库，例如 `suishouqian-releases`（空仓库即可，不放源码）
2. `make_appcast.sh` 的下载前缀已经是可覆盖的：

   ```bash
   REPO_SLUG="xfanchuang-dot/suishouqian-releases" bash scripts/make_appcast.sh
   ```

3. `build.sh` 里写入的 `Info.plist` → `SUFeedURL`，以及
   `Sources/Suishouqian/UpdateManager.swift` 的 `feedURL`，两处一起改成新仓库地址
   （**三处必须同步**：`UpdateManager.feedURL` / `build.sh` 的 `Info.plist` / `make_appcast.sh` 的 `URL_PREFIX`）
4. release.yml 里 `gh release create` 加 `--repo xfanchuang-dot/suishouqian-releases`，
   并把 `GH_TOKEN` 换成对该仓库有写权限的 PAT（默认 `GITHUB_TOKEN` 只能操作本仓库）

> CI 的第 3 步「检查更新通道可达性」会做匿名探测并在非 200 时打 `::warning::`，
> 就是为了让这件事**每次都出现在日志里**，而不是等到用户来问"为什么没更新"。

## 2. 发一版

### 2.1 本地发版（能出 DMG，不发布）

```bash
# 1) 改版本号（两处，见第 0 节）
vim VERSION CHANGELOG.md

# 2) 全量测试
swift test

# 3) 构建 + 签名，产物留在 dist/（不装进 /Applications、不启动）
bash build.sh --dist-only

# 4) 打 DMG（顺便再验一次签名；签名不过直接拒绝打包）
bash scripts/package_dmg.sh --no-build

# 5) 生成 appcast.xml
bash scripts/make_appcast.sh

# 产物
ls dist/          # 随手迁-2.16.0.dmg  appcast.xml  随手迁.app
```

日常开发只需 `bash build.sh` —— 编译 + 签名 + 装进 `/Applications` + 启动，一条命令。

### 2.2 CI 发版（推荐：一条 tag 全自动）

```bash
git tag v2.16.0
git push origin main --tags
```

`.github/workflows/release.yml` 会依次：

1. 校验 tag 与 `VERSION` 一致
2. `swift test` 全量回归（**不过就不发**）
3. **检查更新通道可达性**（匿名拉仓库 API；非 200 就告警，见 1.4）
4. 准备签名身份（配了 `APPLE_CERTIFICATE_P12` 才导入证书，否则走自签；结果写进 `SIGNED` 变量）
5. `build.sh --dist-only` 构建 + 分层签名
6. 公证并装订 `.app`（需 `SIGNED=yes` 且配了 `APPLE_ID`）
7. 打 DMG → 公证并装订 DMG
8. 从 `CHANGELOG.md` 抽出该版本说明（抽不到直接报错，不会发出空说明）→ 生成 `appcast.xml`
9. `gh release create` 发布 Release（DMG + appcast.xml 一起上传）

> 条件判断全部写在 shell 里，不用 `if: ${{ env.X != '' }}`。理由见文件头注释：
> 某些上下文（如 `secrets`）在 step 级 `if` 里不可用，写错**不报错、只静默跳过**，
> 是最难查的一类 CI 事故。`[ -n "${X}" ]` 没有这个歧义，本地还能照跑照验。

`SUFeedURL` 指向 `.../releases/latest/download/appcast.xml`，所以**每次发版都会自动成为最新**，
App 端「检查更新」不需要改任何配置 —— **前提是仓库公开（见 1.4）**。

## 3. 有账号 / 没账号的差别

| | 有 Developer ID + 公证 | 没有（当前状态） |
|---|---|---|
| 首次打开 | 双击即可 | 需右键 →「打开」，或到「系统设置 → 隐私与安全性」放行 |
| 公证票据 | 已装订，离线也能验 | 无 |
| Sparkle 自动更新 | 完整可用 | 通道本身可用，但新版本首次启动同样需要放行 |
| 签名身份 | Developer ID Application（带安全时间戳） | 自签 `Suishouqian CodeSign` / ad-hoc |

**这两列都还有个共同前提**：仓库必须是公开的，否则 appcast 匿名拉不到（见 1.4）。

流水线是**双路径**的：配好上面那 5 个 secrets 就自动走正式签名 + 公证，没配也照样出可下载的 DMG。
所以「先发起来」和「以后升级到正式签名」之间不需要改代码。

## 4. 为什么不能用 `codesign --deep`

`build.sh` 是**由内向外分层签名**：先签 Sparkle 里的 XPC 服务与内嵌 App，再签框架本体，
最后签主 App。`--deep` 是 Apple 明确不推荐用于签名的做法，对带 XPC/Helper 的框架可能漏签或错签。
历史 `Makefile` 里那套 `codesign --force --deep --sign -` 已于 v2.16.0 移除。

## 5. 常见问题

**Q: `make_appcast.sh` 卡住不返回？**
登录钥匙串那条路在自动化环境里会**卡住不返回**（不是报错，是挂着）。脚本已把
`scripts/sparkle_keys.sh` 导出的私钥文件排在钥匙串前面，正常情况下不会再走钥匙串。

**Q: 本地 `bash build.sh` 比以前慢了一倍？**
默认出**通用二进制**（arm64 + x86_64），与 README 声明的「Apple Silicon / Intel」一致 ——
此前只出构建机自己的 arm64，发出去的包 Intel 用户装不了。
改代码时想快：`SUISHOUQIAN_ARCHS=arm64 bash build.sh`。

**Q: 本地 `make_appcast.sh` 报「找不到密钥」？**
先跑一次 `bash scripts/sparkle_keys.sh`。钥匙串会弹一次授权框，点「始终允许」。

**Q: CI 里 appcast 生成失败？**
十有八九是没配 `SPARKLE_PRIVATE_KEY`。CI runner 上没有你的登录钥匙串，只能靠 secret 注入。

**Q: `swift build` 报 `sandbox_apply: Operation not permitted`？**
SwiftPM 会给自己套一层 sandbox-exec，在受限执行环境里会被拒。`build.sh` 已带
`--disable-sandbox`（关的是 SwiftPM 自己那层，不是系统沙箱）。

**Q: `swift build` 报 `disk I/O error`？**
本项目在外置盘上开发时，SwiftPM 的 `build.db`（SQLite）收尾落盘会出错，**且退出码仍是 0**（假成功）。
`build.sh` 已固定把 scratch 放内置盘（`~/Library/Caches/suishouqian-scratch`）。
`SUISHOUQIAN_SCRATCH` 环境变量可覆盖。

**Q: `_bak/` 里堆了一堆东西？**
`build.sh` 不用 `rm -rf`（会触发本机 safe-delete 钩子拦批量删除、把构建打断），
旧产物一律 `mv` 进 `_bak/`。攒多了在 Finder 里整目录拖进废纸篓即可（已进 `.gitignore`，不会误提交）。

**Q: 版本漂移报错？**
`VERSION` 与 `CHANGELOG.md` 顶部版本不一致。改版本号时两处一起改。

**Q: 用户「检查更新」报错 / 一直说已是最新，但明明发了新版？**
先按 1.4 验一下 feed 能不能匿名拉：

```bash
curl -sI https://github.com/xfanchuang-dot/suishouqian/releases/latest/download/appcast.xml | head -1
```

`404` = 仓库还是私有的（或还没发过任何 Release）。`200` 才是正常。
注意 `releases/latest` 只认**最新的非预发布** Release；如果发了 prerelease，它不会成为 latest。

**Q: 能改已发布版本的 DMG 吗？**
不要。appcast 里每个 enclosure 都带签名，改了文件签名就对不上，已安装的 App 会拒绝更新。
要改就发新版本号。
