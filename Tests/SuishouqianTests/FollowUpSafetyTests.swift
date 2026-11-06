import XCTest
import CryptoKit
@testable import 随手迁

final class HashMatchTests: XCTestCase {
    func testMissingHashIsFailure() {
        XCTAssertFalse(AppMigrator.hashesMatch(
            relativePaths: ["a", "b"],
            source: ["a": "1"],
            target: ["a": "1", "b": "2"]))
        XCTAssertFalse(AppMigrator.hashesMatch(
            relativePaths: ["a"],
            source: nil,
            target: ["a": "1"]))
        XCTAssertFalse(AppMigrator.hashesMatch(
            relativePaths: ["a"],
            source: ["a": "1"],
            target: [:]))
    }

    func testMismatchIsFailureAndMatchPasses() {
        XCTAssertFalse(AppMigrator.hashesMatch(
            relativePaths: ["a"],
            source: ["a": "1"],
            target: ["a": "2"]))
        XCTAssertTrue(AppMigrator.hashesMatch(
            relativePaths: ["a", "b"],
            source: ["a": "1", "b": "2"],
            target: ["b": "2", "a": "1"]))
    }
}

final class PrivilegedShellTests: XCTestCase {
    func testPathsStayOutOfAppleScriptSource() {
        let nasty = "/Applications/It's\"\\\n$(rm).app"
        let commands: [PrivilegedShell.Command] = [
            .remove(source: nasty, linkTarget: "/Volumes/外置/App.app", createLink: true),
            .remove(source: nasty, linkTarget: "", createLink: false),
            .rewriteLink(link: nasty, target: "/Volumes/盘/App.app"),
            .trash(source: nasty, trashDir: "/Users/a/.Trash"),
            .spotlight(enabled: false, mount: nasty),
            .addExclusions([nasty, "/Volumes/盘/.suishouqian-backup"]),
        ]
        for command in commands {
            let invocation = PrivilegedShell.invocation(for: command)
            XCTAssertTrue(invocation.script.contains("quoted form of"),
                          "必须用 quoted form of：\(command)")
            XCTAssertFalse(PrivilegedShell.scriptEmbeds(paths: [nasty], script: invocation.script),
                           "路径被拼进了脚本：\(invocation.script)")
            let args = PrivilegedShell.arguments(for: invocation)
            XCTAssertEqual(args.first, "-e")
            XCTAssertTrue(args.contains("--"))
            XCTAssertTrue(args.contains(nasty), "路径应作为 argv 传入")
        }
    }

    func testSpotlightFlagIsWhitelistedInScript() {
        let script = PrivilegedShell.invocation(for: .spotlight(enabled: true, mount: "/Volumes/A")).script
        XCTAssertTrue(script.contains("flag is not \"on\""))
        XCTAssertFalse(script.contains("/Volumes/A"))
    }
}

@MainActor
final class LicenseTierTests: XCTestCase {
    private func license(tier: String) -> (String, Curve25519.Signing.PrivateKey) {
        let key = Curve25519.Signing.PrivateKey()
        let payload = Data("buyer@example.com|2099-12-31|\(tier)".utf8)
        let sig = try! key.signature(for: payload)
        let text = payload.base64EncodedString() + "." + sig.base64EncodedString()
        return (text, key)
    }

    func testOnlyProTierVerifies() {
        let (pro, key) = license(tier: "pro")
        let info = LicenseManager.verify(pro, publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(info?.tier, "pro")
        XCTAssertEqual(info?.grantsPro, true)

        for tier in ["free", "vip", "pro ", "PRO", ""] {
            let (text, other) = license(tier: tier)
            XCTAssertNil(
                LicenseManager.verify(text, publicKeyBase64: other.publicKey.rawRepresentation.base64EncodedString()),
                "层级 \(tier) 验签通过也不能当成 Pro")
        }
    }
}

final class CrashJournalTests: XCTestCase {
    private var root: URL!
    private var journal: CrashJournal!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("crash-journal-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        journal = CrashJournal(directory: root.appendingPathComponent("journal", isDirectory: true))
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func bundle(at path: String, plist: Bool) throws {
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if plist {
            try Data("plist".utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
        }
    }

    private func entry(op: String = "migrate", createLink: Bool = true,
                       link: String? = nil) -> CrashJournal.Entry {
        CrashJournal.Entry(
            op: op, appName: "X.app",
            sourcePath: root.appendingPathComponent("source/X.app").path,
            targetPath: root.appendingPathComponent("target/X.app").path,
            backupPath: root.appendingPathComponent("backup/X.app").path,
            createLink: createLink, linkPath: link)
    }

    func testRestoreRelinksWithoutDeletingExternalCopy() throws {
        let e = entry(op: "restore")
        try bundle(at: e.targetPath, plist: true)
        try Data("ONLY".utf8).write(to: URL(fileURLWithPath: e.targetPath + "/Contents/only.txt"))
        journal.begin(e)

        let notes = journal.recover(fileManager: fm)
        XCTAssertFalse(notes.isEmpty)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: e.sourcePath), e.targetPath)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: e.targetPath + "/Contents/only.txt"), encoding: .utf8),
                       "ONLY")
        XCTAssertNil(journal.current())
    }

    func testDoesNotDeletePartialTargetWhenItMayBeTheOnlyCopy() throws {
        let e = entry()
        try bundle(at: e.targetPath, plist: false)
        try Data("bytes".utf8).write(to: URL(fileURLWithPath: e.targetPath + "/Contents/half"))
        journal.begin(e)

        _ = journal.recover(fileManager: fm)
        XCTAssertTrue(fm.fileExists(atPath: e.targetPath + "/Contents/half"),
                      "源已经不在时，不完整的目标也不能删")
    }

    func testRemovesPartialTargetWhenSourceBundleRemains() throws {
        let e = entry()
        try bundle(at: e.sourcePath, plist: true)
        try bundle(at: e.targetPath, plist: false)
        journal.begin(e)

        _ = journal.recover(fileManager: fm)
        XCTAssertTrue(fm.fileExists(atPath: e.sourcePath + "/Contents/Info.plist"))
        XCTAssertFalse(fm.fileExists(atPath: e.targetPath))
    }

    func testKeepsBothCompleteCopies() throws {
        let e = entry()
        try bundle(at: e.sourcePath, plist: true)
        try bundle(at: e.targetPath, plist: true)
        journal.begin(e)
        _ = journal.recover(fileManager: fm)
        XCTAssertTrue(fm.fileExists(atPath: e.sourcePath + "/Contents/Info.plist"))
        XCTAssertTrue(fm.fileExists(atPath: e.targetPath + "/Contents/Info.plist"))
    }

    func testCorruptJournalDoesNotTouchFiles() throws {
        let e = entry()
        try bundle(at: e.targetPath, plist: true)
        let file = root.appendingPathComponent("journal/crash-journal.json")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: file)
        let notes = journal.recover(fileManager: fm)
        XCTAssertTrue(notes.joined().contains("损坏"))
        XCTAssertTrue(fm.fileExists(atPath: e.targetPath + "/Contents/Info.plist"))
        XCTAssertTrue(fm.fileExists(atPath: file.path), "损坏的日志留着，不根据它删文件")
    }

    func testPlanRelocateRetargetsLinkAndDoesNotInventSourceLink() {
        let link = root.appendingPathComponent("Links/X.app").path
        let e = CrashJournal.Entry(
            op: "relocate", appName: "X.app",
            sourcePath: "/vol/a/X.app", targetPath: "/vol/b/X.app",
            backupPath: nil, createLink: true, linkPath: link)
        let plan = CrashJournal.plan(entry: e, snapshot: .init(
            source: .missing, target: .bundle, backup: .missing,
            link: .symlink(destination: "/vol/a/X.app")))
        XCTAssertTrue(plan.effects.contains(.retargetLink(at: link, to: "/vol/b/X.app")))
        XCTAssertFalse(plan.effects.contains(.makeLink(at: "/vol/a/X.app", to: "/vol/b/X.app")))
    }

    func testPlanRefusesToDropOnlyBackup() {
        let e = entry()
        let plan = CrashJournal.plan(entry: e, snapshot: .init(
            source: .missing, target: .missing, backup: .bundle, link: .missing))
        XCTAssertTrue(plan.effects.isEmpty)
        XCTAssertTrue(plan.message.contains("未删除"))
    }
}
