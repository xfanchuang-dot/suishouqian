import XCTest
@testable import 随手迁

/// 操作日志与撤销规划：存储走 directoryOverride 注入；UndoPlanner 纯逻辑
final class OperationJournalTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        OperationJournal.directoryOverride = tempDir
    }

    override func tearDownWithError() throws {
        OperationJournal.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func journal() -> OperationJournal { .shared }

    private func waitJournalIdle() {
        // record/markUndone 是 queue.async，读回来即说明队列已消化到该点
        _ = journal().recent(limit: 1)
    }

    private func entry(app: String, op: JournalOperation = .migrate,
                       result: String = "ok") -> JournalEntry {
        JournalEntry(id: UUID(), at: Date(), op: op, appName: app,
                     params: ["volumeUUID": "V1"], result: result,
                     snapshotID: nil, backupPath: nil, undoneBy: nil)
    }

    // MARK: - 记录与读取

    func testRecordAndRecentOrdering() throws {
        journal().record(op: .migrate, appName: "A.app", result: "ok")
        Thread.sleep(forTimeInterval: 0.05)
        journal().record(op: .restore, appName: "B.app", result: "ok")
        waitJournalIdle()

        let recent = journal().recent(limit: 10)
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent.first?.appName, "B.app", "倒序：最近的在前")
        XCTAssertEqual(recent.first?.isOK, true)
    }

    func testFailedOperationIsRecordedButNotUndoable() throws {
        journal().record(op: .migrate, appName: "C.app",
                         result: "failed: 目标盘空间不足")
        waitJournalIdle()
        let e = journal().recent(limit: 1).first!
        XCTAssertFalse(e.isOK)
        let plan = UndoPlanner.plan(entry: e, context: .init(
            appRunning: false, trashContainsApp: true, externalCopyExists: true,
            internalCopyExists: true, linkUsable: true, originVolumeOnline: true,
            internalFreeBytes: 1 << 60, externalFreeBytes: 1 << 60, appSize: 1 << 30))
        XCTAssertFalse(plan.feasible)
        XCTAssertTrue(plan.message.contains("失败"))
    }

    func testMarkUndonePreventsDoubleUndo() throws {
        let e = entry(app: "D.app")
        // 直接构造文件写入（record 不带自定义 entry 的入口）；journal 是 JSON Lines
        let url = tempDir.appendingPathComponent("operation-journal.jsonl")
        let lineData = try JSONEncoder().encode(e)
        try String(data: lineData, encoding: .utf8)!.write(to: url, atomically: true,
                                                           encoding: .utf8)

        journal().markUndone(id: e.id, by: UUID())
        Thread.sleep(forTimeInterval: 0.1)
        waitJournalIdle()

        let loaded = journal().recent(limit: 5).first!
        XCTAssertTrue(loaded.isUndone)
        let plan = UndoPlanner.plan(entry: loaded, context: .init(
            appRunning: false, trashContainsApp: true, externalCopyExists: true,
            internalCopyExists: true, linkUsable: true, originVolumeOnline: true,
            internalFreeBytes: 1 << 60, externalFreeBytes: 1 << 60, appSize: 1 << 30))
        XCTAssertFalse(plan.feasible)
        XCTAssertTrue(plan.message.contains("撤销过"))
    }

    // MARK: - UndoPlanner

    private func context(running: Bool = false, trash: Bool = false,
                         externalCopy: Bool = true, internalCopy: Bool = true,
                         originOnline: Bool = true,
                         internalFree: Int64 = 1 << 60, externalFree: Int64 = 1 << 60,
                         size: Int64 = 2 << 30) -> UndoPlanner.UndoContext {
        .init(appRunning: running, trashContainsApp: trash,
              externalCopyExists: externalCopy, internalCopyExists: internalCopy,
              linkUsable: true, originVolumeOnline: originOnline,
              internalFreeBytes: internalFree, externalFreeBytes: externalFree,
              appSize: size)
    }

    func testUndoMigrateRequiresExternalCopyAndInternalSpace() {
        let e = entry(app: "E.app", op: .migrate)
        XCTAssertEqual(UndoPlanner.plan(entry: e, context: context()).inverseOp, .restore)
        XCTAssertFalse(UndoPlanner.plan(entry: e,
                                        context: context(externalCopy: false)).feasible)
        XCTAssertFalse(UndoPlanner.plan(entry: e,
                                        context: context(internalFree: 1 << 30)).feasible,
                       "内置盘空间小于应用体积时拒绝回迁撤销")
    }

    func testUndoRestoreRequiresInternalCopyAndTwoCopyExternalSpace() {
        let e = entry(app: "F.app", op: .restore)
        let plan = UndoPlanner.plan(entry: e, context: context())
        XCTAssertEqual(plan.inverseOp, .migrate)

        // 外置盘要有"两份+5%"：AppMigrator.requiredTargetBytes(2GB) ≈ 4.2GB
        XCTAssertFalse(UndoPlanner.plan(
            entry: e,
            context: context(externalFree: Int64(Double(2 << 30) * 1.1))).feasible)
        XCTAssertTrue(UndoPlanner.plan(
            entry: e,
            context: context(externalFree: AppMigrator.requiredTargetBytes(
                appSize: 2 << 30))).feasible)
        XCTAssertFalse(UndoPlanner.plan(entry: e,
                                        context: context(internalCopy: false)).feasible)
    }

    func testUndoRelocateRequiresOriginOnline() {
        let e = entry(app: "G.app", op: .relocate)
        XCTAssertEqual(UndoPlanner.plan(entry: e, context: context()).inverseOp, .relocate)
        let offline = UndoPlanner.plan(entry: e, context: context(originOnline: false))
        XCTAssertFalse(offline.feasible)
        XCTAssertTrue(offline.message.contains("不在线"))
    }

    func testUndoUninstallSpecialTrashPath() {
        let e = entry(app: "H.app", op: .uninstall)
        let ok = UndoPlanner.plan(entry: e, context: context(trash: true))
        XCTAssertTrue(ok.feasible)
        XCTAssertNil(ok.inverseOp, "卸载撤销走废纸篓特殊路径，不走常规逆操作")
        let gone = UndoPlanner.plan(entry: e, context: context(trash: false))
        XCTAssertFalse(gone.feasible)
        XCTAssertTrue(gone.message.contains("废纸篓"))
    }

    func testRunningAppAlwaysBlocksUndo() {
        for op in [JournalOperation.migrate, .restore, .moveBack, .relocate] {
            let e = entry(app: "I.app", op: op)
            let plan = UndoPlanner.plan(entry: e, context: context(running: true))
            XCTAssertFalse(plan.feasible, "\(op) 的撤销也必须拦运行中的应用")
            XCTAssertTrue(plan.message.contains("正在运行"))
        }
    }

    func testInverseTable() {
        XCTAssertEqual(JournalOperation.migrate.inverse, .restore)
        XCTAssertEqual(JournalOperation.restore.inverse, .migrate)
        XCTAssertEqual(JournalOperation.moveBack.inverse, .migrate)
        XCTAssertEqual(JournalOperation.remigrate.inverse, .restore)
        XCTAssertEqual(JournalOperation.relocate.inverse, .relocate)
        XCTAssertNil(JournalOperation.uninstall.inverse)
        XCTAssertNil(JournalOperation.undo.inverse)
    }
}
