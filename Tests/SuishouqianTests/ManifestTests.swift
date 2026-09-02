import XCTest
@testable import 随手迁

/// 迁移台账（卷 UUID manifest）单元测试：断链自愈的数据基础
final class ManifestTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-tests-\(UUID().uuidString)", isDirectory: true)
        MigrationManifest.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRecordAndFetchNormalizesUUIDCase() throws {
        MigrationManifest.shared.record(
            appName: "Demo.app", linkPath: "/Applications/Demo.app",
            volumeUUID: "abcd-1234-ef", relativePath: "Applications/Demo.app")

        let entry = MigrationManifest.shared.entry(forAppName: "Demo.app")
        XCTAssertEqual(entry?.volumeUUID, "ABCD-1234-EF")   // UUID 统一大写
        XCTAssertEqual(entry?.relativePath, "Applications/Demo.app")
        XCTAssertEqual(entry?.linkPath, "/Applications/Demo.app")
    }

    func testRecordReplacesOldEntryForSameApp() {
        MigrationManifest.shared.record(
            appName: "Demo.app", linkPath: "/Applications/Demo.app",
            volumeUUID: "AA", relativePath: "Applications/Demo.app")
        MigrationManifest.shared.record(
            appName: "Demo.app", linkPath: "/Applications/Demo.app",
            volumeUUID: "BB", relativePath: "Applications/Demo.app")

        XCTAssertEqual(MigrationManifest.shared.all().count, 1)
        XCTAssertEqual(MigrationManifest.shared.entry(forAppName: "Demo.app")?.volumeUUID, "BB")
    }

    func testRemovePersistsToDisk() {
        MigrationManifest.shared.record(
            appName: "X.app", linkPath: "/Applications/X.app",
            volumeUUID: "CC", relativePath: "Applications/X.app")
        XCTAssertNotNil(MigrationManifest.shared.entry(forAppName: "X.app"))

        MigrationManifest.shared.remove(appName: "X.app")
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "X.app"))
        XCTAssertTrue(MigrationManifest.shared.all().isEmpty)
    }

    func testEntriesAreIsolatedByAppName() {
        MigrationManifest.shared.record(
            appName: "A.app", linkPath: "/Applications/A.app",
            volumeUUID: "AA", relativePath: "Applications/A.app")
        MigrationManifest.shared.record(
            appName: "B.app", linkPath: "/Applications/B.app",
            volumeUUID: "BB", relativePath: "Applications/B.app")

        XCTAssertEqual(MigrationManifest.shared.entry(forAppName: "A.app")?.volumeUUID, "AA")
        XCTAssertEqual(MigrationManifest.shared.entry(forAppName: "B.app")?.volumeUUID, "BB")
        MigrationManifest.shared.remove(appName: "A.app")
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "A.app"))
        XCTAssertNotNil(MigrationManifest.shared.entry(forAppName: "B.app"))
    }

    func testMountPointForUnknownUUIDReturnsNil() {
        XCTAssertNil(MigrationManifest.mountPoint(forUUID: "00000000-0000-0000-0000-000000000000"))
    }

    func testVolumeUUIDOfRootVolumeIsReadable() {
        // 内置根卷必有 UUID；验证探测路径本身可用（不关心具体值）
        let uuid = MigrationManifest.volumeUUID(atPath: "/")
        XCTAssertNotNil(uuid)
        XCTAssertEqual(uuid, uuid?.uppercased())
    }

    func testMissingEntryReturnsNil() {
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "NeverMigrated.app"))
    }
}
