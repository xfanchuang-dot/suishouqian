import Foundation

/// 一键腾空间：迁移方案推荐引擎（v3.0 能力二）。
/// 纯计算、零副作用：输出方案，执行前调用方仍须逐应用重跑安全预检
/// （推荐与执行之间盘可能被拔、应用可能被打开——TOCTOU，用执行时复检兜底）。
enum MigrationPlanner {

    struct AppCandidate {
        let name: String
        let bundleName: String
        let size: Int64
        let mechanism: UpdateMechanism
        /// 近 7 天启动次数（LaunchUsageTracker）
        let launchesLast7Days: Int
        let isRunning: Bool
        let isSystemApp: Bool
        let alreadyExternal: Bool
    }

    struct VolumeCandidate {
        let uuid: String
        let name: String
        var freeBytes: Int64
        let tier: LinkTier
        let measuredMBps: Double?
    }

    struct PlanRequest {
        var apps: [AppCandidate]
        var volumes: [VolumeCandidate]
        /// 目标：希望腾出多少字节（UI 层换算，如"腾到剩余 40GB"→差值）
        var targetFreeBytes: Int64
        /// 激进模式：更新方式 unknown 的应用也纳入候选（默认保守不纳）
        var aggressive: Bool = false
        var now: Date = Date()
    }

    struct PlannedMove {
        let app: AppCandidate
        let volumeUUID: String
        let volumeName: String
        /// 人话理由（UI 直接展示）
        let reason: String
        let score: Double
    }

    struct ExcludedApp {
        let app: AppCandidate
        let reason: String
    }

    struct MigrationPlan {
        var moves: [PlannedMove]
        var excluded: [ExcludedApp]
        var totalFreedBytes: Int64
        /// 粗估总耗时（秒）：按有效盘速 ×2.5（复制+留底备份+校验读），仅用于设预期
        var estimatedSeconds: Double
        var targetMet: Bool { totalFreedBytes >= targetFreeBytes }
        let targetFreeBytes: Int64
    }

    static func plan(_ request: PlanRequest) -> MigrationPlan {
        var excluded: [ExcludedApp] = []
        var scored: [(app: AppCandidate, score: Double, reason: String)] = []

        for app in request.apps {
            if let reason = exclusionReason(for: app, aggressive: request.aggressive) {
                excluded.append(ExcludedApp(app: app, reason: reason))
                continue
            }
            // 推荐时按"最快的在线卷"估体感（执行时用户可改目标盘）
            let bestTier = request.volumes.map(\.tier).min { tierRank($0) < tierRank($1) }
                ?? .unknown
            let score = valueScore(app: app, tier: bestTier, aggressive: request.aggressive)
            // P3-3：理由先占位，实际落盘卷定下来后用该卷档位重算（否则"雷电可承受"
            // 可能与实际去的慢盘不符）
            scored.append((app, score, ""))
        }

        // 贪心：按"单位风险价值"从高到低拿，直到腾够
        scored.sort { $0.score > $1.score }
        var volumes = request.volumes
        var moves: [PlannedMove] = []
        var freed: Int64 = 0
        var seconds: Double = 0

        for (app, score, _) in scored {
            if freed >= request.targetFreeBytes { break }
            // 选剩余空间最多的、装得下的卷（口径与执行侧一致：两份+5%）
            guard let idx = volumes.indices
                .filter({ volumes[$0].freeBytes >= AppMigrator.requiredTargetBytes(appSize: app.size) })
                .max(by: { volumes[$0].freeBytes < volumes[$1].freeBytes })
            else {
                excluded.append(ExcludedApp(
                    app: app, reason: "外置盘剩余空间不足以容纳（含留底备份的两份空间）"))
                continue
            }
            let need = AppMigrator.requiredTargetBytes(appSize: app.size)
            volumes[idx].freeBytes -= need
            freed += app.size
            let mbps = volumes[idx].measuredMBps ?? volumes[idx].tier.conservativeMBps
            seconds += Double(app.size) / (mbps * 1_048_576) * 2.5
            moves.append(PlannedMove(
                app: app, volumeUUID: volumes[idx].uuid, volumeName: volumes[idx].name,
                reason: moveReason(app: app, tier: volumes[idx].tier), score: score))
        }

        return MigrationPlan(moves: moves, excluded: excluded,
                             totalFreedBytes: freed, estimatedSeconds: seconds,
                             targetFreeBytes: request.targetFreeBytes)
    }

    // MARK: - 纯逻辑（供测试）

    /// 不纳入方案的人话原因；nil = 可候选
    static func exclusionReason(for app: AppCandidate, aggressive: Bool) -> String? {
        if app.isSystemApp { return "系统应用，不参与迁移" }
        if app.alreadyExternal { return "已在外置盘，无需再搬" }
        if app.isRunning { return "正在运行，先退出后再安排" }
        if app.size < 100 * 1_048_576 { return "不足 100MB，搬了也腾不出多少" }
        if app.mechanism == .unknown, !aggressive {
            return "更新方式未知（保守模式跳过，可在设置里开激进模式）"
        }
        return nil
    }

    /// 搬迁价值分 = 体积得分 × 风险系数 × 体感系数
    /// 体积得分用对数：大应用优先，但防巨无霸垄断整个方案。
    static func valueScore(app: AppCandidate, tier: LinkTier, aggressive: Bool) -> Double {
        let sizeMB = max(Double(app.size) / 1_048_576, 1)
        let volumeScore = log10(sizeMB)
        let riskFactor: Double = {
            switch app.mechanism {
            case .appStore: return 1.0                        // 纯搬迁实测更新无忧
            case .squirrel, .sparkle: return 0.85             // 更新写回有极小概率被 TCC 拒
            case .unknown: return aggressive ? 0.8 : 0.5
            }
        }()
        let feelFactor: Double = {
            guard app.launchesLast7Days >= LaunchUsageTracker.suggestThreshold else { return 1.0 }
            // 高频应用：慢链路重罚，快链路轻罚
            switch tier {
            case .usb2, .unknown: return 0.3
            case .usb3: return 0.7
            case .thunderbolt: return 0.9
            }
        }()
        return volumeScore * riskFactor * feelFactor
    }

    static func moveReason(app: AppCandidate, tier: LinkTier) -> String {
        let size = ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file)
        var parts = [size]
        if app.launchesLast7Days < LaunchUsageTracker.suggestThreshold {
            parts.append("近 7 天只用了 \(app.launchesLast7Days) 次")
        } else {
            parts.append("近 7 天用了 \(app.launchesLast7Days) 次（\(tier.label)链路可承受）")
        }
        switch app.mechanism {
        case .appStore: parts.append("App Store 应用，纯搬迁无忧")
        case .squirrel, .sparkle: parts.append("自带更新器，就地更新")
        case .unknown: parts.append("更新方式未知，搬后留意第一次更新")
        }
        return parts.joined(separator: " · ")
    }

    private static func tierRank(_ t: LinkTier) -> Int {
        switch t {
        case .thunderbolt: return 0
        case .usb3: return 1
        case .usb2: return 2
        case .unknown: return 3
        }
    }
}
