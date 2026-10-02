import XCTest
@testable import 随手迁

/// 中断恢复（Muse 审查第四章，状态模拟法）：按 relocateCore 的步骤顺序构造每个
/// 崩溃点的盘面，再走恢复入口，断言收敛到一致终态。
/// 一致性不变量：链接（若有）指向完整副本、至少一份完整副本存活、
/// 不存在"被链接指向的半截副本"、journal 与盘面不矛盾。
final class InterruptionRecoveryTests: XCTestCase {

    private var tempRoot: URL!
    private var volumeA: URL!
    private var volumeB: URL!
    private var volumeC: URL!
    private var linksDir: URL!
    private var journalDir: URL!
    private var manifestDir: URL!
    private var migrator: AppMigrator!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("interrupt-tests-\(UUID().uuidString)", isDirectory: true)
        volumeA = tempRoot.appendingPathComponent("VolA", isDirectory: true)
        volumeB = tempRoot.appendingPathComponent("VolB", isDirectory: true)
        volumeC = tempRoot.appendingPathComponent("VolC", isDirectory: true)
        linksDir = tempRoot.appendingPathComponent("Links", isDirectory: true)
        journalDir = tempRoot.appendingPathComponent("journal", isDirectory: true)
        manifestDir = tempRoot.appendingPathComponent("manifest", isDirectory: true)
        for dir in [volumeA!, volumeB!, volumeC!, linksDir!, journalDir!, manifestDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        OperationJournal.directoryOverride = journalDir
        MigrationManifest.directoryOverride = manifestDir
        // 快照节流：预置时间戳避免 restore 真去建 APFS 快照（key 以 SystemSnapshot 实现为准）
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")
        migrator = AppMigrator()
    }

    override func tearDownWithError() throws {
        OperationJournal.directoryOverride = nil
        MigrationManifest.directoryOverride = nil
        UserDefaults.standard.removeObject(forKey: "lastLocalSnapshotAt")
        try? FileManager.default.removeItem(at: tempRoot)
    }

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

    private func makeApp(source: URL, linkPath: URL? = nil) -> AppItem {
        AppItem(name: source.deletingPathExtension().lastPathComponent,
                bundleName: source.lastPathComponent,
                path: linkPath?.path ?? "/Applications/\(source.lastPathComponent)",
                version: nil, size: 3, isSymlink: true,
                symlinkTarget: source.path, icon: nil)
    }

    private func isComplete(_ app: URL) -> Bool {
        ["Contents/MacOS/bin", "Contents/Info.plist", "Contents/res.dat"].allSatisfy {
            FileManager.default.fileExists(atPath: app.appendingPathComponent($0).path)
        }
    }

    // MARK: - 崩溃点 1：复制中途（B 上只有半截副本）

    func testCrashDuringCopyHalfTargetRetryConverges() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        let half = try makeFakeApp(at: volumeB.appendingPathComponent("Applications"))
        try FileManager.default.removeItem(at: half.appendingPathComponent("Contents/res.dat"))

        let result = await migrator.relocateCore(
            app: makeApp(source: source), sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(isComplete(volumeB.appendingPathComponent("Applications/Foo.app")),
                      "半截副本应被完整重建")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let entries = OperationJournal.shared.recent(limit: 5)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.isOK, true)
    }

    // MARK: - 崩溃点 2：复制+校验已过、删源之前（两份完整副本并存）

    func testCrashBeforeSourceDeleteBothCopiesRetryConverges() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        _ = try makeFakeApp(at: volumeB.appendingPathComponent("Applications"))
        XCTAssertTrue(OperationJournal.shared.recent(limit: 5).isEmpty,
                      "崩溃发生在记账之前：journal 必须为空")

        let result = await migrator.relocateCore(
            app: makeApp(source: source), sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "源副本应被收尾删除")
        XCTAssertTrue(isComplete(volumeB.appendingPathComponent("Applications/Foo.app")))
    }

    // MARK: - 崩溃点 3：链接已改指 B、源未删（改写幂等）

    func testCrashAfterSwapLinkOnBSourceOnARetryConverges() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        let target = try makeFakeApp(at: volumeB.appendingPathComponent("Applications"))
        let link = linksDir.appendingPathComponent("Foo.app")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: target.path)
        let app = makeApp(source: target, linkPath: link)

        // sourcePath 仍传 A：漂移护栏必须放行"链接已指目标"这一合法中间态
        let result = await migrator.relocateCore(
            app: app, sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path,
            linkDirectory: linksDir.path) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       target.path, "链接保持指向 B（改写幂等）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(isComplete(target))
    }

    // MARK: - 撤销侧：撤销=restore 时外置副本已失，链接必须重建、原条目保持可撤销

    func testUndoRestoreMissingExternalCopyRelinksAndKeepsOriginalUndoable() async throws {
        let linkPos = linksDir.appendingPathComponent("Foo.app")
        let external = volumeB.appendingPathComponent("Applications/Foo.app")  // 故意不创建
        try FileManager.default.createSymbolicLink(atPath: linkPos.path,
                                                   withDestinationPath: external.path)
        let app = AppItem(name: "Foo", bundleName: "Foo.app", path: linkPos.path,
                          version: nil, size: 3, isSymlink: true,
                          symlinkTarget: external.path, icon: nil)
        let migrateID = OperationJournal.shared.record(
            op: .migrate, appName: "Foo.app", params: ["volumeUUID": "B"], result: "ok")

        let result = await migrator.restore(app: app, from: volumeB.path) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertEqual(try? FileManager.default.destinationOfSymbolicLink(atPath: linkPos.path),
                       external.path, "入口不丢：链接被重建回原目标")
        let entries = OperationJournal.shared.recent(limit: 10)
        XCTAssertEqual(entries.first { $0.id == migrateID }?.isUndone, false,
                       "撤销失败不许销账")
        XCTAssertTrue(entries.contains { $0.op == .restore && !$0.isOK })
    }

    // MARK: - 崩溃点 5：journal 尾行写一半（截断容错）

    func testJournalTruncatedTailLineIgnored() throws {
        let url = journalDir.appendingPathComponent("operation-journal.jsonl")
        let e1 = JournalEntry(id: UUID(), at: Date(), op: .migrate, appName: "A.app",
                              params: [:], result: "ok", snapshotID: nil,
                              backupPath: nil, undoneBy: nil)
        let e2 = JournalEntry(id: UUID(), at: Date(), op: .restore, appName: "B.app",
                              params: [:], result: "ok", snapshotID: nil,
                              backupPath: nil, undoneBy: nil)
        let enc = JSONEncoder()
        var text = String(data: try enc.encode(e1), encoding: .utf8)! + "\n"
        text += String(data: try enc.encode(e2), encoding: .utf8)! + "\n"
        text += "{\"id\":\"\(UUID().uuidString)\",\"at\":\"2026-09"   // 写一半进程没了
        try text.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(OperationJournal.shared.recent(limit: 10).count, 2,
                       "截断行应被跳过，其余条目完好")
        OperationJournal.shared.record(op: .migrate, appName: "Z.app", result: "ok")
        XCTAssertEqual(OperationJournal.shared.recent(limit: 10).count, 3,
                       "截断后仍可继续追加")
    }

    // MARK: - P2-3 配套：链接指向第三处时 relocate 必须中止且什么都不动

    func testRelocateAbortsWhenLinkPointsElsewhere() async throws {
        let source = try makeFakeApp(at: volumeA.appendingPathComponent("Applications"))
        let elsewhere = try makeFakeApp(at: volumeC.appendingPathComponent("Applications"))
        let link = linksDir.appendingPathComponent("Foo.app")
        try FileManager.default.createSymbolicLink(atPath: link.path,
                                                   withDestinationPath: elsewhere.path)
        let app = makeApp(source: elsewhere, linkPath: link)

        let result = await migrator.relocateCore(
            app: app, sourcePath: source.path,
            fromVolume: volumeA.path, toVolume: volumeB.path,
            linkDirectory: linksDir.path) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       elsewhere.path, "漂移的链接不许动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "源副本不许删")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: volumeB.appendingPathComponent("Applications/Foo.app").path),
            "中止应发生在复制之前，B 上不能留东西")
        XCTAssertEqual(OperationJournal.shared.recent(limit: 1).first?.isOK, false)
    }
}
