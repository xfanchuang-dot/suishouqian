import XCTest
@testable import 随手迁

/// 版本化备份的存储层：布局、归档、裁剪、删除边界。
/// 守的是"免费用户行为零变化"和"历史版本不会被误删/误当孤儿"。
final class BackupVersionStoreTests: XCTestCase {

    private var root: String!
    private var fileManager: FileManager!

    override func setUp() {
        super.setUp()
        fileManager = .default
        root = NSTemporaryDirectory() + "BackupVersionStoreTests-\(UUID().uuidString)"
        try? fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fileManager.removeItem(atPath: root)
        super.tearDown()
    }

    // MARK: - 夹具

    @discardableResult
    private func makeBackup(named name: String, marker: String = "v1") -> String {
        let path = "\(root!)/\(name)"
        try? fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
        try? marker.write(toFile: "\(path)/marker.txt", atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - 归档

    func testArchiveMovesCurrentBackupIntoVersionStore() {
        let backup = makeBackup(named: "X.app", marker: "original")

        let version = BackupVersionStore.archiveCurrentBackup(
            backupPath: backup, appName: "X.app", in: root, entitled: true,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNotNil(version)
        XCTAssertFalse(fileManager.fileExists(atPath: backup),
                       "归档是 move：当前备份位置应腾空，等待新备份写入")
        XCTAssertTrue(fileManager.fileExists(atPath: version!.path))
        XCTAssertTrue(version!.path.contains("/.versions/X.app/"))
        XCTAssertEqual(try? String(contentsOfFile: "\(version!.path)/marker.txt", encoding: .utf8),
                       "original")
    }

    func testFreeUserArchiveIsNoOp() {
        let backup = makeBackup(named: "Y.app")

        let version = BackupVersionStore.archiveCurrentBackup(
            backupPath: backup, appName: "Y.app", in: root, entitled: false)

        XCTAssertNil(version, "免费用户不产生历史版本")
        XCTAssertTrue(fileManager.fileExists(atPath: backup), "免费用户的当前备份必须原地不动")
        XCTAssertFalse(fileManager.fileExists(atPath: BackupVersionStore.versionsDirectory(in: root)))
    }

    func testArchiveMissingBackupReturnsNil() {
        XCTAssertNil(BackupVersionStore.archiveCurrentBackup(
            backupPath: "\(root!)/Nope.app", appName: "Nope.app",
            in: root, entitled: true))
    }

    // MARK: - 裁剪

    func testPruneKeepsNewestFive() {
        // 连续 7 次：每次建新备份再归档，模拟反复迁移
        for i in 0..<7 {
            let backup = makeBackup(named: "Big.app", marker: "v\(i)")
            let now = Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 3600)
            _ = BackupVersionStore.snapshot(directory: backup, appName: "Big.app",
                                            in: root, mode: .move, now: now)
        }

        let versions = BackupVersionStore.listVersions(in: root, appName: "Big.app",
                                                       computeSize: false)
        XCTAssertEqual(versions.count, BackupVersionStore.maxVersionsPerApp,
                       "每个应用只保留最近 \(BackupVersionStore.maxVersionsPerApp) 个版本")
        // 最新在前：最后一个快照的 marker 应是 v6
        let newest = versions.first!
        XCTAssertEqual(try? String(contentsOfFile: "\(newest.path)/marker.txt", encoding: .utf8),
                       "v6")
    }

    func testPruneDeleteOnlyTimestampDirectories() {
        let appDir = BackupVersionStore.appVersionsDirectory(in: root, appName: "Z.app")
        try? fileManager.createDirectory(atPath: "\(appDir)/keepme", withIntermediateDirectories: true)
        for i in 0..<3 {
            let backup = makeBackup(named: "Z.app", marker: "v\(i)")
            _ = BackupVersionStore.snapshot(
                directory: backup, appName: "Z.app", in: root, mode: .move,
                now: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
        BackupVersionStore.prune(appName: "Z.app", in: root, keep: 1)
        XCTAssertTrue(fileManager.fileExists(atPath: "\(appDir)/keepme"),
                      "裁剪只删时间戳目录，不碰其他内容")
    }

    // MARK: - 同秒冲突

    func testSameSecondSnapshotsGetDistinctDirectories() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = makeBackup(named: "Dup.app", marker: "a")
        _ = BackupVersionStore.snapshot(directory: a, appName: "Dup.app",
                                        in: root, mode: .move, now: now)
        let b = makeBackup(named: "Dup.app", marker: "b")
        _ = BackupVersionStore.snapshot(directory: b, appName: "Dup.app",
                                        in: root, mode: .move, now: now)

        let versions = BackupVersionStore.listVersions(in: root, appName: "Dup.app",
                                                       computeSize: false)
        XCTAssertEqual(versions.count, 2, "同一秒两次归档不能互相覆盖")
        XCTAssertEqual(Set(versions.map(\.path)).count, 2)
    }

    // MARK: - 删除边界

    func testDeleteRefusesPathOutsideVersionsDirectory() {
        _ = makeBackup(named: "A.app")
        let outside = BackupVersion(appName: "A.app",
                                    path: "\(root!)/A.app",
                                    createdAt: Date(), sizeBytes: 0, root: root)
        XCTAssertFalse(BackupVersionStore.delete(outside), "当前备份不允许从版本入口删除")
        XCTAssertTrue(fileManager.fileExists(atPath: "\(root!)/A.app"),
                      "拒绝删除后目录必须原样保留")
    }

    func testDeleteRemovesVersionDirectory() {
        let backup = makeBackup(named: "Del.app")
        let version = BackupVersionStore.snapshot(directory: backup, appName: "Del.app",
                                                  in: root, mode: .move)!
        XCTAssertTrue(BackupVersionStore.delete(version))
        XCTAssertFalse(fileManager.fileExists(atPath: version.path))
    }

    // MARK: - 时间戳

    func testVersionStampRecognition() {
        XCTAssertTrue(BackupVersionStore.isVersionStamp("20261114-123000"))
        XCTAssertTrue(BackupVersionStore.isVersionStamp("20261114-123000-2"))
        XCTAssertFalse(BackupVersionStore.isVersionStamp("keepme"))
        XCTAssertFalse(BackupVersionStore.isVersionStamp("2026-11-14"))
        XCTAssertFalse(BackupVersionStore.isVersionStamp(""))
    }
}
