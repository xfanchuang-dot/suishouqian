import Foundation

/// 外置盘物理健康状态（SMART）。
enum DiskHealth: String, Codable, Equatable {
    /// SMART Verified：盘体自检通过
    case verified
    /// SMART Failing：盘即将/已经出问题——最高优先级告警
    case failing
    /// 读不到 SMART（多数 USB 硬盘盒不支持 passthrough，或虚拟盘）
    case unsupported
    /// 未探测 / 探测失败
    case unknown

    var isCritical: Bool { self == .failing }
}

/// 一次 SMART 探测结果。
struct DiskHealthInfo: Equatable {
    let health: DiskHealth
    /// 原始 SMART 字符串（"Verified" / "Failing" / ...），展示与诊断用
    let rawStatus: String?
}

/// 磁盘健康探测：读物理盘的 SMART 状态。
///
/// 设计说明：
/// - 这是「备份同盘单点故障」的主防线——盘死之前先预警，让用户有机会把应用搬走；
/// - 只有直连的物理盘才有 SMART；硬盘盒不支持 passthrough 时返回 .unsupported，
///   此时退化为「速度基线」监控（VolumeStore.measuredMBps 显著低于历史即告警）；
/// - 两次子进程调用（卷→取 ParentWholeDisk→查整盘），调用方必须放 OffPool。
enum DiskHealthProbe {

    /// 探测挂载点的物理盘 SMART 状态。阻塞子进程，调用方须放 OffPool。
    static func probe(mountPoint: String) -> DiskHealthInfo {
        guard let wholeDisk = parentWholeDisk(mountPoint: mountPoint) else {
            return DiskHealthInfo(health: .unknown, rawStatus: nil)
        }
        guard let plist = runPlist(["info", "-plist", "/dev/\(wholeDisk)"]),
              let dict = plist as? [String: Any] else {
            return DiskHealthInfo(health: .unknown, rawStatus: nil)
        }
        return DiskHealthInfo(
            health: Self.parseHealth(devicePlist: dict),
            rawStatus: dict["SMARTStatus"] as? String
        )
    }

    /// 从 `diskutil info -plist` 的整盘字典解析健康状态。纯函数，可单元测试。
    static func parseHealth(devicePlist: [String: Any]) -> DiskHealth {
        guard let raw = devicePlist["SMARTStatus"] as? String else {
            return .unsupported
        }
        switch raw.lowercased() {
        case "verified":
            return .verified
        case "failing":
            return .failing
        case "not supported":
            return .unsupported
        default:
            return .unknown
        }
    }

    // MARK: - 私有

    /// 卷挂载点 → 所属整盘（如 disk4）。失败返回 nil。
    private static func parentWholeDisk(mountPoint: String) -> String? {
        guard let plist = runPlist(["info", "-plist", mountPoint]),
              let dict = plist as? [String: Any],
              let whole = dict["ParentWholeDisk"] as? String,
              !whole.isEmpty else { return nil }
        return whole
    }

    /// 跑 diskutil 并解析 plist。失败返回 nil（调用方退化为 .unknown）。
    /// 管道纪律：stdout 先读后等（readDataToEndOfFile 在 wait 之前）。
    private static func runPlist(_ args: [String]) -> Any? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = args
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
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}
