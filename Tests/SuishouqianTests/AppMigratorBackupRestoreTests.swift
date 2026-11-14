import XCTest
@testable import 随手迁

/// 版本恢复的安全链：替换成功、恢复前快照保留、临时/旧副本清理干净、版本缺失不动目标。
final class AppMigratorBackupRestoreTests: XCTestCase {

    private var tempRoot: URL!
    private var journalDir: URL!
    private var previousJournalOverride: URL?

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SSQRestore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        journalDir = tempRoot.appendingPathComponent("journal")
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)
        previousJournalOverride = OperationJournal.directoryOverride
        OperationJournal.directoryOverride = journalDir
    }

    override func tearDownWithError() throws {
        OperationJournal.directoryOverride = previousJournalOverride
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 夹具

    private func makeAppBundle(at url: URL, marker: String,
                               bundleID: String = "com.ssq.test.restore") throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"),
                                                withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        <key>CFBundleExecutable</key><string>Test</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"),
                        atomically: true, encoding: .utf8)
        try marker.write(to: url.appendingPathComponent("marker.txt"),
                         atomically: true, encoding: .utf8)
    }

    private func marker(at url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("marker.txt"), encoding: .utf8)
    }

    private func appItem(target: URL) -> AppItem {
        AppItem(name: "Test", bundleName: "Test.app", path: target.path,
                version: "1.0", bundleID: "com.ssq.test.restore",
                size: 100, isSymlink: false, symlinkTarget: nil, icon: nil,
                status: .externalOnly)
    }

    // MARK: - 正向

    func testRestoreReplacesTargetAndKeepsPreRestoreSnapshot() async throws {
        let backupRoot = tempRoot.appendingPathComponent("backup").path
        let target = tempRoot.appendingPathComponent("External/Test.app")
        try makeAppBundle(at: target, marker: "current")

        let oldSource = tempRoot.appendingPathComponent("old-src")
        try makeAppBundle(at: oldSource, marker: "old")
        let version = try XCTUnwrap(BackupVersionStore.snapshot(
            directory: oldSource.path, appName: "Test.app", in: backupRoot,
            mode: .move, now: Date(timeIntervalSince1970: 1_800_000_000)))

        let result = await AppMigrator().restoreVersion(version, for: appItem(target: target))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(marker(at: target), "old", "目标应被历史版本替换")

        let versions = BackupVersionStore.listVersions(in: backupRoot, appName: "Test.app",
                                                       computeSize: false)
        XCTAssertEqual(versions.count, 2, "恢复前快照必须保留，恢复可反悔")
        let markers = versions.compactMap { try? String(contentsOfFile: "\($0.path)/marker.txt",
                                                        encoding: .utf8) }
        XCTAssertTrue(markers.contains("current"), "快照内容应是恢复前的当前版本")

        // 临时目录与旧副本不能留在用户盘上
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path)) ?? []
        XCTAssertFalse(siblings.contains { $0.contains(".ssq-old-") || $0.contains(".ssq-restore-") },
                       "交换用的临时/旧副本必须清理干净：\(siblings)")
    }

    // MARK: - 失败面

    func testMissingVersionFailsWithoutTouchingTarget() async throws {
        let target = tempRoot.appendingPathComponent("External/Test.app")
        try makeAppBundle(at: target, marker: "current")

        let missing = BackupVersion(appName: "Test.app",
                                    path: tempRoot.appendingPathComponent("gone/Test.app").path,
                                    createdAt: Date(), sizeBytes: 0,
                                    root: tempRoot.path)
        let result = await AppMigrator().restoreVersion(missing, for: appItem(target: target))

        XCTAssertFalse(result.success)
        XCTAssertEqual(marker(at: target), "current", "版本缺失时目标必须原样保留")
    }

    func testNonBundleVersionIsRejectedBeforeSwap() async throws {
        let backupRoot = tempRoot.appendingPathComponent("backup").path
        let target = tempRoot.appendingPathComponent("External/Test.app")
        try makeAppBundle(at: target, marker: "current")

        // 不是应用包的"历史版本"（没有 Contents/Info.plist）
        let junk = tempRoot.appendingPathComponent("junk-src")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        try "not an app".write(to: junk.appendingPathComponent("README.txt"),
                               atomically: true, encoding: .utf8)
        let version = try XCTUnwrap(BackupVersionStore.snapshot(
            directory: junk.path, appName: "Test.app", in: backupRoot, mode: .move))

        let result = await AppMigrator().restoreVersion(version, for: appItem(target: target))

        XCTAssertFalse(result.success, "非应用包必须在交换前被拦下")
        XCTAssertEqual(marker(at: target), "current")
    }
}
