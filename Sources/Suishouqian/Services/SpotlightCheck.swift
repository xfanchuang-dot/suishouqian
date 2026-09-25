import Foundation

/// 外置盘 Spotlight 索引状态与开关（v2.10.0 链路体感三期）。
///
/// 为什么要管：外置盘默认被 Spotlight 全量索引——搜索应用名时外置副本会和
/// 内置入口一起冒出来（两个结果点哪个全看运气），后台持续扫描还白白消耗
/// 盘的读写寿命和电。关掉这块盘的索引是外置 SSD 的标准养护动作，
/// 代价只有一条：盘上的东西不再出现在 Spotlight 搜索里。
///
/// 关闭需要管理员权限（mdutil -i off 是 sudo 命令），走 osascript 提权，
/// 与迁移的提权同一套管道纪律：stdout 丢弃、stderr 读至 EOF 再等退出。
enum SpotlightCheck {

    /// 解析 `mdutil -s <挂载点>` 的输出。nil = 状态未知（命令失败/路径不认识）。
    static func parseStatus(_ output: String) -> Bool? {
        // 先判 disabled：两行都含 "Indexing "，顺序反了会把关着的当成开着
        if output.contains("Indexing disabled") { return false }
        if output.contains("Indexing enabled") { return true }
        return nil
    }

    /// 查询某挂载点的索引状态。mdutil 是阻塞子进程，调用方负责放 OffPool。
    static func status(for mountPoint: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", mountPoint]

        // 先读至 EOF 再等待退出（项目铁律，输出短但规矩就是规矩）
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        return parseStatus(out)
    }

    /// 开/关某挂载点的索引（需要管理员授权，弹系统密码框）。
    /// 返回 (是否成功, 失败原因)。
    @discardableResult
    static func setIndexing(_ enabled: Bool, mountPoint: String) -> (success: Bool, error: String?) {
        let flag = enabled ? "on" : "off"
        // 挂载点名含空格/单引号也不破壳：shell 层单引号包裹，单引号翻倍转义
        let escaped = mountPoint.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"mdutil -i \(flag) '\(escaped)'\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        // stdout 直接丢弃：不读它的输出，接成管道没人读会写满 64KB 永久阻塞
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 0 { return (true, nil) }
        let msg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
        if msg.contains("User canceled") { return (false, "已取消授权") }
        return (false, msg)
    }

    /// 给用户复制/留档用的等价命令
    static func commandLine(enabled: Bool, mountPoint: String) -> String {
        let flag = enabled ? "on" : "off"
        return "sudo mdutil -i \(flag) '\(mountPoint)'"
    }
}
