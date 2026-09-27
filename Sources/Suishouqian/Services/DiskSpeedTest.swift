import Foundation

/// 磁盘实测速度（v2.12.0，链路体检的量化版）。
///
/// 链路体检只报协议（USB/雷电/fabric），协议不等于体感——同一根 USB 线上
/// NVMe 盒子能跑 900MB/s，老机械盒子只有 40MB/s，差 20 倍。这里用 dd 写一坨
/// 临时文件再读回来，给出真实数字：数字好，换线建议才有底气说"不用换"；
/// 数字差，才轮到建议换线换盒。
///
/// 代价是写 sizeMB 的临时文件（测完即删）：做成手动触发，不随体检自动跑，
/// 避免每次体检都白写几百 MB 磨盘。
enum DiskSpeedTest {

    /// 实测写入与读取速度（MB/s）。任何一步失败返回 nil。
    static func run(mountPoint: String, sizeMB: Int = 256) -> (writeMBps: Double, readMBps: Double)? {
        // 写盘前必须先确认"目标盘此刻真的挂在这条路径上"：盘已拔出而 /Volumes/X
        // 只是个残留目录时（本项目历史上出现过这种残留），dd 会把 256MB 真写进内置盘，
        // 结果还被当成外置盘速度展示。顺带预检只读与剩余空间。
        guard isWritableMount(mountPoint: mountPoint,
                              needBytes: Int64(sizeMB) * 1_048_576) else { return nil }
        let temp = mountPoint + "/.suishouqian-speedtest"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        guard let write = dd(mbs: sizeMB, args: ["if=/dev/zero", "of=\(temp)", "bs=1m", "count=\(sizeMB)"]),
              write > 0 else { return nil }
        guard let read = dd(mbs: sizeMB, args: ["if=\(temp)", "of=/dev/null", "bs=1m"]),
              read > 0 else { return nil }
        return (write, read)
    }

    /// 该路径是否是一个"可写的、已挂载的非内置卷"（不是内置盘上的残留目录、不是只读卷、空间够）
    static func isWritableMount(mountPoint: String, needBytes: Int64) -> Bool {
        // 用卷属性而不是 statfs 设备名判断：APFS 的「系统卷 / 数据卷」是两个设备节点，
        // 拿根卷设备名比对认不出 /Users 一类路径其实也在内置盘上。
        guard let values = try? URL(fileURLWithPath: mountPoint).resourceValues(
            forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey,
                      .volumeIsReadOnlyKey, .volumeIsLocalKey,
                      .volumeAvailableCapacityKey]) else { return false }
        // 内置卷（且不可移除）= 盘没挂上，路径只是内置盘上的普通目录
        if values.volumeIsInternal == true && values.volumeIsRemovable != true { return false }
        if values.volumeIsLocal == false { return false }
        if values.volumeIsReadOnly == true { return false }
        let need = needBytes + needBytes / 20
        guard let free = values.volumeAvailableCapacity, Int64(free) >= need else { return false }
        return true
    }

    /// 跑一次 dd，从 stderr 的统计行解析速率（dd 的统计走 stderr 不是 stdout）。
    private static func dd(mbs: Int, args: [String]) -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/dd")
        process.arguments = args

        // stdout 丢弃（读盘时 of=/dev/null，写盘时本就无 stdout 输出）；
        // stderr 接管道读统计——先读至 EOF 再等退出（项目铁律）
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        guard (try? process.run()) != nil else { return nil }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let err = String(data: data, encoding: .utf8) else { return nil }
        guard let bytesPerSec = parseSpeed(err) else { return nil }
        return bytesPerSec / 1_048_576.0
    }

    /// 从 dd 统计输出取最后一个 "(N bytes/sec)"。纯逻辑，可测。
    static func parseSpeed(_ output: String) -> Double? {
        // dd 输出形如：536870912 bytes transferred in 0.61 secs (876046225 bytes/sec)
        guard let regex = try? NSRegularExpression(pattern: #"\(([0-9.]+) bytes/sec\)"#) else {
            return nil
        }
        let ns = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        let value = last.range(at: 1)   // 捕获组：括号里的数字本身
        guard value.location != NSNotFound, let r = Range(value, in: output) else { return nil }
        return Double(output[r])
    }
}
