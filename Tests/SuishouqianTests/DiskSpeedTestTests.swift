import XCTest
@testable import 随手迁

/// 磁盘实测速度（v2.12.0）：dd 统计行解析
final class DiskSpeedTestTests: XCTestCase {

    func testParseSpeedFromRealDdOutput() {
        let line = """
        536870912 bytes transferred in 0.612834 secs (876046225 bytes/sec)
        """
        XCTAssertEqual(DiskSpeedTest.parseSpeed(line), 876_046_225.0)
    }

    func testParseSpeedTakesLastOccurrence() {
        let two = "16 bytes transferred in 0.1 secs (160 bytes/sec)\n1024 bytes transferred in 0.2 secs (5120 bytes/sec)"
        XCTAssertEqual(DiskSpeedTest.parseSpeed(two), 5120.0)
    }

    func testParseSpeedRejectsGarbage() {
        XCTAssertNil(DiskSpeedTest.parseSpeed("dd: /Volumes/X: Permission denied"))
        XCTAssertNil(DiskSpeedTest.parseSpeed(""))
        XCTAssertNil(DiskSpeedTest.parseSpeed("876046225 bytes/sec"))   // 缺括号
    }

    func testDecimalSpeedParses() {
        // 部分 dd 平台输出小数速率
        XCTAssertEqual(DiskSpeedTest.parseSpeed("100 bytes transferred in 0.1 secs (1000.5 bytes/sec)"),
                       1000.5)
    }
}
