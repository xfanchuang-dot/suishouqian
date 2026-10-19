import XCTest
@testable import 随手迁

/// 更新助手引擎层：skipBackup（纯搬迁＝跳过备份）与 targetSubdir（"搬回去"精确还原）。
/// 回归背景：Muse 首版 skipBackup 分支漏建软链接（P0）、建链失败会删唯一副本（P0），
/// 这组测试把两条红线钉死。
final class SkipBackupMigrationTests: XCTestCase {

    private var root: URL!
    private var drive: URL!
    private var manifestDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("skip-backup-\(UUID().uuidString)", isDirectory: true)
        drive = root.appendingPathComponent("Drive", isDirectory: true)
        try fm.createDirectory(
            at: drive.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        manifestDir = root.appendingPathComponent("Manifest", isDirectory: true)
        try fm.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = manifestDir
        // 快照节流：预置时间戳避免真去建 APFS 快照
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        UserDefaults.standard.removeObject(forKey: "lastLocalSnapshotAt")
        try? fm.removeItem(at: root)
    }

    /// 复用 NoGuardMigrator 手法：temp 目录不是挂载点，放行 validateTarget
    /// （挂载点护栏语义由 relocate 系测试覆盖）
    private final class NoGuardMigrator: AppMigrator {
        override func validateTarget(drivePath: String, appSize: Int64) -> String? { nil }
    }

    @discardableResult
    private func makeApp() throws -> (app: AppItem, sourcePath: String) {
        let sourceRoot = root.appendingPathComponent("Apps", isDirectory: true)
        try fm.createDirectory(
            at: sourceRoot.appendingPathComponent("X.app/Contents/MacOS"),
            withIntermediateDirectories: true)
        try Data("macho".utf8).write(
            to: sourceRoot.appendingPathComponent("X.app/Contents/MacOS/bin"))
        try Data("plist".utf8).write(
            to: sourceRoot.appendingPathComponent("X.app/Contents/Info.plist"))
        let path = sourceRoot.appendingPathComponent("X.app").path
        let app = AppItem(name: "X", bundleName: "X.app", path: path,
                          version: nil, size: 1, isSymlink: false, symlinkTarget: nil, icon: nil)
        return (app, path)
    }

    /// 更新助手"搬回去"主路径：skipBackup + 留链接。
    /// P0 回归钉：无备份模式下源位置必须重建软链接（首版漏建＝应用从 /Applications 消失）
    func testSkipBackupWithLinkRebuildsSymlinkAndLeavesNoBackup() async throws {
        let (app, sourcePath) = try makeApp()

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "未知错误")
        XCTAssertTrue((try? fm.destinationOfSymbolicLink(atPath: sourcePath)) != nil,
                      "skipBackup + createLink 必须在源位置重建软链接")
        XCTAssertEqual(try? fm.destinationOfSymbolicLink(atPath: sourcePath),
                       drive.appendingPathComponent("Applications/X.app").path)
        XCTAssertTrue(fm.fileExists(
            atPath: drive.appendingPathComponent("Applications/X.app/Contents/Info.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: BackupLocations.backupRoot(for: drive.path)),
                       "skipBackup 不得创建 .suishouqian-backup 留底")
        // 台账照常记录（temp 目录在根卷上，volumeUUID 可取）
        XCTAssertEqual(MigrationManifest.shared.entry(forAppName: "X.app")?.relativePath,
                       "Applications/X.app")
    }

    /// skipBackup + 不留链接（原"纯搬迁"原住民搬回原位）：无链接、无台账、无备份
    func testSkipBackupWithoutLinkLeavesNoManifestNoBackup() async throws {
        let (app, sourcePath) = try makeApp()

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: false, skipBackup: true) { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "未知错误")
        XCTAssertFalse(fm.fileExists(atPath: sourcePath),
                       "不留链接时源位置不应残留任何东西")
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: sourcePath))
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "X.app"))
        XCTAssertFalse(fm.fileExists(atPath: BackupLocations.backupRoot(for: drive.path)))
    }

    /// targetSubdir：搬回去要精确还原原位置（Suishouqian_Apps/ 住民不能被搬去 Applications/）
    func testTargetSubdirRestoresExactLocation() async throws {
        let (app, _) = try makeApp()
        try fm.createDirectory(
            at: drive.appendingPathComponent("Suishouqian_Apps"), withIntermediateDirectories: true)

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true,
            targetSubdir: "Suishouqian_Apps") { _, _ in }

        XCTAssertTrue(result.success, result.error ?? "未知错误")
        XCTAssertTrue(fm.fileExists(
            atPath: drive.appendingPathComponent("Suishouqian_Apps/X.app").path))
        XCTAssertFalse(fm.fileExists(
            atPath: drive.appendingPathComponent("Applications/X.app").path),
            "不得在默认 Applications/ 萃出第二份")
        XCTAssertEqual(MigrationManifest.shared.entry(forAppName: "X.app")?.relativePath,
                       "Suishouqian_Apps/X.app")
    }

    /// P0 回归钉：skipBackup 建链失败时绝不丢应用。
    /// 源父目录只读逼出失败分支——删源与建链都失败，应用必须仍然"至少一份完好副本"，
    /// 且失败路径绝不能把唯一校验通过的目标副本删掉（首版会在 catch 里删目标＝数据丢失）
    func testSkipBackupLinkFailureNeverLosesApp() async throws {
        let (app, sourcePath) = try makeApp()
        let targetPath = drive.appendingPathComponent("Applications/X.app").path
        let parent = (sourcePath as NSString).deletingLastPathComponent
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }

        let result = await NoGuardMigrator().migrateInternal(
            app: app, to: drive.path, createLink: true, skipBackup: true) { _, _ in }

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("符号链接") == true,
                      "应如实报建链失败，实际：\(result.error ?? "nil")")
        let sourceAlive = fm.fileExists(atPath: sourcePath)
        let targetAlive = fm.fileExists(atPath: targetPath)
        XCTAssertTrue(sourceAlive || targetAlive,
                      "无备份模式下失败必须保住至少一份应用副本，现在两处皆无＝数据丢失")
        // 两处都在也不算坏（目标副本是校验过的真身，删除它才是本次回归要拦的行为）
        if sourceAlive {
            XCTAssertTrue(fm.fileExists(
                atPath: sourcePath + "/Contents/Info.plist"), "源副本必须完整")
        }
    }
}

/// UpdateSession 持久化（UserDefaults 独立 suite 测试缝）
final class UpdateSessionStoreTests: XCTestCase {

    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "updatesession-tests-\(UUID().uuidString)"
        UpdateSessionStore.defaultsOverride = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        UpdateSessionStore.defaultsOverride = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeSession(appName: String = "Demo.app") -> UpdateSession {
        UpdateSession(bundleID: "com.example.demo", appName: appName,
                      appPath: "/Applications/\(appName)",
                      originalExternalPath: "/Volumes/X/Applications/\(appName)",
                      wasMigrated: true)
    }

    func testRoundtrip() throws {
        let sessions = [makeSession(), makeSession(appName: "Other.app")]
        UpdateSessionStore.save(sessions)
        let loaded = UpdateSessionStore.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].id, sessions[0].id)
        XCTAssertEqual(loaded[0].bundleID, "com.example.demo")
        XCTAssertEqual(loaded[0].originalExternalPath, "/Volumes/X/Applications/Demo.app")
        XCTAssertTrue(loaded[0].wasMigrated)
    }

    func testLoadMissingReturnsEmpty() {
        XCTAssertTrue(UpdateSessionStore.load().isEmpty)
    }

    func testLoadCorruptedReturnsEmpty() throws {
        UpdateSessionStore.defaultsOverride?.set(Data("not json".utf8),
                                                 forKey: "updateSessions.v1")
        XCTAssertTrue(UpdateSessionStore.load().isEmpty,
                      "损坏数据按空会话处理，不崩不误报")
    }
}

/// targetSubdir 纯函数：从原外置路径提取还原子目录
final class UpdateSessionTargetSubdirTests: XCTestCase {

    func testApplicationsSubdir() {
        XCTAssertEqual(
            UpdateSession.targetSubdir(of: "/Volumes/X/Applications/A.app",
                                       volumeMount: "/Volumes/X"),
            "Applications")
    }

    func testSuishouqianAppsSubdir() {
        XCTAssertEqual(
            UpdateSession.targetSubdir(of: "/Volumes/X/Suishouqian_Apps/A.app",
                                       volumeMount: "/Volumes/X"),
            "Suishouqian_Apps")
    }

    func testVolumeRootPlacementReturnsNil() {
        XCTAssertNil(
            UpdateSession.targetSubdir(of: "/Volumes/X/A.app", volumeMount: "/Volumes/X"),
            "卷根直放没有子目录，返回 nil 由调用方决定去向")
    }

    func testForeignVolumeReturnsNil() {
        XCTAssertNil(
            UpdateSession.targetSubdir(of: "/Volumes/Y/Applications/A.app",
                                       volumeMount: "/Volumes/X"),
            "原路径不在目标卷上（盘换过挂载名/换过盘）时返回 nil")
    }
}
