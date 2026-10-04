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

    // MARK: - 台账 v2（v3.0 batchID / volumeRole）

    /// v1 格式的 JSON 老文件必须直接可读，新字段解码为 nil——老用户无感升级
    func testV1ManifestFileStillDecodes() throws {
        let v1JSON = """
        {"version":1,"apps":[{"appName":"Old.app","linkPath":"/Applications/Old.app",\
        "volumeUUID":"OLD-UUID","relativePath":"Applications/Old.app",\
        "migratedAt":"2026-08-20T10:00:00Z","kind":"bundle"}]}
        """
        let url = tempDir.appendingPathComponent("migration-manifest.json")
        // 本类的 setUp 只注入 directoryOverride 不建目录（旧测试依赖 fileURL 懒创建），
        // 直接写文件前要先建好
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path,
                                                     contents: Data(v1JSON.utf8)),
                      "v1 台账文件必须写得进去")
        let entry = MigrationManifest.shared.entry(forAppName: "Old.app")
        XCTAssertNotNil(entry, "v1 台账必须照常读出")
        XCTAssertNil(entry?.batchID)
        XCTAssertNil(entry?.volumeRole)
    }

    /// v2 新字段走 record 写入并持久化
    func testV2FieldsRoundTrip() {
        MigrationManifest.shared.record(
            appName: "New.app", linkPath: "/Applications/New.app",
            volumeUUID: "NEW-UUID", relativePath: "Applications/New.app",
            batchID: "batch-1", volumeRole: "primary")
        let entry = MigrationManifest.shared.entry(forAppName: "New.app")
        XCTAssertEqual(entry?.batchID, "batch-1")
        XCTAssertEqual(entry?.volumeRole, "primary")
        XCTAssertEqual(MigrationManifest.shared.all().count, 1)
    }

    /// 降级安全：v2 写出的文件仍是合法 JSON，version=2（老版本解码时忽略未知 key）
    func testV2FileContainsNewFieldsButRemainsValidJSON() throws {
        MigrationManifest.shared.record(
            appName: "Both.app", linkPath: "/Applications/Both.app",
            volumeUUID: "UU", relativePath: "Applications/Both.app")
        let text = try String(contentsOf: tempDir.appendingPathComponent(
            "migration-manifest.json"), encoding: .utf8)
        let decoded = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        XCTAssertEqual(decoded?["version"] as? Int, 2)
        let apps = decoded?["apps"] as? [[String: Any]]
        XCTAssertEqual(apps?.count, 1)
    }

    // MARK: - 高-5 台账损坏抢救（2026-10-04 审计）

    /// 逐条解码：坏条目跳过，好条目保住
    func testRescueEntriesSkipsCorruptElement() {
        let json = """
        {"version":2,"apps":[
          {"appName":"Good.app","linkPath":"/Applications/Good.app",\
          "volumeUUID":"UU","relativePath":"Applications/Good.app",\
          "migratedAt":"2026-10-01T10:00:00Z"},
          {"appName":"Bad.app","linkPath":12345,\
          "volumeUUID":"UU","relativePath":"Applications/Bad.app",\
          "migratedAt":"2026-10-01T10:00:00Z"},
          {"appName":"Good2.app","linkPath":"/Applications/Good2.app",\
          "volumeUUID":"UU","relativePath":"Applications/Good2.app",\
          "migratedAt":"2026-10-01T10:00:00Z","kind":"data"}]}
        """
        let rescued = MigrationManifest.rescueEntries(from: Data(json.utf8))
        XCTAssertEqual(rescued.map(\.appName).sorted(), ["Good.app", "Good2.app"])
        XCTAssertEqual(rescued.first(where: { $0.appName == "Good2.app" })?.kind, "data")
    }

    /// 完全无法解析时返回空（不崩溃、不抛错）
    func testRescueEntriesReturnsEmptyForGarbage() {
        XCTAssertTrue(MigrationManifest.rescueEntries(
            from: Data("not json at all".utf8)).isEmpty)
        XCTAssertTrue(MigrationManifest.rescueEntries(
            from: Data("{\"version\":2}".utf8)).isEmpty)  // 没有 apps 键
        XCTAssertTrue(MigrationManifest.rescueEntries(from: Data()).isEmpty)
    }

    /// 端到端：顶层解码失败时 load() 走抢救路径，好条目仍可读出
    func testCorruptManifestFileRescuesGoodEntriesOnLoad() throws {
        // Broken.app 缺 migratedAt（必需字段）→ 顶层解码整体失败
        let json = """
        {"version":2,"apps":[
          {"appName":"Survivor.app","linkPath":"/Applications/Survivor.app",\
          "volumeUUID":"UU","relativePath":"Applications/Survivor.app",\
          "migratedAt":"2026-10-01T10:00:00Z"},
          {"appName":"Broken.app","linkPath":"/Applications/Broken.app",\
          "volumeUUID":"UU","relativePath":"Applications/Broken.app"}]}
        """
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("migration-manifest.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path,
                                                     contents: Data(json.utf8)))
        // 旧行为：整体隔离 → Survivor 也读不出来；新行为：抢救回 Survivor
        XCTAssertNotNil(MigrationManifest.shared.entry(forAppName: "Survivor.app"),
                        "损坏文件中完好的条目必须被抢救回来")
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "Broken.app"))
        // 隔离文件照样留档（人工可再捞）
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasPrefix("migration-manifest.corrupt-") }
        XCTAssertEqual(quarantined.count, 1, "坏文件仍应隔离留档")
    }
}
