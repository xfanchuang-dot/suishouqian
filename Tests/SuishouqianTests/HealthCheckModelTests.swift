import XCTest
@testable import 随手迁

/// HealthCheckModel（v2.15.0 拆分）：装载引擎产出 + 即时重算
@MainActor
final class HealthCheckModelTests: XCTestCase {

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
