import Foundation

/// Time Machine 协作（v3.0 能力四）：让 TM 跳过外置盘上的随手迁管理目录，
/// 省下备份盘上"应用被重复备份"的隐形空间税。
///
/// 安全定位：纯优化项，非破坏性（exclusion 只让 TM 跳过，不删已有备份），
/// 任何失败都不阻塞迁移、不弹错，只记审计日志。提权走显式用户确认——
/// `tmutil addexclusion` 通常需要管理员权限，本模块只做"不提权试一次"，
/// 提权版本由调用方（UI）复用 AppMigrator 的 osascript 提权写法执行。
enum TimeMachineCoordinator {

    /// 随手迁在卷上管理的目录（exclusion 以目录为单位）
    static func managedDirs(on volumeRoot: String) -> [String] {
        ["Applications", "SuishouqianData", ".suishouqian-backup"]
            .map { "\(volumeRoot)/\($0)" }
    }

    /// 该路径是否已被 TM 排除（tmutil isexcluded）。
    /// 阻塞子进程，调用方必须走 OffPool。
    static func isExcluded(_ path: String) -> Bool {
        guard let output = runTmutilCapturing(["isexcluded", path]) else { return false }
        return Self.parseExcluded(output)
    }

    /// 解析 tmutil isexcluded 的输出（纯函数，供测试）。
    /// 输出形如 "[Excluded]\t/Volumes/X/Applications" 或 "[Not Excluded]\t…"。
    static func parseExcluded(_ output: String) -> Bool {
        output.contains("[Excluded]") && !output.contains("[Not Excluded]")
    }

    /// 把路径加入 TM 排除（通常需管理员权限；不提权试一次）。
    static func addExclusion(_ path: String) -> Bool {
        runTmutil(["addexclusion", path])
    }

    /// 移出 TM 排除（某卷上不再有随手迁管理内容时恢复）。
    static func removeExclusion(_ path: String) -> Bool {
        runTmutil(["removeexclusion", path])
    }

    /// 体检用：哪些管理目录还没被排除（→ 待办"可为备份盘省约 XX GB"）。
    /// 每个 isexcluded 都是一次子进程，调用方放 OffPool 批量跑。
    static func missingExclusions(on volumeRoot: String) -> [String] {
        managedDirs(on: volumeRoot).filter { dir in
            FileManager.default.fileExists(atPath: dir) && !isExcluded(dir)
        }
    }

    // MARK: - Private

    private static func runTmutil(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 跑 tmutil 并取回 stdout（铁律：先读至 EOF 再等待退出，防管道 64KB 死锁）
    private static func runTmutilCapturing(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
