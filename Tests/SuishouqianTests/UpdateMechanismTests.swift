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

    /// 只有 App Store 应用更适合"不留链接"（本机实测：不留链接不受更新影响，
    /// 而留链接能否扛住更新尚未观测到）
    func testOnlyAppStorePrefersNoLink() {
        XCTAssertTrue(UpdateMechanism.appStore.prefersNoLink)
        XCTAssertFalse(UpdateMechanism.sparkle.prefersNoLink)
        XCTAssertFalse(UpdateMechanism.squirrel.prefersNoLink)
        XCTAssertFalse(UpdateMechanism.unknown.prefersNoLink,
                       "看不出更新方式的不该被特殊对待")
    }

    func testGuidanceMentionsVerifiedInPlaceUpdate() {
        // 这条结论是实测得来的（QQ音乐 11.8.1 → 11.9.1，外置盘就地升级、无第二份），
        // 写进文案是为了让用户放心搬；改动前请先确认结论仍成立
        let guidance = UpdateMechanism.appStore.guidance
        XCTAssertTrue(guidance.contains("就地"), "要说明更新是就地写在外置盘上的")
        XCTAssertTrue(guidance.contains("11.8.1"), "带上实测的证据")
        XCTAssertTrue(guidance.contains("Spotlight"), "要讲清代价：不再出现在「应用程序」里")
        XCTAssertTrue(UpdateMechanism.sparkle.guidance.contains("外置盘"))
    }

    // MARK: - 两种搬法的后果必须分开讲

    /// 实测（2026-09-11）推翻了原先"App Store 会把它当成没装、另装一份"的推测：
    /// 不留链接是干净的，因此**不该**再对纯搬迁告警
    func testPureRelocationOfAppStoreAppNeedsNoWarning() {
        XCTAssertNil(UpdateMechanism.appStore.updateConsequence(linkBack: false),
                     "不留链接已实测不受更新影响，不该打扰用户")
    }

    func testLinkRelocationWarnsAboutUnverifiedRisk() throws {
        let linked = try XCTUnwrap(UpdateMechanism.appStore.updateConsequence(linkBack: true))
        XCTAssertTrue(linked.contains("链接"), "要讲清风险发生在链接上")
        XCTAssertTrue(linked.contains("体检页"), "要给出发现手段")
        XCTAssertTrue(linked.contains("纯搬迁"), "要给出更稳的替代方案")
        // 不能再说"会另装一份"——那是被实测推翻的推测
        XCTAssertFalse(linked.contains("各有一份"))
    }

    func testOnlyAppStoreHasUpdateConsequences() {
        XCTAssertNil(UpdateMechanism.sparkle.updateConsequence(linkBack: true))
        XCTAssertNil(UpdateMechanism.squirrel.updateConsequence(linkBack: false))
        XCTAssertNil(UpdateMechanism.unknown.updateConsequence(linkBack: true),
                     "看不出更新方式的应用不该被警告")
    }
}
