import Foundation
import AppKit

/// 单条软链接的健康状态
struct LinkHealth: Identifiable {
    let id = UUID()
    let appName: String
    let linkPath: String
    let target: String
    let state: LinkState

    enum LinkState {
        case healthy       // 目标存在
        case volumeOffline // 目标所在卷未挂载（插回硬盘即恢复）
        case broken        // 卷在线但目标丢失（需修复或回迁）

        var label: String {
            switch self {
            case .healthy: return "正常"
            case .volumeOffline: return "硬盘未连接"
            case .broken: return "断链"
            }
        }
    }
}

/// 备份目录里的问题项（孤儿或超龄）
struct BackupIssue: Identifiable {
    let id = UUID()
    let appName: String
    let path: String
    let sizeBytes: Int64
    let ageDays: Int
    let isOrphan: Bool

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// 一块外置盘的物理健康（SMART 探测结果）
struct DiskHealthIssue: Identifiable {
    let id = UUID()
    let volumeName: String
    let mountPoint: String
    let volumeUUID: String
    let info: DiskHealthInfo

    var isCritical: Bool { info.health.isCritical }
}

/// 失联的卷：台账里有它的应用，但它已不在挂载表里、且超过阈值没再出现过。
/// 与「离线」（只是没插）不同——失联意味着盘可能已损坏/丢失。
struct LostVolumeInfo: Identifiable {
    let id = UUID()
    let volumeUUID: String
    let appNames: [String]
    let lastSeen: Date?
}

/// 实测速度相对自身历史显著塌陷——USB 盒读不到 SMART 时的盘况预警
struct SpeedAlertIssue: Identifiable {
    let id = UUID()
    let volumeName: String
    let volumeUUID: String
    let alert: VolumeSpeedBaseline.Alert
    /// 触发告警的那次实测时刻
    let measuredAt: Date?
}

/// 已卸载应用在 ~/Library 里的残留数据
struct ResidueItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let sizeBytes: Int64
    let location: String    // Application Support / Caches

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// 内置盘上的大文件（省空间线索）
struct BigFileItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let sizeBytes: Int64

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var directory: String {
        (path as NSString).deletingLastPathComponent
    }

    /// 人话分类说明 + 是否系统管理的数据（v2.5.2：让用户知道"这是什么、敢不敢清"）
    var classification: BigFileClassifier.Result {
        BigFileClassifier.classify(path: path)
    }
}

/// 大文件分类器（纯逻辑，可测试）：按路径特征给用户能看懂的说明
enum BigFileClassifier {
    struct Result: Equatable {
        let label: String          // 这是什么
        let systemManaged: Bool    // 系统管理的数据 → 禁用清理按钮
        /// 工具**不提供**一键清理的高价值数据（不是系统数据，但不该由"省空间"
        /// 这个入口顺手删掉）。iPhone 备份属于这一类：不可再生，且与残留扫描里
        /// 的保护名单 MobileSync 必须是同一口径。
        let protected: Bool

        init(label: String, systemManaged: Bool, protected: Bool = false) {
            self.label = label
            self.systemManaged = systemManaged
            self.protected = protected
        }

        /// 是否禁用"清理"按钮（系统数据与受保护数据都禁用）
        var cleanupDisabled: Bool { systemManaged || protected }
    }

    static func classify(path: String) -> Result {
        let p = path.lowercased()

        // 系统管理的数据：只读展示，绝不建议清理
        if p.contains("containers/com.apple.")
            || p.contains("group containers/group.com.apple.")
            || p.hasPrefix("/private/var")
            || p.contains("library/cloudstorage") {
            return Result(label: "系统数据（建议保留）", systemManaged: true)
        }
        // iPhone 备份：不可再生的高价值数据。残留扫描已把 MobileSync 列进保护名单，
        // 大文件面板此前却给了一个可点的「清理」按钮（只有通用确认文案），
        // 同一份数据两套安全等级。这里统一为"工具不提供一键清理"。
        if p.contains("mobilesync") {
            return Result(label: "iPhone 备份（不可再生，本工具不提供清理）",
                          systemManaged: false, protected: true)
        }
        // 开发缓存：可再生，清理无损
        let devCaches = ["deriveddata", "coresimulator", "node_modules",
                         "/.cocoapods", "/.gradle", "/.npm", "xcode/archives"]
        if devCaches.contains(where: { p.contains($0) }) {
            return Result(label: "开发缓存（可清理，会自动重建）", systemManaged: false)
        }
        // 应用数据：清理可能丢设置/记录
        if p.contains("application support") || p.contains("/containers/")
            || p.contains("group containers") {
            return Result(label: "应用数据（清理可能丢失设置或记录）", systemManaged: false)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "dmg", "iso", "pkg":
            return Result(label: "安装镜像/安装包（装完即可删）", systemManaged: false)
        case "mp4", "mkv", "mov", "avi", "m4v", "mp3", "flac", "wav", "aac":
            return Result(label: "音视频文件", systemManaged: false)
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return Result(label: "压缩包", systemManaged: false)
        case "raw", "vmdk", "qcow2", "img", "hdd", "vdi":
            return Result(label: "虚拟磁盘镜像", systemManaged: false)
        default:
            return Result(label: "其他大文件", systemManaged: false)
        }
    }
}

/// 升级回退（迁移被悄悄撤销）：/Applications 的链接被应用更新器换回了真实目录，
/// 而外置盘还留着迁移副本——内置盘空间被重新占用
struct RegressionItem: Identifiable {
    let id = UUID()
    let appName: String
    let appPath: String       // 内置盘真实目录
    let externalPath: String  // 外置盘旧副本
    let sizeBytes: Int64      // 内置盘重新占用的大小

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// 链接体检：扫描 /Applications 软链接 + 审计 .suishouqian-backup
class HealthChecker: @unchecked Sendable {
    private let fileManager = FileManager.default

    /// 扫描 /Applications 下所有指向 /Volumes 的软链接并分类
    func checkLinks() -> [LinkHealth] {
        var results: [LinkHealth] = []
        guard let contents = try? fileManager.contentsOfDirectory(atPath: "/Applications") else {
            return results
        }

        for item in contents where item.hasSuffix(".app") {
            let linkPath = "/Applications/\(item)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: linkPath),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeSymbolicLink,
                  let target = try? fileManager.destinationOfSymbolicLink(atPath: linkPath),
                  target.hasPrefix("/Volumes/") else { continue }

            results.append(LinkHealth(
                appName: item,
                linkPath: linkPath,
                target: target,
                state: classify(target: target)))
        }
        return results
    }

    /// v2.10.0 开机自启体检：launchd 配置里引用了 /Volumes 的条目。
    /// 挂载名单读 /Volumes 目录——判断"卷在线"对照名单，不 stat 路径本身
    /// （离线卷上 stat 得到的"不存在"与"路径写错"无法区分）。
    func checkLaunchAgents() -> [LaunchAgentIssue] {
        let mounted = Set((try? fileManager.contentsOfDirectory(atPath: "/Volumes")) ?? [])
        return BootAgentScanner.scan(roots: BootAgentScanner.defaultRoots,
                                     mountedVolumes: mounted)
    }

    /// 备份保留天数（设置页可调）。此前体检里硬编码 7 天，
    /// 用户把保留期设成 90 天后仍会被报"超过 7 天可清理"，口径必须与设置一致
    var backupRetentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "backupRetentionDays")
        return days > 0 ? days : 7
    }

    /// 审计备份目录：孤儿（应用已不在任何位置）或超龄（超过保留期）。
    /// 跨盘备份：扫描「全部备份根目录」（同盘 + 指定备份盘），切换备份盘后
    /// 旧备份不会变成扫不到的孤儿。
    func checkBackups(drivePath: String) -> [BackupIssue] {
        var issues: [BackupIssue] = []
        for backupDir in BackupLocations.backupRoots(for: drivePath) {
            issues.append(contentsOf: checkBackups(in: backupDir, drivePath: drivePath))
        }
        return issues
    }

    private func checkBackups(in backupDir: String, drivePath: String) -> [BackupIssue] {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: backupDir) else {
            return []
        }

        // 判孤儿时同时看内置 /Applications 和外置 Applications（链接断了但应用还在的情况）
        var knownApps = Set(contentsOfApplications())
        let externalApps = (try? fileManager.contentsOfDirectory(
            atPath: "\(drivePath)/Applications")) ?? []
        for name in externalApps { knownApps.insert(name) }

        let retentionDays = backupRetentionDays
        var issues: [BackupIssue] = []
        for item in contents {
            // v2.3: 数据目录备份（Data-*）由数据面板负责，不参与应用孤儿审计
            if item.hasPrefix(DataMigrator.manifestPrefix) { continue }
            let full = "\(backupDir)/\(item)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: full),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            let age = Int(Date().timeIntervalSince(mtime) / 86400)
            let orphan = !knownApps.contains(item)
            if orphan || age > retentionDays {
                issues.append(BackupIssue(
                    appName: item, path: full,
                    sizeBytes: duSize(full), ageDays: age, isOrphan: orphan))
            }
        }
        return issues
    }

    // MARK: - 磁盘物理健康（SMART）

    /// 探测每块在线外置盘的 SMART 状态。阻塞子进程，调用方须放 OffPool。
    /// 这是「备份同盘单点故障」的主防线：盘死之前先预警，用户有机会把应用搬走。
    /// USB 硬盘盒多不支持 SMART passthrough → .unsupported，此时看速度基线。
    func checkDiskHealth() -> [DiskHealthIssue] {
        let candidates = DiskMonitor.enumerateVolumes().candidates
        return candidates.compactMap { c in
            guard let uuid = c.volumeUUID, !c.mountPoint.isEmpty else { return nil }
            let info = DiskHealthProbe.probe(mountPoint: c.mountPoint)
            return DiskHealthIssue(volumeName: c.name, mountPoint: c.mountPoint,
                                  volumeUUID: uuid.uppercased(), info: info)
        }
    }

    /// 实测速度塌陷告警（只读历史，**不跑测速**——诚实反映最近一次手动实测的结果）。
    /// SMART 读不到的 USB 盒子靠它兜底；没有足够历史的卷保持沉默（宁缺毋滥）。
    func checkSpeedAlerts() -> [SpeedAlertIssue] {
        DiskMonitor.enumerateVolumes().candidates.compactMap { c in
            guard let uuid = c.volumeUUID?.uppercased(), !c.mountPoint.isEmpty else { return nil }
            let history = VolumeSpeedBaseline.history(volumeUUID: uuid)
            guard let alert = VolumeSpeedBaseline.assess(history: history) else { return nil }
            return SpeedAlertIssue(volumeName: c.name, volumeUUID: uuid,
                                   alert: alert, measuredAt: history.last?.at)
        }
    }

    // MARK: - 失联卷检测

    /// 台账里有应用、但超过阈值没再出现过的卷（≠ 离线：离线只是没插）。
    /// 阈值内没见过的不算——避免用户只是出差没带盘就误报「盘丢了」。
    /// 老用户升级前没有 lastSeen 记录 → 保守地不报（guard let seen）。
    /// 注：协议见证必须是无参签名（默认参数不构成 Checking 的协议满足），
    /// 所以拆成无参入口 + 带阈值实现。
    func checkLostVolumes() -> [LostVolumeInfo] {
        checkLostVolumes(thresholdDays: 90)
    }

    func checkLostVolumes(thresholdDays: Int) -> [LostVolumeInfo] {
        let mounted = Set(DiskMonitor.enumerateVolumes().candidates
            .compactMap(\.volumeUUID).map { $0.uppercased() })
        let lastSeen = VolumeStore.lastSeenMap()
        let cutoff = Date().addingTimeInterval(TimeInterval(-thresholdDays) * 86400)
        let grouped = Dictionary(grouping: MigrationManifest.shared.all(),
                                 by: { $0.volumeUUID.uppercased() })
        return grouped.compactMap { uuid, entries in
            guard !mounted.contains(uuid) else { return nil }
            guard let seen = lastSeen[uuid], seen < cutoff else { return nil }
            return LostVolumeInfo(volumeUUID: uuid,
                                  appNames: entries.map(\.appName).sorted(),
                                  lastSeen: seen)
        }
    }

    /// 失联卷恢复：删掉指向死卷的断链 + 清理其台账条目。
    /// 链接目标已不存在，删除是安全的；返回实际清理的应用名。
    /// 有副作用，不进 Checking 协议，由体检页直接调用。
    func cleanupLostVolume(uuid: String) -> [String] {
        let upper = uuid.uppercased()
        let entries = MigrationManifest.shared.all().filter {
            $0.volumeUUID.uppercased() == upper
        }
        var cleaned: [String] = []
        for e in entries {
            // 只删软链接：误删真目录是灾难（高-1 的教训）
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: e.linkPath, isDirectory: &isDir),
               (try? fileManager.destinationOfSymbolicLink(atPath: e.linkPath)) != nil {
                try? fileManager.removeItem(atPath: e.linkPath)
            }
            MigrationManifest.shared.remove(appName: e.appName)
            cleaned.append(e.appName)
        }
        if !cleaned.isEmpty {
            AuditLog.append("失联卷恢复：清理 \(cleaned.count) 条死链（卷 \(upper.prefix(8))…）")
        }
        return cleaned.sorted()
    }

    /// 修复断链：在所有已挂载卷的 Applications / Suishouqian_Apps（旧版目录）
    /// 里找同名应用，找到则重建软链接。
    /// **优先按台账里的卷 UUID 定位**：同名应用可能同时存在于两块盘上
    /// （换盘后旧盘仍有副本），只认"第一个找到的"会把链接指到错误的盘。
    func repair(_ link: LinkHealth) -> Bool {
        var searchRoots: [String] = []
        if let entry = MigrationManifest.shared.entry(forAppName: link.appName),
           let mount = MigrationManifest.mountPoint(forUUID: entry.volumeUUID) {
            searchRoots.append(mount)
        }
        let mounted = (fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .map(\.path)
            .filter { $0.hasPrefix("/Volumes") }
        for path in mounted where !searchRoots.contains(path) { searchRoots.append(path) }

        for volPath in searchRoots {
            for sub in ["Applications", "Suishouqian_Apps"] {
                let candidate = "\(volPath)/\(sub)/\(link.appName)"
                guard fileManager.fileExists(atPath: candidate) else { continue }
                do {
                    // 高-2（2026-10-04 审计）：原子替换，失败时旧链接原样保留
                    try AppMigrator.swapSymlink(at: link.linkPath, to: candidate)
                    // v2.2: 修复后同步台账（新卷/新位置），后续断链可自愈
                    if let uuid = MigrationManifest.volumeUUID(atPath: volPath) {
                        MigrationManifest.shared.record(
                            appName: link.appName, linkPath: link.linkPath,
                            volumeUUID: uuid, relativePath: "\(sub)/\(link.appName)")
                    }
                    AuditLog.append("修复断链 \(link.appName) → \(candidate)")
                    return true
                } catch {
                    return false
                }
            }
        }
        return false
    }

    /// 删除备份。
    /// **走废纸篓而非永久删除**：界面对用户的承诺就是"删除会移入废纸篓，可恢复"，
    /// 而这不是可选项——它是迁移出问题时唯一的兜底。此前用 removeItem 永久删除，
    /// 与文案不符，且在"全部清理"一键操作下能直接抹掉所有安全底。
    @discardableResult
    func deleteBackup(_ issue: BackupIssue) async -> Bool {
        let ok = await recycleToTrash(issue.path)
        if ok {
            AuditLog.append("删除备份 \(issue.appName)（\(issue.isOrphan ? "孤儿" : "超龄 \(issue.ageDays) 天")，\(issue.sizeFormatted)，已入废纸篓）")
        } else {
            AuditLog.append("删除备份失败 \(issue.appName)：\(issue.path) 未能移入废纸篓")
        }
        return ok
    }

    /// 移入废纸篓并等待完成。
    /// NSWorkspace.recycleURLs 是**异步**的（头文件明确写 Asynchronous），
    /// 此前调用后立刻查 fileExists 判成功，结果恒为 false：界面不移除条目、
    /// 不写审计日志——而文件其实已经进了废纸篓，用户看到的与真实状态不符。
    @discardableResult
    func recycleToTrash(_ path: String) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle([URL(fileURLWithPath: path)]) { _, error in
                // 以"路径是否真的不在了"为准，而不是只看 error
                let gone = !FileManager.default.fileExists(atPath: path)
                continuation.resume(returning: error == nil && gone)
            }
        }
    }

    /// 断链且目标彻底消失时的找回：更新器（Squirrel/ShipIt）的安装分两步——
    /// 先把旧版移走、再把新版从缓存写入；若第二步被系统权限拒绝（本机实测：
    /// 2026-09-12 VS Code 更新写外置盘被 TCC 静默拒绝），应用就"消失"了——
    /// 链接还在但目标为空，新版完整躺在 `~/Library/Caches/<id>.ShipIt/update.*`。
    ///
    /// 这里扫描这些更新缓存，找同名 .app 移回链接指向的目标位置（链接不用动，
    /// 它本来就指着那里）——正是当时手工恢复走过的路径。
    ///
    /// - Parameter cacheRoots: 更新缓存候选根目录（默认扫 ~/Library/Caches，
    ///   传入以供测试）
    static func findVanishedAppCandidates(appName: String,
                                           cacheRoots: [String]? = nil) -> [String] {
        let roots = cacheRoots ?? [NSHomeDirectory() + "/Library/Caches"]
        var candidates: [String] = []
        let fm = FileManager.default

        for root in roots {
            guard let products = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for product in products where product.hasSuffix(".ShipIt") {
                let shipItDir = "\(root)/\(product)"
                guard let entries = try? fm.contentsOfDirectory(atPath: shipItDir) else { continue }
                for entry in entries where entry.hasPrefix("update.") {
                    let candidate = "\(shipItDir)/\(entry)/\(appName)"
                    // 必须像个完整应用（有 Info.plist），半截缓存不能拿来恢复
                    if fm.fileExists(atPath: candidate + "/Contents/Info.plist") {
                        candidates.append(candidate)
                    }
                }
            }
        }
        return candidates
    }

    /// 从更新缓存恢复"消失"的应用：把找到的新版移回断链指向的目标位置。
    /// 返回 nil=恢复成功；返回 String=失败原因
    /// - Parameter cacheRoots: 更新缓存候选根目录（默认扫 ~/Library/Caches，传入以供测试）
    func recoverVanishedTarget(_ link: LinkHealth,
                               cacheRoots: [String]? = nil) -> String? {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link.linkPath),
              !fileManager.fileExists(atPath: target) else {
            return "链接目标仍存在，无需恢复"
        }
        guard let candidate = Self.findVanishedAppCandidates(
                appName: link.appName, cacheRoots: cacheRoots).first else {
            return "更新缓存里没有找到「\(link.appName)」的新版本"
        }

        do {
            try fileManager.createDirectory(
                atPath: (target as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: candidate, toPath: target)
            AuditLog.append("从更新缓存恢复 \(link.appName)：\(candidate) → \(target)")
            return nil
        } catch {
            return "恢复失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 断链自愈与台账回填（v2.2 卷改名免疫）

    /// 按台账自愈所有断链：卷改名/挂载点变化后，链接的绝对路径全断，
    /// 但台账里存了卷 UUID——按 UUID 找到卷（无论叫什么名字）重写链接。
    /// 返回自愈成功的应用名列表。
    func healBrokenLinks() -> [String] {
        var healed: [String] = []
        for link in checkLinks() where link.state == .broken {
            guard let entry = MigrationManifest.shared.entry(forAppName: link.appName),
                  let mount = MigrationManifest.mountPoint(forUUID: entry.volumeUUID) else {
                continue
            }
            let candidate = "\(mount)/\(entry.relativePath)"
            guard fileManager.fileExists(atPath: candidate) else { continue }

            do {
                // 高-2（2026-10-04 审计）：原子替换。旧写法先删后建，建链失败时
                // 条目彻底消失（比断链更糟）；swapSymlink 失败时旧链接原样保留。
                try AppMigrator.swapSymlink(at: link.linkPath, to: candidate)
                if let uuid = MigrationManifest.volumeUUID(atPath: mount) {
                    MigrationManifest.shared.record(
                        appName: link.appName, linkPath: link.linkPath,
                        volumeUUID: uuid, relativePath: entry.relativePath)
                }
                AuditLog.append("断链自愈 \(link.appName)：按卷 UUID 重新定位 → \(candidate)")
                healed.append(link.appName)
            } catch {
                // swapSymlink 是原子的：失败时旧链接原样保留，仍是断链状态，体检页可手动修复
            }
        }
        return healed
    }

    /// 台账回填：v2.1 及更早的迁移没有台账，体检时给健康链接补账，
    /// 让历史迁移也获得卷改名自愈能力（只写缺失项，幂等）
    func backfillManifest() {
        for link in checkLinks() where link.state == .healthy {
            guard MigrationManifest.shared.entry(forAppName: link.appName) == nil,
                  let (root, rel) = volumeRootAndRelative(ofTarget: link.target),
                  let uuid = MigrationManifest.volumeUUID(atPath: root) else { continue }
            MigrationManifest.shared.record(
                appName: link.appName, linkPath: link.linkPath,
                volumeUUID: uuid, relativePath: rel)
        }
    }

    /// 把 "/Volumes/<卷>/剩余/路径" 拆成 卷根 + 相对路径
    private func volumeRootAndRelative(ofTarget target: String) -> (root: String, rel: String)? {
        guard target.hasPrefix("/Volumes/") else { return nil }
        let parts = target.split(separator: "/").map(String.init)
        guard parts.count >= 3 else { return nil }
        return ("/\(parts[0])/\(parts[1])", parts.dropFirst(2).joined(separator: "/"))
    }

    /// 台账校准：清掉链接位已不存在的应用条目。
    ///
    /// 应用被手动卸载、或用户绕过本工具删掉链接后，台账会留下"幽灵记录"
    /// （本机实测积了 6 条：应用早已不在 /Applications，条目仍在），
    /// 会让后续读台账的功能误判。
    ///
    /// 判"不存在"必须用 **lstat 语义**（`attributesOfItem` 不跟随符号链接）：
    /// 硬盘未连接时链接是断的，但链接本身仍在，那种情况绝不能清——
    /// 否则插回硬盘就失去了自愈所需的定位信息。
    /// 数据条目（kind == "data"）不处理：分叉场景下它的链接位本来就可能是真目录。
    @discardableResult
    func pruneStaleManifestEntries() -> [String] {
        var pruned: [String] = []
        for entry in MigrationManifest.shared.all() {
            if entry.kind == "data" { continue }
            // lstat 成功 = 链接（即使断链）或真目录都算"位上有东西"，保留
            if (try? fileManager.attributesOfItem(atPath: entry.linkPath)) != nil { continue }
            MigrationManifest.shared.remove(appName: entry.appName)
            pruned.append(entry.appName)
        }
        if !pruned.isEmpty {
            AuditLog.append("台账校准：清理 \(pruned.count) 条已失效记录（\(pruned.joined(separator: "、"))）")
        }
        return pruned
    }

    // MARK: - 升级回退检测（v2.2）

    /// /Applications 出现真实应用目录、但外置盘还有同名副本 →
    /// 多半是应用自升级时用真目录替换了软链接（迁移被撤销，内置盘重新被占用）。
    /// 用户点过忽略的应用不再上报。
    func checkRegressions(drivePath: String) -> [RegressionItem] {
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "regressionIgnoredApps") ?? [])
        guard let contents = try? fileManager.contentsOfDirectory(atPath: "/Applications") else {
            return []
        }

        var results: [RegressionItem] = []
        for item in contents where item.hasSuffix(".app") {
            if ignored.contains(item) { continue }
            let appPath = "/Applications/\(item)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: appPath),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeDirectory else { continue }   // 软链接（正常迁移态）不算

            // 新旧两个外置应用目录都要看：历史迁移落在 Suishouqian_Apps 里，
            // 只查 Applications 会漏掉它们的"迁移被撤销"
            guard let externalPath = externalAppPath(named: item, drivePath: drivePath) else {
                continue
            }

            results.append(RegressionItem(appName: item, appPath: appPath,
                                          externalPath: externalPath,
                                          sizeBytes: duSize(appPath)))
        }
        return results.sorted { $0.appName < $1.appName }
    }

    /// 外置盘上承载应用本体的目录：新版 Applications + 旧版 Suishouqian_Apps
    func externalAppPath(named bundleName: String, drivePath: String) -> String? {
        for sub in ["Applications", "Suishouqian_Apps"] {
            let candidate = "\(drivePath)/\(sub)/\(bundleName)"
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// 忽略某个升级回退提示（记录后不再上报）
    func ignoreRegression(_ item: RegressionItem) {
        var ignored = UserDefaults.standard.stringArray(forKey: "regressionIgnoredApps") ?? []
        ignored.append(item.appName)
        UserDefaults.standard.set(ignored, forKey: "regressionIgnoredApps")
        AuditLog.append("忽略升级回退：\(item.appName)")
    }

    // MARK: - 大文件扫描（省空间）

    /// 扩展扫描（桌面/文稿/下载）开关。**刻意不做自动探测**——v2.1.1 曾用
    /// contentsOfDirectory 读 Safari/Messages 探测完全磁盘访问，结果这两个
    /// 目录本身就是会弹授权框的受保护目录，正是「点体检弹好多授权」的元凶。
    /// 现在改为设置页显式开关（默认关，开启前引导用户先授权）。
    var extendedScanEnabled: Bool {
        UserDefaults.standard.bool(forKey: "bigFileExtendedScanEnabled")
    }

    /// 大文件扫描范围。桌面/文稿/下载受 TCC 保护，未授权时触碰即弹权限框，
    /// 只有用户在设置页显式开启扩展扫描时才纳入。
    var bigFileRoots: [String] {
        let home = NSHomeDirectory()
        var roots = ["\(home)/Library"]
        if extendedScanEnabled {
            roots.append(contentsOf: ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"])
        }
        return roots
    }

    /// 用户目录下 ≥500MB 的大文件（排除废纸篓与应用包内部文件），按大小取前 N
    func scanBigFiles(minBytes: Int64 = 500 * 1_048_576, limit: Int = 20) -> [BigFileItem] {
        let rootArgs = bigFileRoots
            .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
            .map { "'\($0)'" }
            .joined(separator: " ")
        let minKB = minBytes / 1024
        // *.app/*：应用包内部文件不报（那是应用列表的职责）。
        // Safari/Mail/Messages/com.apple.TCC：双重保险排除——就算扩展扫描开启，
        // 这些高敏目录也绝不触碰（读不到是小事，弹授权框是大事）
        // 注意：这里不再接 `head -200`——find 输出是 NUL 分隔、整条流没有换行，
        // head 按行计数对它完全无效（实测 300 条过 head 仍是 300 条），
        // 真正的条数上限由下面的 prefix(limit) 负责
        let script = """
        find \(rootArgs) -type f -size +\(minKB)k \
          -not -path '*/.Trash/*' -not -path '*.app/*' \
          -not -path '*/Library/Safari/*' -not -path '*/Library/Mail/*' \
          -not -path '*/Library/Messages/*' -not -path '*/com.apple.TCC/*' \
          -print0 2>/dev/null
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        // 铁律：先读至 EOF 再等待退出（先等后读会在管道写满时死锁）
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        process.waitUntilExit()
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        guard !paths.isEmpty else { return [] }

        var items: [BigFileItem] = []
        for path in paths {
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64, size >= minBytes else { continue }
            items.append(BigFileItem(name: (path as NSString).lastPathComponent,
                                     path: path, sizeBytes: size))
        }
        return Array(items.sorted { $0.sizeBytes > $1.sizeBytes }.prefix(limit))
    }

    /// 大文件移入废纸篓（可恢复）。等待回收真正完成，再如实回报结果
    @discardableResult
    func recycleBigFile(_ item: BigFileItem) async -> Bool {
        let ok = await recycleToTrash(item.path)
        if ok {
            AuditLog.append("清理大文件 \(item.name)（\(item.sizeFormatted)，已入废纸篓）")
        }
        return ok
    }

    /// 在 Finder 中显示
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 已卸载应用残留扫描（省空间）

    /// 残留扫描绝不上报的目录：高价值用户数据，即使"找不到属主"也不算残留。
    /// MobileSync = iPhone 备份（苹果无属主标记，误清理代价极高）
    private let protectedResidueNames: Set<String> = ["MobileSync"]

    /// 残留扫描的根目录（v3.1 深清理：从 2 个扩展到 5 个）。
    /// - Application Support / Caches：传统重灾区
    /// - Containers：沙盒应用数据（与 Application Support 同一套认领规则）
    /// - Group Containers：共享容器，被任一在装应用认领即排除（防误删共享数据）
    /// - Saved Application State：窗口恢复状态，卸载后常年堆积
    /// Preferences 只放 plist 文件不放目录，不在扫描范围。
    static let residueScanRoots: [(location: String, subpath: String)] = [
        ("Application Support", "Library/Application Support"),
        ("Caches", "Library/Caches"),
        ("Containers", "Library/Containers"),
        ("Group Containers", "Library/Group Containers"),
        ("Saved State", "Library/Saved Application State"),
    ]

    /// 扫描 ~/Library 下各数据目录：
    /// 找出没有任何在装应用可认领、且 ≥100MB 的目录
    func checkResidues(drivePath: String?) -> [ResidueItem] {
        let signatures = installedAppSignatures(drivePath: drivePath)
        guard !signatures.isEmpty else { return [] }

        let home = NSHomeDirectory()
        var results: [ResidueItem] = []

        for (location, subpath) in Self.residueScanRoots {
            let base = "\(home)/\(subpath)"
            let items = (try? fileManager.contentsOfDirectory(atPath: base)) ?? []
            for item in items {
                // 系统自有目录与工具自身目录不参与；保护名单绝不上报
                if item.lowercased().hasPrefix("com.apple.") || item == "随手迁" { continue }
                if protectedResidueNames.contains(item) { continue }

                let full = "\(base)/\(item)"
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: full, isDirectory: &isDir),
                      isDir.boolValue else { continue }

                let size = duSize(full)
                guard size >= 100 * 1_048_576 else { continue }   // 只报 ≥100MB

                if !residueMatches(item, signatures: signatures) {
                    results.append(ResidueItem(name: item, path: full,
                                               sizeBytes: size, location: location))
                }
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 残留移入废纸篓（可恢复，不做永久删除）。等待回收完成再回报
    @discardableResult
    func recycleResidue(_ item: ResidueItem) async -> Bool {
        let ok = await recycleToTrash(item.path)
        if ok {
            AuditLog.append("清理应用残留 \(item.name)（\(item.location)，\(item.sizeFormatted)，已入废纸篓）")
        }
        return ok
    }

    /// 在装应用特征集：应用名（含去空格/去尾数字变体）+ BundleID + 其前两段
    private func installedAppSignatures(drivePath: String?) -> Set<String> {
        var dirs = ["/Applications", "\(NSHomeDirectory())/Applications"]
        if let drivePath { dirs.append("\(drivePath)/Applications") }

        var signatures = Set<String>()
        for dir in dirs {
            for item in (try? fileManager.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                let bid = (NSDictionary(contentsOfFile: "\(dir)/\(item)/Contents/Info.plist")
                    as? [String: Any])?["CFBundleIdentifier"] as? String
                signatures.formUnion(Self.appSignatures(name: name, bundleID: bid))
            }
        }
        return signatures
    }

    /// 单个应用的特征集（纯逻辑，可测）：名字及其去空格变体 + BundleID + 其前两段。
    /// 在装应用认领目录（checkResidues）与卸载后找残留（residues(forUninstalledApp:)）
    /// 用的是同一套匹配定义，改一处两边同步。
    static func appSignatures(name: String, bundleID: String?) -> Set<String> {
        var signatures = Set<String>()
        let key = name.lowercased()
        signatures.insert(key)
        signatures.insert(key.replacingOccurrences(of: " ", with: ""))
        if let bid = bundleID?.lowercased(), !bid.isEmpty {
            signatures.insert(bid)
            let parts = bid.split(separator: ".")
            if parts.count >= 2 {
                signatures.insert("\(parts[0]).\(parts[1])")
            }
        }
        return signatures
    }

    /// 卸载一条龙（v2.13.0）：应用刚被卸载，找出它在 ~/Library 留下的数据目录。
    /// 与体检的残留扫描不同：阈值降到 10MB（卸载场景用户有明确意图，小残留也有价值），
    /// 且只报匹配被卸载应用自己的目录。清理仍由用户确认后逐项入废纸篓。
    func residues(forUninstalledApp name: String, bundleID: String?) -> [ResidueItem] {
        let signatures = Self.appSignatures(name: name, bundleID: bundleID)
        guard !signatures.isEmpty else { return [] }

        // 先排掉"能被别的在装应用认领"的目录。前缀匹配会误伤：卸载微信
        // （com.tencent.xinWeChat）时，com.tencent 这一段会命中 QQ / 腾讯会议等
        // 其它在装应用的数据目录，用户一路确认就把别人的数据送进废纸篓。
        // 判据用与体检残留扫描同一套特征集（含所有在装应用）。
        let installedSignatures = installedAppSignatures(drivePath: nil)

        let home = NSHomeDirectory()
        var results: [ResidueItem] = []
        for (location, subpath) in Self.residueScanRoots {
            let base = "\(home)/\(subpath)"
            let items = (try? fileManager.contentsOfDirectory(atPath: base)) ?? []
            for item in items {
                if item.lowercased().hasPrefix("com.apple.") { continue }
                let full = "\(base)/\(item)"
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: full, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                guard residueMatches(item, signatures: signatures) else { continue }
                guard !residueMatches(item, signatures: installedSignatures) else { continue }
                let size = duSize(full)
                guard size >= 10 * 1_048_576 else { continue }
                results.append(ResidueItem(name: item, path: full,
                                           sizeBytes: size, location: location))
            }
        }
        return results.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// 目录名是否可被在装应用认领：精确匹配不限长度；前缀互含仅对 ≥4 字符的键（防误匹配）
    func residueMatches(_ dirName: String, signatures: Set<String>) -> Bool {
        var key = dirName.lowercased()
        while let last = key.last, last.isNumber { key.removeLast() }

        if signatures.contains(key) { return true }
        if signatures.contains(dirName.lowercased()) { return true }

        if key.count >= 4 {
            for s in signatures where s.count >= 4 {
                if key.hasPrefix(s) || s.hasPrefix(key) { return true }
            }
        }
        return false
    }

    // MARK: - Private

    func classify(target: String) -> LinkHealth.LinkState {
        if fileManager.fileExists(atPath: target) { return .healthy }

        // 提取目标所在卷挂载点 /Volumes/<卷名>
        let parts = target.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return .broken }
        let volumePath = "/" + parts[0] + "/" + parts[1]

        // 卷路径不存在、或不是独立挂载点（只是内置盘残留目录）→ 视为硬盘未连接
        guard fileManager.fileExists(atPath: volumePath) else { return .volumeOffline }
        var st = statfs()
        guard volumePath.withCString({ statfs($0, &st) }) == 0 else { return .volumeOffline }
        var root = statfs()
        _ = "/".withCString({ statfs($0, &root) })
        let volDev = withUnsafeBytes(of: st.f_mntfromname) { buf in
            buf.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        }
        let rootDev = withUnsafeBytes(of: root.f_mntfromname) { buf in
            buf.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        }
        if volDev == rootDev { return .volumeOffline }

        // 卷在线但目标不存在 → 断链
        return .broken
    }

    private func contentsOfApplications() -> [String] {
        return (try? fileManager.contentsOfDirectory(atPath: "/Applications")) ?? []
    }

    /// du 结果缓存（10 分钟 TTL）：残留/备份审计每次体检会对几十个目录跑 du，
    /// 冷缓存可达几十秒；短时间内重复体检直接复用。近似值对"省空间线索"足够。
    nonisolated(unsafe) private static var duCache: [String: (bytes: Int64, at: Date)] = [:]
    private static let duCacheLock = NSLock()
    private static let duCacheTTL: TimeInterval = 600

    private func duSize(_ path: String) -> Int64 {
        Self.duCacheLock.lock()
        if let hit = Self.duCache[path], Date().timeIntervalSince(hit.at) < Self.duCacheTTL {
            Self.duCacheLock.unlock()
            return hit.bytes
        }
        Self.duCacheLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        // 先读至 EOF 再等待退出（项目铁律：先等后读会在输出写满管道时死锁）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let bytes = Int64(output.split(separator: "\t").first ?? "").map { $0 * 1024 } ?? 0

        Self.duCacheLock.lock()
        Self.duCache[path] = (bytes, Date())
        Self.duCacheLock.unlock()
        return bytes
    }
}
