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

    /// 端到端：跑一遍清理扫描，确认三条规则同时成立
    /// ① 刚建的备份活下来（原现场 bug：建好 6 秒后被当超龄清掉）
    /// ② 超龄且"另有可用副本"的备份 → 允许自动清理
    /// ③ 超龄且"可能是唯一副本"的备份 → 必须原样保留（v3.0.1：此前会被永久删除）
    ///
    /// 注意：这里只断言"保留/允许清理"的判定与最终文件状态，不断言真的进了废纸篓——
    /// `swift test` 是无 GUI 会话的进程，NSWorkspace.recycle 未必可用，那会是环境相关的不稳定断言。
    func testCleanOldBackupsKeepsFreshAndLastResortBackups() async throws {
        let drive = try makeDir("cleandrive")
        // 冒充 /Applications：真身在不在，决定备份是不是"唯一副本"
        let appsRoot = try makeDir("cleandrive-apps")
        let backupDir = "\(drive)/.suishouqian-backup"
        try FileManager.default.createDirectory(atPath: backupDir,
                                                withIntermediateDirectories: true)
        UserDefaults.standard.set(7, forKey: "backupRetentionDays")
        defer { UserDefaults.standard.removeObject(forKey: "backupRetentionDays") }

        let installed = Date(timeIntervalSinceNow: -60 * 86400)
        let migrator = AppMigrator()

        // ① 刚迁移出来的备份：目录 mtime 继承自原应用（60 天前），已按新逻辑打时间戳
        let fresh = "\(backupDir)/Fresh.app"
        try FileManager.default.createDirectory(atPath: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: fresh)
        migrator.stampBackupCreation(at: fresh)

        // ② 超龄但应用仍有可用副本（/Applications 里的真身还在）→ 允许自动清理
        let redundant = "\(backupDir)/Redundant.app"
        try FileManager.default.createDirectory(atPath: redundant, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: redundant)
        _ = try makeDir("cleandrive-apps/Redundant.app")
        XCTAssertTrue(migrator.canAutoCleanBackup(named: "Redundant.app", drivePath: drive,
                                                  applicationsRoot: appsRoot),
                      "应用本体还在时，超龄备份可以自动清理")

        // ③ 超龄且哪里都没有可用副本（更新器把真身弄丢的形态）→ 备份就是唯一退路
        let lastResort = "\(backupDir)/LastResort.app"
        try FileManager.default.createDirectory(atPath: lastResort, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: installed],
                                             ofItemAtPath: lastResort)
        XCTAssertFalse(migrator.canAutoCleanBackup(named: "LastResort.app", drivePath: drive,
                                                   applicationsRoot: appsRoot),
                       "没有任何可用副本时，备份必须留给人工确认")

        await migrator.cleanOldBackups(at: drive, applicationsRoot: appsRoot)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh),
                      "刚建的备份必须留下——现场 bug 是 6 秒后被当超龄删掉")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lastResort),
                      "可能是唯一副本的备份绝不能被自动清理")
    }

    /// 纯逻辑：允许自动清理的唯一条件是"另有可用副本"
    func testBackupAutoCleanRequiresAnotherUsableCopy() {
        XCTAssertTrue(AppMigrator.backupCanBeAutoCleaned(appLinkUsable: true,
                                                         externalCopyExists: false))
        XCTAssertTrue(AppMigrator.backupCanBeAutoCleaned(appLinkUsable: false,
                                                         externalCopyExists: true))
        XCTAssertFalse(AppMigrator.backupCanBeAutoCleaned(appLinkUsable: false,
                                                          externalCopyExists: false))
    }

    /// 空间预检必须按"两份"算：目标副本 + 同盘留底备份。
    /// 此前按一份 + 5% 校验，会在第二步备份时把目标盘写满（迁移失败并把盘占满）。
    func testRequiredTargetBytesCountsBothCopies() {
        XCTAssertEqual(AppMigrator.requiredTargetBytes(appSize: 0), 0)
        XCTAssertEqual(AppMigrator.requiredTargetBytes(appSize: 1_000), 2_050,
                       "1 份目标副本 + 1 份同盘备份 + 5% 余量")
        // 100GB 应用需要约 205GB，而不是 105GB
        let hundredGB: Int64 = 100 * 1_073_741_824
        XCTAssertEqual(AppMigrator.requiredTargetBytes(appSize: hundredGB),
                       hundredGB * 2 + hundredGB / 20)
    }

    /// 硬护栏：源与目标是同一位置时，迁移必须直接拒绝。
    /// copyWithDitto 的第一步是 removeItem(dst)，若 dst 就是应用自身，等于把应用删掉。
    func testMigrateRefusesWhenSourceIsTheTarget() async throws {
        let drive = try makeDir("selfdelete")
        let appPath = try makeDir("selfdelete/Applications/SelfApp.app")
        let app = AppItem(name: "SelfApp", bundleName: "SelfApp.app", path: appPath,
                          version: nil, size: 1024, isSymlink: false,
                          symlinkTarget: nil, icon: nil)

        let result = await AppMigrator().migrate(app: app, to: drive) { _, _ in }
        XCTAssertFalse(result.success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appPath),
                      "源应用必须原封不动——这条路径绝不能走到 removeItem(dst)")
    }

    // MARK: - ⑫ 更新失败致应用消失：从更新缓存恢复（2026-09-12 VS Code 实测事故）

    /// 现场还原：Squirrel/ShipIt 更新分两步——先把旧版移走，再把缓存里的新版
    /// 写回应用位置；第二步被系统权限拒绝（实测日志：Operation not permitted，
    /// ShipIt 无 App Management 授权静默失败）后，应用本体消失、链接悬空，
    /// 新版完整留在 ~/Library/Caches/<id>.ShipIt/update.*/。
    /// 修复 = 扫描该缓存找同名 .app 移回目标位置（当时手工恢复的路径，已产品化）
    func testFindVanishedAppCandidatesInShipItCache() throws {
        // 构造 ShipIt 缓存形态：caches/<product>.ShipIt/update.<id>/<App>.app
        let caches = try makeDir("caches")
        let good = try makeDir("caches/com.example.ShipIt/update.abc123/GoneApp.app")
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(good)/Contents.plist")) // 占位，非 Info.plist
        // 完整版（带 Info.plist）才是可用候选
        let complete = try makeDir("caches/com.example.ShipIt/update.def456/GoneApp.app/Contents")
        try Data("plist".utf8).write(to: URL(fileURLWithPath: "\(complete)/Info.plist"))
        // 半截缓存（无 Info.plist）必须被排除
        _ = try makeDir("caches/com.example.ShipIt/update.half/GoneApp.app")

        let found = HealthChecker.findVanishedAppCandidates(appName: "GoneApp.app",
                                                            cacheRoots: [caches])
        XCTAssertEqual(found, ["\(caches)/com.example.ShipIt/update.def456/GoneApp.app"],
                       "只应找到带 Info.plist 的完整候选")
    }

    func testRecoverVanishedTargetRestoresFromCache() throws {
        // 断链：链接指向已消失的外置目标
        let siteDir = try makeDir("recover2")
        let site = "\(siteDir)/GoneApp.app"
        try FileManager.default.createSymbolicLink(
            atPath: site, withDestinationPath: "/Volumes/Nowhere/Applications/GoneApp.app")

        // 更新缓存里有完整新版
        let caches = try makeDir("caches2")
        let staged = try makeDir(
            "caches2/com.example.ShipIt/update.zz/GoneApp.app/Contents")
        try Data("new".utf8).write(to: URL(fileURLWithPath: "\(staged)/Info.plist"))

        // 把断链指到一个可写的"消失目标"位置，便于验证移回
        let targetDir = try makeDir("vanishedTarget/Applications")
        let target = "\(targetDir)/GoneApp.app"
        try FileManager.default.removeItem(atPath: site)
        try FileManager.default.createSymbolicLink(atPath: site, withDestinationPath: target)

        let link = LinkHealth(appName: "GoneApp.app", linkPath: site,
                              target: target, state: .broken)
        let failure = HealthChecker().recoverVanishedTarget(link, cacheRoots: [caches])

        XCTAssertNil(failure, failure ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/Contents/Info.plist"),
                      "新版应已就位到链接指向的目标")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/Volumes/Nowhere/Applications/GoneApp.app"),
                       "恢复不得把文件写到不存在的卷上")
    }

    func testRecoverRefusesWhenTargetStillExists() throws {
        // 目标还在（普通断链，比如盘没插）时绝不能动——缓存恢复只用于"本体消失"
        let dir = try makeDir("exists")
        let real = try makeDir("exists/real/App.app/Contents")  // 目标真实存在
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(real)/Info.plist"))
        let site = "\(dir)/App.app"
        try FileManager.default.createSymbolicLink(atPath: site,
                                                   withDestinationPath: "\(dir)/real/App.app")
        let link = LinkHealth(appName: "App.app", linkPath: site,
                              target: "\(dir)/real/App.app", state: .broken)

        let failure = HealthChecker().recoverVanishedTarget(link)
        XCTAssertEqual(failure, "链接目标仍存在，无需恢复")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/real/App.app/Contents/Info.plist"),
                      "目标存在时恢复流程不得碰任何文件")
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

        XCTAssertEqual(dict["WatchPaths"] as? [String], ["/Volumes"],
                       "监视始终存在的父目录：卷拔掉后它自己的挂载点会消失，"
                       + "而 launchd 对『监视不存在的路径』语义无保证")
        let args = dict["ProgramArguments"] as? [String] ?? []
        XCTAssertEqual(args.count, 6, "sh -c 脚本 + $0 + 卷路径 + 应用路径")
        XCTAssertEqual(args[4], tricky, "卷路径必须以原样经 argv 传入，而不是拼进脚本")
        XCTAssertTrue(args[2].contains("$1"), "脚本从 argv 取路径")
        XCTAssertTrue(args[2].contains("tr -c"), "状态文件必须按卷区分，否则换盘后边沿检测失效")
    }
}
