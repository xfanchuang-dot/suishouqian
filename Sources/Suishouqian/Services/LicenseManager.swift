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

    /// 内嵌公钥（base64）。与仓库根 `license_public_key.txt` 同源，改一处必须改另一处。
    /// 私钥绝不进仓库：默认落在 `~/Library/Caches/suishouqian-license/private_key.txt`。
    static let publicKeyBase64 = "CVIcMAiWyS8ap1EY8Wm237flexTjFjf66CWZyQxWVQE="

    /// 占位符：仓库刚 clone 下来、还没注入公钥时是它。此时任何许可证都验不过。
    static let placeholderPublicKey = "REPLACE_WITH_YOUR_PUBLIC_KEY"

    private static let storageKey = "proLicense.v1"

    @Published private(set) var isPro: Bool = false
    @Published private(set) var licensedEmail: String?

    private init() {
        // 启动时从 UserDefaults 恢复并验证（防篡改：每次都验签）
        if let stored = UserDefaults.standard.string(forKey: Self.storageKey) {
            _ = activate(license: stored)  // 失败则保持免费版
        }
    }

    /// 输入许可证字符串，验证通过则激活 Pro。返回人话结果。
    @discardableResult
    func activate(license: String) -> (ok: Bool, message: String) {
        guard let result = Self.verify(license) else {
            return (false, "许可证无效：格式错误或签名不匹配")
        }
        guard !result.isExpired else {
            return (false, "许可证已过期（\(Self.dateString(result.expiry))）")
        }
        // 存**规范化后**的字符串：粘贴时带进来的换行/缩进不该让恢复时验签失败
        UserDefaults.standard.set(Self.normalized(license), forKey: Self.storageKey)
        isPro = true
        licensedEmail = result.email
        AuditLog.append("Pro 许可证已激活：\(result.email)")
        return (true, "Pro 已激活，感谢支持！")
    }

    /// 退出 Pro（清除本地许可证）
    func deactivate() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
        isPro = false
        licensedEmail = nil
    }

    // MARK: - 验证

    struct LicenseInfo {
        let email: String
        let expiry: Date
        let tier: String

        /// 有效期**含当日**：到期日当天仍可用，次日 00:00 起失效。
        /// 不这么做的话，`2099-12-31` 会在当天 00:00 就被判过期，用户看到"已过期"少一天。
        var isExpired: Bool {
            guard let endOfDay = Calendar(identifier: .gregorian)
                .date(byAdding: .day, value: 1, to: expiry) else { return true }
            return Date() >= endOfDay
        }
    }

    /// 用内嵌公钥验证。返回 nil 表示格式错误或签名不匹配。
    static func verify(_ license: String) -> LicenseInfo? {
        if publicKeyBase64 == placeholderPublicKey {
            NSLog("[随手迁] 许可证公钥仍是占位符，Pro 激活一定失败——发布前必须注入真实公钥")
            return nil
        }
        return verify(license, publicKeyBase64: publicKeyBase64)
    }

    /// 可注入公钥的验证实现（单元测试用；生产走上面的单参重载）。
    static func verify(_ license: String, publicKeyBase64 key: String) -> LicenseInfo? {
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
        guard let expiry = payloadDateFormatter.date(from: fields[1]) else { return nil }
        return LicenseInfo(email: fields[0], expiry: expiry, tier: fields[2])
    }

    /// 去掉粘贴许可证时带进来的全部空白（含内部换行）。签发端做同样处理，两端必须一致。
    static func normalized(_ license: String) -> String {
        license.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// 固定格式的日期解析器。
    ///
    /// `dateFormat` 必须锁 `en_US_POSIX`：否则会跟随用户区域设置，同一张许可证在
    /// 佛历 / 民国历 / 伊斯兰历的 Mac 上会解析成完全不同的日期（甚至解析失败）。
    /// 时区固定 Asia/Shanghai，保证"到期日"对全世界用户是同一个瞬间。
    private static let payloadDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt
    }()

    private static func dateString(_ date: Date) -> String {
        payloadDateFormatter.string(from: date)
    }
}
