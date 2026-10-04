import XCTest
@testable import 随手迁

/// 检查引擎（v2.14.0）：编排顺序、范围裁剪与字段映射。
/// 注入 MockChecker——引擎的可测性正是这次重构的目的之一。
final class CheckEngineTests: XCTestCase {

    /// 记录调用顺序、返回罐头结果的假检查器
    /// （调用序列有锁保护，但编译器验证不了，按惯例 @unchecked）
    private final class MockChecker: Checking, @unchecked Sendable {
        let lock = NSLock()
        private(set) var calls: [String] = []
        var brokenLinkCount = 0
        var backupCount = 0
        var regressionCount = 0

        private func record(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            calls.append(name)
        }

        func healBrokenLinks() -> [String] {
            record("heal")
            return ["已修复"]
        }

        func backfillManifest() {
            record("backfill")
        }

        func pruneStaleManifestEntries() -> [String] {
            record("prune")
            return []
        }

        func checkLinks() -> [LinkHealth] {
            record("links")
            return (0..<brokenLinkCount).map { _ in
                LinkHealth(appName: "x", linkPath: "/a", target: "/b", state: .broken)
            }
        }

        func checkBackups(drivePath: String) -> [BackupIssue] {
            record("backups")
            return (0..<backupCount).map { _ in
                BackupIssue(appName: "b", path: "/p", sizeBytes: 1, ageDays: 9, isOrphan: false)
            }
        }

        func checkRegressions(drivePath: String) -> [RegressionItem] {
            record("regressions")
            return (0..<regressionCount).map { _ in
                RegressionItem(appName: "r", appPath: "/p", externalPath: "/e", sizeBytes: 1)
            }
        }

        func checkResidues(drivePath: String?) -> [ResidueItem] {
            record("residues")
            return [ResidueItem(name: "res", path: "/p", sizeBytes: 1, location: "Caches")]
        }

        func checkLaunchAgents() -> [LaunchAgentIssue] {
            record("launchAgents")
            return []
        }

        func scanBigFiles(minBytes: Int64, limit: Int) -> [BigFileItem] {
            record("bigFiles")
            return [BigFileItem(name: "big", path: "/p/big", sizeBytes: 1)]
        }

        func checkDiskHealth() -> [DiskHealthIssue] {
            record("diskHealth")
            return []
        }

        func checkLostVolumes() -> [LostVolumeInfo] {
            record("lostVolumes")
            return []
        }
    }

    private func makeEngine(_ mock: MockChecker) -> CheckEngine {
        CheckEngine(checker: mock, tracker: LaunchUsageTracker())
    }

    func testHealRunsBeforeLinkCheck() async {
        let mock = MockChecker()
        _ = await makeEngine(mock).run(drivePath: nil, apps: [])
        let order = mock.calls
        if let healIdx = order.firstIndex(of: "heal"),
           let linksIdx = order.firstIndex(of: "links") {
            XCTAssertLessThan(healIdx, linksIdx, "自愈必须先于查链接")
        } else {
            XCTFail("自愈与查链接都应被调用：\(order)")
        }
    }

    func testFullScopeRunsBigFilesAndRegressions() async {
        let mock = MockChecker()
        _ = await makeEngine(mock).run(drivePath: "/Volumes/X", apps: [], scope: .full)
        XCTAssertTrue(mock.calls.contains("bigFiles"))
        XCTAssertTrue(mock.calls.contains("regressions"))
    }

    func testOverviewScopeSkipsSlowItems() async {
        let mock = MockChecker()
        _ = await makeEngine(mock).run(drivePath: "/Volumes/X", apps: [], scope: .overview)
        XCTAssertFalse(mock.calls.contains("bigFiles"), "总览不跑大文件扫描（最慢项）")
        XCTAssertFalse(mock.calls.contains("regressions"), "总览不跑回归明细")
    }

    func testNilDrivePathLeavesDriveBoundFieldsEmpty() async {
        let mock = MockChecker()
        mock.backupCount = 3
        mock.regressionCount = 2
        let report = await makeEngine(mock).run(drivePath: nil, apps: [])
        XCTAssertTrue(report.backups.isEmpty, "没有外置盘就不该有备份审计结果")
        XCTAssertTrue(report.regressions.isEmpty)
        XCTAssertNil(report.spotlightIndexing)
    }

    func testReportMapsCannedResultsAndHealCount() async {
        let mock = MockChecker()
        mock.brokenLinkCount = 2
        mock.backupCount = 1
        let report = await makeEngine(mock).run(drivePath: "/Volumes/X", apps: [], scope: .full)
        XCTAssertEqual(report.links.count, 2)
        XCTAssertEqual(report.backups.count, 1)
        XCTAssertEqual(report.healedCount, 1)
        XCTAssertFalse(report.residues.isEmpty)
    }
}
