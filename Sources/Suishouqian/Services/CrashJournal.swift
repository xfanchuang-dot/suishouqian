import Foundation

/// 迁移/回迁进行中的崩溃日志。
///
/// 破坏性步骤开始前同步落盘，正常返回时清掉。进程若死在中途，文件还在；
/// 下次启动按盘面恢复入口或清掉半截副本。唯一的完整副本永远不删。
final class CrashJournal: @unchecked Sendable {
    static let shared = CrashJournal()

    nonisolated(unsafe) static var directoryOverride: URL?
    /// 测试进程里不要写用户的 Application Support。
    nonisolated(unsafe) private static var testFallbackDirectory: URL?
    /// 非 nil 时这本日志独占该目录，测试不用动全局 override。
    private let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    struct Entry: Codable, Equatable {
        var op: String
        var appName: String
        var sourcePath: String
        var targetPath: String
        var backupPath: String?
        /// 迁移留链接、回迁重建链接时为 true
        var createLink: Bool
        /// 盘间迁移的 /Applications 链接。没有单独链接时为 nil。
        var linkPath: String?
    }

    enum Node: Equatable {
        case missing
        case symlink(destination: String)
        case bundle
        case partialDirectory
        case other
    }

    struct Snapshot: Equatable {
        var source: Node
        var target: Node
        var backup: Node
        var link: Node
    }

    enum Effect: Equatable {
        /// 先摘掉半截目录（调用方必须另有一份 bundle），再把链接指过去
        case replacePartialWithLink(at: String, to: String, keeper: String)
        case makeLink(at: String, to: String)
        /// 只改符号链接。真目录或半截目录一律不动。
        case retargetLink(at: String, to: String)
        case removePartial(path: String, keeper: String)
        case clearMarker(atTarget: String)
    }

    struct Plan: Equatable {
        var effects: [Effect]
        var message: String
    }

    private let queue = DispatchQueue(label: "com.suishouqian.crash-journal")
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    private var fileURL: URL {
        let dir: URL
        if let directory {
            dir = directory
        } else if let override = Self.directoryOverride {
            dir = override
        } else if Self.runningUnderTests {
            if Self.testFallbackDirectory == nil {
                Self.testFallbackDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ssq-crash-\(UUID().uuidString)", isDirectory: true)
            }
            dir = Self.testFallbackDirectory!
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("随手迁", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("crash-journal.json")
    }

    func begin(_ entry: Entry) {
        queue.sync {
            guard let data = try? encoder.encode(entry) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func end() {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    func current() -> Entry? {
        queue.sync { loadEntry() }
    }

    /// 启动时调用。返回给用户看的说明；没有未完成操作时为空。
    @discardableResult
    func recover(fileManager: FileManager = .default) -> [String] {
        queue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
            guard let entry = loadEntry() else {
                return ["崩溃日志损坏，没有改动任何文件"]
            }
            let snap = Self.snapshot(of: entry, fileManager: fileManager)
            let plan = Self.plan(entry: entry, snapshot: snap)
            let applied = Self.apply(plan, fileManager: fileManager)
            try? FileManager.default.removeItem(at: fileURL)
            let text = applied ?? plan.message
            AuditLog.append("崩溃恢复 \(entry.appName)：\(text)")
            return ["\(entry.appName)：\(text)"]
        }
    }

    // MARK: - 纯逻辑

    static func plan(entry: Entry, snapshot: Snapshot) -> Plan {
        if entry.op == "restore" {
            return planRestore(entry, snapshot)
        }
        return planTransfer(entry, snapshot)
    }

    static func snapshot(of entry: Entry, fileManager: FileManager) -> Snapshot {
        Snapshot(
            source: classify(entry.sourcePath, fileManager),
            target: classify(entry.targetPath, fileManager),
            backup: entry.backupPath.map { classify($0, fileManager) } ?? .missing,
            link: entry.linkPath.map { classify($0, fileManager) } ?? .missing)
    }

    static func classify(_ path: String, _ fm: FileManager) -> Node {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType else { return .missing }
        if type == .typeSymbolicLink {
            let dest = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
            return .symlink(destination: dest)
        }
        if type == .typeDirectory {
            let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
            return fm.fileExists(atPath: plist) ? .bundle : .partialDirectory
        }
        return .other
    }

    static func apply(_ plan: Plan, fileManager: FileManager) -> String? {
        for effect in plan.effects {
            switch effect {
            case .removePartial(let path, let keeper):
                guard canDiscard(path, keeper: keeper, fileManager: fileManager) else {
                    return "原计划要清掉半截目录，但另一份副本已不在，已中止且未删除 \(path)"
                }
                try? fileManager.removeItem(atPath: path)
            case .replacePartialWithLink(let at, let to, let keeper):
                guard canDiscard(at, keeper: keeper, fileManager: fileManager) else {
                    return "链接位上有残留，但另一份副本已不在，未删除 \(at)"
                }
                try? fileManager.removeItem(atPath: at)
                try? fileManager.createSymbolicLink(atPath: at, withDestinationPath: to)
            case .makeLink(let at, let to):
                if classify(at, fileManager) == .missing {
                    let parent = (at as NSString).deletingLastPathComponent
                    try? fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try? fileManager.createSymbolicLink(atPath: at, withDestinationPath: to)
                }
            case .retargetLink(let at, let to):
                switch classify(at, fileManager) {
                case .bundle, .partialDirectory:
                    return "链接位是目录，未覆盖 \(at)"
                case .symlink:
                    try? fileManager.removeItem(atPath: at)
                    let parent = (at as NSString).deletingLastPathComponent
                    try? fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try? fileManager.createSymbolicLink(atPath: at, withDestinationPath: to)
                case .missing:
                    let parent = (at as NSString).deletingLastPathComponent
                    try? fileManager.createDirectory(atPath: parent, withIntermediateDirectories: true)
                    try? fileManager.createSymbolicLink(atPath: at, withDestinationPath: to)
                case .other:
                    return "链接位被其它文件占用，未删除 \(at)"
                }
            case .clearMarker(let target):
                try? fileManager.removeItem(atPath: target + AppMigrator.relocationMarkerSuffix)
            }
        }
        return nil
    }

    /// 只有「要删的不是 bundle、且 keeper 仍是 bundle」才允许删。
    private static func canDiscard(_ path: String, keeper: String, fileManager: FileManager) -> Bool {
        guard path != keeper else { return false }
        guard classify(keeper, fileManager) == .bundle else { return false }
        guard classify(path, fileManager) == .partialDirectory else { return false }
        return true
    }

    private static func planRestore(_ entry: Entry, _ snap: Snapshot) -> Plan {
        let link = entry.sourcePath
        let external = entry.targetPath
        if case .symlink(let dest) = snap.source, same(dest, external) {
            return Plan(effects: [], message: "回迁未完成，入口链接已在，外置副本未动")
        }
        switch snap.source {
        case .missing:
            if snap.target == .bundle {
                return Plan(effects: [.makeLink(at: link, to: external)],
                            message: "回迁中断，已把入口指回外置副本，未删除外置副本")
            }
            if snap.backup == .bundle, let backup = entry.backupPath {
                return Plan(effects: [],
                            message: "回迁中断且外置副本不在，备份仍在 \(backup)，未删除")
            }
            return Plan(effects: [], message: "回迁中断，没有找到可恢复的副本，未删除任何文件")
        case .partialDirectory:
            if snap.target == .bundle {
                return Plan(
                    effects: [.replacePartialWithLink(at: link, to: external, keeper: external)],
                    message: "回迁中断，已清掉内置盘上的半截副本并恢复链接，外置副本保留")
            }
            return Plan(effects: [], message: "回迁中断，内置盘有残留且外置副本不在，未删除残留")
        case .bundle:
            if snap.target == .bundle {
                return Plan(effects: [], message: "回迁中断，内置与外置两份都在，未删除任何一份")
            }
            return Plan(effects: [], message: "回迁已落到内置盘，外置副本不在，未再删除内置副本")
        case .symlink, .other:
            return Plan(effects: [], message: "回迁中断，入口状态无法安全自动处理，未删除任何文件")
        }
    }

    private static func planTransfer(_ entry: Entry, _ snap: Snapshot) -> Plan {
        let source = entry.sourcePath
        let target = entry.targetPath
        if entry.createLink, case .symlink(let dest) = snap.source, same(dest, target) {
            return Plan(effects: [.clearMarker(atTarget: target)],
                        message: "迁移已切换完成，补清标记，未删除目标副本")
        }
        switch snap.source {
        case .missing:
            if snap.target == .bundle {
                var effects: [Effect] = []
                // 盘间迁移的源路径是旧盘上的真身，不要在那里补一条链接。
                if entry.op != "relocate", entry.createLink {
                    effects.append(.makeLink(at: source, to: target))
                }
                effects.append(.clearMarker(atTarget: target))
                effects.append(contentsOf: linkEffects(entry, snap, target: target))
                let msg = entry.createLink
                    ? "迁移中断，源已不在，已把入口指到目标副本，未删除目标"
                    : "迁移中断，应用留在目标位置，未删除目标副本"
                return Plan(effects: effects, message: msg)
            }
            if snap.backup == .bundle, let backup = entry.backupPath {
                return Plan(effects: [],
                            message: "迁移中断，唯一完整副本在备份 \(backup)，未删除")
            }
            return Plan(effects: [], message: "迁移中断，没有找到完整副本，未删除任何文件")
        case .bundle:
            if snap.target == .partialDirectory {
                return Plan(
                    effects: [.removePartial(path: target, keeper: source)],
                    message: "迁移中断，已清掉目标盘上的半截副本，原件未动")
            }
            return Plan(effects: [], message: "迁移中断，原件仍在，目标副本也保留，未删除任何一份")
        case .partialDirectory:
            if snap.target == .bundle {
                var effects: [Effect] = [.removePartial(path: source, keeper: target)]
                if entry.op != "relocate", entry.createLink {
                    effects.append(.makeLink(at: source, to: target))
                }
                effects.append(contentsOf: linkEffects(entry, snap, target: target))
                return Plan(effects: effects,
                            message: "迁移中断，已清掉源位置的半截内容并指回目标副本，未删除目标")
            }
            return Plan(effects: [], message: "迁移中断，源位置不完整且目标也不是完整应用，未删除")
        case .symlink, .other:
            return Plan(effects: [], message: "迁移中断，源位置状态无法安全自动处理，未删除任何文件")
        }
    }

    /// 盘间迁移的单独链接：只在缺失，或已经指向源/目标时，改到目标。指向别处不动。
    private static func linkEffects(_ entry: Entry, _ snap: Snapshot, target: String) -> [Effect] {
        guard entry.op == "relocate", let linkPath = entry.linkPath else { return [] }
        switch snap.link {
        case .missing:
            return [.makeLink(at: linkPath, to: target)]
        case .symlink(let dest) where same(dest, entry.sourcePath) || same(dest, target):
            return same(dest, target) ? [] : [.retargetLink(at: linkPath, to: target)]
        default:
            return []
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        return (a as NSString).resolvingSymlinksInPath == (b as NSString).resolvingSymlinksInPath
    }

    private static var runningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
    }

    private func loadEntry() -> Entry? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(Entry.self, from: data)
    }
}
