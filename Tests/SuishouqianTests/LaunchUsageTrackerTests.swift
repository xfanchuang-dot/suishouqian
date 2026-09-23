import XCTest
@testable import 随手迁

/// 使用频率顾问单元测试：启动记录、窗口统计与"建议搬回"判定（v2.9.0）
final class LaunchUsageTrackerTests: XCTestCase {

    private var tempDir: URL!
    private let now = Date()

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-usage-tests-\(UUID().uuidString)", isDirectory: true)
        LaunchUsageTracker.directoryOverride = tempDir
        LaunchUsageTracker.shared.reload()
    }

    override func tearDownWithError() throws {
        LaunchUsageTracker.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func daysAgo(_ n: Double) -> Date {
        Date(timeIntervalSinceNow: -n * 86400)
    }

    private func app(name: String, bundleID: String?,
                     external: Bool, externalOnly: Bool = false) -> AppItem {
        var item = AppItem(
            name: name, bundleName: "\(name).app",
            path: external ? "/Volumes/Ext/\(name).app" : "/Applications/\(name).app",
            version: nil, size: 100, isSymlink: external && !externalOnly,
            symlinkTarget: external && !externalOnly ? "/Volumes/Ext/\(name).app" : nil,
            icon: nil)
        if externalOnly { item.status = .externalOnly }
        item.bundleID = bundleID
        return item
    }

    func testRecordAndCountWithinWindow() {
        let t = LaunchUsageTracker.shared
        t.record(bundleID: "com.t.a", name: "A", at: now)
        t.record(bundleID: "com.t.a", name: "A", at: daysAgo(1))
        t.record(bundleID: "com.t.a", name: "A", at: daysAgo(6))

        XCTAssertEqual(t.recentLaunchCount(bundleID: "com.t.a", days: 7, now: now), 3)
        XCTAssertEqual(t.recentLaunchCount(bundleID: "com.t.b", days: 7, now: now), 0)
    }

    func testCountIgnoresTimestampsBeyondWindow() {
        let t = LaunchUsageTracker.shared
        t.record(bundleID: "com.t.a", name: "A", at: daysAgo(8))
        t.record(bundleID: "com.t.a", name: "A", at: daysAgo(6))

        XCTAssertEqual(t.recentLaunchCount(bundleID: "com.t.a", days: 7, now: now), 1)
    }

    func testRetentionPruneDropsStaleEntries() {
        let t = LaunchUsageTracker.shared
        t.record(bundleID: "com.t.old", name: "Old", at: daysAgo(31))
        t.prune(now: now)

        XCTAssertEqual(t.recentLaunchCount(bundleID: "com.t.old", days: 30, now: now), 0)
    }

    func testStorePersistsAcrossReload() {
        let t = LaunchUsageTracker.shared
        t.record(bundleID: "com.t.a", name: "A", at: now)
        t.record(bundleID: "com.t.a", name: "A", at: daysAgo(1))
        t.reload()

        XCTAssertEqual(t.recentLaunchCount(bundleID: "com.t.a", days: 7, now: now), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: t.storeURL.path))
    }

    func testSuggestionsFilterExternalAndThreshold() {
        // 原住民（外置盘、无链接）3 次 → 建议
        let native = app(name: "Native", bundleID: "com.t.native",
                         external: true, externalOnly: true)
        // 链接迁移态 5 次 → 建议且排在前
        let linked = app(name: "Linked", bundleID: "com.t.linked", external: true)
        // 内置盘应用启动再多也不建议
        let local = app(name: "Local", bundleID: "com.t.local", external: false)
        // 外置盘但没有 bundleID → 无法关联，宁缺毋滥
        let noBid = app(name: "NoBid", bundleID: nil, external: true, externalOnly: true)
        // 外置盘但只有 2 次 → 未达阈值
        let quiet = app(name: "Quiet", bundleID: "com.t.quiet",
                        external: true, externalOnly: true)

        var entries: [LaunchUsageEntry] = []
        for id in ["com.t.native", "com.t.linked", "com.t.local"] {
            let n = id == "com.t.linked" ? 5 : (id == "com.t.local" ? 9 : 3)
            entries.append(LaunchUsageEntry(bundleID: id, name: id,
                                            timestamps: (0..<n).map { daysAgo(Double($0)).timeIntervalSince1970 }))
        }
        entries.append(LaunchUsageEntry(bundleID: "com.t.quiet", name: "q",
                                        timestamps: [daysAgo(1).timeIntervalSince1970,
                                                     daysAgo(2).timeIntervalSince1970]))

        let apps = [native, linked, local, noBid, quiet]
        let sug = LaunchUsageTracker.suggestions(apps: apps, entries: entries,
                                                 days: 7, threshold: 3, now: now)

        XCTAssertEqual(sug.map(\.app.name), ["Linked", "Native"])
        XCTAssertEqual(sug.first?.count, 5)
        // 5 次的排在前（按次数降序）
        XCTAssertGreaterThan(sug[0].count, sug[1].count)
    }

    func testThresholdBoundaryExactlyThreeSuggests() {
        let native = app(name: "Edge", bundleID: "com.t.edge",
                         external: true, externalOnly: true)
        let entries = [LaunchUsageEntry(bundleID: "com.t.edge", name: "Edge",
                                        timestamps: [daysAgo(1), daysAgo(2), daysAgo(3)]
                                            .map { $0.timeIntervalSince1970 })]
        let sug = LaunchUsageTracker.suggestions(apps: [native], entries: entries,
                                                 days: 7, threshold: 3, now: now)
        XCTAssertEqual(sug.count, 1)
        XCTAssertEqual(sug.first?.count, 3)
    }

    func testEmptyBundleIDRecordIsIgnored() {
        let t = LaunchUsageTracker.shared
        t.record(bundleID: "", name: "Broken", at: now)
        XCTAssertTrue(t.entries.isEmpty)
    }
}
