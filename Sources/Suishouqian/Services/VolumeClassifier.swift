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
    /// 上次读取失败的时刻（nil = 上次读取成功）。用来区分「确实没有 TM 目标」与「读不到」
    nonisolated(unsafe) private static var lastFailureAt: Date?

    /// 缓存有效期。此前 cachedAt 只写不读、也没有 TTL：应用启动后新设的 Time Machine
    /// 目标盘永远进不了缓存，TM 护栏在运行时静默失效（迁到备份盘 = 应用会被系统清理掉）
    static let cacheTTL: TimeInterval = 600

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

    /// 上次读取是否成功。缓存为空但读取成功 = 确实没有 TM 目标；否则是"读不到"，不可当依据
    static var lastReadSucceeded: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastFailureAt == nil
    }

    /// 重新读取 Time Machine 目标盘并更新缓存。
    /// **读取失败时绝不覆盖已有结果**：此前失败会把缓存清成空集合，而
    /// `isOnTimeMachineVolume` 对空缓存一律放行（fail-open）——一次读取失败就让
    /// TM 护栏整轮失效，且再也不会自愈。现在失败只记录、保留上一次的已知结果。
    /// tmutil 是阻塞子进程，调用方必须放到 OffPool。
    @discardableResult
    static func refreshTimeMachineCache() -> Set<String> {
        guard let plist = timeMachineDestinationPlist() else {
            lock.lock()
            let isFirstFailure = (lastFailureAt == nil)
            lastFailureAt = Date()
            let known = cachedMountPoints
            lock.unlock()
            if isFirstFailure {
                AuditLog.append("读取 Time Machine 目标盘失败：本次无法确认哪些盘是备份盘，迁移预检缺少这一层")
            }
            return known
        }
        let points = parseTimeMachineDestinations(plist: plist)
        lock.lock()
        cachedMountPoints = points
        cachedAt = Date()
        lastFailureAt = nil
        lock.unlock()
        return points
    }

    /// 缓存不新鲜（未建立，或超过 maxAge）时补一次。
    /// 读取失败不会更新 cachedAt，所以会自然重试到成功为止。
    static func ensureCachePrimed(maxAge: TimeInterval = cacheTTL) {
        lock.lock()
        let at = cachedAt
        lock.unlock()
        let stale = at.map { Date().timeIntervalSince($0) >= maxAge } ?? true
        if stale { refreshTimeMachineCache() }
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
