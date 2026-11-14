import Foundation

/// 一条智能迁移建议：为什么推荐搬走、搬走能省多少。
struct SmartRecommendation: Identifiable {
    let app: AppItem
    /// 距上次使用的天数（nil = 系统没有可用记录，按中等活跃度估算）
    let lastUsedDays: Int?
    /// 排序分：体积(GB) × 闲置因子
    let score: Double
    /// 人话理由（不含体积——体积由 UI 单独用大字号呈现）
    let reasons: [String]

    var id: UUID { app.id }
    var sizeText: String { app.sizeFormatted }
}

/// 智能迁移建议引擎（Pro）。
///
/// 与免费的「高频应用 / 长期未用」顾问互补：那两项只回答单一信号，
/// 这里把**体积 × 闲置时长**合成一个排序分，并附上理由——
/// 用户看到的是"先搬这几个最划算"，而不是一堆分散的提示。
///
/// 边界（宁缺毋滥）：
/// - 只推荐内置盘、普通状态、非系统、≥500MB 的应用；
/// - 最近 14 天用过的**不推荐**——再大也不该动正在用的东西；
/// - 拿不到使用记录时给中性分（2.5），不因为"没数据"而误杀或误推。
enum SmartAdvice {
    static let minSizeBytes: Int64 = 500 * 1024 * 1024
    static let recentUseDays = 14
    /// UI 默认展示条数（完整计划仍会包含全部建议）
    static let displayLimit = 5

    // MARK: - 候选

    static func candidates(_ apps: [AppItem]) -> [AppItem] {
        apps.filter { app in
            app.status == .normal && !app.isSystemApp && app.size >= minSizeBytes
        }
    }

    // MARK: - 排序

    /// 纯函数：给定应用与「bundleID → 最近使用时刻」，产出排序后的建议。
    static func rank(apps: [AppItem],
                     lastUsed: [String: Date],
                     now: Date = Date()) -> [SmartRecommendation] {
        var out: [SmartRecommendation] = []
        for app in candidates(apps) {
            let key = app.bundleID ?? app.path
            let used = lastUsed[key] ?? lastUsed[app.path]
            let days: Int? = used.map {
                max(0, Int(now.timeIntervalSince($0) / 86400))
            }
            // 近 14 天用过：不推荐（数据明确时才排除；无数据不拦）
            if let days, days < recentUseDays { continue }

            out.append(SmartRecommendation(
                app: app,
                lastUsedDays: days,
                score: score(sizeBytes: app.size, lastUsedDays: days),
                reasons: reasons(for: app, lastUsedDays: days)))
        }
        return out.sorted { $0.score > $1.score }
    }

    /// 体积(GB) × 闲置因子。闲置因子：天数/30，截断 0.5–8；无数据取 2.5。
    static func score(sizeBytes: Int64, lastUsedDays: Int?) -> Double {
        let gb = Double(sizeBytes) / 1_073_741_824
        let factor: Double
        if let days = lastUsedDays {
            factor = min(max(Double(days) / 30.0, 0.5), 8.0)
        } else {
            factor = 2.5
        }
        return gb * factor
    }

    static func reasons(for app: AppItem, lastUsedDays: Int?) -> [String] {
        var out: [String] = []
        if let days = lastUsedDays {
            out.append(l10n("%lld 天未用", days))
        } else {
            out.append(l10n("使用记录不足，按中等活跃度估算"))
        }
        if app.updateMechanism == .appStore {
            out.append(l10n("App Store 应用，更新后需重新迁移"))
        }
        return out
    }

    /// 汇总文案用的总可腾出空间
    static func totalSavings(_ recommendations: [SmartRecommendation]) -> Int64 {
        recommendations.reduce(Int64(0)) { $0 + $1.app.size }
    }
}
