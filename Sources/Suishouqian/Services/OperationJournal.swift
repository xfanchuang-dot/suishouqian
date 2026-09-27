import Foundation

/// 用户意图级操作（撤销的逆操作定义在这里，执行走完整安全链）
enum JournalOperation: String, Codable {
    case migrate      // 迁移（含纯搬迁，params 区分 createLink）
    case restore      // 回迁
    case moveBack     // 外置盘原住民搬回内置盘
    case uninstall    // 卸载一条龙
    case remigrate    // 更新回归后重新迁移
    case relocate     // 盘间迁移（params: fromUUID/toUUID）
    case undo         // 撤销（params.undoneID 指被撤销的条目）

    /// 逆操作（nil = 无常规逆操作：uninstall 走"从废纸篓恢复"特殊路径，
    /// undo 本身不再套娃——撤销链用 undoneBy 字段记，防止糊涂账）
    var inverse: JournalOperation? {
        switch self {
        case .migrate: return .restore
        case .restore: return .migrate
        case .moveBack: return .migrate
        case .uninstall: return nil
        case .remigrate: return .restore
        case .relocate: return .relocate // 逆向盘间迁移（params 交换 from/to）
        case .undo: return nil
        }
    }
}

struct JournalEntry: Codable, Equatable {
    let id: UUID
    let at: Date
    let op: JournalOperation
    let appName: String
    /// volumeUUID / createLink / batchID / fromUUID→toUUID 等
    let params: [String: String]
    /// "ok" 或 "failed: 原因"
    let result: String
    /// 当时拍的 APFS 快照描述（终极后悔药的线索）
    let snapshotID: String?
    /// 留底备份位置
    let backupPath: String?
    /// 被哪条撤销覆盖（防"我撤销了撤销"的糊涂账）
    var undoneBy: UUID?

    var isOK: Bool { result == "ok" }
    var isUndone: Bool { undoneBy != nil }
}

/// 结构化操作日志（JSON Lines，append-only）。
/// AuditLog（人类文本）保留不动；这个是给机器读的：时间线 UI + 撤销依据。
/// 记日志永不抛错、永不阻塞主流程——日志写不进去，迁移本身不能失败。
final class OperationJournal: @unchecked Sendable {
    static let shared = OperationJournal()

    /// 测试注入：重定向存储目录（业务代码勿动）
    nonisolated(unsafe) static var directoryOverride: URL?

    /// 文件超过这个体积就裁剪到 recentKeep 条（防年复一年无限膨胀）
    private static let trimThresholdBytes = 1_048_576
    private static let recentKeep = 500

    private let queue = DispatchQueue(label: "com.suishouqian.journal")

    private var fileURL: URL {
        let dir: URL
        if let override = Self.directoryOverride {
            dir = override
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
                .appendingPathComponent("随手迁", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("operation-journal.jsonl")
    }

    /// 记录一条。失败静默放弃。
    func record(op: JournalOperation, appName: String,
                params: [String: String] = [:], result: String,
                snapshotID: String? = nil, backupPath: String? = nil) {
        let entry = JournalEntry(id: UUID(), at: Date(), op: op, appName: appName,
                                 params: params, result: result,
                                 snapshotID: snapshotID, backupPath: backupPath,
                                 undoneBy: nil)
        queue.async { [fileURL] in
            guard let line = try? JSONEncoder().encode(entry),
                  var text = String(data: line, encoding: .utf8) else { return }
            text += "\n"
            guard let data = text.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = FileHandle(forWritingAtPath: fileURL.path) else { return }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                Self.trimIfNeeded(fileURL: fileURL)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// 标记某条目已被撤销（撤销链）
    func markUndone(id: UUID, by undoID: UUID) {
        queue.async { [fileURL] in
            var entries = Self.readAll(from: fileURL)
            guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[i].undoneBy = undoID
            Self.rewrite(entries: entries, to: fileURL)
        }
    }

    /// 最近 N 条（时间线 UI 用，倒序）。读文件虽快，UI 侧仍建议包 Task 调。
    func recent(limit: Int = 10) -> [JournalEntry] {
        queue.sync {
            Self.readAll(from: fileURL).sorted { $0.at > $1.at }.prefix(limit).map { $0 }
        }
    }

    // MARK: - Private

    private static func readAll(from url: URL) -> [JournalEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(JournalEntry.self, from: Data(line.utf8))
        }
    }

    private static func rewrite(entries: [JournalEntry], to url: URL) {
        let lines = entries.compactMap { e -> String? in
            guard let d = try? JSONEncoder().encode(e),
                  let s = String(data: d, encoding: .utf8) else { return nil }
            return s
        }.joined(separator: "\n") + "\n"
        try? lines.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 只在写线程上调用；超阈值时保留最近 recentKeep 条
    private static func trimIfNeeded(fileURL: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path)[.size] as? Int64), size > trimThresholdBytes else { return }
        let kept = Array(readAll(from: fileURL).suffix(recentKeep))
        rewrite(entries: kept, to: fileURL)
    }
}

/// 撤销规划器（纯逻辑）：给定一条 journal 条目与**实时**文件系统上下文，
/// 判定撤销是否可行、可行时逆操作是什么。不可行必须给人话原因。
/// 撤销是 TOCTOU 高发区：上下文必须由调用方在执行前一刻采集，全部重验。
enum UndoPlanner {

    struct UndoContext {
        var appRunning: Bool
        /// 卸载撤销：废纸篓里还有应用本体吗
        var trashContainsApp: Bool
        /// 外置盘上还有可用副本吗（迁移/盘间迁移的撤销依赖它）
        var externalCopyExists: Bool
        /// 内置盘上还有可用副本吗（回迁的撤销=再迁出，依赖它）
        var internalCopyExists: Bool
        /// /Applications 链接位当前可用吗
        var linkUsable: Bool
        /// 撤销动作涉及的原卷（如盘间迁移的源盘）在线吗
        var originVolumeOnline: Bool
        var internalFreeBytes: Int64
        var externalFreeBytes: Int64
        var appSize: Int64
    }

    struct UndoPlan: Equatable {
        /// 是否可执行
        let feasible: Bool
        /// 不可行时的人话原因；可行时是执行说明
        let message: String
        /// 可行时的逆操作（调用方据此走现有安全链执行；uninstall 撤销是特殊路径，返回 nil）
        let inverseOp: JournalOperation?
    }

    static func plan(entry: JournalEntry, context: UndoContext) -> UndoPlan {
        guard entry.isOK else {
            return UndoPlan(feasible: false,
                            message: "这条操作当时就失败了，没有东西可撤销", inverseOp: nil)
        }
        guard !entry.isUndone else {
            return UndoPlan(feasible: false, message: "已经撤销过一次了", inverseOp: nil)
        }
        guard !context.appRunning else {
            return UndoPlan(feasible: false,
                            message: "「\(entry.appName)」正在运行，先退出再撤销", inverseOp: nil)
        }

        switch entry.op {
        case .migrate, .remigrate:
            // 撤销迁移 = 回迁：外置副本要在，内置盘要有单份空间
            guard context.externalCopyExists else {
                return UndoPlan(feasible: false,
                                message: "外置盘上的副本已不在，无法回迁撤销", inverseOp: nil)
            }
            guard context.internalFreeBytes >= context.appSize else {
                return UndoPlan(feasible: false,
                                message: "内置盘剩余空间不够放下这个应用，先清理再撤销", inverseOp: nil)
            }
            return UndoPlan(feasible: true, message: "回迁到内置盘（走完整安全链）",
                            inverseOp: .restore)

        case .restore, .moveBack:
            // 撤销回迁 = 再迁出：内置副本要在，外置盘要装得下两份（副本+留底）
            guard context.internalCopyExists else {
                return UndoPlan(feasible: false,
                                message: "内置盘上的应用副本已不在，无法再迁出撤销", inverseOp: nil)
            }
            let need = AppMigrator.requiredTargetBytes(appSize: context.appSize)
            guard context.externalFreeBytes >= need else {
                return UndoPlan(feasible: false,
                                message: "外置盘剩余空间不够（需容纳副本与留底备份两份）", inverseOp: nil)
            }
            return UndoPlan(feasible: true, message: "重新迁移到外置盘（走完整安全链）",
                            inverseOp: .migrate)

        case .relocate:
            // 撤销盘间迁移 = 反向搬回去：目标盘（当前所在）副本要在，源盘在线且装得下
            guard context.externalCopyExists else {
                return UndoPlan(feasible: false,
                                message: "应用当前所在盘的副本已不在，无法反向撤销", inverseOp: nil)
            }
            guard context.originVolumeOnline else {
                return UndoPlan(feasible: false,
                                message: "原来的那块盘现在不在线，插上后再撤销", inverseOp: nil)
            }
            let need = AppMigrator.requiredTargetBytes(appSize: context.appSize)
            guard context.externalFreeBytes >= need else {
                return UndoPlan(feasible: false,
                                message: "目标盘剩余空间不够（需容纳副本与留底备份两份）", inverseOp: nil)
            }
            return UndoPlan(feasible: true, message: "搬回原来的盘（链接指回源盘）",
                            inverseOp: .relocate)

        case .uninstall:
            // 卸载没有常规逆操作：废纸篓还在就能恢复，不在就如实告知
            guard context.trashContainsApp else {
                return UndoPlan(feasible: false,
                                message: "废纸篓已清空，无法从废纸篓恢复；如留有备份可在体检页查看",
                                inverseOp: nil)
            }
            return UndoPlan(feasible: true,
                            message: "从废纸篓恢复应用本体与链接", inverseOp: nil)

        case .undo:
            return UndoPlan(feasible: false, message: "撤销本身不需要再撤销", inverseOp: nil)
        }
    }
}
