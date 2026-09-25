import XCTest
@testable import 随手迁

/// v2.13.0：卸载残留特征集 + 数据目录清单新增条目
final class UninstallAndCatalogTests: XCTestCase {

    // MARK: - 单应用特征集

    func testAppSignaturesNameVariants() {
        let sigs = HealthChecker.appSignatures(name: "Visual Studio Code", bundleID: nil)
        XCTAssertTrue(sigs.contains("visual studio code"))
        XCTAssertTrue(sigs.contains("visualstudiocode"))
        XCTAssertFalse(sigs.contains("Visual Studio Code"))
    }

    func testAppSignaturesBundleIDAndPrefix() {
        let sigs = HealthChecker.appSignatures(name: "QQMusic", bundleID: "com.tencent.QQMusicMac")
        XCTAssertTrue(sigs.contains("qqmusic"))
        XCTAssertTrue(sigs.contains("com.tencent.qqmusicmac"))
        XCTAssertTrue(sigs.contains("com.tencent"))
    }

    func testAppSignaturesEmptyBundleIDIgnored() {
        let sigs = HealthChecker.appSignatures(name: "X", bundleID: "")
        XCTAssertEqual(sigs, ["x"])
    }

    // MARK: - 数据目录清单

    func testWeChatEntryExistsWithNativeGuide() {
        let entry = DataMigrator.catalog.first { $0.id == "wechat-data" }
        XCTAssertNotNil(entry, "微信条目必须在清单里（本机已验证路径存在）")
        guard case .native = entry?.relocation else {
            return XCTFail("微信必须是原生搬迁指引，不做链接迁移")
        }
        XCTAssertTrue(entry?.homeRelativePath.contains("xwechat_files") ?? false)
        XCTAssertNotNil(entry?.ownerBundleID)
    }

    func testAllCatalogIDsUnique() {
        let ids = DataMigrator.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "清单 id 必须唯一（台账/外置目录名都靠它）")
    }

    // MARK: - 体积未知显示

    func testSizeDisplayShowsUnknownForZero() throws {
        let item = try makeItem(sizeBytes: 0)
        XCTAssertEqual(item.sizeDisplay, "体积未知")
        let sized = try makeItem(sizeBytes: 150 * 1_048_576)
        XCTAssertEqual(sized.sizeDisplay,
                       ByteCountFormatter.string(fromByteCount: 150 * 1_048_576, countStyle: .file))
    }

    private func makeItem(sizeBytes: Int64) throws -> DataMigrator.DataLocationItem {
        var item = DataMigrator.DataLocationItem(
            id: "wechat-data", title: "微信", path: "~/x",
            sizeBytes: sizeBytes, isSymlink: false, linkBroken: false,
            accessible: true, managedByUs: false, ownerRunning: false,
            relocation: .native(guide: "g", launchAppName: nil), note: nil)
        return item
    }
}
