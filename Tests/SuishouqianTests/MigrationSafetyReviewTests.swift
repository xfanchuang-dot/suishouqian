import XCTest
@testable import 随手迁

/// 2026-11 审查回归：迁移标记不能在源已经切走后删掉唯一副本；
/// 建链失败且原件搬不回去时，已校验副本必须留下。
final class MigrationSafetyReviewTests: XCTestCase {

    private var root: URL!
    private var drive: URL!
    private var manifestDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("safety-review-\(UUID().uuidString)", isDirectory: true)
        drive = root.appendingPathComponent("Drive", isDirectory: true)
        try fm.createDirectory(
            at: drive.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        manifestDir = root.appendingPathComponent("Manifest", isDirectory: true)
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = manifestDir
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        UserDefaults.standard.removeObject(forKey: "lastLocalSnapshotAt")
        try? fm.removeItem(at: root)
    }

    private final class NoGuardMigrator: AppMigrator {
        override func validateTarget(
            drivePath: String, appSize: Int64,
            expectedVolumeUUID: String? = nil,
            reservesBackupCopy: Bool = true
        ) -> String? { nil }
    }

    /// 第一次搬移成功；第二次把原件搬回失败，用来钉住「失败不许删已校验副本」。
    private final class RollbackFailsMigrator: NoGuardMigrator {
        override func moveItem(from src: String, to dst: String) async -> Bool {
            if src.contains(".suishouqian-backup") { return false }
            let ok = await super.moveItem(from: src, to: dst)
            if ok, dst.contains(".suishouqian-backup") {
                // 占住源路径，让随后的 createSymbolicLink 失败，从而走进回滚分支
                FileManager.default.createFile(atPath: src, contents: Data("block".utf8))
            }
            return ok
        }
    }

    private func makeApp(named name: String = "X.app") throws -> (app: AppItem, sourcePath: String) {
        let sourceRoot = root.appendingPathComponent("Apps", isDirectory: true)
        let appURL = sourceRoot.appendingPathComponent(name)
        try fm.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("macho".utf8).write(to: appURL.appendingPathComponent("Contents/MacOS/bin"))
        try Data("plist".utf8).write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        let app = AppItem(name: String(name.dropLast(4)), bundleName: name, path: appURL.path,
                          version: nil, size: 1, isSymlink: false, symlinkTarget: nil, icon: nil)
        return (app, appURL.path)
    }

    func testMarkedTargetNotDeletedWhenSourceIsSymlinkOrMissing() throws {
        let source = root.appendingPathComponent("Apps/X.app")
        let target = drive.appendingPathComponent("Applications/X.app")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertTrue(AppMigrator.markedTargetMayBeDeleted(
            sourcePath: source.path, targetPath: target.path))

        try fm.removeItem(at: source)
        try fm.createSymbolicLink(at: source, withDestinationURL: target)
        XCTAssertFalse(AppMigrator.markedTargetMayBeDeleted(
            sourcePath: source.path, targetPath: target.path),
                       "源已是指向目标的链接时，目标就是正在使用的副本")

        try fm.removeItem(at: source)
        XCTAssertFalse(AppMigrator.markedTargetMayBeDeleted(
            sourcePath: source.path, targetPath: target.path),
                       "源已经不在时不能把目标当半截遗留删掉")
    }

    /// 清标记前崩溃再重试：链接已经指向目标。重试必须原样留下目标里的内容。
    func testRetryAfterSwitchKeepsSoleCopy() async throws {
        let (app, sourcePath) = try makeApp()
        let target = drive.appendingPathComponent("Applications/X.app")
        let migrator = NoGuardMigrator()
        let first = await migrator.migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }
        XCTAssertTrue(first.success, first.error ?? "")

        let sentinel = target.appendingPathComponent("Contents/only-on-target.txt")
        try Data("ONLY".utf8).write(to: sentinel)
        fm.createFile(atPath: target.path + AppMigrator.relocationMarkerSuffix, contents: nil)

        let second = await migrator.migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }
        XCTAssertTrue(second.success, second.error ?? "")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "ONLY",
                       "重试不能删掉已经切换完成的唯一副本再从链接重拷")
        XCTAssertTrue(AppMigrator.pathsIdentifySameItem(
            try fm.destinationOfSymbolicLink(atPath: sourcePath), target.path))
        XCTAssertFalse(fm.fileExists(atPath: target.path + AppMigrator.relocationMarkerSuffix))
    }

    /// 源已经删掉、标记还在、目标是完整副本：补建链接，不能先把目标删了。
    func testMissingSourceWithMarkerRelinksWithoutDeletingTarget() async throws {
        let source = root.appendingPathComponent("Apps/X.app")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = drive.appendingPathComponent("Applications/X.app")
        try fm.createDirectory(
            at: target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("macho".utf8).write(to: target.appendingPathComponent("Contents/MacOS/bin"))
        try Data("plist".utf8).write(to: target.appendingPathComponent("Contents/Info.plist"))
        try Data("ONLY".utf8).write(to: target.appendingPathComponent("Contents/only-on-target.txt"))
        fm.createFile(atPath: target.path + AppMigrator.relocationMarkerSuffix, contents: nil)

        let app = AppItem(name: "X", bundleName: "X.app", path: source.path,
                          version: nil, size: 1, isSymlink: false, symlinkTarget: nil, icon: nil)
        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("Contents/only-on-target.txt"),
                                  encoding: .utf8), "ONLY")
        XCTAssertTrue(AppMigrator.pathsIdentifySameItem(
            try fm.destinationOfSymbolicLink(atPath: source.path), target.path))
    }

    /// 源仍是真目录时，带标记的半截副本仍然要清掉重拷（中断恢复契约不能被收紧弄坏）。
    func testIncompleteMarkedTargetIsReplacedWhenSourceIsReal() async throws {
        let (app, _) = try makeApp()
        let target = drive.appendingPathComponent("Applications/X.app")
        try fm.createDirectory(at: target.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: target.appendingPathComponent("Contents/Info.plist"))
        fm.createFile(atPath: target.path + AppMigrator.relocationMarkerSuffix, contents: nil)

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Contents/MacOS/bin").path),
                      "源还在时，半截目标应该被完整重拷")
    }

    func testLinkFailureKeepsVerifiedCopyWhenRollbackFails() async throws {
        let (app, sourcePath) = try makeApp()
        let target = drive.appendingPathComponent("Applications/X.app")
        let result = await RollbackFailsMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: false) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains(target.path) == true, result.error ?? "")
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path),
                      "原件搬不回去时，已校验的目标副本不能删")
        XCTAssertTrue(fm.fileExists(atPath: sourcePath) || fm.fileExists(
            atPath: drive.appendingPathComponent(".suishouqian-backup/X.app").path))
    }
}
