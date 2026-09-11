import Foundation

/// 卷用途识别：把「哪些盘不能放应用」这类常识固化成代码。
///
/// 目前唯一但致命的规则是 Time Machine 备份盘不能当迁移目标——系统在备份盘
/// 空间紧张时会自动清理旧备份，放上去的应用会被静默销毁，而 /Applications 的
/// 链接还指向那里。本机实测：数据盘与 TM 备份盘是同一块物理盘的两个分区、
/// 容量完全相同，仅靠"取容量最大"选盘会选错。
enum VolumeClassifier {

    // MARK: - Time Machine 备份盘识别

    private static let lock = NSLock()
    // 与 HealthChecker 的 duCache 同款写法：访问都由 lock 保护
    nonisolated(unsafe) private static var cachedMountPoints: Set<String> = []
    nonisolated(unsafe) private static var cachedAt: Date?

    /// 已缓存的结果（主线程可安全读，不做子进程调用）
    static var timeMachineMountPoints: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return cachedMountPoints
    }

    /// 缓存是否已建立过（用于判断"读不到"还是"还没有 TM 配置"）
    static var cacheIsPrimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedAt != nil
    }

    /// 重新读取 Time Machine 目标盘并更新缓存。
    /// tmutil 是阻塞子进程，调用方必须放到后台（Task.detached）或可接受阻塞的时机。
    @discardableResult
    static func refreshTimeMachineCache() -> Set<String> {
        let points = parseTimeMachineDestinations(plist: timeMachineDestinationPlist())
        lock.lock()
        cachedMountPoints = points
        cachedAt = Date()
        lock.unlock()
        return points
    }

    /// 缓存未建立时补一次（迁移前的最后一道拦截用它，见 AppMigrator.validateTarget）
    static func ensureCachePrimed() {
        if !cacheIsPrimed { _ = refreshTimeMachineCache() }
    }

    /// 解析 `tmutil destinationinfo -X` 的 plist，取出本地目标的挂载点。
    /// 纯函数，便于单元测试。
    /// 注意：Destination 的 ID **不是**卷 UUID（本机实测两者不同），只能按挂载点匹配。
    static func parseTimeMachineDestinations(plist: Data?) -> Set<String> {
        guard let plist,
              let parsed = try? PropertyListSerialization.propertyList(
                  from: plist, options: [], format: nil),
              let dict = parsed as? [String: Any],
              let destinations = dict["Destinations"] as? [[String: Any]] else {
            return []
        }

        var points = Set<String>()
        for destination in destinations {
            // 网络目标（Kind != Local）没有本地挂载点，不参与
            if let kind = destination["Kind"] as? String, kind != "Local" { continue }
            guard let mount = destination["MountPoint"] as? String, !mount.isEmpty else { continue }
            points.insert(canonical(mount))
        }
        return points
    }

    /// 该路径是否位于 Time Machine 备份盘上（含其子目录）
    static func isOnTimeMachineVolume(path: String) -> Bool {
        let points = timeMachineMountPoints
        guard !points.isEmpty else { return false }
        let target = canonical(path)
        return points.contains { target == $0 || target.hasPrefix($0 + "/") }
    }

    private static func timeMachineDestinationPlist() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["destinationinfo", "-X"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // 铁律：先读至 EOF 再等待退出（先等后读会在管道写满时死锁）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    // MARK: - 「这块盘我们以前用过吗」评分

    /// 盘根留着的随手迁足迹，越明确分越高。
    /// 多盘（尤其同容量的两块盘）并列时，用它认出「一直在用的那块盘」，
    /// 避免目标盘在数据盘与备份盘之间来回漂移。
    static func footprintScore(volumeRoot: String) -> Int {
        var score = 0
        if exists("\(volumeRoot)/.suishouqian-backup") { score += 4 }
        if exists("\(volumeRoot)/Suishouqian_Apps") { score += 3 }
        if exists("\(volumeRoot)/SuishouqianData") { score += 2 }
        if exists("\(volumeRoot)/Applications") { score += 1 }
        return score
    }

    private static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func canonical(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
