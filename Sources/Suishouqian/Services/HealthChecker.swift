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

    /// 审计备份目录：孤儿（应用已不在任何位置）或超龄（>7 天）
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

        let retentionDays = 7
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

    func deleteBackup(_ issue: BackupIssue) {
        try? fileManager.removeItem(atPath: issue.path)
        AuditLog.append("删除备份 \(issue.appName)（\(issue.isOrphan ? "孤儿" : "超龄 \(issue.ageDays) 天")，\(issue.sizeFormatted)）")
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

            let externalPath = "\(drivePath)/Applications/\(item)"
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: externalPath, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            results.append(RegressionItem(appName: item, appPath: appPath,
                                          externalPath: externalPath,
                                          sizeBytes: duSize(appPath)))
        }
        return results.sorted { $0.appName < $1.appName }
    }

    /// 忽略某个升级回退提示（记录后不再上报）
    func ignoreRegression(_ item: RegressionItem) {
        var ignored = UserDefaults.standard.stringArray(forKey: "regressionIgnoredApps") ?? []
        ignored.append(item.appName)
        UserDefaults.standard.set(ignored, forKey: "regressionIgnoredApps")
        AuditLog.append("忽略升级回退：\(item.appName)")
    }

    // MARK: - 大文件扫描（省空间）

    /// 是否已授予完全磁盘访问权限。
    /// 探测 Safari / Messages 目录：这两处未授权时被系统**静默拒绝**（不会弹窗），
    /// 授权后可读——用它们探测不会触发任何 TCC 弹窗。
    var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        for probe in ["\(home)/Library/Safari", "\(home)/Library/Messages"] {
            if (try? fileManager.contentsOfDirectory(atPath: probe)) != nil { return true }
        }
        return false
    }

    /// 大文件扫描范围。桌面/文稿/下载受 TCC 保护，未授权时触碰即弹权限框，
    /// 而本应用 ad-hoc 签名系统存不住授权——未授予 FDA 时一律跳过，保证体检零弹窗。
    var bigFileRoots: [String] {
        let home = NSHomeDirectory()
        var roots = ["\(home)/Library"]
        if hasFullDiskAccess {
            roots.append(contentsOf: ["\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads"])
        }
        return roots
    }

    /// 内置盘用户目录下 ≥500MB 的大文件（排除废纸篓与应用包内部文件），按大小取前 N
    func scanBigFiles(minBytes: Int64 = 500 * 1_048_576, limit: Int = 20) -> [BigFileItem] {
        let rootArgs = bigFileRoots
            .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
            .map { "'\($0)'" }
            .joined(separator: " ")
        let minKB = minBytes / 1024
        // *.app/*：应用包内部文件不报（那是应用列表的职责）
        let script = """
        find \(rootArgs) -type f -size +\(minKB)k \
          -not -path '*/.Trash/*' -not -path '*.app/*' -print0 2>/dev/null | head -200
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

    /// 大文件移入废纸篓（可恢复）
    @discardableResult
    func recycleBigFile(_ item: BigFileItem) -> Bool {
        NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)]) { _, _ in }
        let gone = !fileManager.fileExists(atPath: item.path)
        if gone {
            AuditLog.append("清理大文件 \(item.name)（\(item.sizeFormatted)，已入废纸篓）")
        }
        return gone
    }

    /// 在 Finder 中显示
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 已卸载应用残留扫描（省空间）

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
                // 系统自有目录与工具自身目录不参与
                if item.lowercased().hasPrefix("com.apple.") || item == "随手迁" { continue }

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

    /// 残留移入废纸篓（可恢复，不做永久删除）
    @discardableResult
    func recycleResidue(_ item: ResidueItem) -> Bool {
        var didRecycle = false
        NSWorkspace.shared.recycle([URL(fileURLWithPath: item.path)]) { _, _ in }
        didRecycle = !fileManager.fileExists(atPath: item.path)
        if didRecycle {
            AuditLog.append("清理应用残留 \(item.name)（\(item.location)，\(item.sizeFormatted)，已入废纸篓）")
        }
        return didRecycle
    }

    /// 在装应用特征集：应用名（含去空格/去尾数字变体）+ BundleID + 其前两段
    private func installedAppSignatures(drivePath: String?) -> Set<String> {
        var dirs = ["/Applications", "\(NSHomeDirectory())/Applications"]
        if let drivePath { dirs.append("\(drivePath)/Applications") }

        var signatures = Set<String>()
        for dir in dirs {
            for item in (try? fileManager.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasSuffix(".app") {
                let name = String(item.dropLast(4)).lowercased()
                signatures.insert(name)
                signatures.insert(name.replacingOccurrences(of: " ", with: ""))
                if let plist = NSDictionary(contentsOfFile: "\(dir)/\(item)/Contents/Info.plist"),
                   let bid = plist["CFBundleIdentifier"] as? String {
                    signatures.insert(bid.lowercased())
                    let parts = bid.lowercased().split(separator: ".")
                    if parts.count >= 2 {
                        signatures.insert("\(parts[0]).\(parts[1])")
                    }
                }
            }
        }
        return signatures
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

    private func duSize(_ path: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        if let kb = Int64(output.split(separator: "\t").first ?? "") {
            return kb * 1024
        }
        return 0
    }
}
