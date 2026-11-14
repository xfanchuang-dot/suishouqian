# 销售与发货：xios.uk 订单系统（半自动）

> 2026-11-14 起**停用爱发电**，购买入口统一为
> <https://xios.uk/suishouqian/buy/>。
>
> 个人支付宝收款码**没有支付回调**，所以是「半自动」：
> 买家下单 → 扫码转账（备注订单号）→ 管理员核对到账后点一次确认 →
> **服务器自动从许可证池取一张，买家订单页立刻显示**。签发与交付全自动，只有收款确认是人工。

## 1. 入口与流程

| 项 | 值 |
|---|---|
| 购买页 | <https://xios.uk/suishouqian/buy/> |
| 订单页 | `/suishouqian/order/?id=<订单号>#t=<token>`（下单后生成；token 放 fragment，不进服务器日志） |
| 管理后台 | <https://xios.uk/suishouqian/admin/> |
| 价格 | **¥29 一次性买断**（非订阅） |
| 收款 | 支付宝个人收款码（站点 `assets/img/alipay-qr.png`） |
| 发货 | 管理员确认后自动发证；承诺 24h 内，通常几小时 |

买家流程：

1. 购买页填邮箱 + 可选备注 → 创建订单，得到订单号（如 `4CD90D0E`）与专属订单页；
2. 支付宝扫码转 ¥29，**备注订单号**；
3. 打开订单页，等待状态从「等待确认」变为「已发放」；
4. 复制许可证 → App → 设置 → Pro → 已有许可证 → 激活。

订单页链接丢失：用「订单号 + 下单邮箱」在订单页底部找回（会生成新 token，旧链接失效）。

## 2. 管理后台

- 地址：<https://xios.uk/suishouqian/admin/>
- Token：服务器 `/etc/ssq-order/config.json` 的 `admin_token`；
  本地留了一份在 `~/ZCodeProject/xios-site/.ssq-admin-token`（已 gitignore，权限 600）。
- 后台能力：待确认列表、一键「确认到账并发放」、取消订单、库存余量（<5 张警告）、
  粘贴导入库存、已发放记录（含许可证复制）。
- Token 只存在浏览器 localStorage；换浏览器需重新输入。泄露就换：
  改 `/etc/ssq-order/config.json` 后 `systemctl restart ssq-order`。

## 3. 许可证池

服务器**不持有签发私钥**，只从预先生成的池里取号。补货：

```bash
# 在你自己的 Mac 上（私钥只在本地）
swift scripts/license_tool.swift pool --batch 20261114 --count 50
# stdout 一行一张 → 整段复制 → 后台「导入库存」粘贴
```

- 身份位固定为 `pro-<批次>-<序号>@xios.uk`，买家真实邮箱只存在订单记录里。
- 每批最多 5000 张；重复导入自动去重。
- 后台库存 <5 会红色警告；发货时库存为空会返回 409，不会出现「收了钱发不出证」。

## 4. 服务运维

| 项 | 位置 |
|---|---|
| 代码 | `/opt/ssq-order/app.py`（源码在站点仓库 `ssq-order/`） |
| 配置 | `/etc/ssq-order/config.json`（`admin_token` / `db_path` / `port` / 限流） |
| 数据库 | `/var/lib/ssq-order/orders.db`（订单 + 库存，**要备份**） |
| 服务 | `systemctl status/restart ssq-order`；日志 `journalctl -u ssq-order` |
| 反向代理 | Caddy `handle /api/* { reverse_proxy 127.0.0.1:8788 }` |
| 监听 | 仅 `127.0.0.1:8788`，公网只能经 Caddy |

接口（均同源）：

```
POST /api/orders                 下单（邮箱+备注）
GET  /api/orders/{id}?t=         订单状态 / 领取许可证
POST /api/orders/recover         订单号+邮箱找回
GET  /api/admin/*                X-Admin-Token 鉴权
```

## 5. 安全与限制（诚实版）

- 私钥不在服务器；服务器被入侵最多泄露**未发放**的库存许可证，已售出的不受影响。
- 订单 token 只存 SHA-256，且只走 URL fragment（`#t=`）与 `X-Order-Token` 请求头：
  fragment 不会发给服务器，Caddy 访问日志里不会出现 token。
- 下单限流：同 IP 5 单/小时；请求体上限 16KB；管理接口恒定时间比较 token。
- **没有 MX 记录**：`hello@xios.uk` 收不到邮件，所以流程完全不依赖邮件。
  若要恢复客服邮箱，建议用 Cloudflare Email Routing 转发到真实邮箱。
- 退款口径：未激活可联系退款；已激活原则上不退（页面已写明）。
- 个人支付宝长期收工具款有风控可能；量起来后换商户码/当面付。

## 6. 改价 / 换链接清单

1. 站点 `suishouqian/buy/index.html`（价格、收款码、文案、FAQ）
2. App `Sources/Suishouqian/Services/PurchaseLinks.swift`（`proCheckout` 单一常量）
3. `README.md` 购买入口（中文 + 英文）
4. 本文件
