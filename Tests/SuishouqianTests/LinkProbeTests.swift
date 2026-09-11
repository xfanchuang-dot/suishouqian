import XCTest
@testable import 随手迁

/// v2.5 链路体检：体感结论分级逻辑
final class LinkProbeTests: XCTestCase {

    func testExFATAlwaysWarns() {
        let info = LinkInfo(filesystem: "exfat", protocolKind: "USB")
        XCTAssertFalse(info.verdict.positive, "exFAT 无论链路如何都必须告警")
        XCTAssertTrue(info.isExFAT)
    }

    func testThunderboltClassPositive() {
        let info = LinkInfo(filesystem: "apfs", protocolKind: "PCI-Express")
        XCTAssertTrue(info.verdict.positive)
        XCTAssertTrue(info.verdict.text.contains("体感与内置盘一致"))
    }

    func testUSBPositiveWithHint() {
        let info = LinkInfo(filesystem: "apfs", protocolKind: "USB")
        XCTAssertTrue(info.verdict.positive)
        XCTAssertTrue(info.verdict.text.contains("换线缆"), "USB 档位给可操作的改进建议")
    }

    func testUnknownProtocolNeutral() {
        let info = LinkInfo(filesystem: "apfs", protocolKind: "")
        XCTAssertTrue(info.verdict.positive)
    }

    func testFilesystemDisplayUppercase() {
        XCTAssertEqual(LinkInfo(filesystem: "apfs", protocolKind: "USB").filesystemDisplay,
                       "APFS")
    }
}
