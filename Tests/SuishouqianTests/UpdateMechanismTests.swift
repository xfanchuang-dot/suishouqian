import XCTest
@testable import 随手迁

/// 更新方式识别：决定"搬到外置盘后更新会不会把迁移顶掉"的判据
final class UpdateMechanismTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("updmode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 造一个最小 .app：可指定要放进包里的标记文件
    @discardableResult
    private func makeApp(_ name: String, files: [String] = [],
                         dirs: [String] = [], info: [String: Any]? = nil) throws -> String {
        let app = tempDir.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        for f in files {
            let url = app.appendingPathComponent(f)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        for d in dirs {
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        if let info {
            (info as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"),
                                         atomically: true)
        }
        return app.path
    }

    func testDetectsAppStoreByReceipt() throws {
        let app = try makeApp("StoreApp", files: ["Contents/_MASReceipt/receipt"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .appStore)
    }

    func testDetectsSquirrelByFramework() throws {
        let app = try makeApp("ElectronApp", dirs: ["Contents/Frameworks/Squirrel.framework"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .squirrel)
    }

    func testDetectsSparkleByFramework() throws {
        let app = try makeApp("SparkleApp", dirs: ["Contents/Frameworks/Sparkle.framework"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .sparkle)
    }

    func testDetectsSparkleByFeedURL() throws {
        let app = try makeApp("FeedApp", info: ["SUFeedURL": "https://example.com/appcast.xml"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .sparkle)
    }

    func testEmptyFeedURLIsNotSparkle() throws {
        let app = try makeApp("EmptyFeedApp", info: ["SUFeedURL": ""])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .unknown)
    }

    func testUnknownWhenNoMarkers() throws {
        let app = try makeApp("PlainApp", info: ["CFBundleName": "Plain"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .unknown)
    }

    /// App Store 收据优先于自带更新器：带收据就该由系统管理，即使包内也捆了 Sparkle
    func testAppStoreTakesPrecedenceOverBundledUpdater() throws {
        let app = try makeApp("BothApp",
                              files: ["Contents/_MASReceipt/receipt"],
                              dirs: ["Contents/Frameworks/Sparkle.framework"])
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app), .appStore)
    }

    /// 复用调用方已读到的 Info.plist（扫描器就是这么用的，省一次读盘）
    func testUsesPassedInInfoPlist() throws {
        let app = try makeApp("NoPlistOnDiskApp")   // 磁盘上没有 Info.plist
        let injected: NSDictionary = ["SUFeedURL": "https://example.com/appcast.xml"]
        XCTAssertEqual(UpdateMechanism.detect(atAppPath: app, infoPlist: injected), .sparkle)
    }

    // MARK: - 迁移建议的取向

    func testOnlyAppStoreIsUnsafeToRelocate() {
        XCTAssertFalse(UpdateMechanism.appStore.isSafeToRelocate)
        XCTAssertTrue(UpdateMechanism.sparkle.isSafeToRelocate)
        XCTAssertTrue(UpdateMechanism.squirrel.isSafeToRelocate)
        XCTAssertTrue(UpdateMechanism.unknown.isSafeToRelocate,
                      "看不出来不该拦着用户，只提示留意")
    }

    func testGuidanceMentionsConsequence() {
        XCTAssertTrue(UpdateMechanism.appStore.guidance.contains("顶掉"))
        XCTAssertTrue(UpdateMechanism.appStore.guidance.contains("数据"),
                      "App Store 应用的指引要给出替代方案（迁数据）")
        XCTAssertTrue(UpdateMechanism.sparkle.guidance.contains("外置盘"))
    }

    // MARK: - 两种搬法的后果必须分开讲（现场教训：纯搬迁曾绕过确认框）

    func testAppStoreConsequencesDifferByMode() throws {
        let linked = try XCTUnwrap(UpdateMechanism.appStore.updateConsequence(linkBack: true))
        let pure = try XCTUnwrap(UpdateMechanism.appStore.updateConsequence(linkBack: false))

        // 留链接：更新顶掉链接，应用回到内置盘、仍能用（优雅降级）
        XCTAssertTrue(linked.contains("重新装回"))
        XCTAssertTrue(linked.contains("照常能用"), "留链接的后果是优雅降级，要讲清不丢数据")

        // 不留链接：App Store 视为没装，可能再装一份 → 两份并存
        XCTAssertTrue(pure.contains("没装"))
        XCTAssertTrue(pure.contains("各有一份"), "纯搬迁对 App Store 应用会产生重复副本，必须讲清")
        XCTAssertNotEqual(linked, pure, "两种搬法的后果不同，不能共用文案")
    }

    func testOnlyAppStoreHasUpdateConsequences() {
        XCTAssertNil(UpdateMechanism.sparkle.updateConsequence(linkBack: true))
        XCTAssertNil(UpdateMechanism.sparkle.updateConsequence(linkBack: false))
        XCTAssertNil(UpdateMechanism.squirrel.updateConsequence(linkBack: false))
        XCTAssertNil(UpdateMechanism.unknown.updateConsequence(linkBack: false),
                     "看不出更新方式的应用，纯搬迁反而更稳，不该警告")
    }
}
