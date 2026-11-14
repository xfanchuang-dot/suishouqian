import Foundation
import Combine
import CryptoKit

/// Pro 许可证管理器：离线 Ed25519 签名验证，零服务器成本。
///
/// 原理：
/// - 开发者本地保管 Ed25519 私钥，用它给 `email|expiry|tier` 签名
/// - App 内嵌公钥（下面 `publicKeyBase64`），启动/输入时验签
/// - 无网络也可用；防君子不防小人（开源项目接受这一点）
///
/// 密钥与签发都用仓库里的工具，**不要**在两个地方各造一套逻辑：
/// ```bash
/// swift scripts/license_tool.swift keygen                 # 一次性，私钥出仓
/// swift scripts/license_tool.swift issue --email a@b.com  # 每来一单跑一次
/// swift scripts/license_tool.swift verify '<许可证>'       # 发出去之前自检
/// ```
/// 该脚本与下面的 `verify` 共用同一份格式约定（payload 编码、日期区域、分隔符）。
///
/// `@MainActor`：`@Published` 的属性变更必须在主线程驱动 SwiftUI，
/// 静态单例也因此获得 Swift 6 严格并发下的安全性。
@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    /// 签发端与校验端共同接受的层级。目前只有买断 Pro。
    /// nonisolated：LicenseInfo 不在主 actor 上，比对层级时不能读隔离属性。
    nonisolated static let proTier = "pro"

    /// 内嵌公钥（base64）。与仓库根 `license_public_key.txt` 同源，改一处必须改另一处。
    /// 私钥绝不进仓库：默认落在 `~/Library/Caches/suishouqian-license/private_key.txt`。
    /// nonisolated：后台线程（迁移前归档判断）也要验签，与 UI 用同一把公钥。
    nonisolated static let publicKeyBase64 = "CVIcMAiWyS8ap1EY8Wm237flexTjFjf66CWZyQxWVQE="

    /// 占位符：仓库刚 clone 下来、还没注入公钥时是它。此时任何许可证都验不过。
    nonisolated static let placeholderPublicKey = "REPLACE_WITH_YOUR_PUBLIC_KEY"

    private static let storageKey = "proLicense.v1"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var licensedEmail: String?
    /// 完整权益状态（Pro / 试用 / 免费）。UI 只读它，避免各处自己拼 isPro + 试用。
    @Published private(set) var entitlement: ProEntitlement.Status = .free
    /// 试用剩余天数（Pro 激活后为 nil）
    @Published private(set) var trialDaysLeft: Int?

    private init() {
        // 启动时从 UserDefaults 恢复并验证（防篡改：每次都验签）
        if let stored = UserDefaults.standard.string(forKey: Self.storageKey) {
            _ = activate(license: stored)  // 失败则保持免费版
        }
        refreshEntitlement()
    }

    /// 输入许可证字符串，验证通过则激活 Pro。返回人话结果。
    @discardableResult
    func activate(license: String) -> (ok: Bool, message: String) {
        guard let result = Self.verify(license) else {
            return (false, l10n("许可证无效：格式错误或签名不匹配"))
        }
        guard !result.isExpired else {
            return (false, l10n("许可证已过期（%@）", Self.dateString(result.expiry)))
        }
        guard result.grantsPro else {
            return (false, l10n("许可证层级不是 Pro（%@），不能解锁", result.tier))
        }
        // 存**规范化后**的字符串：粘贴时带进来的换行/缩进不该让恢复时验签失败
        UserDefaults.standard.set(Self.normalized(license), forKey: Self.storageKey)
        refreshEntitlement()
        AuditLog.append("Pro 许可证已激活：\(result.email)")
        return (true, l10n("Pro 已激活，感谢支持！"))
    }

    /// 开始 7 天全功能试用（一次性）。返回 false = 以前用过。
    @discardableResult
    func startTrial(now: Date = Date()) -> Bool {
        guard ProEntitlement.startTrialIfAvailable(now: now) else { return false }
        refreshEntitlement(now: now)
        AuditLog.append("Pro 试用已开始（\(ProEntitlement.trialDays) 天）")
        return true
    }

    /// 是否用过试用（无论是否仍在有效期）
    var hasUsedTrial: Bool { ProEntitlement.hasUsedTrial }

    /// 重新计算权益状态。启动、激活、开始试用、退出 Pro、以及界面重新出现时调用。
    /// 试用倒计时按当前时刻现算，不依赖定时器。
    func refreshEntitlement(now: Date = Date()) {
        let status = ProEntitlement.status(now: now)
        entitlement = status
        switch status {
        case .free:
            isPro = false
            licensedEmail = nil
            trialDaysLeft = nil
        case .trial(let days):
            isPro = false
            licensedEmail = nil
            trialDaysLeft = days
        case .pro(let email, _):
            isPro = true
            licensedEmail = email
            trialDaysLeft = nil
        }
    }

    /// 退出 Pro（清除本地许可证）。**不清试用标记**——试用是一次性的，
    /// 退出 Pro 不应把试用时间重置成"又能白用 7 天"。
    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        refreshEntitlement()
    }

    // MARK: - 验证

    struct LicenseInfo {
        let email: String
        let expiry: Date
        let tier: String

        /// 与功能门控同一口径：只有 `pro` 才算 Pro。验签通过但层级不对不能解锁。
        var grantsPro: Bool { tier == LicenseManager.proTier }

        /// 有效期**含当日**：到期日当天仍可用，次日 00:00 起失效。
        /// 不这么做的话，`2099-12-31` 会在当天 00:00 就被判过期，用户看到"已过期"少一天。
        /// 传 now 便于试用/测试用同一"当下"口径判断。
        func isExpired(now: Date = Date()) -> Bool {
            guard let endOfDay = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 1, to: expiry) else { return true }
            return now >= endOfDay
        }

        /// 兼容属性写法（激活流程/既有测试）
        var isExpired: Bool { isExpired(now: Date()) }
    }

    /// 用内嵌公钥验证。返回 nil 表示格式错误或签名不匹配。
    /// nonisolated：后台线程判权（版本化备份归档、智能建议）与 UI 走同一实现。
    nonisolated static func verify(_ license: String) -> LicenseInfo? {
        if publicKeyBase64 == placeholderPublicKey {
            NSLog("[随手迁] 许可证公钥仍是占位符，Pro 激活一定失败——发布前必须注入真实公钥")
            return nil
        }
        return verify(license, publicKeyBase64: publicKeyBase64)
    }

    /// 可注入公钥的验证实现（单元测试用；生产走上面的单参重载）。
    nonisolated static func verify(_ license: String, publicKeyBase64 key: String) -> LicenseInfo? {
        // 格式：base64(payload).base64(signature)
        // base64 字母表不含 "."，所以按第一个 "." 切分是安全的。
        let parts = normalized(license).split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let payloadData = Data(base64Encoded: parts[0]),
              let sigData = Data(base64Encoded: parts[1]),
              let payload = String(data: payloadData, encoding: .utf8) else {
            return nil
        }
        // 先验签、后解析：未签名的内容不参与任何业务判断
        guard let pubKeyData = Data(base64Encoded: key),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData),
              pubKey.isValidSignature(sigData, for: payloadData) else {
            return nil
        }
        // 解析 payload：email|expiry|tier
        let fields = payload.split(separator: "|").map(String.init)
        guard fields.count == 3 else { return nil }
        guard let expiry = parseExpiry(fields[1]) else { return nil }
        let tier = fields[2]
        guard tier == proTier else { return nil }
        return LicenseInfo(email: fields[0], expiry: expiry, tier: tier)
    }

    /// 去掉粘贴许可证时带进来的全部空白（含内部换行）。签发端做同样处理，两端必须一致。
    nonisolated static func normalized(_ license: String) -> String {
        license.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 固定格式 `yyyy-MM-dd` 的线程安全解析（不能再共用静态 DateFormatter：
    /// DateFormatter 非 Sendable，后台判权会构成数据竞争）。
    ///
    /// 语义与旧实现一致：公历、`Asia/Shanghai` 时区——同一张许可证在佛历 /
    /// 民国历 / 伊斯兰历区域的 Mac 上必须解析成同一个瞬间。
    /// 额外做回读校验，拒绝 `2026-02-30` 这类会被 Calendar 归一化的假日期。
    nonisolated static func parseExpiry(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1970...9999).contains(year), (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    private static func dateString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt.string(from: date)
    }
}
