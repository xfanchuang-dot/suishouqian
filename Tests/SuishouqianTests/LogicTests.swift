import XCTest
@testable import 随手迁

/// 核心纯逻辑单元测试
final class LogicTests: XCTestCase {

    let checker = HealthChecker()

    // MARK: - 残留匹配（防误删的关键逻辑）

    private let signatures: Set<String> = [
        "qqbrowser", "google chrome", "googlechrome",
        "com.tencent.qqbrowser", "com.tencent",
        "trae solo cn", "traesolocn",
    ]

    func testResidueMatchesByNameWithTrailingDigits() {
        // QQBrowser3 是 QQ浏览器的数据目录名（带版本尾数字）
        XCTAssertTrue(checker.residueMatches("QQBrowser3", signatures: signatures))
    }

    func testResidueMatchesBySpacelessVariant() {
        XCTAssertTrue(checker.residueMatches("TRAE SOLO CN", signatures: signatures))
    }

    func testResidueMatchesByBundleIDPrefix() {
        // 目录名是完整 bundleID，签名里有 vendor 前缀
        XCTAssertTrue(checker.residueMatches("com.tencent.qqbrowser.helper",
                                             signatures: signatures))
    }

    func testResidueRejectsUnknownApp() {
        XCTAssertFalse(checker.residueMatches("抖音", signatures: signatures))
        XCTAssertFalse(checker.residueMatches("someoldgame", signatures: signatures))
    }

    func testResiduePrefixOnlyForLongKeys() {
        // 短键不做前缀启发：两字目录只有精确匹配才算认领，
        // 否则"抖音"这类两字真实残留会被永远漏报
        let sig: Set<String> = ["qqbrowser"]
        XCTAssertFalse(checker.residueMatches("qq", signatures: sig))
        // 长键前缀互含生效
        XCTAssertTrue(checker.residueMatches("qqbrowserhelper", signatures: sig))
    }

    // MARK: - 链接状态分类

    func testClassifyHealthy() {
        let state = checker.classify(target: "/Applications/Safari.app")
        XCTAssertEqual(state, .healthy)
    }

    func testClassifyVolumeOfflineWhenVolumeMissing() {
        let state = checker.classify(target: "/Volumes/绝对不存在的卷/X.app")
        XCTAssertEqual(state, .volumeOffline)
    }

    func testClassifyStaleVolumesDirIsOffline() {
        // /tmp 在根卷上而非独立挂载点 → 等价"卷未挂载"（内置盘残留目录场景）
        let state = checker.classify(target: "/tmp/不存在的目标.app")
        XCTAssertEqual(state, .volumeOffline)
    }

    // MARK: - 外置判定

    func testIsOnExternal() {
        let item = AppItem(name: "X", bundleName: "X.app", path: "/Applications/X.app",
                           version: nil, size: 1, isSymlink: true,
                           symlinkTarget: "/Volumes/T/X.app", icon: nil)
        XCTAssertTrue(item.isOnExternal)

        let local = AppItem(name: "Y", bundleName: "Y.app", path: "/Applications/Y.app",
                            version: nil, size: 1, isSymlink: false,
                            symlinkTarget: nil, icon: nil)
        XCTAssertFalse(local.isOnExternal)
    }

    // MARK: - 审计日志（目录注入隔离）

    func testAuditLogAppendAndRead() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        AuditLog.directoryOverride = tmp
        defer { AuditLog.directoryOverride = nil }

        let marker = "TEST-\(UUID().uuidString)"
        AuditLog.append(marker)

        let content = AuditLog.readAll()
        XCTAssertTrue(content.contains(marker), "日志应包含刚写入的事件")
    }
}
