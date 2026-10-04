import XCTest
@testable import 随手迁

/// VolumeSpeedBaseline：速度历史持久化 + 塌陷评估纯逻辑
final class SpeedBaselineTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // 独立 suite，绝不碰真实 UserDefaults
        let suiteName = "speed-baseline-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        VolumeSpeedBaseline.defaultsOverride = defaults
    }

    override func tearDownWithError() throws {
        VolumeSpeedBaseline.defaultsOverride = nil
    }

    private func sample(_ mbps: Double) -> VolumeSpeedBaseline.Sample {
        .init(at: Date(), mbps: mbps)
    }

    // MARK: - record / history

    func testRecordNormalizesUUIDCase() {
        VolumeSpeedBaseline.record(volumeUUID: "abcd", readMBps: 400)
        XCTAssertFalse(VolumeSpeedBaseline.history(volumeUUID: "ABCD").isEmpty)
    }

    func testHistoryCapsAtMaxSamples() {
        for i in 1...9 {
            VolumeSpeedBaseline.record(volumeUUID: "V1", readMBps: Double(i) * 100)
        }
        let history = VolumeSpeedBaseline.history(volumeUUID: "V1")
        XCTAssertEqual(history.count, VolumeSpeedBaseline.maxSamples)
        // 只留最新的：最后一个是 900
        XCTAssertEqual(history.last?.mbps, 900)
    }

    // MARK: - assess 纯逻辑

    func testNoAlertWithInsufficientHistory() {
        // 只有 2 次历史（不含最新不足 3 次）：不判
        let history = [sample(400), sample(400), sample(100)]
        XCTAssertNil(VolumeSpeedBaseline.assess(history: history))
    }

    func testNoAlertWhenSpeedStable() {
        let history = [sample(400), sample(420), sample(390), sample(400)]
        XCTAssertNil(VolumeSpeedBaseline.assess(history: history))
    }

    func testAlertOnCollapse() {
        // 基线 400 中位数，最新 100 = 25% < 40% → 告警
        let history = [sample(400), sample(420), sample(380), sample(100)]
        let alert = VolumeSpeedBaseline.assess(history: history)
        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.baselineMBps ?? 0, 400, accuracy: 0.01)
        XCTAssertEqual(alert?.latestMBps ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(alert?.percentOfBaseline, 25)
    }

    /// 偶数个历史取中间两数均值
    func testMedianWithEvenPriorCount() {
        // prior = [300, 400, 500, 600] → 中位数 450；最新 100 < 40%×450 → 告警
        let history = [sample(300), sample(400), sample(500), sample(600), sample(100)]
        let alert = VolumeSpeedBaseline.assess(history: history)
        XCTAssertEqual(alert?.baselineMBps ?? 0, 450, accuracy: 0.01)
    }

    /// 基线本身太慢（USB2 机械盘正常 30-40MB/s）不判塌陷——比例抖动失真
    func testNoAlertWhenBaselineTooSlow() {
        let history = [sample(35), sample(36), sample(34), sample(10)]
        XCTAssertNil(VolumeSpeedBaseline.assess(history: history))
    }

    func testEmptyHistoryNoAlert() {
        XCTAssertNil(VolumeSpeedBaseline.assess(history: []))
    }
}
