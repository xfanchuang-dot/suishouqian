import XCTest
@testable import 随手迁

/// TrashRecovery：卸载撤销的废纸篓候选定位
final class TrashRecoveryTests: XCTestCase {

    private var fakeRootsRoot: URL!
    private var homeTrash: URL!
    private var volTrash: URL!

    override func setUpWithError() throws {
        fakeRootsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("trash-tests-\(UUID().uuidString)", isDirectory: true)
        homeTrash = fakeRootsRoot.appendingPathComponent("HomeTrash", isDirectory: true)
        volTrash = fakeRootsRoot.appendingPathComponent("VolTrashes", isDirectory: true)
        try FileManager.default.createDirectory(at: homeTrash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volTrash, withIntermediateDirectories: true)
        // 注入测试根目录，绝不碰真实废纸篓
        TrashRecovery.rootsOverride = [homeTrash.path, volTrash.path]
    }

    override func tearDownWithError() throws {
        TrashRecovery.rootsOverride = nil
        try? FileManager.default.removeItem(at: fakeRootsRoot)
    }

    /// 造一个假 app 目录（含 Info.plist 可选）
    @discardableResult
    private func makeTrashedApp(name: String, in root: URL,
                                bundleID: String? = nil) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let bundleID {
            let plist = ["CFBundleIdentifier": bundleID]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        return app
    }

    func testFindsExactInHomeTrash() throws {
        try makeTrashedApp(name: "Foo.app", in: homeTrash)
        let hit = TrashRecovery.locate(appName: "Foo.app", bundleID: nil,
                                       in: TrashRecovery.roots(externalMounts: []))
        XCTAssertEqual(hit, homeTrash.appendingPathComponent("Foo.app").path)
    }

    /// 关键场景：外置盘应用卸载后真身在卷的 .Trashes/<UID>/，家废纸篓没有
    func testFindsInVolumeTrash() throws {
        try makeTrashedApp(name: "Foo.app", in: volTrash)
        let hit = TrashRecovery.locate(appName: "Foo.app", bundleID: nil,
                                       in: [volTrash.path])
        XCTAssertEqual(hit, volTrash.appendingPathComponent("Foo.app").path)
    }

    func testReturnsNilWhenNothingMatches() throws {
        try makeTrashedApp(name: "Bar.app", in: homeTrash)
        XCTAssertNil(TrashRecovery.locate(appName: "Foo.app", bundleID: nil,
                                          in: TrashRecovery.roots(externalMounts: [])))
    }

    /// Finder 重名回收改名的变体（"Foo 2.app"）也要能找到
    func testFindsRenamedVariant() throws {
        try makeTrashedApp(name: "Foo 2.app", in: homeTrash)
        let hit = TrashRecovery.locate(appName: "Foo.app", bundleID: nil,
                                       in: TrashRecovery.roots(externalMounts: []))
        XCTAssertEqual(hit, homeTrash.appendingPathComponent("Foo 2.app").path)
    }

    /// 同名多次卸载：bundleID 对得上的优先，不捞错
    func testVariantPrefersBundleIDMatch() throws {
        try makeTrashedApp(name: "Foo 2.app", in: homeTrash, bundleID: "com.other.foo")
        try makeTrashedApp(name: "Foo 3.app", in: homeTrash, bundleID: "com.real.foo")
        let hit = TrashRecovery.locate(appName: "Foo.app", bundleID: "com.real.foo",
                                       in: TrashRecovery.roots(externalMounts: []))
        XCTAssertEqual(hit, homeTrash.appendingPathComponent("Foo 3.app").path)
    }

    /// 精确名永远优先于变体（哪怕变体 bundleID 也对得上）
    func testExactNameBeatsVariant() throws {
        try makeTrashedApp(name: "Foo 2.app", in: homeTrash, bundleID: "com.real.foo")
        try makeTrashedApp(name: "Foo.app", in: volTrash, bundleID: "com.other.foo")
        let hit = TrashRecovery.locate(appName: "Foo.app", bundleID: "com.real.foo",
                                       in: [homeTrash.path, volTrash.path])
        XCTAssertEqual(hit, volTrash.appendingPathComponent("Foo.app").path)
    }

    /// 变体名规则纯逻辑
    func testIsTrashVariant() {
        XCTAssertTrue(TrashRecovery.isTrashVariant("Foo 2.app", of: "Foo.app"))
        XCTAssertTrue(TrashRecovery.isTrashVariant("Foo 12.app", of: "Foo.app"))
        XCTAssertFalse(TrashRecovery.isTrashVariant("Foo.app", of: "Foo.app"))
        XCTAssertFalse(TrashRecovery.isTrashVariant("Foo 2.app.bak", of: "Foo.app"))
        XCTAssertFalse(TrashRecovery.isTrashVariant("FooX 2.app", of: "Foo.app"))
        XCTAssertFalse(TrashRecovery.isTrashVariant("Bar 2.app", of: "Foo.app"))
        // 非 .app 结尾的应用名没有变体规则可言
        XCTAssertFalse(TrashRecovery.isTrashVariant("Foo 2", of: "Foo"))
    }

    /// 变体命中但不是目录（残缺文件）不能当候选
    func testVariantMustBeDirectory() throws {
        try Data("junk".utf8).write(to: homeTrash.appendingPathComponent("Foo 2.app"))
        XCTAssertNil(TrashRecovery.locate(appName: "Foo.app", bundleID: nil,
                                          in: TrashRecovery.roots(externalMounts: [])))
    }
}
