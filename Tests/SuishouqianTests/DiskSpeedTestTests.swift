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

    /// 测速前的落盘护栏：盘没挂上时 /Volumes/X 可能只是个残留目录，
    /// 此时 dd 会把 256MB 真写进内置盘，结果还被当成外置盘速度展示。
    func testSpeedTestRefusesPathsThatAreNotMountedVolumes() {
        XCTAssertFalse(DiskSpeedTest.isWritableMount(mountPoint: "/Volumes/绝对不存在的卷",
                                                     needBytes: 1),
                       "不存在的挂载点不能测速")
        XCTAssertFalse(DiskSpeedTest.isWritableMount(mountPoint: NSHomeDirectory(),
                                                     needBytes: 1),
                       "内置盘上的普通目录不是外置卷（设备名与根卷相同）")
    }
}
