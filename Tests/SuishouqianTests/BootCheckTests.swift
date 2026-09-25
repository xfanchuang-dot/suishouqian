import XCTest
@testable import 随手迁

/// 开机自启体检 + Spotlight 状态解析（v2.10.0 链路体感三期）单元测试
final class BootCheckTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bootcheck-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 引用抽取

    func testVolumeReferencesExtractsAllKeysAndFiltersOthers() {
        let refs = BootAgentScanner.volumeReferences(dict: [
            "Program": "/Volumes/Ext/App.app/Contents/MacOS/App",
            "ProgramArguments": ["/usr/bin/open", "/Volumes/Ext2/notes"],
            "WatchPaths": ["/Users/fan/Desktop", "/Volumes/Ext3/watch"],
            "QueueDirectories": ["/tmp/queue"],
            "Label": "test.agent",
        ])
        XCTAssertEqual(Set(refs), [
            "/Volumes/Ext/App.app/Contents/MacOS/App",
            "/Volumes/Ext2/notes",
            "/Volumes/Ext3/watch",
        ])
    }

    func testVolumeReferencesOfNonVolumePlistIsEmpty() {
        let refs = BootAgentScanner.volumeReferences(dict: [
            "Program": "/usr/local/bin/helper",
            "ProgramArguments": ["-d"],
        ])
        XCTAssertTrue(refs.isEmpty)
    }

    func testVolumeReferencesOfGarbageDataIsEmptyNotCrash() {
        XCTAssertTrue(BootAgentScanner.volumeReferences(plistData: Data("not a plist".utf8)).isEmpty)
        XCTAssertTrue(BootAgentScanner.volumeReferences(plistData: Data()).isEmpty)
    }

    func testVolumeReferencesReadsBinaryPlistData() throws {
        let dict: [String: Any] = ["ProgramArguments": ["/Volumes/Disk/tool"]]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        XCTAssertEqual(BootAgentScanner.volumeReferences(plistData: data), ["/Volumes/Disk/tool"])
    }

    // MARK: - 卷在线判定

    func testVolumeName() {
        XCTAssertEqual(BootAgentScanner.volumeName(ofPath: "/Volumes/MyDisk/a/b"), "MyDisk")
        XCTAssertEqual(BootAgentScanner.volumeName(ofPath: "/Volumes/MyDisk"), "MyDisk")
        XCTAssertEqual(BootAgentScanner.volumeName(ofPath: "/Applications/X.app"), "")
    }

    func testVolumesOnlineRequiresEveryReferencedVolumeMounted() {
        let refs = ["/Volumes/A/x", "/Volumes/B/y"]
        XCTAssertTrue(BootAgentScanner.volumesOnline(for: refs, mountedVolumes: ["A", "B", "C"]))
        XCTAssertFalse(BootAgentScanner.volumesOnline(for: refs, mountedVolumes: ["A"]))
    }

    // MARK: - 目录扫描

    private func writePlist(_ name: String, dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: tempDir.appendingPathComponent(name))
    }

    func testScanReturnsOnlyVolumeReferencingAgents() throws {
        try writePlist("com.ext.updater.plist", dict: [
            "Label": "com.ext.updater",
            "ProgramArguments": ["/Volumes/Ext/App.app/Contents/MacOS/App", "--check"],
        ])
        try writePlist("com.local.helper.plist", dict: [
            "Label": "com.local.helper",
            "Program": "/usr/local/bin/helper",
        ])
        // 坏文件：不许让整轮体检中断
        try Data("garbage".utf8).write(to: tempDir.appendingPathComponent("broken.plist"))

        let issues = BootAgentScanner.scan(roots: [(tempDir.path, .userAgent)],
                                           mountedVolumes: ["Ext"])
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.label, "com.ext.updater")
        XCTAssertEqual(issues.first?.kind, .userAgent)
        XCTAssertTrue(issues.first?.volumesOnline ?? false)
    }

    func testScanFlagsOfflineVolume() throws {
        try writePlist("com.offline.agent.plist", dict: [
            "WatchPaths": ["/Volumes/Gone/stuff"],
        ])
        let issues = BootAgentScanner.scan(roots: [(tempDir.path, .userAgent)],
                                           mountedVolumes: ["Other"])
        XCTAssertEqual(issues.count, 1)
        XCTAssertFalse(issues.first?.volumesOnline ?? true)
    }

    func testDaemonVerdictIsMoreSevereWhenOffline() {
        let daemon = LaunchAgentIssue(id: "p", label: "d", plistPath: "p",
                                      kind: .daemon, references: ["/Volumes/X"],
                                      volumesOnline: false)
        let agent = LaunchAgentIssue(id: "q", label: "a", plistPath: "q",
                                     kind: .userAgent, references: ["/Volumes/X"],
                                     volumesOnline: false)
        XCTAssertTrue(daemon.verdict.severe)
        XCTAssertTrue(agent.verdict.severe)
        XCTAssertTrue(daemon.verdict.text.contains("开机"), "守护项的文案要点明开机阶段必然失败")
    }

    // MARK: - Spotlight 状态解析

    func testSpotlightStatusParsing() {
        XCTAssertEqual(SpotlightCheck.parseStatus("Indexing enabled."), true)
        XCTAssertEqual(SpotlightCheck.parseStatus("/Volumes/X:\n\tIndexing enabled."), true)
        XCTAssertEqual(SpotlightCheck.parseStatus("Indexing disabled."), false)
        XCTAssertNil(SpotlightCheck.parseStatus("Error: unknown pathname."))
        XCTAssertNil(SpotlightCheck.parseStatus(""))
    }

    func testSpotlightCommandLineEscapesAndFlags() {
        XCTAssertEqual(SpotlightCheck.commandLine(enabled: false, mountPoint: "/Volumes/My Disk"),
                       "sudo mdutil -i off '/Volumes/My Disk'")
        XCTAssertEqual(SpotlightCheck.commandLine(enabled: true, mountPoint: "/Volumes/A"),
                       "sudo mdutil -i on '/Volumes/A'")
    }
}
