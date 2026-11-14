import XCTest
@testable import 随手迁

/// 智能建议：只推荐"该搬的"，不碰正在用的、系统应用和小应用。
final class SmartAdviceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb: Int64 = 1_073_741_824

    private func app(_ name: String, sizeGB: Double, status: AppItem.AppStatus = .normal,
                     path: String = "/Applications/\(UUID().uuidString).app",
                     update: UpdateMechanism = .unknown) -> AppItem {
        AppItem(name: name, bundleName: "\(name).app", path: path,
                version: "1.0", bundleID: "com.test.\(name)",
                size: Int64(sizeGB * Double(gb)),
                isSymlink: status == .migrated,
                symlinkTarget: nil, icon: nil,
                status: status, updateMechanism: update)
    }

    private func daysAgo(_ days: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now)!
    }

    // MARK: - 候选过滤

    func testExcludesSystemMigratedAndSmallApps() {
        let normal = app("Big", sizeGB: 10)
        let system = app("Sys", sizeGB: 20, path: "/System/Applications/Sys.app")
        let migrated = app("Migrated", sizeGB: 30, status: .migrated)
        let small = app("Small", sizeGB: 0.3)

        let ranked = SmartAdvice.rank(apps: [normal, system, migrated, small],
                                      lastUsed: [:], now: now)

        XCTAssertEqual(ranked.map(\.app.name), ["Big"],
                       "只推荐内置盘、普通状态、非系统、≥500MB 的应用")
    }

    func testExcludesRecentlyUsedApps() {
        let warmed = app("Warmed", sizeGB: 50)
        let idle = app("Idle", sizeGB: 1)
        let lastUsed = [
            warmed.bundleID!: daysAgo(3),
            idle.bundleID!: daysAgo(90),
        ]

        let ranked = SmartAdvice.rank(apps: [warmed, idle], lastUsed: lastUsed, now: now)

        XCTAssertEqual(ranked.map(\.app.name), ["Idle"],
                       "再大也不该推荐最近 14 天还在用的应用")
    }

    // MARK: - 排序

    func testRankingUsesSizeTimesIdleFactor() {
        // A：20GB、闲置 30 天 → 20 × 1 = 20
        // B：5GB、闲置 240 天 → 5 × 8 = 40（更久没用，更优先）
        let a = app("A", sizeGB: 20)
        let b = app("B", sizeGB: 5)
        let lastUsed = [a.bundleID!: daysAgo(30), b.bundleID!: daysAgo(240)]

        let ranked = SmartAdvice.rank(apps: [a, b], lastUsed: lastUsed, now: now)

        XCTAssertEqual(ranked.map(\.app.name), ["B", "A"])
        XCTAssertEqual(ranked[0].score, 40, accuracy: 0.001)
        XCTAssertEqual(ranked[1].score, 20, accuracy: 0.001)
    }

    func testUnknownLastUsedGetsNeutralFactor() {
        let a = app("Unknown", sizeGB: 10)
        let ranked = SmartAdvice.rank(apps: [a], lastUsed: [:], now: now)
        XCTAssertEqual(ranked.first?.score ?? 0, 25, accuracy: 0.001,
                       "无使用记录时按中性因子 2.5 估算，不能当成「刚用过」也不能当成「永远没用」")
        XCTAssertNil(ranked.first?.lastUsedDays)
    }

    func testFreshnessFactorIsClamped() {
        XCTAssertEqual(SmartAdvice.score(sizeBytes: 10 * gb, lastUsedDays: 1),
                       5, accuracy: 0.001, "下限 0.5")
        XCTAssertEqual(SmartAdvice.score(sizeBytes: 10 * gb, lastUsedDays: 9999),
                       80, accuracy: 0.001, "上限 8")
    }

    // MARK: - 理由

    func testReasonsMentionIdleDaysAndAppStoreRisk() {
        let store = app("Store", sizeGB: 2, update: .appStore)
        let rec = SmartAdvice.rank(apps: [store],
                                   lastUsed: [store.bundleID!: daysAgo(75)],
                                   now: now).first!
        XCTAssertTrue(rec.reasons.contains { $0.contains("75") }, "理由要点明天数")
        XCTAssertTrue(rec.reasons.contains { $0.contains("App Store") }, "App Store 应用要提示更新风险")
    }

    func testTotalSavingsSumsAppSizes() {
        let a = app("A", sizeGB: 3)
        let b = app("B", sizeGB: 2)
        let ranked = SmartAdvice.rank(apps: [a, b], lastUsed: [:], now: now)
        XCTAssertEqual(SmartAdvice.totalSavings(ranked), 5 * gb)
    }
}
