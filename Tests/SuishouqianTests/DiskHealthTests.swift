import XCTest
@testable import 随手迁

/// DiskHealthProbe.parseHealth：SMART 状态解析
final class DiskHealthTests: XCTestCase {

    func testVerified() {
        XCTAssertEqual(
            DiskHealthProbe.parseHealth(devicePlist: ["SMARTStatus": "Verified"]),
            .verified
        )
    }

    func testFailing() {
        XCTAssertEqual(
            DiskHealthProbe.parseHealth(devicePlist: ["SMARTStatus": "Failing"]),
            .failing
        )
    }

    func testNotSupported() {
        XCTAssertEqual(
            DiskHealthProbe.parseHealth(devicePlist: ["SMARTStatus": "Not Supported"]),
            .unsupported
        )
    }

    /// 多数 USB 硬盘盒：根本没有 SMARTStatus 键
    func testMissingKeyIsUnsupported() {
        XCTAssertEqual(
            DiskHealthProbe.parseHealth(devicePlist: [:]),
            .unsupported
        )
    }

    func testUnknownRawValue() {
        XCTAssertEqual(
            DiskHealthProbe.parseHealth(devicePlist: ["SMARTStatus": "???"]),
            .unknown
        )
    }

    func testFailingIsCritical() {
        XCTAssertTrue(DiskHealth.failing.isCritical)
        XCTAssertFalse(DiskHealth.verified.isCritical)
        XCTAssertFalse(DiskHealth.unsupported.isCritical)
    }
}

/// BackupLocations.resolveWriteRoot：备份写目标纯逻辑
final class BackupLocationsTests: XCTestCase {

    func testDefaultIsSameDisk() {
        XCTAssertEqual(
            BackupLocations.resolveWriteRoot(drivePath: "/Volumes/A", alternateMount: nil),
            "/Volumes/A/.suishouqian-backup"
        )
    }

    func testAlternateVolume() {
        XCTAssertEqual(
            BackupLocations.resolveWriteRoot(drivePath: "/Volumes/A", alternateMount: "/Volumes/B"),
            "/Volumes/B/.suishouqian-backup"
        )
    }

    /// 指定盘就是应用所在盘 → 等价于同盘，不折腾
    func testAlternateSameAsDrive() {
        XCTAssertEqual(
            BackupLocations.resolveWriteRoot(drivePath: "/Volumes/A", alternateMount: "/Volumes/A"),
            "/Volumes/A/.suishouqian-backup"
        )
    }

    func testEmptyAlternateFallsBack() {
        XCTAssertEqual(
            BackupLocations.resolveWriteRoot(drivePath: "/Volumes/A", alternateMount: ""),
            "/Volumes/A/.suishouqian-backup"
        )
    }
}
