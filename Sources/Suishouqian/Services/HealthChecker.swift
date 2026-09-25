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
        // iPhone 备份：高价值数据
        if p.contains("mobilesync") {
            return Result(label: "iPhone 备份（误删代价高）", systemManaged: false)
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

    /// 审计备份目录：孤儿（应用已不在任何位置）或超龄（超过保留期）
    func checkBackups(drivePath: String) -> [BackupIssue] {
        let backupDir = "\(drivePath)/.suishouqian-backup"
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

    /// 修复断链：在所有已挂载卷的 Applications / Suishouqian_Apps（旧版目录）
    /// 里找同名应用，找到则重建软链接
    func repair(_ link: LinkHealth) -> Bool {
        guard let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) else {
            return false
        }
        for vol in volumes where vol.path.hasPrefix("/Volumes") {
            for sub in ["Applications", "Suishouqian_Apps"] {
                let candidate = "\(vol.path)/\(sub)/\(link.appName)"
                guard fileManager.fileExists(atPath: candidate) else { continue }
                try? fileManager.removeItem(atPath: link.linkPath)
                do {
                    try fileManager.createSymbolicLink(
                        atPath: link.linkPath, withDestinationPath: candidate)
                    // v2.2: 修复后同步台账（新卷/新位置），后续断链可自愈
                    if let uuid = MigrationManifest.volumeUUID(atPath: vol.path) {
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

            try? fileManager.removeItem(atPath: link.linkPath)
            do {
                try fileManager.createSymbolicLink(
                    atPath: link.linkPath, withDestinationPath: candidate)
                if let uuid = MigrationManifest.volumeUUID(atPath: mount) {
                    MigrationManifest.shared.record(
                        appName: link.appName, linkPath: link.linkPath,
                        volumeUUID: uuid, relativePath: entry.relativePath)
                }
                AuditLog.append("断链自愈 \(link.appName)：按卷 UUID 重新定位 → \(candidate)")
                healed.append(link.appName)
            } catch {
                // 自愈失败保持断链状态，体检页仍可手动修复
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

    /// 扫描 ~/Library/Application Support 与 ~/Library/Caches：
    /// 找出没有任何在装应用可认领、且 ≥100MB 的目录
    func checkResidues(drivePath: String?) -> [ResidueItem] {
        let signatures = installedAppSignatures(drivePath: drivePath)
        guard !signatures.isEmpty else { return [] }

        let home = NSHomeDirectory()
        var results: [ResidueItem] = []

        for (location, base) in [
            ("Application Support", "\(home)/Library/Application Support"),
            ("Caches", "\(home)/Library/Caches")
        ] {
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

        let home = NSHomeDirectory()
        var results: [ResidueItem] = []
        for (location, base) in [
            ("Application Support", "\(home)/Library/Application Support"),
            ("Caches", "\(home)/Library/Caches"),
        ] {
            let items = (try? fileManager.contentsOfDirectory(atPath: base)) ?? []
            for item in items {
                if item.lowercased().hasPrefix("com.apple.") { continue }
                let full = "\(base)/\(item)"
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: full, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                guard residueMatches(item, signatures: signatures) else { continue }
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
