import XCTest
@testable import 随手迁

/// 端到端搬迁测试：跑真实的复制→校验→备份→收尾链路，对比「迁移（留链接）」
/// 与「纯搬迁（不留链接）」的结果差异。
///
/// 需要一个可写的外置卷（与内置卷不同设备）；没有就跳过，不阻塞其他机器。
/// 全部操作都发生在自建沙箱目录里，结束后清理。
final class ExternalVolumeRelocationTests: XCTestCase {

    private var tempDir: URL!
    private var volume: URL!
    private var sandbox: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reloc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = tempDir
        AuditLog.directoryOverride = tempDir
        // 快照节流：别让测试真的去建 APFS 快照
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")

        guard let external = Self.findWritableExternalVolume() else {
            throw XCTSkip("没有可写的外置卷，跳过端到端搬迁测试")
        }
        volume = external
        sandbox = external.appendingPathComponent(".suishouqian-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        AuditLog.directoryOverride = nil
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// 找一个与内置卷不同设备、且可写的外置卷
    private static func findWritableExternalVolume() -> URL? {
        let keys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else {
            return nil
        }
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsInternal == false || values.volumeIsRemovable == true else {
                continue
            }
            // 可写且不是 Time Machine 备份盘（备份盘不能放应用）
            VolumeClassifier.ensureCachePrimed()
            guard FileManager.default.isWritableFile(atPath: url.path),
                  !VolumeClassifier.isOnTimeMachineVolume(path: url.path) else { continue }
            return url
        }
        return nil
    }

    /// 造一个最小的"已安装应用"（带 Info.plist 与可执行文件，供运行检测/签名调用）
    private func makeFakeApp(named name: String) throws -> String {
        let app = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleIdentifier": "com.example.relocationtest",
            "CFBundleName": "RelocationTest",
            "CFBundleExecutable": "RelocationTest",
            "CFBundleShortVersionString": "1.0",
        ]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Data("#!/bin/sh\nexit 0\n".utf8)
            .write(to: app.appendingPathComponent("Contents/MacOS/RelocationTest"))
        try Data("payload".utf8)
            .write(to: app.appendingPathComponent("Contents/payload.txt"))
        return app.path
    }

    private func makeAppItem(path: String, bundleName: String) -> AppItem {
        AppItem(name: "RelocationTest", bundleName: bundleName, path: path,
                version: "1.0", size: 1_048_576, isSymlink: false,
                symlinkTarget: nil, icon: nil)
    }

    // MARK: - 纯搬迁（不在 /Applications 留替身）

    func testPureRelocationMovesAppAndLeavesNoEntryPoint() async throws {
        let source = try makeFakeApp(named: "PureApp.app")
        let app = makeAppItem(path: source, bundleName: "PureApp.app")

        let result = await AppMigrator().moveToExternal(app: app, drivePath: sandbox.path) { _, _ in }
        XCTAssertTrue(result.success, result.error ?? "搬迁应成功")

        let target = sandbox.appendingPathComponent("Applications/PureApp.app").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: target), "外置盘上应有应用")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/Contents/payload.txt"),
                      "内容应完整搬过去")

        // 核心：源位置必须干干净净——不留链接、不留任何东西
        XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: source),
                     "纯搬迁不得在 /Applications 留下任何替身（链接也没有）")

        // 留底备份仍在（stamped 的创建时刻）
        let backup = sandbox.appendingPathComponent(".suishouqian-backup/PureApp.app").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup), "应有留底备份")

        // 纯搬迁不写台账：没有链接可修，写了反而会被"台账校准"当幽灵清掉
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "PureApp.app"))
    }

    // MARK: - 链接迁移（对照：留软链接）

    func testLinkMigrationLeavesSymlinkEntryPoint() async throws {
        let source = try makeFakeApp(named: "LinkedApp.app")
        let app = makeAppItem(path: source, bundleName: "LinkedApp.app")

        let result = await AppMigrator().migrate(app: app, to: sandbox.path) { _, _ in }
        XCTAssertTrue(result.success, result.error ?? "迁移应成功")

        let target = sandbox.appendingPathComponent("Applications/LinkedApp.app").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: target))

        // 源位置是软链接（应用仍有入口）
        let attrs = try FileManager.default.attributesOfItem(atPath: source)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "链接迁移应在源位置留软链接")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source), target)

        // 留链接的迁移要写台账（卷改名自愈的依据）
        let entry = MigrationManifest.shared.entry(forAppName: "LinkedApp.app")
        XCTAssertNotNil(entry, "链接迁移应记录台账")
        XCTAssertEqual(entry?.relativePath, "Applications/LinkedApp.app")
        XCTAssertFalse(entry?.volumeUUID.isEmpty ?? true)
    }

    // MARK: - 两种方式都受前置校验保护

    func testRelocationRejectsUnmountedTarget() async throws {
        let source = try makeFakeApp(named: "StrayApp.app")
        let app = makeAppItem(path: source, bundleName: "StrayApp.app")

        // 目标是不存在的卷：必须拒绝，绝不能在 /Volumes 下落一个假目录（历史事故）
        let result = await AppMigrator().moveToExternal(
            app: app, drivePath: "/Volumes/绝对不存在的卷") { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/绝对不存在的卷"),
                       "拒绝迁移后不得在 /Volumes 留下任何痕迹")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source), "源应用应原封不动")
    }
}
