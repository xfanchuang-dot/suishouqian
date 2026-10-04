import XCTest
@testable import 随手迁

/// ProgressThrottle：进度节流纯逻辑（假时钟，决策完全确定）。
/// 这是"看不见的优化"的可证明形式——节流确实在丢事件、收尾确实放行。
final class ProgressThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func assertPublishes(_ result: (progress: Double, file: String)?,
                                 _ pct: Double, _ expectedFile: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(result, "应发布", file: file, line: line)
        XCTAssertEqual(result?.progress, pct, file: file, line: line)
        XCTAssertEqual(result?.file, expectedFile, file: file, line: line)
    }

    func testFirstCallAlwaysPublishes() {
        var throttle = ProgressThrottle()
        assertPublishes(throttle.filtered(
            pct: 0.1, file: "a", currentProgress: 0, currentFile: "", now: t0), 0.1, "a")
    }

    /// 有变化但时间窗未到（100ms < 250ms）→ 丢
    func testRapidChangeInsideWindowDropped() {
        var throttle = ProgressThrottle()
        _ = throttle.filtered(pct: 0.10, file: "a", currentProgress: 0, currentFile: "", now: t0)
        XCTAssertNil(throttle.filtered(
            pct: 0.11, file: "a", currentProgress: 0.10, currentFile: "a",
            now: t0.addingTimeInterval(0.1)))
    }

    /// 时间窗到了但变化太小（0.3% < 0.5%）→ 丢
    func testTinyChangeAfterWindowDropped() {
        var throttle = ProgressThrottle()
        _ = throttle.filtered(pct: 0.10, file: "a", currentProgress: 0, currentFile: "", now: t0)
        XCTAssertNil(throttle.filtered(
            pct: 0.103, file: "a", currentProgress: 0.10, currentFile: "a",
            now: t0.addingTimeInterval(0.5)))
    }

    /// 窗外 + 有变化 → 正常发布
    func testChangeAfterWindowPublishes() {
        var throttle = ProgressThrottle()
        _ = throttle.filtered(pct: 0.10, file: "a", currentProgress: 0, currentFile: "", now: t0)
        assertPublishes(throttle.filtered(
            pct: 0.50, file: "a", currentProgress: 0.10, currentFile: "a",
            now: t0.addingTimeInterval(0.3)), 0.50, "a")
    }

    /// 收尾直通：progress(1.0) 即使落在时间窗内也必须放行，
    /// 否则进度条冻在 9x% 就直接跳"已完成"
    func testFinalFlushesInsideWindow() {
        var throttle = ProgressThrottle()
        _ = throttle.filtered(pct: 0.10, file: "a", currentProgress: 0, currentFile: "", now: t0)
        assertPublishes(throttle.filtered(
            pct: 1.0, file: "完成", currentProgress: 0.10, currentFile: "a",
            now: t0.addingTimeInterval(0.05)), 1.0, "完成")
    }

    /// 文件名变化也算"有变化"（阶段切换的文案要及时跟上）
    func testFileChangeAfterWindowPublishes() {
        var throttle = ProgressThrottle()
        _ = throttle.filtered(pct: 0.10, file: "复制", currentProgress: 0, currentFile: "", now: t0)
        assertPublishes(throttle.filtered(
            pct: 0.10, file: "校验", currentProgress: 0.10, currentFile: "复制",
            now: t0.addingTimeInterval(0.3)), 0.10, "校验")
    }
}
