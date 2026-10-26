import XCTest
@testable import 随手迁

/// 拔盘保护（v3.3.0）：弹出审批前的依赖判定纯逻辑
final class DiskEjectGuardTests: XCTestCase {

    private func probe(_ name: String, _ exec: String, regular: Bool = true) -> DiskEjectGuard.AppProbe {
        DiskEjectGuard.AppProbe(name: name, executablePath: exec, isRegular: regular)
    }

    // MARK: - 卷内判定

    func testPathInsideVolume() {
        XCTAssertTrue(DiskEjectGuard.path("/Volumes/USB/Applications/X.app/Contents/MacOS/X",
                                          isInsideVolume: "/Volumes/USB"))
        // 卷根自身算在内（可执行体直接躺在卷根的极端情况）
        XCTAssertTrue(DiskEjectGuard.path("/Volumes/USB", isInsideVolume: "/Volumes/USB/"),
                      "卷根路径尾部斜杠必须归一化")
        // 前缀陷阱：USB2 不是 USB 的内容
        XCTAssertFalse(DiskEjectGuard.path("/Volumes/USB2/Applications/X.app",
                                           isInsideVolume: "/Volumes/USB"))
        XCTAssertFalse(DiskEjectGuard.path("/Applications/X.app", isInsideVolume: "/Volumes/USB"))
    }

    // MARK: - 运行应用依赖判定

    func testDependentRunningAppsFiltersByVolumeAndPolicy() {
        let running = [
            probe("外置应用", "/Volumes/USB/Applications/Foo.app/Contents/MacOS/Foo"),
            probe("内置应用", "/Applications/Bar.app/Contents/MacOS/Bar"),
            probe("后台进程", "/Volumes/USB/Library/Helper", regular: false),
        ]
        let names = DiskEjectGuard.dependentRunningApps(volumePath: "/Volumes/USB", running: running)
        XCTAssertEqual(names, ["外置应用"],
                       "只算卷上的常规应用；非 regular（菜单栏/后台）不算依赖")
    }

    func testDependentRunningAppsMatchesAnyRootPrefix() {
        // 「只拦 /Volumes 外置卷」的门在 approveUnmount 把守，本函数只做卷内判定：
        // 卷根之外的路径不算依赖（根目录路径永远不会命中子目录前缀）
        let running = [probe("X", "/Applications/X.app/Contents/MacOS/X")]
        XCTAssertTrue(DiskEjectGuard.dependentRunningApps(
            volumePath: "/", running: running).isEmpty)
        XCTAssertTrue(DiskEjectGuard.dependentRunningApps(
            volumePath: "/Users/fan/Downloads/dmg-mount", running: running).isEmpty)
    }

    /// 链接态应用：executablePath 经过软链接，必须解析后才判卷——
    /// 已迁移应用在 /Applications 的入口是链接，这条是拔盘保护的核心场景
    func testDependentRunningAppsResolvesSymlinksIntoVolume() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ssq-eject-\(UUID().uuidString)")
        let volApp = root.appendingPathComponent("Volumes/USB/Applications/Real.app")
        try fm.createDirectory(
            at: volApp.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true)
        try Data().write(to: volApp.appendingPathComponent("Contents/MacOS/Real"))
        // /Applications 下放软链接入口（临时目录本身也可能是 /var→/private/var 链，
        // 两边都按解析后路径对齐）；createSymbolicLink 不建中间目录，父目录先建好
        let linkApp = root.appendingPathComponent("Applications/Real.app")
        try fm.createDirectory(at: root.appendingPathComponent("Applications"),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkApp, withDestinationURL: volApp)
        defer { try? fm.removeItem(at: root) }

        let resolvedRoot = (root.appendingPathComponent("Volumes/USB").path as NSString)
            .resolvingSymlinksInPath
        let probe = probe("链接应用",
                          linkApp.appendingPathComponent("Contents/MacOS/Real").path)
        let names = DiskEjectGuard.dependentRunningApps(
            volumePath: resolvedRoot, running: [probe])
        XCTAssertEqual(names, ["链接应用"],
                       "软链接入口解析后落在卷内，必须判为依赖")
    }

    func testDependentRunningAppsKeepsInputOrder() {
        let running = [
            probe("B", "/Volumes/USB/Applications/B.app/Contents/MacOS/B"),
            probe("A", "/Volumes/USB/Applications/A.app/Contents/MacOS/A"),
        ]
        XCTAssertEqual(DiskEjectGuard.dependentRunningApps(
            volumePath: "/Volumes/USB", running: running), ["B", "A"],
            "名单顺序保持输入序（通知点名按运行序）")
    }
}
