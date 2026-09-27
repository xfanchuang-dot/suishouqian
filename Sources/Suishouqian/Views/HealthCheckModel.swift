import SwiftUI

/// 体检页的检查结果装载层（v2.15.0 从 814 行上帝视图拆出）。
///
/// 只负责「吃引擎产出 → 装载发布字段」这一层，让体检页的检查结果
/// 可以脱离视图做断言（注入 MockChecker 的引擎即可测）。
/// 带副作用的动作（清理/修复/搬回/Spotlight 开关）仍属视图层，
/// 它们直接操作用户界面确认流，不适合无头测试。
@MainActor
final class HealthCheckModel: ObservableObject {
    @Published var links: [LinkHealth] = []
    @Published var backups: [BackupIssue] = []
    @Published var residues: [ResidueItem] = []
    @Published var bigFiles: [BigFileItem] = []
    @Published var regressions: [RegressionItem] = []
    @Published var usageSuggestions: [UsageSuggestion] = []
    @Published var launchAgents: [LaunchAgentIssue] = []
    @Published var spotlightIndexing: Bool?
    @Published var unusedApps: [UnusedAppInfo] = []
    @Published var healedCount = 0
    @Published var isChecking = false
    /// 健康分（v3.0）：装载体检结果时顺带出分，纯只读派生
    @Published var healthScore: HealthScore.Result?

    /// 跑一轮全量检查并装载结果。引擎内部处理 OffPool 与并行，这里只等。
    func refresh(engine: CheckEngine, drivePath: String?, apps: [AppItem]) async {
        isChecking = true
        let report = await engine.run(drivePath: drivePath, apps: apps, scope: .full)
        links = report.links
        backups = report.backups
        residues = report.residues
        bigFiles = report.bigFiles
        regressions = report.regressions
        launchAgents = report.launchAgents
        spotlightIndexing = report.spotlightIndexing
        unusedApps = report.unusedApps
        usageSuggestions = report.usageSuggestions
        healedCount = report.healedCount

        // v3.0 健康分：主盘口径。有真实主盘 UUID 才落历史（score 是只读派生，
        // 绝不驱动自动动作）；drivePath 为 nil 时不落，测试注入不污染真实文件
        let score = HealthScore.score(HealthScoreInputFactory.input(from: report))
        healthScore = score
        if let drivePath {
            // resourceValues 是 IO：按铁律走 OffPool，别占主线程
            let uuid = await OffPool.run { MigrationManifest.volumeUUID(atPath: drivePath) }
            if let uuid { HealthHistory.append(volumeUUID: uuid, score: score.score) }
        }
        isChecking = false
    }

    /// 纯内存的即时重算（搬回成功后立刻摘人，不等下一轮体检）
    func computeUsage(apps: [AppItem]) {
        usageSuggestions = LaunchUsageTracker.suggestions(
            apps: apps, entries: LaunchUsageTracker.shared.entriesSnapshot)
    }

    func removeUnused(appPath: String) {
        unusedApps.removeAll { $0.app.path == appPath }
    }
}
