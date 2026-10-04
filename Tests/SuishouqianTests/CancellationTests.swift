import XCTest
@testable import 随手迁

/// 协作式取消：CancellationToken 引用语义 + MigrationTask 携带
final class CancellationTests: XCTestCase {

    func testTokenStartsUncancelled() {
        let token = CancellationToken()
        XCTAssertFalse(token.isCancelled)
    }

    func testCancelSetsFlag() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    /// 引用语义：Task 是 struct，进度回调里 `var t = ...` 会拷贝整个 struct；
    /// token 必须是 class，否则取消信号被拷贝稀释、管道收不到。
    func testTokenSurvivesStructCopy() {
        let app = AppItem(
            name: "X", bundleName: "X.app", path: "/Applications/X.app",
            version: nil, size: 1, isSymlink: false, symlinkTarget: nil, icon: nil)
        let task = MigrationTask(app: app, operation: .migrate)
        var copy = task          // 模拟进度回调里的 struct 拷贝
        copy.progress = 0.5
        task.cancellationToken.cancel()   // 从原 task 取消
        XCTAssertTrue(copy.cancellationToken.isCancelled,
                      "拷贝后的 task 必须共享同一个 token")
    }

    func testCancelledResultFlag() {
        let r = AppMigrator.MigrationResult(
            success: false, error: "已取消", spaceSaved: 0, cancelled: true)
        XCTAssertTrue(r.cancelled)
        XCTAssertFalse(r.success)
    }

    func testDefaultResultNotCancelled() {
        let r = AppMigrator.MigrationResult(success: true, spaceSaved: 100)
        XCTAssertFalse(r.cancelled)
    }

    func testTaskStatusCancelledIsTerminal() {
        XCTAssertTrue(MigrationTask.TaskStatus.cancelled.isTerminal)
        XCTAssertEqual(MigrationTask.TaskStatus.cancelled,
                        MigrationTask.TaskStatus.cancelled)
        XCTAssertNotEqual(MigrationTask.TaskStatus.cancelled,
                           MigrationTask.TaskStatus.completed)
    }
}

/// 放行 validateTarget（temp 目录不是挂载点；挂载点护栏语义由 relocate 系测试覆盖）
private final class NoGuardMigrator: AppMigrator {
    override func validateTarget(drivePath: String, appSize: Int64) -> String? { nil }
}

/// 端到端取消安全：阶段边界取消必须"源应用完好 + 只清目标副本"。
/// （回归背景：取消清理曾放在 move 之后，把装着原件唯一真身的备份一起删掉——P0）
final class CancelSafetyE2ETests: XCTestCase {

    func testCancelledMigrateKeepsSourceIntactAndCleansTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-e2e-\(UUID().uuidString)", isDirectory: true)
        let drive = root.appendingPathComponent("Drive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: drive.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceRoot = root.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceRoot.appendingPathComponent("X.app/Contents/MacOS"),
            withIntermediateDirectories: true)
        try Data("macho".utf8).write(
            to: sourceRoot.appendingPathComponent("X.app/Contents/MacOS/bin"))
        try Data("plist".utf8).write(
            to: sourceRoot.appendingPathComponent("X.app/Contents/Info.plist"))

        let app = AppItem(name: "X", bundleName: "X.app",
                          path: sourceRoot.appendingPathComponent("X.app").path,
                          version: nil, size: 1, isSymlink: false,
                          symlinkTarget: nil, icon: nil)

        // 快照节流：预置时间戳避免真去建 APFS 快照
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")
        defer { UserDefaults.standard.removeObject(forKey: "lastLocalSnapshotAt") }

        let token = CancellationToken()
        token.cancel()   // 预先取消：复制照跑（无害），阶段边界必须停下并清理

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true,
            cancellationToken: token) { _, _ in }

        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.success)
        // 源应用分毫不动
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sourceRoot.appendingPathComponent("X.app").path), "源应用不能被动")
        // 目标副本已清理
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: drive.appendingPathComponent("Applications/X.app").path))
        // 源位置没有被挂上错误产物
        let sourceContents = try FileManager.default.contentsOfDirectory(
            atPath: sourceRoot.path)
        XCTAssertEqual(sourceContents, ["X.app"])
    }
}
