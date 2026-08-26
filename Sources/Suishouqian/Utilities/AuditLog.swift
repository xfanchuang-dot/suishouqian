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

    static func append(_ event: String) {
        queue.sync {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let line = "[\(df.string(from: Date()))] \(event)\n"
            let url = logURL
            if let handle = FileHandle(forWritingAtPath: url.path) {
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
