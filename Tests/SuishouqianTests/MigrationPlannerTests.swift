import XCTest
@testable import 随手迁

/// 一键腾空间推荐引擎：纯逻辑测试，不碰文件系统
/// （requiredTargetBytes 是纯算术：两份 + 5%）
final class MigrationPlannerTests: XCTestCase {

    private func app(name: String, size: Int64, mechanism: UpdateMechanism = .appStore,
                     launches: Int = 0, running: Bool = false,
                     system: Bool = false, external: Bool = false) -> MigrationPlanner.AppCandidate {
        MigrationPlanner.AppCandidate(name: name, bundleName: name, size: size,
                                      mechanism: mechanism, launchesLast7Days: launches,
                                      isRunning: running, isSystemApp: system,
                                      alreadyExternal: external)
    }

    private func volume(uuid: String, free: Int64,
                        tier: LinkTier = .usb3) -> MigrationPlanner.VolumeCandidate {
        MigrationPlanner.VolumeCandidate(uuid: uuid, name: uuid, freeBytes: free,
                                         tier: tier, measuredMBps: nil)
    }

    private let gb: Int64 = 1_073_741_824

    // MARK: - 排除规则

    func testExclusionRules() {
        XCTAssertEqual(MigrationPlanner.exclusionReason(
            for: app(name: "Sys", size: 2 * gb, system: true), aggressive: false),
            "系统应用，不参与迁移")
        XCTAssertEqual(MigrationPlanner.exclusionReason(
            for: app(name: "Ext", size: 2 * gb, external: true), aggressive: false),
            "已在外置盘，无需再搬")
        XCTAssertEqual(MigrationPlanner.exclusionReason(
            for: app(name: "Run", size: 2 * gb, running: true), aggressive: false),
            "正在运行，先退出后再安排")
        XCTAssertEqual(MigrationPlanner.exclusionReason(
            for: app(name: "Tiny", size: 50 * 1_048_576), aggressive: false),
            "不足 100MB，搬了也腾不出多少")
        XCTAssertNotNil(MigrationPlanner.exclusionReason(
            for: app(name: "Unk", size: 2 * gb, mechanism: .unknown), aggressive: false),
            "保守模式下 unknown 更新方式要被排除")
        XCTAssertNil(MigrationPlanner.exclusionReason(
            for: app(name: "Unk", size: 2 * gb, mechanism: .unknown), aggressive: true),
            "激进模式下 unknown 纳入候选")
        XCTAssertNil(MigrationPlanner.exclusionReason(
            for: app(name: "OK", size: 2 * gb), aggressive: false))
    }

    // MARK: - 评分

    func testAppStoreScoresHigherThanUnknownInConservativeMode() {
        let good = app(name: "MAS", size: 2 * gb, mechanism: .appStore)
        let unk = app(name: "Unk", size: 2 * gb, mechanism: .unknown)
        let tier = LinkTier.usb3
        XCTAssertGreaterThan(
            MigrationPlanner.valueScore(app: good, tier: tier, aggressive: false),
            MigrationPlanner.valueScore(app: unk, tier: tier, aggressive: false))
    }

    func testFrequentlyUsedAppOnSlowLinkIsPenalized() {
        let highFreq = app(name: "Hot", size: 2 * gb, launches: 5)
        let lowFreq = app(name: "Cold", size: 2 * gb, launches: 0)
        XCTAssertLessThan(
            MigrationPlanner.valueScore(app: highFreq, tier: .usb2, aggressive: false),
            MigrationPlanner.valueScore(app: lowFreq, tier: .usb2, aggressive: false),
            "高频应用去慢链路要被重罚")
    }

    // MARK: - 方案

    func testPlanGreedyFillsTargetAndExcludesReported() {
        // 三个 App Store 应用，都够格；目标只够装两个
        let big = app(name: "Big", size: 8 * gb)
        let mid = app(name: "Mid", size: 5 * gb)
        let small = app(name: "Small", size: 1 * gb)
        let running = app(name: "Run", size: 10 * gb, running: true)
        let plan = MigrationPlanner.plan(.init(
            apps: [running, small, mid, big],
            volumes: [volume(uuid: "V1", free: 30 * gb)],
            targetFreeBytes: 13 * gb))

        XCTAssertEqual(plan.moves.count, 2, "目标 13GB，8+5 即达标，第三个不再纳入")
        XCTAssertTrue(plan.targetMet)
        // 被排除的运行中应用必须给出原因（信任感来源）
        XCTAssertTrue(plan.excluded.contains { $0.app.name == "Run" })
        XCTAssertTrue(plan.moves.allSatisfy { $0.volumeUUID == "V1" })
        XCTAssertGreaterThan(plan.estimatedSeconds, 0)
    }

    func testPlanRespectsTwoCopySpaceBudget() {
        // 30GB 盘：10GB 应用需要 21GB 预算（两份+5%），装得下；
        // 但目标再要第二个 10GB 时盘上只剩 30-21=9GB，装不下 → 排除并说明
        let a = app(name: "A", size: 10 * gb)
        let b = app(name: "B", size: 10 * gb)
        let plan = MigrationPlanner.plan(.init(
            apps: [a, b],
            volumes: [volume(uuid: "V1", free: 30 * gb)],
            targetFreeBytes: 25 * gb))
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertTrue(plan.excluded.contains {
            $0.app.name == "B" && $0.reason.contains("两份空间")
        }, "装不下时被排除的应用要有'两份空间'的人话原因")
    }

    func testPlanPrefersVolumeWithMostFreeSpace() {
        let plan = MigrationPlanner.plan(.init(
            apps: [app(name: "A", size: 2 * gb)],
            volumes: [volume(uuid: "V-SMALL", free: 10 * gb),
                      volume(uuid: "V-BIG", free: 100 * gb)],
            targetFreeBytes: 1 * gb))
        XCTAssertEqual(plan.moves.first?.volumeUUID, "V-BIG")
    }

    func testHighFrequencyAppStillPlannedButScoredLower() {
        let hot = app(name: "Hot", size: 2 * gb, launches: 10)
        let cold = app(name: "Cold", size: 2 * gb, launches: 0)
        let plan = MigrationPlanner.plan(.init(
            apps: [cold, hot],
            volumes: [volume(uuid: "V1", free: 50 * gb, tier: .usb2)],
            targetFreeBytes: 5 * gb))
        // 目标 5GB 两个都要搬（没有更好的候选），但 Cold 排前面
        XCTAssertEqual(plan.moves.first?.app.name, "Cold")
        XCTAssertEqual(plan.moves.count, 2)
    }
}
