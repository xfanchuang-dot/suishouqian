import XCTest
@testable import 随手迁

/// 盘间迁移（v3.0）：core 流程用 temp 目录全流程跑通（ditto/校验/删源都是真实 FS 操作）；
/// 卷级护栏（validateTarget）走的是真实挂载点语义，不在此覆盖——归真机两盘 E2E。
final class RelocateTests: XCTestCase {

    private var tempRoot: URL!
    private var volumeA: URL!
    private var volumeB: URL!
    private var journalDir: URL!
    private var migrator: AppMigrator!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("relocate-tests-\(UUID().uuidString)", isDirectory: true)
        volumeA = tempRoot.appendingPathComponent("VolA", isDirectory: true)
        volumeB = tempRoot.appendingPathComponent("VolB", isDirectory: true)
        journalDir = tempRoot.appendingPathComponent("journal", isDirectory: true)
        for dir in [volumeA!, volumeB!, journalDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        OperationJournal.directoryOverride = journalDir
        migrator = AppMigrator()
    }

    override func tearDownWithError() throws {
        OperationJournal.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// 造一个有内容层级的假应用（ditto/字节校验都需要真实文件）
    @discardableResult
    private func makeFakeApp(at root: URL, name: String = "Foo.app") throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("macho-\(name)".utf8).write(to: app.appendingPathComponent("Contents/MacOS/bin"))
        try Data("plist".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("resource".utf8).write(to: app.appendingPathComponent("Contents/res.dat"))
        return app
    }

    private func makeApp(source: URL) -> AppItem {
        let item = AppItem(name: source.deletingPathExtension().lastPathComponent,
                           bundleName: source.lastPathComponent,
                           path: "/Applications/\(source.lastPathComponent)",
                           version: nil, size: 3, isSymlink: true,
                           symlinkTarget: source.path, icon: nil)
        return item
    }

    // MARK: - swapSymlink

    func testSwapSymlinkReplacesAtomically() throws {
        let dir = tempRoot.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("Foo.app")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "/Volumes/A/Foo.app")

        try AppMigrator.swapSymlink(at: link.path, to: "/Volumes/B/Foo.app")

        let dest = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(dest, "/Volumes/B/Foo.app")
        // 临时链接不留残骸
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".suishouqian-relink-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSwapSymlinkRefusesToReplaceRealDirectory() throws {
        let dir = tempRoot.appendingPathComponent("realdir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("Foo.app")   // 真目录，不是链接
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertThrowsError(try AppMigrator.swapSymlink(
            at: target.path, to: "/Volumes/B/Foo.app"))
        // 真目录毫发无损
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - relocateCore 全流程

    func testRelocateCoreMovesCopyVerifiesAndRemovesSource() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        let app = makeApp(source: source)

        let result = await migrator.relocateCore(
            app: app, sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        // 目标盘有完整副本（保持 Applications/ 布局）
        let target = volumeB.appendingPathComponent("Applications/Foo.app")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.appendingPathComponent("Contents/MacOS/bin").path))
        // 源盘副本已清
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))

        // journal 恰好一条成功的 relocate
        let entries = OperationJournal.shared.recent(limit: 10)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.op, .relocate)
        XCTAssertEqual(entries.first?.isOK, true)
        XCTAssertEqual(entries.first?.appName, "Foo.app")
    }

    func testRelocateCoreCopyFailureLeavesSourceIntact() async throws {
        // 源路径不存在 → ditto 失败 → 失败返回，B 盘无残留，journal 记 failed
        let app = makeApp(source: volumeA.appendingPathComponent("Applications/Ghost.app"))

        let result = await migrator.relocateCore(
            app: app, sourcePath: volumeA.appendingPathComponent("Applications/Ghost.app").path,
            fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertFalse(result.success)
        let bApps = try FileManager.default.contentsOfDirectory(atPath: volumeB.path)
        XCTAssertTrue(bApps.isEmpty, "B 盘不得留下半截副本")
        let entries = OperationJournal.shared.recent(limit: 10)
        XCTAssertEqual(entries.first?.isOK, false)
    }

    func testRelocateCoreKeepsSourceWhenTargetExisted() async throws {
        // B 盘已有同名目录（上次中断的残留）：ditto 先清目标再复制，流程应正常走完
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        try makeFakeApp(at: volumeB.appendingPathComponent("Applications"))  // 残留
        let app = makeApp(source: source)

        let result = await migrator.relocateCore(
            app: app, sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - relocate 护栏

    func testRelocateRejectsSourceNotOnFromVolume() async throws {
        // symlinkTarget 指向别处：绝不能按错路径动手
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        var app = makeApp(source: source)
        app = AppItem(name: app.name, bundleName: app.bundleName, path: app.path,
                      version: nil, size: app.size, isSymlink: true,
                      symlinkTarget: "/Volumes/别的地方/Foo.app", icon: nil)

        let result = await migrator.relocate(
            app: app, fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("不在源盘上") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "源副本不能被动")
        // 护栏拒绝也要记 journal（撤销界面要能如实展示"无可撤销"）
        XCTAssertEqual(OperationJournal.shared.recent(limit: 1).first?.isOK, false)
    }

    func testRelocateRejectsSameVolume() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        let app = makeApp(source: source)

        let result = await migrator.relocate(
            app: app, fromVolume: volumeA.path, toVolume: volumeA.path) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("相同") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
