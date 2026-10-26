import XCTest
@testable import 随手迁

/// v2.13.0：卸载残留特征集 + 数据目录清单新增条目
final class UninstallAndCatalogTests: XCTestCase {

    // MARK: - 单应用特征集

    func testAppSignaturesNameVariants() {
        let sigs = HealthChecker.appSignatures(name: "Visual Studio Code", bundleID: nil)
        XCTAssertTrue(sigs.contains("visual studio code"))
        XCTAssertTrue(sigs.contains("visualstudiocode"))
        XCTAssertFalse(sigs.contains("Visual Studio Code"))
    }

    func testAppSignaturesBundleIDAndPrefix() {
        let sigs = HealthChecker.appSignatures(name: "QQMusic", bundleID: "com.tencent.QQMusicMac")
        XCTAssertTrue(sigs.contains("qqmusic"))
        XCTAssertTrue(sigs.contains("com.tencent.qqmusicmac"))
        XCTAssertTrue(sigs.contains("com.tencent"))
    }

    func testAppSignaturesEmptyBundleIDIgnored() {
        let sigs = HealthChecker.appSignatures(name: "X", bundleID: "")
        XCTAssertEqual(sigs, ["x"])
    }

    // MARK: - 数据目录清单

    func testWeChatEntryExistsWithNativeGuide() {
        let entry = DataMigrator.catalog.first { $0.id == "wechat-data" }
        XCTAssertNotNil(entry, "微信条目必须在清单里（本机已验证路径存在）")
        guard case .native = entry?.relocation else {
            return XCTFail("微信必须是原生搬迁指引，不做链接迁移")
        }
        XCTAssertTrue(entry?.homeRelativePath.contains("xwechat_files") ?? false)
        XCTAssertNotNil(entry?.ownerBundleID)
    }

    func testAllCatalogIDsUnique() {
        let ids = DataMigrator.catalog.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "清单 id 必须唯一（台账/外置目录名都靠它）")
    }

    // MARK: - 体积未知显示

    func testSizeDisplayShowsUnknownForZero() throws {
        let item = try makeItem(sizeBytes: 0)
        XCTAssertEqual(item.sizeDisplay, "体积未知")
        let sized = try makeItem(sizeBytes: 150 * 1_048_576)
        XCTAssertEqual(sized.sizeDisplay,
                       ByteCountFormatter.string(fromByteCount: 150 * 1_048_576, countStyle: .file))
    }

    private func makeItem(sizeBytes: Int64) throws -> DataMigrator.DataLocationItem {
        var item = DataMigrator.DataLocationItem(
            id: "wechat-data", title: "微信", path: "~/x",
            sizeBytes: sizeBytes, isSymlink: false, linkBroken: false,
            accessible: true, managedByUs: false, ownerRunning: false,
            relocation: .native(guide: "g", launchAppName: nil), note: nil)
        return item
    }

    // MARK: - root 属主应用的卸载提权兜底（v3.2.2，WeRead.app root wheel 实测案例）

    func testTrashEligibleForElevationBootVolumeOnly() {
        XCTAssertTrue(AppMigrator.trashEligibleForElevation("/Applications/WeRead.app"),
                      "系统盘路径允许提权兜底")
        XCTAssertFalse(AppMigrator.trashEligibleForElevation("/Volumes/USB/WeRead.app"),
                       "外置卷 .Trashes 结构不提权，保持安全失败")
        XCTAssertFalse(AppMigrator.trashEligibleForElevation("/Volumes/Samsung990/Applications/X.app"),
                       "外置卷上迁移过的真身同样不提权")
    }

    func testIsRootOwnedFalseForUserOwnedTempDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssq-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(AppMigrator.isRootOwned(dir.path),
                       "当前用户自建目录不是 root 属主")
        XCTAssertFalse(AppMigrator.isRootOwned("/nonexistent/path/xx"),
                       "路径不存在时判定为否（不触发提权）")
    }

    func testPrivilegedTrashCommandEscapesShellQuotes() {
        let cmd = AppMigrator.privilegedTrashCommand(
            sourcePath: "/Applications/It's My.app", userTrashDir: "/Users/x/.Trash")
        // 单引号必须被 '\'' 序列打断，否则路径里的引号会提前闭合命令
        XCTAssertTrue(cmd.contains("S='/Applications/It'\\''s My.app'"),
                      "含单引号的路径必须按 shell 单引号串转义：\(cmd)")
        XCTAssertTrue(cmd.contains("T='/Users/x/.Trash'"))
    }

    func testPrivilegedTrashCommandAvoidsCollisionAndUsesMv() {
        let cmd = AppMigrator.privilegedTrashCommand(
            sourcePath: "/Applications/WeRead.app", userTrashDir: "/Users/x/.Trash")
        // 重名避让必须发生在目标侧：~/.Trash 已有同名条目时直接 mv 会嵌进同名目录
        XCTAssertTrue(cmd.contains("while [ -e \"$D\" ]"), "必须有重名避让循环：\(cmd)")
        XCTAssertTrue(cmd.contains("D=\"$T/$N $i\""), "重名时必须追加 \" 2\"式变体名")
        XCTAssertTrue(cmd.contains("mv \"$S\" \"$D\""), "必须同卷 mv（废纸篓语义，可撤销）")
        XCTAssertFalse(cmd.contains("rm -rf"), "提权兜底是移入废纸篓，绝不允许 rm")
    }

    func testPrivilegedTrashCommandNotHomeDependent() {
        // 提权后 shell 以 root 跑，$HOME 是 /var/root；废纸篓必须由 Swift 侧显式传入
        let cmd = AppMigrator.privilegedTrashCommand(
            sourcePath: "/Applications/X.app", userTrashDir: "/Users/fan/.Trash")
        XCTAssertTrue(cmd.contains("/Users/fan/.Trash"))
        XCTAssertFalse(cmd.contains("$HOME"), "脚本里不允许出现 $HOME（root 的 HOME 是 /var/root）")
    }
}
