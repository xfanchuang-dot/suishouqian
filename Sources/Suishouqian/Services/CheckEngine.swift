import Foundation

/// 一轮检查的完整结果（体检页 / 总览页共用同一份定义）
struct CheckReport {
    var links: [LinkHealth] = []
    var backups: [BackupIssue] = []
    var regressions: [RegressionItem] = []
    var residues: [ResidueItem] = []
    var bigFiles: [BigFileItem] = []
    var launchAgents: [LaunchAgentIssue] = []
    var spotlightIndexing: Bool?
    var unusedApps: [UnusedAppInfo] = []
    var usageSuggestions: [UsageSuggestion] = []
    var healedCount = 0
}

/// 检查能力抽象：生产实现是 HealthChecker，测试可注入 Mock 验证编排本身。
/// 只收"只读检查/自愈"；带副作用的动作（清理、修复、回迁）不进这里。
protocol Checking: Sendable {
    func healBrokenLinks() -> [String]
    func backfillManifest()
    func pruneStaleManifestEntries() -> [String]
    func checkLinks() -> [LinkHealth]
    func checkBackups(drivePath: String) -> [BackupIssue]
    func checkRegressions(drivePath: String) -> [RegressionItem]
    func checkResidues(drivePath: String?) -> [ResidueItem]
    func checkLaunchAgents() -> [LaunchAgentIssue]
    func scanBigFiles(minBytes: Int64, limit: Int) -> [BigFileItem]
}

extension HealthChecker: Checking {}

/// 检查引擎（v2.14.0）：体检页与总览页共同的"跑一遍检查"编排，
/// 之前两页各手写一份，已经出现项数漂移；现在只有这一份。
///
/// 并行结构（v2.14.0）：唯一顺序依赖是「自愈 → 查链接」（自愈可能修好链接），
/// 其余检查项互相独立，用 async let 结构化并行——整体耗时从"各项之和"
/// 降到"最慢一项"。每项内部仍是 OffPool 跑子进程（铁律不变）。
final class CheckEngine: @unchecked Sendable {

    struct Scope {
        let bigFiles: Bool
        let regressions: Bool

        /// 体检页：全量
        static let full = Scope(bigFiles: true, regressions: true)
        /// 总览页：不要大文件（最慢）与回归明细，只留结论项
        static let overview = Scope(bigFiles: false, regressions: false)
    }

    private let checker: any Checking
    private let tracker: LaunchUsageTracker

    init(checker: any Checking = HealthChecker(), tracker: LaunchUsageTracker = .shared) {
        self.checker = checker
        self.tracker = tracker
    }

    func run(drivePath: String?, apps: [AppItem], scope: Scope = .full) async -> CheckReport {
        var report = CheckReport()

        // ── 顺序段：自愈 → 补台账 → 查链接（后续检查要在修完之后看）──
        let healed = await OffPool.run { [checker] in checker.healBrokenLinks() }
        report.healedCount = healed.count
        await OffPool.run { [checker] in checker.backfillManifest() }
        await OffPool.run { [checker] in checker.pruneStaleManifestEntries() }
        report.links = await OffPool.run { [checker] in checker.checkLinks() }

        // ── 并行段：互相独立的慢检查项 ──
        func offMain<T>(_ work: @escaping @Sendable () -> T) async -> T {
            await OffPool.run(work)
        }

        async let backups: [BackupIssue] = offMain { [checker] in
            drivePath.map { checker.checkBackups(drivePath: $0) } ?? []
        }
        async let regressions: [RegressionItem] = offMain { [checker] in
            (scope.regressions ? drivePath.map { checker.checkRegressions(drivePath: $0) } : nil) ?? []
        }
        async let residues: [ResidueItem] = offMain { [checker] in
            checker.checkResidues(drivePath: drivePath)
        }
        async let launchAgents: [LaunchAgentIssue] = offMain { [checker] in
            checker.checkLaunchAgents()
        }
        async let unusedApps: [UnusedAppInfo] = offMain {
            UnusedAppsCheck.scanSync(apps: apps)
        }
        async let bigFiles: [BigFileItem] = offMain { [checker] in
            scope.bigFiles ? checker.scanBigFiles(minBytes: 500 * 1_048_576, limit: 20) : []
        }
        async let spotlight: Bool? = offMain {
            drivePath.flatMap { SpotlightCheck.status(for: $0) }
        }

        report.backups = await backups
        report.regressions = await regressions
        report.residues = await residues
        report.launchAgents = await launchAgents
        report.unusedApps = await unusedApps
        report.bigFiles = await bigFiles
        report.spotlightIndexing = await spotlight

        // 使用频率建议是纯内存计数（要过 NSImage，不走 OffPool 边界），主线程算即可
        report.usageSuggestions = LaunchUsageTracker.suggestions(
            apps: apps, entries: tracker.entries)
        return report
    }
}
