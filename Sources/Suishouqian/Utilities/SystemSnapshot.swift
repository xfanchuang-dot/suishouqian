import Foundation

/// APFS 本地快照：迁移/回迁前的最后一道整机保险（出大事先整体回滚）。
/// 快照由系统自动管理（约一天后自动清理、空间紧张时优先回收），零维护成本。
enum SystemSnapshot {
    /// 1 小时内不重复拍——批量迁移 10 个应用只拍一次
    private static let throttleKey = "lastLocalSnapshotAt"
    private static let throttleInterval: TimeInterval = 3600

    /// 创建本地快照（节流版）。成功返回快照描述；失败/节流跳过返回 nil。
    /// 快照只是额外保险层，任何失败都不应阻塞迁移主流程。
    /// 注意：tmutil 是阻塞进程，调用方必须放在 OffPool 里跑。
    @discardableResult
    static func createThrottled() -> String? {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: throttleKey) as? Date,
           Date().timeIntervalSince(last) < throttleInterval {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["localsnapshot", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else {
            AuditLog.append("快照保险：tmutil 无法启动（跳过，不影响主流程）")
            return nil
        }

        // 先读至 EOF 再等待（防管道死锁铁律）
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            AuditLog.append("快照保险：创建失败（跳过，不影响主流程）")
            return nil
        }

        defaults.set(Date(), forKey: throttleKey)
        let desc = output.trimmingCharacters(in: .whitespacesAndNewlines)
        AuditLog.append("快照保险：已建本地快照（\(desc)）")
        return desc
    }
}
