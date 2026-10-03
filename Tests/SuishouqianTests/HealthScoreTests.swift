import XCTest
@testable import 随手迁

/// 健康分：纯逻辑测试 + 历史存储（directoryOverride 注入）
final class HealthScoreTests: XCTestCase {

    func testPerfectInputScores100() {
        let result = HealthScore.score(.init())
        XCTAssertEqual(result.score, 100)
        XCTAssertTrue(result.deductions.isEmpty)
        XCTAssertEqual(result.grade, "很健康")
        XCTAssertNil(result.topAction)
    }

    func testBrokenLinksDeduct15EachWithCap45() {
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 1)).score, 85)
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 2)).score, 70)
        // 4 条 ×15 = 60 > 上限 45 → 只扣 45
        let capped = HealthScore.score(.init(brokenLinks: 4))
        XCTAssertEqual(capped.score, 55)
        XCTAssertEqual(capped.deductions.first?.points, 45)
        // 10 条也只扣 45
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 10)).score, 55)
    }

    func testOfflineVolumePenalty() {
        let result = HealthScore.score(.init(offlineVolumesWithApps: 1))
        XCTAssertEqual(result.score, 80)
        XCTAssertTrue(result.deductions[0].reason.contains("离线"))
    }

    func testUSB2PenaltyOnlyWhenAppsLiveThere() {
        XCTAssertEqual(HealthScore.score(.init()).score, 100)
        XCTAssertEqual(HealthScore.score(.init(hasUSB2VolumeWithApps: true)).score, 95)
    }

    func testFloorIsZeroNotNegative() {
        let awful = HealthScore.score(.init(
            brokenLinks: 10, offlineVolumesWithApps: 3, regressions: 10,
            dataForks: 10, backupIssues: 100, residues: 100,
            hasUSB2VolumeWithApps: true))
        XCTAssertEqual(awful.score, 0)
        XCTAssertEqual(awful.grade, "建议处理")
    }

    func testGrades() {
        // 分档：90+很健康 / 70-89 良好 / 50-69 需要关注 / <50 建议处理
        XCTAssertEqual(HealthScore.score(.init()).grade, "很健康")                 // 100
        XCTAssertEqual(HealthScore.score(.init(residues: 5)).grade, "很健康")      // 95
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 1)).grade, "良好")     // 85
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 2)).grade, "良好")     // 70
        XCTAssertEqual(HealthScore.score(.init(brokenLinks: 3)).grade, "需要关注")  // 55
        // 45(断链封顶) + 20(离线) + 5(USB2) = 70 → 30 分
        XCTAssertEqual(HealthScore.score(.init(
            brokenLinks: 4, offlineVolumesWithApps: 1,
            hasUSB2VolumeWithApps: true)).grade, "建议处理")
    }

    func testTopActionNamesBiggestDeduction() {
        let result = HealthScore.score(.init(brokenLinks: 3, backupIssues: 2)) // 45 vs 4
        XCTAssertEqual(result.topAction, "先处理：3 条修不好的断链，可回 45 分")
    }
}

final class HealthHistoryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-history-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        HealthHistory.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        HealthHistory.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testAppendAndLoadRoundTrip() throws {
        HealthHistory.append(volumeUUID: "V1", score: 95, now: Date())
        HealthHistory.append(volumeUUID: "V2", score: 88, now: Date())
        let all = HealthHistory.loadAll()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.contains { $0.volumeUUID == "V1" && $0.score == 95 })
    }

    func testSameDayRecordIsOverwritten() throws {
        // 用"当天 12 点/13 点"做锚：+1 小时法在 23 点后运行会跨天，变成假失败
        let cal = Calendar.current
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        HealthHistory.append(volumeUUID: "V1", score: 80, now: now)
        HealthHistory.append(volumeUUID: "V1", score: 92, now: now.addingTimeInterval(3600))
        let all = HealthHistory.loadAll()
        XCTAssertEqual(all.count, 1, "同卷同天只保留最后一条")
        XCTAssertEqual(all.first?.score, 92)
    }

    func testPrunePureFunctionRemovesOldAndBadRecords() throws {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now)!

        func record(_ daysAgo: Int, volume: String = "V1") -> HealthHistory.Record {
            .init(date: df.string(from: now.addingTimeInterval(Double(-daysAgo) * 86_400)),
                  volumeUUID: volume, score: 90)
        }

        let kept = HealthHistory.prune(
            records: [record(91), record(90), record(89), record(1),
                      .init(date: "not-a-date", volumeUUID: "V1", score: 1)],
            before: cutoff)
        // 记录日解析为当天零点，早于 cutoff（当天此刻）→ 恰好 90 天整的也被清；
        // 89 天前、昨天保留；坏日期清掉
        XCTAssertEqual(kept.map(\.date), [record(89).date, record(1).date])
    }

    func testRecentFiltersByVolumeAndRange() throws {
        let now = Date()
        HealthHistory.append(volumeUUID: "V1", score: 90, now: now.addingTimeInterval(-10 * 86_400))
        HealthHistory.append(volumeUUID: "V2", score: 80, now: now.addingTimeInterval(-5 * 86_400))
        HealthHistory.append(volumeUUID: "V1", score: 85, now: now.addingTimeInterval(-1 * 86_400))
        let recent = HealthHistory.recent(volumeUUID: "V1", days: 30, now: now)
        XCTAssertEqual(recent.map(\.score), [90, 85], "只取该卷、按日期升序")
    }

    func testCorruptFileTreatedAsEmpty() throws {
        try "# not json".write(to: tempDir.appendingPathComponent("health-history.json"),
                               atomically: true, encoding: .utf8)
        XCTAssertTrue(HealthHistory.loadAll().isEmpty, "坏文件按空处理，不抛错")
    }
}
