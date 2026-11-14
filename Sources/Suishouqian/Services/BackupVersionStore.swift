import Foundation

/// 一个历史备份版本。
/// 目录布局（向后兼容，免费用户的 `<root>/<AppName>` 当前备份保持原样）：
/// ```
/// <backupRoot>/<AppName>                                       ← 当前备份
/// <backupRoot>/.versions/<AppName>/<yyyyMMdd-HHmmss>/<AppName> ← 历史版本
/// ```
struct BackupVersion: Identifiable, Equatable {
    let appName: String
    /// 内层应用目录（.../<时间戳>/<AppName>）
    let path: String
    let createdAt: Date
    let sizeBytes: Int64
    /// 所属备份根（恢复前快照回同一根）
    let root: String

    var id: String { path }

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// 版本化备份的存储层（纯文件操作，不含 UI）。
///
/// 安全边界：
/// - 归档/快照失败绝不影响正在进行的迁移（调用方只当它不存在，继续走原逻辑）；
/// - 裁剪只删除版本目录内、名称形如时间戳的子目录，不碰 `<root>/<AppName>`；
/// - `delete` 校验路径必须位于 `.versions` 下，防止误删当前备份。
enum BackupVersionStore {
    static let versionsDirName = ".versions"
    static let maxVersionsPerApp = 5

    enum SnapshotMode {
        /// 同卷 rename（迁移前归档当前备份，零拷贝、瞬时）
        case move
        /// 复制后保留原件（恢复前快照；原件随后要被替换，不能直接搬走）
        case copy
    }

    // MARK: - 路径

    static func versionsDirectory(in backupRoot: String) -> String {
        "\(backupRoot)/\(versionsDirName)"
    }

    static func appVersionsDirectory(in backupRoot: String, appName: String) -> String {
        "\(versionsDirectory(in: backupRoot))/\(appName)"
    }

    // MARK: - 写

    /// 迁移写新备份前调用：把上一份当前备份归档为历史版本。
    /// `entitled == false`（免费用户）直接返回 nil——行为与历史版本完全一致。
    @discardableResult
    static func archiveCurrentBackup(backupPath: String,
                                     appName: String,
                                     in backupRoot: String,
                                     entitled: Bool,
                                     now: Date = Date(),
                                     fileManager: FileManager = .default) -> BackupVersion? {
        guard entitled else { return nil }
        return snapshot(directory: backupPath, appName: appName, in: backupRoot,
                        mode: .move, now: now, fileManager: fileManager)
    }

    /// 把目录存为版本。返回 nil 表示目录不存在或操作失败（调用方继续原流程）。
    @discardableResult
    static func snapshot(directory: String,
                         appName: String,
                         in backupRoot: String,
                         mode: SnapshotMode = .move,
                         now: Date = Date(),
                         fileManager: FileManager = .default) -> BackupVersion? {
        guard fileManager.fileExists(atPath: directory) else { return nil }
        let appDir = appVersionsDirectory(in: backupRoot, appName: appName)
        guard (try? fileManager.createDirectory(atPath: appDir,
                                                withIntermediateDirectories: true)) != nil else {
            AuditLog.append("备份归档失败 \(appName)：无法创建版本目录")
            return nil
        }
        let stamp = uniqueStamp(in: appDir, now: now, fileManager: fileManager)
        let versionDir = "\(appDir)/\(stamp)"
        let payload = "\(versionDir)/\(appName)"

        do {
            try fileManager.createDirectory(atPath: versionDir, withIntermediateDirectories: true)
            switch mode {
            case .move:
                try fileManager.moveItem(atPath: directory, toPath: payload)
            case .copy:
                guard copyDirectory(from: directory, to: payload) else {
                    throw NSError(domain: "BackupVersionStore", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "复制失败"])
                }
            }
        } catch {
            try? fileManager.removeItem(atPath: versionDir)
            AuditLog.append("备份归档失败 \(appName)：\(error.localizedDescription)")
            return nil
        }

        prune(appName: appName, in: backupRoot, fileManager: fileManager)
        return BackupVersion(appName: appName, path: payload, createdAt: now,
                             sizeBytes: 0, root: backupRoot)
    }

    // MARK: - 读

    /// 列出历史版本（新的在前）。`appName == nil` 时列出所有应用。
    /// `computeSize == false` 跳过 du（单测/快速探测用）。
    static func listVersions(in backupRoot: String,
                             appName: String? = nil,
                             computeSize: Bool = true,
                             fileManager: FileManager = .default) -> [BackupVersion] {
        let versionsDir = versionsDirectory(in: backupRoot)
        let appNames: [String]
        if let appName {
            appNames = [appName]
        } else {
            appNames = ((try? fileManager.contentsOfDirectory(atPath: versionsDir)) ?? [])
                .filter { !$0.hasPrefix(".") }
        }

        var out: [BackupVersion] = []
        for app in appNames {
            let appDir = "\(versionsDir)/\(app)"
            let stamps = ((try? fileManager.contentsOfDirectory(atPath: appDir)) ?? [])
                .filter { isVersionStamp($0) }
            for stamp in stamps {
                let payload = "\(appDir)/\(stamp)/\(app)"
                guard fileManager.fileExists(atPath: payload) else { continue }
                let created = date(fromStamp: stamp)
                    ?? ((try? fileManager.attributesOfItem(atPath: payload)[.modificationDate]) as? Date)
                    ?? Date.distantPast
                let size = computeSize ? AppScanner.directorySizeBytes(atPath: payload) : 0
                out.append(BackupVersion(appName: app, path: payload,
                                         createdAt: created, sizeBytes: size,
                                         root: backupRoot))
            }
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    /// 扫描全部备份根（同盘 + 指定备份盘），新的在前。
    static func listAllVersions(roots: [String],
                                computeSize: Bool = true,
                                fileManager: FileManager = .default) -> [BackupVersion] {
        var seen = Set<String>()
        var out: [BackupVersion] = []
        for root in roots where !seen.contains(root) {
            seen.insert(root)
            out.append(contentsOf: listVersions(in: root,
                                                computeSize: computeSize,
                                                fileManager: fileManager))
        }
        return out.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 删

    /// 删除一个历史版本（连同其时间戳目录）。只允许删除 `.versions` 下的内容。
    @discardableResult
    static func delete(_ version: BackupVersion,
                       fileManager: FileManager = .default) -> Bool {
        let versionDir = (version.path as NSString).deletingLastPathComponent
        guard version.path.contains("/\(versionsDirName)/"),
              versionDir != versionsDirectory(in: version.root) else {
            AuditLog.append("拒绝删除版本：路径不在 .versions 下（\(version.path)）")
            return false
        }
        let ok = (try? fileManager.removeItem(atPath: versionDir)) != nil
        if ok { AuditLog.append("已删除历史版本：\(version.appName) \(stampText(version.createdAt))") }
        return ok
    }

    // MARK: - 裁剪

    /// 每个应用只保留最新 `keep` 个版本（按时间戳降序）。
    static func prune(appName: String,
                      in backupRoot: String,
                      keep: Int = maxVersionsPerApp,
                      fileManager: FileManager = .default) {
        let appDir = appVersionsDirectory(in: backupRoot, appName: appName)
        guard let entries = try? fileManager.contentsOfDirectory(atPath: appDir) else { return }
        let stamps = entries.filter(isVersionStamp).sorted(by: >)   // yyyyMMdd-HHmmss 字典序 = 时间序
        let overflow = stamps.count - max(keep, 1)
        guard overflow > 0 else { return }
        for stamp in stamps.suffix(overflow) {
            try? fileManager.removeItem(atPath: "\(appDir)/\(stamp)")
        }
    }

    // MARK: - 时间戳

    /// `yyyyMMdd-HHmmss`；同秒冲突时追加 `-2`、`-3`…
    static func uniqueStamp(in directory: String,
                            now: Date,
                            fileManager: FileManager = .default) -> String {
        let base = stampText(now)
        var candidate = base
        var index = 2
        while fileManager.fileExists(atPath: "\(directory)/\(candidate)") {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    /// 供 UI 显示（本地时区，人读）
    static func stampText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    /// 展示用：`2026-11-14 12:30`
    static func displayText(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt.string(from: date)
    }

    static func isVersionStamp(_ name: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count >= 2,
              parts[0].count == 8, parts[1].count == 6,
              Int(parts[0]) != nil, Int(parts[1]) != nil else { return false }
        return true
    }

    private static func date(fromStamp stamp: String) -> Date? {
        let parts = stamp.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt.date(from: "\(parts[0])-\(parts[1])")
    }

    // MARK: - 复制

    /// ditto 保留资源分支/权限/扩展属性；比 FileManager.copyItem 更适合 .app 包。
    private static func copyDirectory(from source: String, to destination: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source, destination]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: destination) else { return false }
        return true
    }
}
