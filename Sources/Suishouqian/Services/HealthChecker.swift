import Foundation

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

    // MARK: - Private

    private func classify(target: String) -> LinkHealth.LinkState {
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
