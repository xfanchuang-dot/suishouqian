import XCTest
@testable import 随手迁

/// TM 协作：解析逻辑纯测试。子进程路径（isexcluded 实跑）不在单测覆盖内——
/// 那属于真机 checklist（方案第八章步骤 7）。
final class TimeMachineCoordinatorTests: XCTestCase {

    func testManagedDirsCoverAllManagedLocations() {
        let dirs = TimeMachineCoordinator.managedDirs(on: "/Volumes/X")
        XCTAssertEqual(dirs, [
            "/Volumes/X/Applications",
            "/Volumes/X/SuishouqianData",
            "/Volumes/X/.suishouqian-backup",
        ])
    }

    func testParseExcludedOutput() {
        XCTAssertTrue(TimeMachineCoordinator.parseExcluded(
            "[Excluded]\t/Volumes/X/Applications\n"))
        XCTAssertFalse(TimeMachineCoordinator.parseExcluded(
            "[Not Excluded]\t/Volumes/X/Applications\n"))
        XCTAssertFalse(TimeMachineCoordinator.parseExcluded(""))
        // 防御：输出异常时宁可当作"未排除"（提示用户可省空间，无害）
        XCTAssertFalse(TimeMachineCoordinator.parseExcluded("[???]\t/Volumes/X\n"))
    }
}
