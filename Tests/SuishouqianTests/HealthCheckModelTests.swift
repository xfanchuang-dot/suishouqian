import XCTest
@testable import 随手迁

/// HealthCheckModel（v2.15.0 拆分）：装载引擎产出 + 即时重算
@MainActor
final class HealthCheckModelTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        // v3.0 起模型装载时会算健康分并落历史——历史文件必须重定向，别污染真实目录
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-model-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        HealthHistory.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        HealthHistory.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 与 CheckEngineTests 同款假检查器
    private final class MockChecker: Checking, @unchecked Sendable {
        func healBrokenLinks() -> [String] { ["x"] }
        func backfillManifest() {}
        func pruneStaleManifestEntries() -> [String] { [] }
        func checkLinks() -> [LinkHealth] {
            [LinkHealth(appName: "Broken.app", linkPath: "/a", target: "/b", state: .broken)]
        }
        func checkBackups(drivePath: String) -> [BackupIssue] {
            [BackupIssue(appName: "b.app", path: "/p", sizeBytes: 9, ageDays: 9, isOrphan: true)]
        }
        func checkRegressions(drivePath: String) -> [RegressionItem] { [] }
        func checkResidues(drivePath: String?) -> [ResidueItem] { [] }
        func checkLaunchAgents() -> [LaunchAgentIssue] { [] }
        func scanBigFiles(minBytes: Int64, limit: Int) -> [BigFileItem] { [] }
        func checkDiskHealth() -> [DiskHealthIssue] { [] }
        func checkLostVolumes() -> [LostVolumeInfo] { [] }
    }

    func testRefreshLoadsEngineReportAndClearsCheckingFlag() async {
        let model = HealthCheckModel()
        let engine = CheckEngine(checker: MockChecker(), tracker: LaunchUsageTracker())

        await model.refresh(engine: engine, drivePath: "/Volumes/X", apps: [])

        XCTAssertEqual(model.links.count, 1)
        XCTAssertEqual(model.links.first?.state, .broken)
        XCTAssertEqual(model.backups.count, 1)
        XCTAssertTrue(model.backups[0].isOrphan)
        XCTAssertFalse(model.isChecking, "装载完成后必须复位检查中标志")
        XCTAssertEqual(model.healedCount, 1, "Mock 自愈返回 1 条，应如实装载")
    }

    /// v3.0 健康分：装载完成即出分（Mock 有 1 条断链 → 85 分），并落当天历史
    func testRefreshComputesHealthScoreAndHistory() async throws {
        let model = HealthCheckModel()
        let engine = CheckEngine(checker: MockChecker(), tracker: LaunchUsageTracker())

        // 用真实可取 UUID 的根卷（/Volumes/X 不是挂载点，volumeUUID 会是 nil → 不落历史）
        await model.refresh(engine: engine, drivePath: "/", apps: [])

        let score = try XCTUnwrap(model.healthScore)
        XCTAssertEqual(score.score, 83, "1 条断链扣 15 + 1 条备份孤儿扣 2")
        XCTAssertEqual(score.deductions.first?.reason, "1 条修不好的断链")

        let records = HealthHistory.loadAll()
        XCTAssertEqual(records.count, 1, "当天一条历史")
        XCTAssertEqual(records.first?.volumeUUID,
                       MigrationManifest.volumeUUID(atPath: "/")?.uppercased())
    }

    func testRemoveUnusedRemovesOnlyMatchedPath() {
        let model = HealthCheckModel()
        var item = AppItem(name: "A", bundleName: "A.app", path: "/Volumes/Ext/A.app",
                           version: nil, size: 1, isSymlink: false,
                           symlinkTarget: nil, icon: nil)
        item.status = .externalOnly
        item.bundleID = "com.t.a"
        model.unusedApps = [UnusedAppInfo(app: item, lastUsed: Date())]

        model.removeUnused(appPath: "/其他/不相干")
        XCTAssertEqual(model.unusedApps.count, 1)
        model.removeUnused(appPath: "/Volumes/Ext/A.app")
        XCTAssertTrue(model.unusedApps.isEmpty)
    }
}
