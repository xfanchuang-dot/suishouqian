import Foundation

/// 磁盘链路体检：卷格式 + 连接协议 + 一句话体感结论。
/// v2.5：让「外置盘体感是否等同内置盘」从玄学变成看得见的结论。
struct LinkInfo: Equatable {
    let filesystem: String      // apfs / exfat / msdos ...
    let protocolKind: String    // PCI-Express / USB / ...

    var isExFAT: Bool { filesystem.lowercased().contains("exfat") }
    var filesystemDisplay: String { filesystem.uppercased() }

    /// (结论文案, 是否正面)。exFAT 告警优先级最高，其余按协议分档。
    var verdict: (text: String, positive: Bool) {
        if isExFAT {
            return ("exFAT 拖累性能与可靠性，建议备份数据后抹为 APFS", false)
        }
        let p = protocolKind.lowercased()
        if p.contains("pci") || p.contains("thunderbolt") || p.contains("fabric") {
            return ("雷电/NVMe 级链路，满速体验", true)
        }
        if p.contains("usb") {
            return ("USB 链路，日常流畅；大应用若启动偏慢优先换线缆/硬盘盒", true)
        }
        return ("链路正常，可正常使用", true)
    }
}

enum DiskLinkProbe {

    /// 探测卷格式与连接协议。内部有阻塞子进程，调用方须放 OffPool。
    static func probe(mountPoint: String) -> LinkInfo? {
        var st = statfs()
        guard mountPoint.withCString({ statfs($0, &st) }) == 0 else { return nil }
        let filesystem = cString(of: st.f_fstypename)
        let protocolKind = diskutilProtocol(mountPoint: mountPoint)
        return LinkInfo(filesystem: filesystem, protocolKind: protocolKind)
    }

    /// diskutil info 文本里抓 "Protocol:" 行（阻塞子进程，调用方须放 OffPool）
    private static func diskutilProtocol(mountPoint: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        // 参数数组直传 argv，不经 shell，无需转义
        process.arguments = ["info", mountPoint]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        // 先读至 EOF 再等待（防管道死锁铁律）
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        process.waitUntilExit()

        for line in output.split(separator: "\n") {
            if line.contains("Protocol:") {
                return line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces) ?? ""
            }
        }
        return ""
    }

    private static func cString(of tuple: some Any) -> String {
        withUnsafeBytes(of: tuple) { buffer in
            buffer.baseAddress.map {
                String(cString: $0.assumingMemoryBound(to: CChar.self))
            } ?? ""
        }
    }
}
