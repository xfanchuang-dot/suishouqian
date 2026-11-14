import Foundation

/// Pro 权益清单。新增权益只加 case，门控口径统一走下方 `ProEntitlement`，
/// 不允许在各页面各写一份 `isPro || trial` 判断——那正是"设置页显示已解锁、
/// 执行链按免费跑"这类分叉的来源。
enum ProFeature: String, CaseIterable, Identifiable {
    /// 版本化备份：每次迁移把上一份备份归档为历史版本，可回滚
    case versionedBackup
    /// 智能迁移建议：按占用 × 闲置时长排序，一键生成计划
    case smartAdvice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .versionedBackup: return l10n("版本化备份")
        case .smartAdvice: return l10n("智能迁移建议")
        }
    }

    var detail: String {
        switch self {
        case .versionedBackup:
            return l10n("每次迁移保留最近 5 个历史版本，更新翻车时一键回滚到旧版")
        case .smartAdvice:
            return l10n("按占用空间与闲置时长排序，附上理由，一键生成迁移计划")
        }
    }
}

/// 唯一权益口径：Pro 许可证 > 7 天试用 > 免费。
///
/// **nonisolated**：迁移/备份等文件操作跑在后台线程，必须在任意线程上
/// 得到与 UI 完全一致的结论。因此这里不碰 `LicenseManager` 的 @Published
/// 状态，只读 UserDefaults + 纯验签（`LicenseManager.verify` 已 nonisolated）。
enum ProEntitlement {
    /// 试用天数（一次性，显式开始）
    static let trialDays = 7
    /// 试用开始时刻（Double，timeIntervalSince1970）。存在即表示已用过试用。
    static let trialStartKey = "proTrial.startedAt.v1"
    /// 与 LicenseManager 共用的许可证存储键
    static let licenseStorageKey = "proLicense.v1"

    enum Status: Equatable {
        case free
        case trial(daysLeft: Int)
        case pro(email: String, expiry: Date)

        var isActive: Bool {
            switch self {
            case .free: return false
            case .trial, .pro: return true
            }
        }

        var isPro: Bool {
            if case .pro = self { return true }
            return false
        }

        var trialDaysLeft: Int? {
            if case .trial(let days) = self { return days }
            return nil
        }
    }

    // MARK: - 查询

    /// 当前权益状态。许可证过期不会挡住仍在有效期内的试用（两者独立）。
    /// `licenseVerifier` 可注入（单测用；生产走内嵌公钥验签）。
    static func status(now: Date = Date(),
                       defaults: UserDefaults = .standard,
                       licenseVerifier: (String) -> LicenseManager.LicenseInfo?
                           = { LicenseManager.verify($0) }) -> Status {
        if let info = storedLicenseInfo(defaults: defaults, verifier: licenseVerifier),
           info.grantsPro,
           !info.isExpired(now: now) {
            return .pro(email: info.email, expiry: info.expiry)
        }
        if let daysLeft = trialDaysLeft(now: now, defaults: defaults) {
            return .trial(daysLeft: daysLeft)
        }
        return .free
    }

    /// 功能门控的唯一判断。保留 feature 参数是为了调用点自解释、
    /// 也为将来按功能分级留出口（当前所有 Pro 功能同一档）。
    static func isEntitled(_ feature: ProFeature,
                           now: Date = Date(),
                           defaults: UserDefaults = .standard,
                           licenseVerifier: (String) -> LicenseManager.LicenseInfo?
                               = { LicenseManager.verify($0) }) -> Bool {
        status(now: now, defaults: defaults, licenseVerifier: licenseVerifier).isActive
    }

    /// 试用剩余天数（向上取整，至少 1；已到期返回 nil）。
    static func trialDaysLeft(now: Date = Date(),
                              defaults: UserDefaults = .standard) -> Int? {
        guard let started = trialStartedAt(defaults: defaults) else { return nil }
        let elapsed = now.timeIntervalSince(started)
        let total = Double(trialDays) * 86400
        guard elapsed < total else { return nil }
        let left = (total - elapsed) / 86400
        return max(1, Int(ceil(left)))
    }

    /// 是否用过试用（无论是否仍在有效期）。
    static var hasUsedTrial: Bool {
        hasUsedTrial(defaults: .standard)
    }

    static func hasUsedTrial(defaults: UserDefaults) -> Bool {
        trialStartedAt(defaults: defaults) != nil
    }

    /// 开始试用。只能用一次；已用过返回 false。
    @discardableResult
    static func startTrialIfAvailable(now: Date = Date(),
                                      defaults: UserDefaults = .standard) -> Bool {
        guard trialStartedAt(defaults: defaults) == nil else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: trialStartKey)
        return true
    }

    // MARK: - 内部

    static func trialStartedAt(defaults: UserDefaults = .standard) -> Date? {
        guard let raw = defaults.object(forKey: trialStartKey) as? Double else { return nil }
        return Date(timeIntervalSince1970: raw)
    }

    /// 已存储的许可证（验签失败/未存储返回 nil）。
    static func storedLicenseInfo(defaults: UserDefaults = .standard,
                                  verifier: (String) -> LicenseManager.LicenseInfo?
                                      = { LicenseManager.verify($0) }) -> LicenseManager.LicenseInfo? {
        guard let raw = defaults.string(forKey: licenseStorageKey), !raw.isEmpty else {
            return nil
        }
        return verifier(raw)
    }
}
