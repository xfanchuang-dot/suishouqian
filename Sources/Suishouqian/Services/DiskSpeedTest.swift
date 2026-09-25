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
        let temp = mountPoint + "/.suishouqian-speedtest"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        guard let write = dd(mbs: sizeMB, args: ["if=/dev/zero", "of=\(temp)", "bs=1m", "count=\(sizeMB)"]),
              write > 0 else { return nil }
        guard let read = dd(mbs: sizeMB, args: ["if=\(temp)", "of=/dev/null", "bs=1m"]),
              read > 0 else { return nil }
        return (write, read)
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
