import XCTest
@testable import 随手迁

/// v2.6.0 全量审查修复的回归测试。
/// 每个用例都对应一个已实证的缺陷，防止回退。
final class RegressionFixTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fix-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        MigrationManifest.directoryOverride = tempDir
        AuditLog.directoryOverride = tempDir
        // 快照节流：避免测试真的去建 APFS 快照
        UserDefaults.standard.set(Date(), forKey: "lastLocalSnapshotAt")
    }

    override func tearDownWithError() throws {
        MigrationManifest.directoryOverride = nil
        AuditLog.directoryOverride = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeDir(_ relative: String) throws -> String {
        let path = tempDir.appendingPathComponent(relative).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// 造一个「复制必然中途失败」的目录：含一个不可读文件。
    /// 实测 ditto 遇到不可读文件会退出 1 并在目标留下半截副本，正是线上失败形态
    private func makeDirWithUnreadableFile(_ relative: String) throws -> String {
        let path = try makeDir(relative)
        FileManager.default.createFile(atPath: "\(path)/ok.txt", contents: Data("good".utf8))
        FileManager.default.createFile(atPath: "\(path)/bad.txt", contents: Data("bad".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: "\(path)/bad.txt")
        return path
    }

    private func restorePermissions(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: "\(path)/bad.txt")
    }

    // MARK: - ① 已迁移应用的体积必须跟随软链接（此前恒为 0）

    func testDirectorySizeFollowsSymlink() async throws {
        let real = try makeDir("size/real")
        let blob = Data(count: 2 * 1_048_576)
        try blob.write(to: URL(fileURLWithPath: "\(real)/big.bin"))
        let link = tempDir.appendingPathComponent("size/link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        let realSize = AppScanner.directorySizeBytes(atPath: real)
        let linkSize = AppScanner.directorySizeBytes(atPath: link)

        XCTAssertGreaterThanOrEqual(realSize, 2 * 1_048_576)
        // 核心：经由软链接读到的体积不能是 0（不带 -L 的 du 会报 0，
        // 后果是界面显示 0 字节、回迁空间预检永远放行）
        XCTAssertGreaterThan(linkSize, 0, "软链接必须跟随统计目标体积")
        XCTAssertEqual(linkSize, realSize, "链接与真身的体积应一致")
    }

    // MARK: - ② 复制失败不得留下半截副本

    func testCopyWithDittoCleansPartialDestinationOnFailure() async throws {
        let src = try makeDirWithUnreadableFile("copy-src")
        let dst = tempDir.appendingPathComponent("copy-dst").path

        let migrator = AppMigrator()
        let ok = await migrator.copyWithDitto(from: src, to: dst) { _ in }
        XCTAssertFalse(ok, "含不可读文件时复制必须报告失败")

        // 半截副本必须被清掉：留着它会占住链接位，导致后续重建软链接失败
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst),
                       "失败后不能留下半截目标副本")

        restorePermissions(src)
    }

    // MARK: - ③ 回迁复制失败后，应用必须仍有入口（软链接）

    func testRestoreFailureKeepsSymlinkEntryPoint() async throws {
        let external = try makeDirWithUnreadableFile("restore/external/App.app")
        let siteDir = try makeDir("restore/site")
        let site = "\(siteDir)/App.app"
        try FileManager.default.createSymbolicLink(atPath: site, withDestinationPath: external)

        let app = AppItem(name: "App", bundleName: "App.app", path: site,
                          version: nil, size: 0, isSymlink: true,
                          symlinkTarget: external, icon: nil)
        let drive = try makeDir("restore/drive")

        let result = await AppMigrator().restore(app: app, from: drive) { _, _ in }
        XCTAssertFalse(result.success, "外置副本不可读时回迁应失败")

        // 关键：失败后链接位必须还是软链接（应用仍能启动），
        // 而不是被半截真目录占住——那样应用等于消失了
        let attrs = try FileManager.default.attributesOfItem(atPath: site)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "回迁失败后必须恢复软链接入口")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: site)
        XCTAssertEqual(destination, external, "软链接应仍指向外置副本")

        restorePermissions(external)
    }

    // MARK: - ④ 选盘：不落 Time Machine 卷、认住用户选定与用过的盘

    private func drive(_ name: String, uuid: String?, total: Int64 = 1_000) -> DriveInfo {
        DriveInfo(name: name, mountPoint: "/Volumes/\(name)", totalSize: total,
                  freeSize: total / 2, isExternal: true, volumeUUID: uuid)
    }

    func testPickPrefersPersistedUUID() {
        let candidates = [drive("Big", uuid: "AAAA", total: 9_000),
                          drive("Chosen", uuid: "BBBB", total: 1_000)]
        let picked = DiskMonitor.pickExternalDrive(
            candidates: candidates, persistedUUID: "BBBB", footprintScores: [:])
        XCTAssertEqual(picked?.name, "Chosen", "应认住用户上次选定的盘，而不是取容量最大")
    }

    func testPickPrefersFootprintWhenNoPersistedChoice() {
        let candidates = [drive("Bigger", uuid: "AAAA", total: 9_000),
                          drive("Used", uuid: "BBBB", total: 1_000)]
        let picked = DiskMonitor.pickExternalDrive(
            candidates: candidates, persistedUUID: nil,
            footprintScores: ["/Volumes/Used": 4])
        XCTAssertEqual(picked?.name, "Used", "有随手迁足迹的盘优先于容量")
    }

    func testPickFallsBackToLargest() {
        let candidates = [drive("Small", uuid: "AAAA", total: 1_000),
                          drive("Large", uuid: "BBBB", total: 9_000)]
        let picked = DiskMonitor.pickExternalDrive(
            candidates: candidates, persistedUUID: "FFFF", footprintScores: [:])
        XCTAssertEqual(picked?.name, "Large", "找不到记忆中的盘时退化为取容量最大")
    }

    func testPickReturnsNilWhenNoCandidates() {
        XCTAssertNil(DiskMonitor.pickExternalDrive(
            candidates: [], persistedUUID: "AAAA", footprintScores: [:]))
    }

    func testFootprintScoreRanksMigrationMarkers() throws {
        let bare = try makeDir("footprint/bare")
        XCTAssertEqual(VolumeClassifier.footprintScore(volumeRoot: bare), 0)

        let used = try makeDir("footprint/used")
        _ = try makeDir("footprint/used/.suishouqian-backup")
        XCTAssertGreaterThan(VolumeClassifier.footprintScore(volumeRoot: used), 0)
    }

    // MARK: - ⑤ Time Machine 目标盘解析（不依赖真实备份盘）

    func testParseTimeMachineDestinationsKeepsLocalOnly() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Destinations</key>
            <array>
                <dict>
                    <key>Kind</key><string>Local</string>
                    <key>ID</key><string>BFA13CAE-9677-42C9-9248-8BBD24E45DA4</string>
                    <key>Name</key><string>Mac Backup</string>
                    <key>MountPoint</key><string>/Volumes/Mac Backup</string>
                </dict>
                <dict>
                    <key>Kind</key><string>Network</string>
                    <key>Name</key><string>Time Capsule</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let points = VolumeClassifier.parseTimeMachineDestinations(plist: Data(xml.utf8))
        XCTAssertEqual(points, ["/Volumes/Mac Backup"], "只取本地目标的挂载点；网络目标没有挂载点")
    }

    func testParseTimeMachineDestinationsHandlesBadInput() {
        XCTAssertTrue(VolumeClassifier.parseTimeMachineDestinations(plist: nil).isEmpty)
        XCTAssertTrue(VolumeClassifier.parseTimeMachineDestinations(plist: Data("not a plist".utf8)).isEmpty)
    }

    // MARK: - ⑥ 台账校准：清幽灵记录，但绝不误清「盘离线」的断链

    func testPruneRemovesEntryWhoseLinkPathIsGone() throws {
        let linkPath = tempDir.appendingPathComponent("ghost/App.app").path
        MigrationManifest.shared.record(appName: "Ghost.app", linkPath: linkPath,
                                         volumeUUID: "AA",
                                         relativePath: "Applications/Ghost.app")

        let pruned = HealthChecker().pruneStaleManifestEntries()

        XCTAssertEqual(pruned, ["Ghost.app"])
        XCTAssertNil(MigrationManifest.shared.entry(forAppName: "Ghost.app"))
    }

    func testPruneKeepsBrokenSymlinkBecauseVolumeMayBeOffline() throws {
        let dir = try makeDir("offline")
        let linkPath = "\(dir)/App.app"
        // 断链：目标在未挂载的卷上（典型场景：外置盘没插）
        try FileManager.default.createSymbolicLink(
            atPath: linkPath, withDestinationPath: "/Volumes/NotMounted/Applications/App.app")
        MigrationManifest.shared.record(appName: "App.app", linkPath: linkPath,
                                         volumeUUID: "AA",
                                         relativePath: "Applications/App.app")

        let pruned = HealthChecker().pruneStaleManifestEntries()

        XCTAssertTrue(pruned.isEmpty, "断链（可能只是盘没插）绝不能清，否则插回盘就失去自愈依据")
        XCTAssertNotNil(MigrationManifest.shared.entry(forAppName: "App.app"))
    }

    func testPruneSkipsDataEntries() throws {
        // 数据条目在分叉场景下，链接位可能是真目录、也可能暂时不在，交给分叉对账处理
        MigrationManifest.shared.record(
            appName: "Data-ios-backup",
            linkPath: tempDir.appendingPathComponent("nowhere/MobileSync").path,
            volumeUUID: "AA", relativePath: "SuishouqianData/ios-backup", kind: "data")

        let pruned = HealthChecker().pruneStaleManifestEntries()

        XCTAssertTrue(pruned.isEmpty)
        XCTAssertNotNil(MigrationManifest.shared.entry(forAppName: "Data-ios-backup"))
    }

    // MARK: - ⑦ 备份保留期跟随设置（此前体检硬编码 7 天）

    func testBackupRetentionFollowsSetting() {
        let checker = HealthChecker()
        UserDefaults.standard.set(30, forKey: "backupRetentionDays")
        XCTAssertEqual(checker.backupRetentionDays, 30)
        UserDefaults.standard.set(0, forKey: "backupRetentionDays")
        XCTAssertEqual(checker.backupRetentionDays, 7, "未设置/非法值回落到 7 天")
        UserDefaults.standard.removeObject(forKey: "backupRetentionDays")
    }

    // MARK: - ⑨ 定时刷新绝不能触发「挂载变化」回调
    //
    // 这是"每 10 分钟误报一次外置硬盘已连接"的根因：refresh() 此前无条件回调，
    // 定时器、Time Machine 备份卷挂卸都会各触发一轮（连带全量重扫与自愈）。
    func testSilentRefreshDoesNotFireMountCallback() {
        let monitor = DiskMonitor()
        var callbacks = 0
        monitor.onMountChange = { _ in callbacks += 1 }

        // 模拟定时器刷新（默认 notifyChanges: false）
        monitor.refresh()
        monitor.refresh()

        XCTAssertEqual(callbacks, 0, "静默刷新不得回调挂载变化")
    }

    // MARK: - ⑪ 备份时间戳：刚建的备份绝不能被当"超龄"清掉

    /// 现场复现（2026-09-11 实测迁移 VS Code）：
    /// 备份经 ditto/move 得到会继承原应用的安装时间（VS Code 是 7 月 22 日），
    /// 而保留期按 mtime 判 → 审计日志出现
    /// `10:46:29 迁移成功` / `10:46:35 清理过期备份：Visual Studio Code.app（超过 7 天）`，
    /// 刚建 6 秒的备份被删，"原件留底可回滚"形同不存在
    func testStampBackupCreationKeepsFreshBackupAlive() throws {
        let backup = try makeDir("stamp/Visual Studio Code.app")
        // 模拟继承来的旧安装时间
        let installed = Date(timeIntervalSinceNow: -60 * 86400)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: backup)
        XCTAssertTrue(AppMigrator.isBackupExpired(modifiedAt: installed, retentionDays: 7),
                      "前提：继承来的旧 mtime 会被判超龄（正是被误删的原因）")

        AppMigrator().stampBackupCreation(at: backup)

        let attrs = try FileManager.default.attributesOfItem(atPath: backup)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertFalse(AppMigrator.isBackupExpired(modifiedAt: mtime, retentionDays: 7),
                       "打完创建时刻后，刚建的备份不得被判超龄")
    }

    func testBackupExpiryBoundary() {
        let now = Date()
        XCTAssertTrue(AppMigrator.isBackupExpired(
            modifiedAt: now.addingTimeInterval(-8 * 86400), now: now, retentionDays: 7))
        XCTAssertFalse(AppMigrator.isBackupExpired(
            modifiedAt: now.addingTimeInterval(-6 * 86400), now: now, retentionDays: 7))
        XCTAssertFalse(AppMigrator.isBackupExpired(
            modifiedAt: now, now: now, retentionDays: 7), "刚建的备份绝不能过期")
    }

    /// 端到端：跑一遍清理扫描，确认刚建的备份活下来、真超龄的被清掉
    func testCleanOldBackupsKeepsFreshStampedBackup() throws {
        let drive = try makeDir("cleandrive")
        let backupDir = "\(drive)/.suishouqian-backup"
        try FileManager.default.createDirectory(atPath: backupDir,
                                                withIntermediateDirectories: true)
        UserDefaults.standard.set(7, forKey: "backupRetentionDays")
        defer { UserDefaults.standard.removeObject(forKey: "backupRetentionDays") }

        let installed = Date(timeIntervalSinceNow: -60 * 86400)

        // 刚迁移出来的备份：目录 mtime 继承自原应用（60 天前），已按新逻辑打时间戳
        let fresh = "\(backupDir)/Fresh.app"
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: fresh)
        let migrator = AppMigrator()
        migrator.stampBackupCreation(at: fresh)

        // 真正超龄的备份（未打时间戳，mtime 就是 60 天前）
        let stale = "\(backupDir)/Stale.app"
        try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: stale)

        migrator.cleanOldBackups(at: drive)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh),
                      "刚建的备份必须留下——现场 bug 是 6 秒后被当超龄删掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale),
                       "真正超龄的备份应被清理")
    }

    // MARK: - ⑩ 守护 plist 对特殊卷名必须仍是合法 XML

    func testLaunchAgentPlistEscapesTrickyVolumeName() throws {
        // 卷名含 & < > " 时：此前只转义了 WatchPaths 一处，脚本内嵌的同一路径
        // 未转义，会生成非法 plist（守护装不上，插盘唤醒静默失效）
        let tricky = "/Volumes/A & B <\"x\">"
        let xml = LaunchAgentManager.plistContent(watchPath: tricky)

        var format = PropertyListSerialization.PropertyListFormat.xml
        let parsed = try PropertyListSerialization.propertyList(
            from: Data(xml.utf8), options: [], format: &format)
        guard let dict = parsed as? [String: Any] else {
            return XCTFail("生成的 plist 无法解析")
        }

        XCTAssertEqual(dict["WatchPaths"] as? [String], [tricky])
        let args = dict["ProgramArguments"] as? [String] ?? []
        XCTAssertEqual(args.count, 6, "sh -c 脚本 + $0 + 卷路径 + 应用路径")
        XCTAssertEqual(args[4], tricky, "卷路径必须以原样经 argv 传入，而不是拼进脚本")
        XCTAssertTrue(args[2].contains("$1"), "脚本从 argv 取路径")
    }
}
