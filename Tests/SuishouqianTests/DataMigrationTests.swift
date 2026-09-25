import XCTest
@testable import 随手迁

/// v2.3 数据迁移：台账 kind 字段兼容性 + 目录清单健壮性
final class DataMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("datamig-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - kind 字段

    func testDataKindRoundTrip() {
        MigrationManifest.shared.record(
            appName: "Data-ios-backup", linkPath: "/Users/x/MobileSync/Backup",
            volumeUUID: "AB", relativePath: "SuishouqianData/ios-backup", kind: "data")

        let entry = MigrationManifest.shared.entry(forAppName: "Data-ios-backup")
        XCTAssertEqual(entry?.kind, "data")
    }

    func testLegacyManifestWithoutKindStillDecodes() throws {
        // v2.2 写的台账没有 kind 字段，升级后必须还能读（kind = nil 视为应用）
        let legacyJSON = """
        {
          "version": 1,
          "apps": [
            {"appName": "Demo.app", "linkPath": "/Applications/Demo.app",
             "volumeUUID": "AB-CD", "relativePath": "Applications/Demo.app",
             "migratedAt": "2026-09-01T00:00:00Z"}
          ]
        }
        """
        try legacyJSON.data(using: .utf8)!.write(
            to: tempDir.appendingPathComponent("migration-manifest.json"))

        let entry = MigrationManifest.shared.entry(forAppName: "Demo.app")
        XCTAssertNotNil(entry, "v2.2 旧台账必须能解码")
        XCTAssertNil(entry?.kind, "旧条目 kind 应为 nil（= 应用）")
    }

    func testBundleRecordDefaultsToNilKind() {
        MigrationManifest.shared.record(
            appName: "Demo.app", linkPath: "/Applications/Demo.app",
            volumeUUID: "AB", relativePath: "Applications/Demo.app")
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "Demo.app")?.kind)
    }

    // MARK: - 目录清单

    func testCatalogIDsAreUniqueAndASCII() {
        let ids = DataMigrator.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "id 必须唯一（外置盘目录名/台账名依赖它）")
        for id in ids {
            XCTAssertTrue(id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                          "id 只允许字母数字连字符：\(id)")
        }
    }

    func testCatalogPathsAreHomeRelativeAndSafe() {
        for location in DataMigrator.catalog {
            XCTAssertTrue(location.homeRelativePath.hasPrefix("~/"),
                          "清单路径必须以 ~ 开头（只碰用户目录）：\(location.id)")
            // 红线：链接迁移（symlink）条目不得指向偏好设置/缓存/沙盒容器——那是工具要动手搬的；
            // native 指引条目只指路不动手，允许指进容器（docker-disk、wechat-data），
            // 旧 id 白名单已泛化为按 relocation 类型判断
            let forbidden = ["Preferences", "/Caches", "Containers/"]
            let violations = forbidden.filter {
                location.homeRelativePath.contains($0) && !location.relocation.isNativeGuide
            }
            XCTAssertTrue(violations.isEmpty, "链接迁移条目触碰保护目录：\(location.id)")
        }
    }

    func testManifestNamePrefixMatchesBackupFilter() {
        XCTAssertEqual(DataMigrator.manifestName(for: "ios-backup"), "Data-ios-backup")
        XCTAssertTrue(DataMigrator.manifestName(for: "ios-backup")
            .hasPrefix(DataMigrator.manifestPrefix))
    }

    // MARK: - 外置盘原住民应用扫描（v2.4.2）

    func testExternalCandidatesDedupeAgainstInternal() {
        let names = ["wpsoffice.app", "Cursor.app", "LM Studio.app", "Demo.app"]
        let internalNames: Set<String> = ["Cursor.app", "Demo.app"]
        let result = AppScanner.externalCandidates(names, alreadyInternal: internalNames)
        // Cursor/Demo 内置盘已有（迁移正本），WPS 和 LM Studio 是外置盘原住民
        XCTAssertEqual(result, ["wpsoffice.app", "LM Studio.app"])
    }

    func testExternalCandidatesKeepAllWhenNothingInternal() {
        let result = AppScanner.externalCandidates(
            ["A.app", "B.app"], alreadyInternal: [])
        XCTAssertEqual(result, ["A.app", "B.app"])
    }
}
