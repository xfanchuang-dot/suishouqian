import Foundation

/// 操作审计日志（append-only）：迁移/回迁/卸载/修复/清理全记录。
/// 出问题时可回答"这个应用什么时候被动过、结果如何"。
/// 位置：~/Library/Application Support/随手迁/migration.log
enum AuditLog {
    private static let queue = DispatchQueue(label: "com.suishouqian.auditlog")

    /// 测试注入：重定向日志目录（单元测试用，业务代码勿动）
    nonisolated(unsafe) static var directoryOverride: URL?

    private static var logURL: URL {
        let dir: URL
        if let directoryOverride {
            dir = directoryOverride
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
                .appendingPathComponent("随手迁", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("migration.log")
    }

    /// 当前日志文件位置（设置页「打开审计日志」用，测试注入时跟随重定向）
    static var currentLogURL: URL { logURL }

    static func append(_ event: String) {
        queue.sync {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = "[\(df.string(from: Date()))] \(event)\n"
            let url = logURL
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists {
                // 文件已存在就**只能追加**。此前打不开写句柄时会落到下面的原子写分支，
                // 那是"临时文件 + rename 整体替换"——文件存在但不可写（root 所有 / ACL /
                // 换机恢复）时会把整本历史日志换成这一行，append-only 契约被静默破坏。
                guard let handle = FileHandle(forWritingAtPath: url.path) else {
                    NSLog("[随手迁] 审计日志不可写，已跳过本次记录：%@", url.path)
                    return
                }
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                if let data = line.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 读取全部日志（供 UI 展示预留）
    static func readAll() -> String {
        return (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }
}
