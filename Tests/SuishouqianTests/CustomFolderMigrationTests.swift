import XCTest
@testable import 随手迁

/// 自选文件夹迁移（v2.11.0）：护栏判定 + 台账扫描
final class CustomFolderMigrationTests: XCTestCase {

    private var tempDir: URL!
    private let home = "/Users/tester"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom-folder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = tempDir.appendingPathComponent("manifest")
        try FileManager.default.createDirectory(at: MigrationManifest.directoryOverride!,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 护栏

    private func issue(_ path: String) -> String? {
        DataMigrator.customFolderIssue(forPath: path, home: home)
    }

    func testAllowsOrdinaryHomeFolders() {
        XCTAssertNil(issue("/Users/tester/Movies/我的项目"))
        XCTAssertNil(issue("/Users/tester/bigdata"))
        XCTAssertNil(issue("/Users/tester/code/notebooks/output"))
        XCTAssertNil(issue("/Users/Shared/stuff"))
    }

    func testRefusesSystemRoots() {
        XCTAssertNotNil(issue("/"))
        XCTAssertNotNil(issue("/Users/tester"))
        XCTAssertNotNil(issue("/System/X"))
        XCTAssertNotNil(issue("/Library/Updates"))
        XCTAssertNotNil(issue("/Applications/Some.app"))
        XCTAssertNotNil(issue("/Volumes/Ext/data"))
        XCTAssertNotNil(issue("/usr/local/share/big"))
        XCTAssertNotNil(issue("/private/var/db"))
        XCTAssertNotNil(issue("/var/db"))
        // /var 是 /private/var 的符号链接：规范化后的路径同样必须被拦
        XCTAssertNotNil(issue("/private/etc/hosts"))
    }

    func testRefusesLibraryAndHotUserDirs() {
        XCTAssertNotNil(issue("/Users/tester/Library/Preferences/x"))
        XCTAssertNotNil(issue("/Users/tester/Library"))
        XCTAssertNotNil(issue("/Users/tester/Desktop/旧文件"))
        XCTAssertNotNil(issue("/Users/tester/Documents/资料"))
        XCTAssertNotNil(issue("/Users/tester/Downloads/dataset"))
    }

    func testRefusesAppBundle() {
        XCTAssertTrue(issue("/Users/tester/Tools/Tool.app")?.contains("迁移") ?? false)
        XCTAssertTrue(issue("/Users/tester/Plug.bundle")?.contains("迁移") ?? false)
    }

    /// 前缀比对必须带 "/" 边界：/Volumes2、/SystemX 不是系统目录
    func testPrefixBoundaryDoesNotOverreach() {
        XCTAssertNil(issue("/Volumes2/data"))
        XCTAssertNil(issue("/SystemX/tools"))
        XCTAssertNil(issue("/Users/tester/LibraryX/notes"))
    }

    // MARK: - 台账扫描

    func testScanCustomItemsReturnsOnlyCustomDataEntries() async throws {
        let target = tempDir.appendingPathComponent("Target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "x".write(to: target.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let link = tempDir.appendingPathComponent("MyData")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: target.path)

        MigrationManifest.shared.record(appName: "Data-custom.MyData",
                                        linkPath: link.path, volumeUUID: "TEST-UUID",
                                        relativePath: "SuishouqianData/Data-custom.MyData",
                                        kind: "data")
        // 清单里的非自选数据条目不该出现在自选列表
        MigrationManifest.shared.record(appName: "Data-ios-backup",
                                        linkPath: link.path, volumeUUID: "TEST-UUID",
                                        relativePath: "SuishouqianData/Data-ios-backup",
                                        kind: "data")

        let items = await DataMigrator().scanCustomItems()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "custom.MyData")
        XCTAssertEqual(items.first?.title, "自选 · MyData")
        XCTAssertEqual(items.first?.isSymlink, true)
        XCTAssertEqual(items.first?.managedByUs, true)
        XCTAssertGreaterThan(items.first?.sizeBytes ?? 0, 0)
    }

    func testScanCustomItemsIgnoresMissingLinks() async throws {
        MigrationManifest.shared.record(appName: "Data-custom.Gone",
                                        linkPath: "/nonexistent/link",
                                        volumeUUID: "TEST-UUID",
                                        relativePath: "x", kind: "data")
        let items = await DataMigrator().scanCustomItems()
        XCTAssertTrue(items.isEmpty)
    }
}
