import Foundation
import AppKit
import CryptoKit

class AppMigrator: @unchecked Sendable {
    private let fileManager = FileManager.default

    /// 备份保留天数（设置页可调，默认 7 天）
    private var retentionDays: Int {
        let days = UserDefaults.standard.integer(forKey: "backupRetentionDays")
        return days > 0 ? days : 7
    }

    struct MigrationResult {
        let success: Bool
        let error: String?
        let spaceSaved: Int64
        /// 迁移返回了取消状态；须结合 error 判断是否为已确认安全清理的简单取消。
        let cancelled: Bool

        init(success: Bool, error: String? = nil, spaceSaved: Int64 = 0,
             cancelled: Bool = false) {
            self.success = success
            self.error = error
            self.spaceSaved = spaceSaved
            self.cancelled = cancelled
        }
    }

    /// Presentation-only capacity facts derived from the same backup-root
    /// convention as validateTarget. This helper performs no filesystem writes;
    /// validateTarget continues to re-check live capacity immediately before work.
    struct CapacityRequirement: Equatable {
        let backupIsOnDestination: Bool
        let destinationBytes: Int64
        let backupBytes: Int64?
    }

    struct MigrationProgressUpdate: Sendable {
        let phase: MigrationPhase
        let progress: Double
        let message: String
    }

    static func capacityRequirement(
        appSize: Int64,
        destinationPath: String,
        backupRoot: String
    ) -> CapacityRequirement {
        let backupIsOnDestination = backupRoot == "\(destinationPath)/.suishouqian-backup"
        let oneCopyWithMargin = requiredSingleCopyBytes(appSize: appSize)
        return CapacityRequirement(
            backupIsOnDestination: backupIsOnDestination,
            destinationBytes: backupIsOnDestination ? requiredTargetBytes(appSize: appSize) : oneCopyWithMargin,
            backupBytes: backupIsOnDestination ? nil : oneCopyWithMargin)
    }

    /// 迁移：把应用搬到外置盘。
    ///
    /// - Parameter createLink: `true` = 在 `/Applications` 留软链接（应用仍有入口，默认）；
    ///   `false` = **纯搬迁**，不留任何替身。好处是从机制上消除"更新把软链接顶掉、
    ///   迁移被悄悄撤销"这件事；代价是应用不再出现在「应用程序」文件夹里
    ///   （靠 Spotlight / Dock / Launchpad 启动）。

    // MARK: - 盘间迁移（v3.0 能力一：多盘）

    /// 原子替换符号链接：新链接先建在同目录临时名，再用 rename(2) 原子盖掉旧链接。
    /// rename 的原子性保证不存在"链接指向半截/悬空"的中间态——盘间迁移的安全关键步。
    /// 目标位若不是链接而是真目录，rename 会失败并抛错（调用方不删真目录）。
    static func swapSymlink(at linkPath: String, to target: String) throws {
        let dir = (linkPath as NSString).deletingLastPathComponent
        let tmp = "\(dir)/.suishouqian-relink-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: tmp, withDestinationPath: target)
        // Darwin.rename 原子覆盖已存在的目标；失败时清理临时链接再抛
        if Darwin.rename(tmp, linkPath) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: NSPOSIXErrorDomain,
                          code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey:
                                l10n("无法替换链接 %@（%@）", linkPath, String(cString: strerror(errno)))])
        }
    }

    /// 提权改写链接（链接位属 root 时 swapSymlink 会被 EPERM 挡）。
    /// osascript 阻塞等密码：必须 OffPool。管道纪律与 authenticatedRemove 相同：
    /// stdout 丢弃、stderr 先读后等。
    private func authenticatedRewriteLink(linkPath: String, toTarget target: String) async
        -> (success: Bool, error: String?) {
        return await OffPool.run {
            // 路径走 argv，脚本里用 quoted form of，不把路径拼进 AppleScript 源。
            PrivilegedShell.run(.rewriteLink(link: linkPath, target: target))
        }
    }

    /// 盘间迁移（v3.0）：A 盘 → B 盘，**不经过内置盘中转**（中转要两份空间，违背省空间初衷）。
    /// 流程：A→B 复制 → 字节校验 → 修属性 → 原子改写链接（有链接才改）→ 台账更新 → 删 A 副本。
    /// 安全关键：A 副本在链接改写成功前**绝不删**——任一步失败，应用仍从 A 盘完整可用。
    /// 失败清场只动 B 盘上的半截副本。
    func relocate(app: AppItem, fromVolume: String, toVolume: String,
                  phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                  progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        phaseProgress(.init(phase: .preflight, progress: 0, message: l10n("正在预检盘间迁移…")))
        let appName = app.bundleName
        let sourcePath = app.symlinkTarget ?? app.path
        let from = (fromVolume as NSString).standardizingPath
        let to = (toVolume as NSString).standardizingPath

        func finish(_ success: Bool, _ error: String?, _ op: JournalOperation = .relocate) -> MigrationResult {
            let result = MigrationResult(success: success, error: error, spaceSaved: 0)
            let fromUUID = MigrationManifest.volumeUUID(atPath: from) ?? ""
            let toUUID = MigrationManifest.volumeUUID(atPath: to) ?? ""
            OperationJournal.shared.record(
                op: op, appName: appName,
                params: ["fromUUID": fromUUID, "toUUID": toUUID],
                result: success ? "ok" : "failed: \(error ?? "未知原因")")
            return result
        }

        // 硬护栏：源必须在 fromVolume 上。symlinkTarget 与 fromVolume 对不上
        // 说明调用方给错了盘（或台账/链接已经漂移），绝不能按错路径删东西
        guard sourcePath.hasPrefix(from + "/") || sourcePath == from else {
            return finish(false, l10n("应用副本不在源盘上（%@ 不在 %@），已取消", sourcePath, from))
        }
        guard from != to else {
            return finish(false, l10n("源盘与目标盘相同，无需迁移"))
        }
        if let runningName = Self.runningAppName(matching: sourcePath) {
            return finish(false, l10n("「%@」正在运行，请先退出后再搬", runningName))
        }
        guard fileManager.fileExists(atPath: sourcePath) else {
            return finish(false, l10n("源盘上的应用副本不存在（%@）", sourcePath))
        }
        // 目标盘三重验证（挂载点/一份副本+5%/TM 排除）。盘间迁移不留备份，
        // 不能按「副本+同盘留底」的两份空间去拒绝。阻塞调用走 OffPool。
        let targetIssue = await OffPool.run { [self] in
            validateTarget(drivePath: to, appSize: app.size, reservesBackupCopy: false)
        }
        if let reason = targetIssue {
            return finish(false, reason)
        }
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        // 护栏全过后交给 core（core 是可测入口，自己记 journal——护栏路径用 finish 记，
        // core 路径由 core 记，两边不会重复）
        return await relocateCore(app: app, sourcePath: sourcePath,
                                  fromVolume: from, toVolume: to,
                                  phaseProgress: phaseProgress, progress: progress)
    }

    // MARK: - 目标占用与迁移标记（高-3 × 中断恢复的和解）

    /// 区分"上次迁移/盘间迁移中断的遗留副本"与"目标盘上无关的同名应用"：
    /// 复制开始前先在目标旁边落标记文件，进程崩溃必然留下"半截副本+标记"成对存在。
    /// 重试见标记 → 清掉遗留重搬（收敛）；无标记 → 外来应用，拒绝。
    static let relocationMarkerSuffix = ".suishouqian-relocating"

    /// 带标记的目标副本是否还能当「半截遗留」删掉重拷。
    ///
    /// 标记的契约是：复制尚未完成，源仍是独立真目录。源一旦变成符号链接，
    /// 或源已经不在，说明切换已经发生——skipBackup 没有留底时，目标就是唯一副本。
    /// 这时再按标记删目标，等于把应用从磁盘上抹掉。
    static func markedTargetMayBeDeleted(sourcePath: String, targetPath: String,
                                         fileManager: FileManager = .default) -> Bool {
        let source = (sourcePath as NSString).standardizingPath
        let target = (targetPath as NSString).standardizingPath
        if source == target { return false }
        guard let attrs = try? fileManager.attributesOfItem(atPath: sourcePath),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeDirectory else {
            // 源不存在，或源已是符号链接（attributesOfItem 不跟随链接）：都不能删目标
            return false
        }
        let resolvedSource = (sourcePath as NSString).resolvingSymlinksInPath
        let resolvedTarget = (targetPath as NSString).resolvingSymlinksInPath
        if resolvedSource == resolvedTarget { return false }
        if resolvedSource.hasPrefix(resolvedTarget + "/") { return false }
        return true
    }

    /// 两条路径是否指向同一条目（字面相等，或解析符号链接后相等）。
    static func pathsIdentifySameItem(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        return (lhs as NSString).resolvingSymlinksInPath
            == (rhs as NSString).resolvingSymlinksInPath
    }

    /// 返回 nil = 目标可用（标记已就位）；返回文案 = 拒绝原因。
    /// `sourcePath` 用来确认源仍是独立真目录，避免把已经切换完成的唯一副本清掉。
    static func prepareTargetForCopy(_ fm: FileManager, sourcePath: String,
                                     targetPath: String) -> String? {
        let marker = targetPath + relocationMarkerSuffix
        if fm.fileExists(atPath: targetPath) {
            guard fm.fileExists(atPath: marker) else {
                return l10n("目标盘已存在同名应用（%@），为避免覆盖已中止", targetPath)
            }
            guard markedTargetMayBeDeleted(sourcePath: sourcePath, targetPath: targetPath,
                                           fileManager: fm) else {
                return l10n("目标盘上的副本可能已是唯一真身（源位置已不是独立原件），")
                    + l10n("为避免删除唯一副本已中止。应用仍在 %@", targetPath)
            }
            // 上次中断的遗留：副本与标记成对清掉（源仍是完整真目录，删了可以重拷）
            try? fm.removeItem(atPath: targetPath)
            try? fm.removeItem(atPath: marker)
        }
        // 空盘没有 Applications/ 目录，而 createFile 不建中间目录——先补上
        // （ditto 本来也会建，提前建只为让标记有地方落）
        let parentDir = (targetPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        if !fm.createFile(atPath: marker, contents: nil) {
            return l10n("无法写入迁移标记文件（%@），已中止", marker)
        }
        return nil
    }

    /// 目标副本被删除或转正时同步摘标记——保持"标记 ⟺ 我方副本在目标盘"不变量，
    /// 防止陈旧标记让日后的外来同名应用被误判成遗留而遭覆盖
    static func clearRelocationMarker(_ fm: FileManager, targetPath: String) {
        try? fm.removeItem(atPath: targetPath + relocationMarkerSuffix)
    }

    /// 切换已经发生、标记却还在时，把这次重试收成终态，而不是删掉目标重拷。
    /// 返回 nil 表示源仍是独立真目录，调用方可以走正常的「清遗留再复制」。
    private func recoverCommittedSwitch(app: AppItem, sourcePath: String, targetPath: String,
                                        drivePath: String, createLink: Bool) -> MigrationResult? {
        let marker = targetPath + Self.relocationMarkerSuffix
        guard fileManager.fileExists(atPath: targetPath),
              fileManager.fileExists(atPath: marker) else { return nil }
        guard !Self.markedTargetMayBeDeleted(
            sourcePath: sourcePath, targetPath: targetPath, fileManager: fileManager) else {
            return nil
        }

        let appName = app.bundleName
        let linkDest = try? fileManager.destinationOfSymbolicLink(atPath: sourcePath)
        let sourceMissing = (try? fileManager.attributesOfItem(atPath: sourcePath)) == nil
        let linkPointsAtTarget = linkDest.map {
            Self.pathsIdentifySameItem($0, targetPath)
        } ?? false

        func commit(note: String) -> MigrationResult {
            recordBundleManifestIfLinked(
                appName: appName, sourcePath: sourcePath, targetPath: targetPath,
                drivePath: drivePath, createLink: createLink)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            AuditLog.append(note)
            return MigrationResult(success: true, error: nil, spaceSaved: app.size)
        }

        if createLink {
            if linkPointsAtTarget {
                return commit(note: l10n("迁移收敛 %@：链接已指向已校验副本，补清迁移标记（未删除目标）", appName))
            }
            if sourceMissing {
                do {
                    try fileManager.createSymbolicLink(atPath: sourcePath,
                                                       withDestinationPath: targetPath)
                } catch {
                    AuditLog.append("迁移收敛失败 \(appName)：源已不在，目标副本保留在 \(targetPath)，"
                        + l10n("重建链接失败：%@", error.localizedDescription))
                    return MigrationResult(
                        success: false,
                        error: l10n("源位置已空，完整副本保留在 %@，但重建链接失败：%@。请勿删除该副本", targetPath, error.localizedDescription),
                        spaceSaved: 0)
                }
                return commit(note: l10n("迁移收敛 %@：源已不在，已补建指向 %@ 的链接", appName, targetPath))
            }
            AuditLog.append("拒绝迁移 \(appName)：目标副本可能是唯一真身，源位置不是独立原件")
            return MigrationResult(
                success: false,
                error: l10n("目标盘上的副本可能已是唯一真身（源位置已不是独立原件），为避免删除唯一副本已中止。应用仍在 %@", targetPath),
                spaceSaved: 0)
        }

        if sourceMissing {
            return commit(note: l10n("迁移收敛 %@：纯搬迁已完成，补清迁移标记", appName))
        }
        if linkPointsAtTarget {
            do {
                try fileManager.removeItem(atPath: sourcePath)
            } catch {
                return MigrationResult(
                    success: false,
                    error: l10n("应用真身在 %@，但无法移除源位置的链接：%@", targetPath, error.localizedDescription),
                    spaceSaved: 0)
            }
            return commit(note: l10n("迁移收敛 %@：已摘掉源位置链接，真身留在 %@", appName, targetPath))
        }
        return MigrationResult(
            success: false,
            error: l10n("目标盘上的副本可能已是唯一真身，为避免删除唯一副本已中止。应用仍在 %@", targetPath),
            spaceSaved: 0)
    }

    private func recordBundleManifestIfLinked(appName: String, sourcePath: String,
                                              targetPath: String, drivePath: String,
                                              createLink: Bool) {
        guard createLink, targetPath.hasPrefix(drivePath + "/") else { return }
        guard let uuid = MigrationManifest.volumeUUID(atPath: drivePath) else { return }
        MigrationManifest.shared.record(
            appName: appName, linkPath: sourcePath, volumeUUID: uuid,
            relativePath: String(targetPath.dropFirst(drivePath.count + 1)))
    }

    /// 盘间迁移核心（可测入口：不做卷级护栏，路径全由调用方保证）。
    /// 单一出口记 journal；测试注入 temp 目录即可全流程验证。
    func relocateCore(app: AppItem, sourcePath: String, fromVolume: String, toVolume: String,
                      linkDirectory: String = "/Applications",
                      phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                      progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let appName = app.bundleName
        var crashOpen = false
        defer { if crashOpen { CrashJournal.shared.end() } }
        let relative = (sourcePath as NSString).lastPathComponent
        // 保持源盘上的相对布局（Applications/ 或 Suishouqian_Apps/ 原样带到目标盘）
        let parentName = (sourcePath as NSString).deletingLastPathComponent
            .replacingOccurrences(of: fromVolume + "/", with: "")
        let targetPath = "\(toVolume)/\(parentName)/\(relative)"
        let linkPath = "\(linkDirectory)/\(appName)"
        let hadLink = (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil
        phaseProgress(.init(phase: .preflight, progress: 0, message: l10n("正在检查盘间迁移…")))
        // P2-3 漂移护栏必须在复制之前：中止越早，目标盘越干净（复制后才查会留下整份副本）
        if hadLink {
            // 合法现状只有两个——还指着源（没动过）或已指着目标（上次中断在改写后，
            // 重跑幂等）；指向第三处说明链接已被回归/自愈改写，必须中止
            let currentLink = try? fileManager.destinationOfSymbolicLink(atPath: linkPath)
            guard currentLink == sourcePath || currentLink == targetPath else {
                return done(false, l10n("链接指向已变化（当前指向 %@），已中止以免误改", currentLink ?? l10n("未知")))
            }
        }

        func done(_ success: Bool, _ error: String?) -> MigrationResult {
            let fromUUID = MigrationManifest.volumeUUID(atPath: fromVolume) ?? ""
            let toUUID = MigrationManifest.volumeUUID(atPath: toVolume) ?? ""
            OperationJournal.shared.record(
                op: .relocate, appName: appName,
                params: ["fromUUID": fromUUID, "toUUID": toUUID],
                result: success ? "ok" : "failed: \(error ?? "未知原因")")
            return MigrationResult(success: success, error: error, spaceSaved: 0)
        }

        // 高-3（2026-10-04 审计）：复制前检查目标占用。无标记的同名应用是目标盘上
        // 的无关应用，拒绝；带标记的是上次中断遗留，清掉重搬（中断恢复契约）。
        if let reject = Self.prepareTargetForCopy(
            fileManager, sourcePath: sourcePath, targetPath: targetPath) {
            return done(false, reject)
        }

        CrashJournal.shared.begin(CrashJournal.Entry(
            op: "relocate", appName: appName, sourcePath: sourcePath, targetPath: targetPath,
            backupPath: nil, createLink: hadLink, linkPath: hadLink ? linkPath : nil))
        crashOpen = true

        phaseProgress(.init(phase: .copying, progress: 0.1, message: l10n("正在复制 %@ 到目标盘...", app.name)))
        progress(0.1, l10n("正在复制 %@ 到目标盘...", app.name))
        let copyOk = await copyWithDitto(from: sourcePath, to: targetPath) { pct in
            let value = 0.1 + pct * 0.5
            phaseProgress(.init(phase: .copying, progress: value, message: l10n("复制 %@...", app.name)))
            progress(value, l10n("复制 %@...", app.name))
        }
        guard copyOk else {
            try? fileManager.removeItem(atPath: targetPath)   // 清半截副本，A 不动
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return done(false, l10n("复制到目标盘失败"))
        }

        phaseProgress(.init(phase: .verifying, progress: 0.65, message: l10n("正在校验完整性...")))
        progress(0.65, l10n("正在校验完整性..."))
        let verified = await verifyFiles(source: sourcePath, target: targetPath)
        guard verified else {
            try? fileManager.removeItem(atPath: targetPath)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return done(false, l10n("文件校验失败，已回滚目标副本（源盘副本未动）"))
        }

        progress(0.75, l10n("修复文件属性..."))
        await fixAttributes(at: targetPath)

        // 链接改写（有 /Applications 链接才做；externalOnly 原住民跳过）
        if hadLink {
            phaseProgress(.init(phase: .backupAndSwitch, progress: 0.85, message: l10n("正在切换应用链接...")))
            progress(0.85, l10n("改写应用链接..."))
            do {
                try Self.swapSymlink(at: linkPath, to: targetPath)
            } catch {
                // 链接仍指向 A（应用可用）；常见原因是链接位属 root → 走提权
                let auth = await authenticatedRewriteLink(linkPath: linkPath, toTarget: targetPath)
                guard auth.success else {
                    return done(false, l10n("链接改写失败：%@（应用仍从源盘运行，两盘副本都在）", auth.error ?? l10n("未知错误")))
                }
            }
            // 回读确认改写生效（覆盖 rename 与提权两条路径），确认无误才允许删源。
            // 自审发现：此护栏最初被插进 guard-else 分支 return 之后，是永不执行的死代码
            guard (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) == targetPath else {
                return done(false, l10n("链接改写后校验未通过，源盘副本未动"))
            }
        }

        // 台账：有链接才记（与 migrate 的纯搬迁语义一致）
        if hadLink, let uuid = MigrationManifest.volumeUUID(atPath: toVolume) {
            MigrationManifest.shared.record(
                appName: appName, linkPath: linkPath, volumeUUID: uuid,
                relativePath: "\(parentName)/\(relative)",
                volumeRole: nil)
        }

        phaseProgress(.init(phase: .backupAndSwitch, progress: 0.95, message: l10n("正在清理源盘副本...")))
        progress(0.95, l10n("清理源盘副本..."))
        do {
            try fileManager.removeItem(atPath: sourcePath)
        } catch {
            // 链接已指向 B，应用可用；源盘残留如实上报
            AuditLog.append("盘间迁移 \(appName)：源盘副本删除失败（\(error.localizedDescription)），"
                + l10n("链接已指向目标盘，可稍后手动清理 %@", sourcePath))
        }

        progress(1.0, l10n("完成"))
        AuditLog.append("盘间迁移成功 \(appName)：\(fromVolume) → \(targetPath)")
        Self.clearRelocationMarker(fileManager, targetPath: targetPath)
        return done(true, nil)
    }

    // MARK: - 操作日志埋点（v3.0 OperationJournal）
    // 埋点收敛在四个公开入口的出口处：内部实现改名 Internal，包装器记完日志原样返回。
    // 记日志永不影响迁移结果（record 内部全 try? + 静默放弃）。
    // 撤销依据就是这些条目——所以成功与失败都要记（失败条目让撤销界面能如实告知"无可撤销"）。

    /// 迁移/纯搬迁（createLink 区分，params 记录）
    func migrate(app: AppItem, to drivePath: String, createLink: Bool = true,
                 expectedTargetVolumeUUID: String? = nil,
                 cancellationToken: CancellationToken? = nil,
                 skipBackup: Bool = false,
                 targetSubdir: String? = nil,
                 phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let result = await migrateInternal(app: app, to: drivePath,
                                           createLink: createLink,
                                           expectedTargetVolumeUUID: expectedTargetVolumeUUID,
                                           cancellationToken: cancellationToken,
                                           skipBackup: skipBackup,
                                           targetSubdir: targetSubdir,
                                           phaseProgress: phaseProgress,
                                           progress: progress)
        OperationJournal.shared.record(
            op: .migrate, appName: app.bundleName,
            params: ["createLink": createLink ? "1" : "0",
                     "backup": skipBackup ? "0" : "1",
                     "volumeUUID": MigrationManifest.volumeUUID(atPath: drivePath) ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "未知原因")")
        return result
    }

    /// 回迁
    func restore(app: AppItem, from drivePath: String,
                 phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let result = await restoreInternal(
            app: app, from: drivePath, phaseProgress: phaseProgress, progress: progress)
        OperationJournal.shared.record(
            op: .restore, appName: app.bundleName,
            params: ["volumeUUID": MigrationManifest.volumeUUID(atPath: drivePath) ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "未知原因")")
        return result
    }

    /// 外置盘原住民搬回内置盘
    func moveBackToInternal(app: AppItem, drivePath: String,
                            phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                            progress: @escaping @Sendable (Double, String) -> Void)
        async -> MigrationResult {
        let result = await moveBackToInternalInternal(app: app, drivePath: drivePath,
                                                      phaseProgress: phaseProgress,
                                                      progress: progress)
        OperationJournal.shared.record(
            op: .moveBack, appName: app.bundleName,
            params: ["volumeUUID": MigrationManifest.volumeUUID(atPath: drivePath) ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "未知原因")")
        return result
    }

    /// 卸载一条龙
    func uninstall(app: AppItem, drivePath: String? = nil) async -> MigrationResult {
        let result = await uninstallInternal(app: app, drivePath: drivePath)
        OperationJournal.shared.record(
            op: .uninstall, appName: app.bundleName,
            // bundleID 供卸载撤销匹配废纸篓候选（重名回收多次时避免捞错）
            params: ["bundleID": app.bundleID ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "部分失败")")
        return result
    }

    /// 卸载撤销：把废纸篓里的应用本体移回 /Applications（撤销链特殊路径，不走常规迁移安全链）。
    /// 安全重验（TOCTOU）：目标位必须为空（用户已重装则拒绝覆盖）；候选必须仍是目录；
    /// 候选消失（清空了废纸篓）如实拒绝。恢复后应用以普通内置应用身份回归——
    /// 不重建链接、不进台账（卸载时二者已清）。
    /// 跨卷场景（外置 .Trashes → /Applications）是整树复制，阻塞 IO 走 OffPool。
    /// externalMounts 由调用方传当前在线的外置卷挂载点（离线盘的废纸篓读不到）。
    func restoreFromTrash(appName: String, bundleID: String?,
                          externalMounts: [String] = []) async -> MigrationResult {
        let destPath = "/Applications/\(appName)"
        return await OffPool.run { [self] in
            guard !fileManager.fileExists(atPath: destPath) else {
                AuditLog.append("卸载撤销拒绝 \(appName)：/Applications 已存在同名应用（可能已重装），不覆盖")
                return MigrationResult(success: false,
                      error: l10n("「/Applications」里已有同名应用（可能你重装过了）。撤销已取消，废纸篓里的原件未动"),
                      spaceSaved: 0)
            }
            let roots = TrashRecovery.roots(externalMounts: externalMounts)
            var isDir: ObjCBool = false
            guard let candidate = TrashRecovery.locate(appName: appName, bundleID: bundleID,
                                                       in: roots),
                  fileManager.fileExists(atPath: candidate, isDirectory: &isDir),
                  isDir.boolValue else {
                AuditLog.append("卸载撤销拒绝 \(appName)：废纸篓里已找不到应用本体（可能已清空）")
                return MigrationResult(success: false,
                      error: l10n("废纸篓里已找不到该应用（可能已清空废纸篓）。无法恢复"),
                      spaceSaved: 0)
            }
            do {
                try fileManager.moveItem(atPath: candidate, toPath: destPath)
            } catch {
                // 跨卷复制中途失败会留半截目标：清掉，废纸篓原件不动（仍是唯一副本）
                try? fileManager.removeItem(atPath: destPath)
                AuditLog.append("卸载撤销失败 \(appName)：\(error.localizedDescription)，废纸篓原件保留")
                return MigrationResult(success: false,
                      error: l10n("恢复失败（可能需要管理员权限）：%@。废纸篓里的原件未动，可重试或手动拖回", error.localizedDescription),
                      spaceSaved: 0)
            }
            AuditLog.append("卸载撤销成功 \(appName)：已从废纸篓恢复到 /Applications")
            return MigrationResult(success: true, error: nil, spaceSaved: 0)
        }
    }

    func migrateInternal(app: AppItem, to drivePath: String, createLink: Bool = true,
                 expectedTargetVolumeUUID: String? = nil,
                 cancellationToken: CancellationToken? = nil,
                 skipBackup: Bool = false,
                 targetSubdir: String? = nil,
                 phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {

        let appName = app.bundleName
        let sourcePath = app.path
        var crashOpen = false
        defer { if crashOpen { CrashJournal.shared.end() } }
        // targetSubdir 用于"搬回去"精确还原原位置（如 Suishouqian_Apps/）；默认 Applications/
        let targetDir = targetSubdir.map { "\(drivePath)/\($0)" } ?? "\(drivePath)/Applications"
        let targetPath = "\(targetDir)/\(appName)"
        phaseProgress(.init(phase: .preflight, progress: 0, message: l10n("正在预检…")))
        // 跨盘备份：备份盘与应用盘可分离（破单点故障）；未指定备份盘时跟应用同盘
        let backupPath = "\(BackupLocations.backupRoot(for: drivePath))/\(appName)"

        /// 协作式取消检查点：每阶段边界调用。取消后清理半截目标副本与备份，
        /// 源目录此时还没动过（链接切换是最后一步），直接返回即可。
        /// 注意：链接切换之后不可取消（源已被搬走），调用方不要在那之后检查。
        func checkCancelled(_ phase: String) -> MigrationResult? {
            guard cancellationToken?.isCancelled == true else { return nil }
            AuditLog.append("迁移取消 \(appName)：在\(phase)阶段用户取消，清理半截副本与备份")
            try? fileManager.removeItem(atPath: targetPath)
            try? fileManager.removeItem(atPath: backupPath)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return MigrationResult(success: false, error: l10n("已取消"), spaceSaved: 0,
                                   cancelled: true)
        }

        // 硬护栏：源与目标不能是同一个位置。copyWithDitto 的第一步是 removeItem(dst)，
        // 若 dst 就是应用自身（外置盘原住民被误走"迁移"入口），等于直接删库。
        // UI 目前按 status 分流不会走到这里，但这条语义必须由 API 自己守住。
        if (sourcePath as NSString).standardizingPath == (targetPath as NSString).standardizingPath {
            return MigrationResult(success: false,
                  error: l10n("「%@」已经在这个目录里，无需再次迁移（若要搬回内置盘请用「搬回内置盘」）", appName),
                  spaceSaved: 0)
        }

        // 稳定性：应用正在运行时移动/替换会导致半完成状态，直接拒绝
        if let runningName = Self.runningAppName(matching: sourcePath) {
            AuditLog.append("拒绝迁移 \(appName)：应用正在运行")
            return MigrationResult(success: false,
                  error: l10n("「%@」正在运行，请先退出后再迁移", runningName), spaceSaved: 0)
        }

        // P0: 目标必须是真实挂载的独立卷。历史上发生过目标卷未挂载时
        // createDirectory 把数据全写进内置盘 /Volumes 的事故，此处硬性拦截。
        // validateTarget 里有 statfs + tmutil + resourceValues，全部是阻塞调用 → OffPool
        let targetIssue = await OffPool.run { [self] in
            validateTarget(
                drivePath: drivePath, appSize: app.size,
                expectedVolumeUUID: expectedTargetVolumeUUID,
                reservesBackupCopy: !skipBackup)
        }
        if let reason = targetIssue {
            AuditLog.append("拒绝迁移 \(appName)：\(reason)")
            return MigrationResult(success: false, error: reason, spaceSaved: 0)
        }

        // v2.2: 迁移前拍 APFS 本地快照（整机级最后保险；阻塞进程必须走 OffPool）
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        do { try fileManager.createDirectory(atPath: targetDir,
              withIntermediateDirectories: true) } catch {
            return MigrationResult(success: false, 
                  error: l10n("无法创建目标目录: %@", error.localizedDescription), spaceSaved: 0)
        }
        
        // 标记还在、但源已经不是独立真目录：切换已经发生（常见于清标记前崩溃，
        // 或 skipBackup 建链前后）。这时目标可能是唯一副本，补完链接即可，绝不能重拷。
        if let recovered = recoverCommittedSwitch(
            app: app, sourcePath: sourcePath, targetPath: targetPath,
            drivePath: drivePath, createLink: createLink) {
            return recovered
        }

        // 高-3（2026-10-04 审计）：复制前检查目标路径占用（copyWithDitto 首句就是删目标）。
        // 无标记的同名应用是目标盘上的无关应用，拒绝；带标记且源仍是真目录的，
        // 是上次中断的遗留，清掉重搬——崩溃后重试必须能收敛。
        if let reject = Self.prepareTargetForCopy(
            fileManager, sourcePath: sourcePath, targetPath: targetPath) {
            AuditLog.append("拒绝迁移 \(appName)：\(reject)")
            return MigrationResult(success: false, error: reject, spaceSaved: 0)
        }

        CrashJournal.shared.begin(CrashJournal.Entry(
            op: "migrate", appName: appName, sourcePath: sourcePath, targetPath: targetPath,
            backupPath: skipBackup ? nil : backupPath, createLink: createLink, linkPath: nil))
        crashOpen = true

        phaseProgress(.init(phase: .copying, progress: 0.1, message: l10n("正在复制 %@...", app.name)))
        progress(0.1, l10n("正在复制 %@...", app.name))
        let copyOk = await copyWithDitto(from: sourcePath, to: targetPath) { pct in
            let value = 0.1 + pct * 0.6
            let message = l10n("复制 %@...", app.name)
            phaseProgress(.init(phase: .copying, progress: value, message: message))
            progress(value, message)
        }
        guard copyOk else {
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)  // 半截副本已由 copyWithDitto 清掉
            return MigrationResult(success: false,
                  error: l10n("复制失败"), spaceSaved: 0)
        }
        if let cancelled = checkCancelled(l10n("复制")) { return cancelled }

        phaseProgress(.init(phase: .verifying, progress: 0.7, message: l10n("正在校验完整性...")))
        progress(0.7, l10n("正在校验完整性..."))
        let verified = await verifyFiles(source: sourcePath, target: targetPath)
        guard verified else {
            AuditLog.append("迁移失败 \(appName)：校验未通过，已回滚目标副本")
            try? fileManager.removeItem(atPath: targetPath)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return MigrationResult(success: false,
                  error: l10n("文件校验失败，请重试"), spaceSaved: 0)
        }
        if let cancelled = checkCancelled(l10n("校验")) { return cancelled }

        // 校验通过后才修复属性（必须在校验之后，因为 codesign 会修改二进制导致 diff 不一致）
        progress(0.8, l10n("修复文件属性..."))
        await fixAttributes(at: targetPath)
        if let cancelled = checkCancelled(l10n("修复属性")) { return cancelled }

        if !skipBackup {
            phaseProgress(.init(phase: .backupAndSwitch, progress: 0.85, message: l10n("备份原件...")))
            progress(0.85, l10n("备份原件..."))
            try? fileManager.createDirectory(atPath: BackupLocations.backupRoot(for: drivePath),
                  withIntermediateDirectories: true)
        }
        
        // 检查是否需要管理员权限（/Applications 下的 root 所有文件）
        let needsAuth = await needsAdminPrivilege(for: sourcePath)
        
        if needsAuth {
            if !skipBackup {
                // 备份到外置盘（普通 ditto，不需要 admin；osascript admin 写不了外置盘）
                phaseProgress(.init(phase: .backupAndSwitch, progress: 0.85, message: l10n("备份原件...")))
                progress(0.85, l10n("备份原件..."))
                let backupOk = await copyWithDitto(from: sourcePath, to: backupPath) { _ in }
                guard backupOk else {
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    return MigrationResult(success: false,
                          error: l10n("备份失败"), spaceSaved: 0)
                }
                // 备份 mtime 必须代表"备份时刻"，否则刚建好就被当超龄清掉
                stampBackupCreation(at: backupPath)
                // 最后可取消点：之后是提权删源+建链，源目录一动就不可回头
                if let cancelled = checkCancelled(l10n("备份")) { return cancelled }
            }
            // skipBackup=true 时无备份：提权失败则无法回滚，但目标副本已校验通过，
            // 应用本体安全落在外置盘，仅需手动处理 /Applications 残留。
            
            // 删原件（按需再建符号链接，需要 admin；只操作 /Applications 不写外置盘）
            phaseProgress(.init(phase: .backupAndSwitch, progress: 0.9, message: l10n("需要管理员权限...")))
            progress(0.9, l10n("需要管理员权限..."))
            let authResult = await authenticatedRemove(
                source: sourcePath, linkTarget: targetPath, createLink: createLink)
            guard authResult.success else {
                // 回滚顺序很重要：**先确认原件恢复/仍在，再回收我们建的副本**。
                // 之前是先 removeItem(targetPath) 再复制，一旦复制失败就只剩一份
                // 从未校验过的备份，而唯一校验通过的副本已经被自己删了。
                if fileManager.fileExists(atPath: sourcePath) {
                    // 最常见的情况：用户取消了密码框，提权动作根本没生效，原件完好。
                    // 此时只回收本次新建的目标副本与留底备份，不再动原件。
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    try? fileManager.removeItem(atPath: backupPath)
                    return MigrationResult(success: false,
                          error: authResult.error ?? l10n("权限操作失败"), spaceSaved: 0)
                }
                // skipBackup 模式无备份可回滚：但目标副本已校验通过，应用本体安全。
                // 若源已被删（部分成功），如实告知应用在外置盘，需手动处理。
                if skipBackup {
                    let sourceGone = !fileManager.fileExists(atPath: sourcePath)
                    AuditLog.append("迁移失败 \(appName)：纯搬迁模式提权失败"
                        + (sourceGone ? l10n("，源已删，应用本体在外置盘 %@", targetPath) : l10n("，源仍在原位")))
                    return MigrationResult(success: false,
                          error: sourceGone
                              ? l10n("权限操作失败，但应用已安全搬到外置盘（%@）。/Applications 里可能有残留，请手动检查。", targetPath)
                              : (authResult.error ?? l10n("权限操作失败")),
                          spaceSaved: 0)
                }
                let restored = await copyWithDitto(from: backupPath, to: sourcePath) { _ in }
                if restored {
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    try? fileManager.removeItem(atPath: backupPath)
                } else {
                    // 回滚未完成：目标副本与备份都保留（两份都能拿来人工恢复）
                    AuditLog.append("迁移失败 \(appName)：授权回滚未完成，"
                        + l10n("目标副本与原件备份都保留（%@ / %@）", targetPath, backupPath))
                }
                return MigrationResult(success: false,
                      error: restored ? (authResult.error ?? l10n("权限操作失败"))
                                      : l10n("权限操作失败且回滚未完成，原件备份保留在外置盘 .suishouqian-backup，可从体检页恢复"),
                      spaceSaved: 0)
            }
        } else if skipBackup {
            // 跳过备份模式（skipBackup）：目标副本已在前面校验通过，删源后按需建链。
            // ⚠️ 此处【禁止】套用"删目标副本"式清理：无备份时目标副本就是唯一真身
            // （处境等同上一分支 move 之后）。建链失败只能把目标副本复制回源位恢复；
            // 复制不回去就保留目标副本并如实报位置，绝不能删。
            try? fileManager.removeItem(atPath: sourcePath)
            if createLink {
                do {
                    try fileManager.createSymbolicLink(atPath: sourcePath,
                                                       withDestinationPath: targetPath)
                } catch {
                    let restored = await copyWithDitto(from: targetPath, to: sourcePath) { _ in }
                    if restored {
                        try? fileManager.removeItem(atPath: targetPath)
                        Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    } else {
                        AuditLog.append("迁移失败 \(appName)：建链失败且回滚未完成，"
                            + l10n("目标副本保留在 %@（/Applications 原件已删），请从该位置手动恢复", targetPath))
                    }
                    return MigrationResult(success: false,
                          error: restored
                              ? l10n("创建符号链接失败: %@", error.localizedDescription)
                              : l10n("创建符号链接失败，且 /Applications 恢复未完成——完整应用保留在 %@，请手动移回", targetPath),
                          spaceSaved: 0)
                }
            }
        } else {
            let moved = await moveItem(from: sourcePath, to: backupPath)
            guard moved else {
                try? fileManager.removeItem(atPath: targetPath)
                Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                return MigrationResult(success: false,
                      error: l10n("无法移动原文件（可能正在运行或权限不足）"), spaceSaved: 0)
            }
            // 备份 mtime 必须代表"备份时刻"（move 会保留原应用的安装时间）
            stampBackupCreation(at: backupPath)
            // ⚠️ 此处【禁止】用 checkCancelled 清理：非提权路径 move 之后原应用
            // 只剩 backupPath 这一份真身（源目录已被搬走），checkCancelled 的
            // "删目标+删备份"会把应用从电脑上抹掉（落地审查抓到的 P0）。
            // 取消改为回滚：原件搬回 /Applications，只清目标副本。
            if cancellationToken?.isCancelled == true {
                AuditLog.append("迁移取消 \(appName)：搬移阶段取消，尝试把原件搬回内置盘")
                let movedBack = await moveItem(from: backupPath, to: sourcePath)
                if movedBack {
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    return MigrationResult(success: false, error: l10n("已取消"),
                          spaceSaved: 0, cancelled: true)
                }
                // 搬回失败时目标副本仍是校验过的完整副本，不能跟着删掉。
                AuditLog.append("迁移取消 \(appName)：原件搬回失败，副本保留在 \(targetPath) 与 \(backupPath)")
                return MigrationResult(success: false,
                      error: l10n("已取消，但原件搬回失败——完整副本保留在 %@ 与 %@，请勿删除", targetPath, backupPath),
                      spaceSaved: 0, cancelled: true)
            }
            if createLink {
                do {
                    try fileManager.createSymbolicLink(atPath: sourcePath,
                                                       withDestinationPath: targetPath)
                } catch {
                    let movedBack = await moveItem(from: backupPath, to: sourcePath)
                    if movedBack {
                        try? fileManager.removeItem(atPath: targetPath)
                        Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                        return MigrationResult(success: false,
                              error: l10n("创建符号链接失败: %@", error.localizedDescription), spaceSaved: 0)
                    }
                    // 原件没有搬回来：已校验的目标副本和备份都是退路，删掉任何一个都可能只剩半份。
                    AuditLog.append("迁移失败 \(appName)：建链失败且原件搬回未完成，"
                        + l10n("已校验副本保留在 %@，原件备份保留在 %@", targetPath, backupPath))
                    return MigrationResult(success: false,
                          error: l10n("创建符号链接失败，且原件搬回未完成——完整副本保留在 %@ 与 %@，请勿删除", targetPath, backupPath),
                          spaceSaved: 0)
                }
            }
        }
        
        progress(1.0, l10n("完成"))
        let byteCount = String(app.size)
        AuditLog.append(createLink
            ? l10n("迁移成功 %@：%@ 字节 → %@", appName, byteCount, targetPath)
            : l10n("纯搬迁成功 %@：%@ 字节 → %@（未在 /Applications 留链接）", appName, byteCount, targetPath))

        // 台账只在留链接时需要——它的用途是"卷改名后按 UUID 重写链接"。
        // 纯搬迁没有链接可修，而且台账校准会把 linkPath 不存在的条目当幽灵清掉，
        // 所以不记录才是正确的（这类应用由扫描 <盘>/Applications 识别为「在外置盘」）
        recordBundleManifestIfLinked(
            appName: appName, sourcePath: sourcePath, targetPath: targetPath,
            drivePath: drivePath, createLink: createLink)
        Self.clearRelocationMarker(fileManager, targetPath: targetPath)
        return MigrationResult(success: true, error: nil, spaceSaved: app.size)
    }

    /// 纯搬迁：把应用搬到外置盘，但**不在 /Applications 留链接**。
    ///
    /// 适合自带更新器、且不需要出现在「应用程序」文件夹的应用。
    /// 对这类应用它比"迁移"更稳：更新器破坏的对象就是那个链接（App Store /
    /// 安装器会往 /Applications 写真目录把链接顶掉），没有链接就没有这个故障模式。
    func moveToExternal(app: AppItem, drivePath: String,
                        expectedTargetVolumeUUID: String? = nil,
                        phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                        progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        await migrate(
            app: app, to: drivePath, createLink: false,
            expectedTargetVolumeUUID: expectedTargetVolumeUUID,
            phaseProgress: phaseProgress, progress: progress)
    }
    
    func restoreInternal(app: AppItem, from drivePath: String,
                 phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        phaseProgress(.init(phase: .preflight, progress: 0, message: l10n("正在预检回迁…")))
        
        guard let target = app.symlinkTarget else {
            return MigrationResult(success: false, error: l10n("未找到外置盘上的应用"), spaceSaved: 0)
        }
        
        let appName = app.bundleName
        let sourcePath = app.path
        let externalPath = target
        let backupDir = "\(BackupLocations.backupRoot(for: drivePath))/\(appName)"
        var crashOpen = false
        defer { if crashOpen { CrashJournal.shared.end() } }

        // 稳定性：回迁同样要求应用未在运行
        if let runningName = Self.runningAppName(matching: sourcePath) {
            return MigrationResult(success: false,
                  error: l10n("「%@」正在运行，请先退出后再回迁", runningName), spaceSaved: 0)
        }

        // 安全：回迁写回内置盘——迁移的初衷就是内置盘紧张，
        // 空间不足时中途失败会留下半截副本，先预检（需 5% 余量）
        if let reason = validateInternalFreeSpace(needBytes: app.size) {
            AuditLog.append("拒绝回迁 \(appName)：\(reason)")
            return MigrationResult(success: false, error: reason, spaceSaved: 0)
        }

        // v2.2: 回迁前拍 APFS 本地快照（整机级最后保险；阻塞进程必须走 OffPool）
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        // 高-1（2026-10-04 审计）：执行前一刻重验链接位仍是软链接。
        // 扫描显示"已迁移"之后、用户点"回迁"之前，应用自动更新可能已把软链接
        // 替换成真目录（"迁移被悄悄撤销"场景）——此时删掉的是用户更新后的真应用。
        guard (try? fileManager.destinationOfSymbolicLink(atPath: sourcePath)) != nil else {
            AuditLog.append("拒绝回迁 \(appName)：\(sourcePath) 已不是软链接（可能已被应用更新替换为真目录），请重新扫描")
            return MigrationResult(success: false,
                error: l10n("该位置已不是软链接（可能已被应用更新替换为真目录），请重新扫描后再操作"),
                spaceSaved: 0)
        }

        CrashJournal.shared.begin(CrashJournal.Entry(
            op: "restore", appName: appName, sourcePath: sourcePath, targetPath: externalPath,
            backupPath: backupDir, createLink: true, linkPath: nil))
        crashOpen = true

        phaseProgress(.init(phase: .copying, progress: 0.1, message: l10n("准备回迁...")))
        progress(0.1, l10n("删除符号链接..."))
        try? fileManager.removeItem(atPath: sourcePath)
        
        phaseProgress(.init(phase: .copying, progress: 0.2, message: l10n("正在回迁 %@...", app.name)))
        progress(0.2, l10n("正在回迁 %@...", app.name))
        let copyOk = await copyWithDitto(from: externalPath, to: sourcePath) { pct in
            let value = 0.2 + pct * 0.7
            phaseProgress(.init(phase: .copying, progress: value, message: l10n("回迁 %@...", app.name)))
            progress(value, l10n("回迁 %@...", app.name))
        }
        guard copyOk else {
            // 复制失败也要保证应用仍有入口：先腾空链接位（半截副本已由
            // copyWithDitto 清掉，这里再兜一次），再重建软链接
            try? fileManager.removeItem(atPath: sourcePath)
            try? fileManager.createSymbolicLink(atPath: sourcePath, withDestinationPath: externalPath)
            AuditLog.append("回迁失败 \(appName)：复制未完成，已恢复软链接（外置副本保留）")
            return MigrationResult(success: false, error: l10n("回迁复制失败"), spaceSaved: 0)
        }
        
        phaseProgress(.init(phase: .verifying, progress: 0.9, message: l10n("正在校验回迁副本...")))
        progress(0.9, l10n("校验..."))
        let verified = await verifyFiles(source: externalPath, target: sourcePath)
        
        if verified {
            phaseProgress(.init(phase: .backupAndSwitch, progress: 0.95, message: l10n("清理外置副本...")))
            try? fileManager.removeItem(atPath: externalPath)
            try? fileManager.removeItem(atPath: backupDir)
            MigrationManifest.shared.remove(appName: appName)
            AuditLog.append("回迁成功 \(appName)：已恢复到内置盘并清理外置副本")
        } else {
            // P0: 校验失败也要恢复软链接，否则应用失去启动入口（半完成状态）
            try? fileManager.removeItem(atPath: sourcePath)
            try? fileManager.createSymbolicLink(atPath: sourcePath, withDestinationPath: externalPath)
            AuditLog.append("回迁校验失败 \(appName)：已恢复软链接，外置副本保留")
        }

        progress(1.0, l10n("完成"))
        return MigrationResult(success: verified, error: verified ? nil : l10n("校验失败"),
                               spaceSaved: -app.size)
    }

    /// 把「一直住在外置盘」的应用搬回内置盘（无链接语义：复制→校验→删外置副本）
    func moveBackToInternalInternal(app: AppItem, drivePath: String,
                            phaseProgress: @escaping @Sendable (MigrationProgressUpdate) -> Void = { _ in },
                            progress: @escaping @Sendable (Double, String) -> Void)
        async -> MigrationResult {
        phaseProgress(.init(phase: .preflight, progress: 0, message: l10n("正在预检搬回操作…")))
        let sourcePath = app.path
        let destPath = "/Applications/\(app.bundleName)"
        var crashOpen = false
        defer { if crashOpen { CrashJournal.shared.end() } }

        if let runningName = Self.runningAppName(matching: sourcePath) {
            return MigrationResult(success: false,
                  error: l10n("「%@」正在运行，请先退出后再搬回", runningName), spaceSaved: 0)
        }
        if fileManager.fileExists(atPath: destPath) {
            return MigrationResult(success: false,
                  error: l10n("内置盘已存在同名应用，无法搬回"), spaceSaved: 0)
        }
        if let reason = validateInternalFreeSpace(needBytes: app.size) {
            AuditLog.append("拒绝搬回 \(app.bundleName)：\(reason)")
            return MigrationResult(success: false, error: reason, spaceSaved: 0)
        }

        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        CrashJournal.shared.begin(CrashJournal.Entry(
            op: "migrate", appName: app.bundleName, sourcePath: sourcePath, targetPath: destPath,
            backupPath: nil, createLink: false, linkPath: nil))
        crashOpen = true

        phaseProgress(.init(phase: .copying, progress: 0.1, message: l10n("正在复制 %@...", app.name)))
        progress(0.1, l10n("正在复制 %@...", app.name))
        guard await copyWithDitto(from: sourcePath, to: destPath, progress: { pct in
            let value = 0.1 + pct * 0.7
            phaseProgress(.init(phase: .copying, progress: value, message: l10n("复制 %@...", app.name)))
            progress(value, l10n("复制 %@...", app.name))
        }) else {
            try? fileManager.removeItem(atPath: destPath)
            return MigrationResult(success: false, error: l10n("复制失败"), spaceSaved: 0)
        }

        phaseProgress(.init(phase: .verifying, progress: 0.9, message: l10n("正在校验搬回副本...")))
        progress(0.9, l10n("校验..."))
        guard await verifyFiles(source: sourcePath, target: destPath) else {
            try? fileManager.removeItem(atPath: destPath)
            AuditLog.append("搬回失败 \(app.bundleName)：校验未通过，外置副本保留")
            return MigrationResult(success: false, error: l10n("文件校验失败，请重试"), spaceSaved: 0)
        }

        phaseProgress(.init(phase: .backupAndSwitch, progress: 0.95, message: l10n("清理外置副本与备份...")))
        try? fileManager.removeItem(atPath: sourcePath)
        // 与回迁一致：应用回到内置盘了，搬迁时的留底备份即可回收
        // （跨盘备份：备份可能在指定盘上，各根目录都清）
        for root in BackupLocations.backupRoots(for: drivePath) {
            try? fileManager.removeItem(atPath: "\(root)/\(app.bundleName)")
        }
        MigrationManifest.shared.remove(appName: app.bundleName)
        AuditLog.append("搬回内置盘成功 \(app.bundleName)：\(app.size) 字节 ← \(sourcePath)")
        progress(1.0, l10n("完成"))
        return MigrationResult(success: true, error: nil, spaceSaved: -app.size)
    }

    /// 卸载（v2.13.0 起为"一条龙"第一步）：链接、外置真身/内置本体、迁移备份
    /// 全部**移入废纸篓**（可恢复）而不是永久删除——卸载是用户最需要"反悔"的时刻，
    /// 废纸篓是唯一后悔药。台账同步移除；残留数据由调用方接着扫（residues(forUninstalledApp:)）。
    func uninstallInternal(app: AppItem, drivePath: String? = nil) async -> MigrationResult {
        var failures: [String] = []
        let checker = HealthChecker()

        // 真身：链接态删的是外置盘上的目标，普通应用删的就是 /Applications 本体
        let realBundle = app.symlinkTarget ?? app.path

        // 第一步：真身进废纸篓。这一步失败就整体放弃——不动链接、不动台账。
        // 此前是"先摘链接、再删真身、再删台账"，真身收不动时（root 所有的应用）
        // 应用会变成"没有入口、台账也没了、只剩外置盘一份真身"的不可逆状态。
        if fileManager.fileExists(atPath: realBundle) {
            if !(await checker.recycleToTrash(realBundle)) {
                // root 属主应用 NSWorkspace.recycle 必失败（WeRead.app root wheel 实测，
                // Finder 语义就是要密码）：改走管理员授权把本体搬进废纸篓，仍失败才放弃。
                // 外置卷的废纸篓是 .Trashes/<uid> 结构，不做提权，保持安全失败
                if Self.trashEligibleForElevation(realBundle), Self.isRootOwned(realBundle) {
                    let elevated = await authenticatedTrash(path: realBundle)
                    let gone = elevated.success && !fileManager.fileExists(atPath: realBundle)
                    if gone {
                        AuditLog.append("卸载 \(app.bundleName)：root 属主应用经管理员授权移入废纸篓")
                    } else {
                        let reason = elevated.error ?? l10n("移动后仍未离开原位")
                        AuditLog.append("卸载 \(app.bundleName) 失败：提权移入废纸篓仍失败（\(reason)），入口与台账保持原样")
                        return MigrationResult(success: false,
                              error: l10n("应用本体移入废纸篓失败（已尝试管理员授权：%@）。", reason)
                                   + l10n("可在 Finder 里手动拖入废纸篓后再重试；此时入口与台账都保持原样"),
                              spaceSaved: 0)
                    }
                } else {
                    AuditLog.append("卸载 \(app.bundleName) 失败：应用本体未能移入废纸篓（入口与台账保持原样）")
                    return MigrationResult(success: false,
                          error: l10n("应用本体移入废纸篓失败（可能需要管理员权限）。")
                               + l10n("可在 Finder 里手动拖入废纸篓后再重试；此时入口与台账都保持原样"),
                          spaceSaved: 0)
                }
            }
        }

        // 第二步：真身已收走，链接位（无数据）直接摘；若已是断链也一并清掉
        if app.isSymlink {
            try? fileManager.removeItem(atPath: app.path)
        }

        // 第三步：迁移备份同样是数据，同样走废纸篓。失败只记账，
        // 不改变"应用本体已卸载"这个事实（备份是额外兜底，不是入口）
        if let drivePath {
            // 跨盘备份：备份可能在指定盘上，各根目录都找
            for root in BackupLocations.backupRoots(for: drivePath) {
                let backup = "\(root)/\(app.bundleName)"
                if fileManager.fileExists(atPath: backup),
                   !(await checker.recycleToTrash(backup)) {
                    failures.append(l10n("迁移备份移入废纸篓失败（仍留在 %@）", backup))
                }
            }
        }

        // 应用本体确实已经收走，台账条目才移除
        MigrationManifest.shared.remove(appName: app.bundleName)

        if failures.isEmpty {
            AuditLog.append("卸载 \(app.bundleName)：应用与备份已入废纸篓（可恢复）")
            return MigrationResult(success: true, error: nil, spaceSaved: app.size)
        }
        let msg = failures.joined(separator: "；")
        AuditLog.append("卸载 \(app.bundleName) 部分失败：应用已入废纸篓；\(msg)")
        return MigrationResult(success: false, error: msg, spaceSaved: 0)
    }
    
    /// 备份是否已过保留期（纯逻辑，供测试）。
    /// 判据是备份目录的 mtime——它必须代表"备份创建时刻"，
    /// 而不是被备份应用的安装时间（见 stampBackupCreation 的说明）
    static func isBackupExpired(modifiedAt: Date, now: Date = Date(),
                                retentionDays: Int) -> Bool {
        modifiedAt < now.addingTimeInterval(-Double(retentionDays) * 86400)
    }

    /// 自动清理过期备份（每次扫描顺手跑）。
    ///
    /// 两条红线（v3.0.1 修正）：
    /// 1. **绝不自动删除"可能是唯一副本"的备份**：对应应用已经没有可用入口时
    ///    （更新器把真身弄丢、应用被绕过本工具删掉），这份留底就是最后的退路——
    ///    此前用 removeItem 无差别永久删除，超过保留期就把唯一副本抹掉了。
    ///    这种情况留给体检页的人工清理，不由后台静默处理。
    /// 2. 删除走**废纸篓**，与 `HealthChecker.deleteBackup` 的口径一致
    ///    （"删除会移入废纸篓"是对用户的承诺，不是可选项）。
    func cleanOldBackups(at drivePath: String, applicationsRoot: String = "/Applications") async {
        // 跨盘备份：各备份根目录都要扫，切换备份盘后旧备份不遗漏
        for backupDir in BackupLocations.backupRoots(for: drivePath) {
            await cleanOldBackups(in: backupDir, drivePath: drivePath,
                                  applicationsRoot: applicationsRoot)
        }
    }

    private func cleanOldBackups(in backupDir: String, drivePath: String,
                                 applicationsRoot: String) async {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: backupDir) else { return }
        let now = Date()
        let checker = HealthChecker()

        for item in contents {
            let fullPath = "\(backupDir)/\(item)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  Self.isBackupExpired(modifiedAt: modDate, now: now,
                                       retentionDays: retentionDays) else { continue }

            guard canAutoCleanBackup(named: item, drivePath: drivePath,
                                     applicationsRoot: applicationsRoot) else {
                AuditLog.append("保留过期备份：\(item)（超过 \(retentionDays) 天，"
                    + l10n("但对应数据当前没有其它可用副本，可能是唯一退路，请在体检页人工确认）"))
                continue
            }
            if await checker.recycleToTrash(fullPath) {
                AuditLog.append("清理过期备份：\(item)（超过 \(retentionDays) 天，已入废纸篓）")
            } else {
                AuditLog.append("清理过期备份失败：\(item)（超过 \(retentionDays) 天，未能移入废纸篓）")
            }
        }
    }

    /// 自动清理的判据（纯逻辑，供测试）：**只有当备份对应的数据另有可用副本时**才允许
    /// 后台自动清理。否则这份留底可能就是唯一退路（更新器把真身弄丢、应用被绕过本工具
    /// 删掉），必须留给体检页的人工清理，不能由后台静默抹掉。
    static func backupCanBeAutoCleaned(appLinkUsable: Bool, externalCopyExists: Bool) -> Bool {
        appLinkUsable || externalCopyExists
    }

    /// 探测某份备份是否"另有可用副本"（`attributesOfItem` 不跟随符号链接 = lstat 语义）
    func canAutoCleanBackup(named appName: String, drivePath: String,
                            applicationsRoot: String = "/Applications") -> Bool {
        // 数据备份（Data-*）：判据是台账里记录的链接位
        if appName.hasPrefix(DataMigrator.manifestPrefix) {
            guard let entry = MigrationManifest.shared.entry(forAppName: appName) else {
                // 高-4（2026-10-04 审计）：无台账条目时无法证明备份冗余
                // （崩溃窗口的兜底备份就长这样），禁止自动清理，留给体检页人工处理
                AuditLog.append("保留无主数据备份 \(appName)：无台账条目，需人工确认")
                return false
            }
            guard (try? fileManager.attributesOfItem(atPath: entry.linkPath)) != nil else {
                return false    // 链接位都没了：备份可能是唯一副本
            }
            return linkIsUsable(atPath: entry.linkPath)
        }

        let linkPath = "\(applicationsRoot)/\(appName)"
        let linkUsable = linkIsUsable(atPath: linkPath)
        let externalCopyExists = Self.externalAppDirs.contains {
            fileManager.fileExists(atPath: "\(drivePath)/\($0)/\(appName)")
        }
        return Self.backupCanBeAutoCleaned(appLinkUsable: linkUsable,
                                           externalCopyExists: externalCopyExists)
    }

    /// 该位置的数据是否可用：真目录算可用；软链接看目标是否存在；不存在则不可用
    private func linkIsUsable(atPath path: String) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path) else { return false }
        guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else { return true }
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: path) else { return false }
        return fileManager.fileExists(atPath: target)
    }

    /// 给刚建立的备份打上"创建时刻"。
    ///
    /// 备份是经 ditto/move 得到的，目录 mtime 会**继承原应用的安装时间**
    /// （实测：VS Code 迁到外置盘后 mtime 仍是 7 月 22 日）。而保留期按 mtime 判断，
    /// 于是刚建好的备份在下一次扫描时就被当成"超龄"删除——日志实证：
    /// `10:46:29 迁移成功` 与 `10:46:35 清理过期备份` 相隔 6 秒，
    /// "原件留底可回滚"这个安全底实际并不存在。
    ///
    /// 备份一旦建立，它的 mtime 就应当代表备份时间。
    /// 改目录的 mtime 不影响代码签名（签名只覆盖文件内容与 CodeResources 封条）。
    func stampBackupCreation(at path: String, now: Date = Date()) {
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: path)
    }
    
    /// P0: 校验目标是真实挂载的独立卷，且剩余空间足够
    /// 返回 nil 表示通过；返回 String 为拒绝原因
    /// 取挂载点的文件系统类型（如 "apfs" / "exfat"）。失败返回 nil。
    /// statfs 是阻塞调用，调用方须在 OffPool。
    private func filesystemType(at path: String) -> String? {
        var st = statfs()
        guard path.withCString({ statfs($0, &st) }) == 0 else { return nil }
        return withUnsafeBytes(of: st.f_fstypename) { raw in
            let ptr = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: ptr)
        }
    }

    /// 取路径所在卷的可用字节数。失败返回 nil（卷离线/不可读）。
    /// statfs 是阻塞调用，调用方须在 OffPool。
    static func freeBytes(at path: String) -> Int64? {
        var st = statfs()
        guard path.withCString({ statfs($0, &st) }) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    func validateTarget(
        drivePath: String,
        appSize: Int64,
        expectedVolumeUUID: String? = nil,
        reservesBackupCopy: Bool = true
    ) -> String? {
        var st = statfs()
        guard drivePath.withCString({ statfs($0, &st) }) == 0 else {
            return l10n("目标路径无法访问（硬盘未插入？），已阻止迁移以免误写内置盘")
        }
        
        // 与根卷比较挂载设备：相同说明"目标盘"其实落在了内置盘上
        var root = statfs()
        _ = "/".withCString({ statfs($0, &root) })
        let targetDev = deviceName(of: st.f_mntfromname)
        let rootDev = deviceName(of: root.f_mntfromname)
        if targetDev == rootDev {
            return l10n("目标路径不是已挂载的外置硬盘（卷名可能已变更），已阻止迁移以免数据写入内置盘")
        }

        // A reviewed plan pins the physical destination, not only its mount path.
        // Re-read the UUID at the write boundary so a replacement disk cannot inherit
        // the approved path between review and execution.
        if let expectedVolumeUUID {
            guard let currentVolumeUUID = MigrationManifest.volumeUUID(atPath: drivePath) else {
                return l10n("无法读取目标盘卷 UUID，目标身份未确认，已阻止迁移")
            }
            guard VolumeIdentity.matches(
                expected: expectedVolumeUUID, current: currentVolumeUUID) else {
                return l10n("目标盘卷 UUID 与审阅计划不符，目标身份已变化，已阻止迁移")
            }
        }

        // 写盘边界的第二道闸：网络共享/云盘卷、只读卷、内置盘都不能当目标。
        // DiskMonitor 已把它们排除在候选外，但 drivePath 是外部传入的字符串，
        // 真正的护栏要落在"即将写数据"的这一刻。
        // 注意用卷属性判断而不是只看 statfs 设备名：APFS 的系统卷与数据卷是两个
        // 设备节点，/Volumes 下残留目录的设备名未必等于根卷。
        if let values = try? URL(fileURLWithPath: drivePath).resourceValues(
                forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey,
                          .volumeIsInternalKey, .volumeIsRemovableKey]) {
            if values.volumeIsInternal == true && values.volumeIsRemovable != true {
                return l10n("目标路径落在内置盘上（目标卷未挂载？），已阻止迁移以免数据写入内置盘")
            }
            if values.volumeIsLocal == false {
                return l10n("目标是网络共享/云盘卷：共享断线后所有链接会失效，不能用于存放应用")
            }
            if values.volumeIsReadOnly == true {
                return l10n("目标是只读卷，无法写入")
            }
        }

        // Time Machine 备份盘不能当目标：系统清理旧备份时会把放上去的应用一起销毁。
        // 这里的缓存最多容忍 60 秒——迁移是低频且高代价的操作，宁可多跑一次 tmutil，
        // 也不要拿"应用启动时的旧快照"去判断备份盘（TM 目标可能刚被改动）。
        // tmutil 是阻塞调用，调用方已把整个 validateTarget 放进 OffPool。
        VolumeClassifier.ensureCachePrimed(maxAge: 60)
        if VolumeClassifier.isOnTimeMachineVolume(path: drivePath) {
            return l10n("目标是 Time Machine 备份盘，系统空间紧张时会自动清理其中的旧备份，不能用于存放应用")
        }

        // exFAT 硬拦截：应用包内全是软链接（Frameworks 等），exFAT 不支持软链接，
        // ditto 过去直接坏掉。此前只在磁盘横条黄字警告，现在迁移入口硬拒绝。
        // 数据迁移同样拦截：权限/大小写等语义差异太多，不值得逐项排雷。
        if let fsType = filesystemType(at: drivePath),
           fsType.lowercased().contains("exfat") {
            return l10n("目标盘是 exFAT 格式：应用包内的软链接在 exFAT 上会损坏，无法迁移。请备份数据后在「磁盘工具」中将该盘抹为 APFS 再试")
        }
        
        // 空间检查：会留备份时，目标盘上要同时落【两份】——目标副本 + 同盘留底备份
        // （needsAuth 分支是两次 ditto；非 auth 分支是 ditto + 跨卷 move，move 同样是整树复制）。
        // 此前按一份体积 + 5% 校验，会在第二步备份时把盘写满、迁移失败。
        // skipBackup 与盘间迁移不写留底，只需要一份副本 + 5%。
        //
        // 跨盘备份时：备份落在另一块盘上，目标盘只需【一份】，但备份盘要单独预检
        // （此前只查目标盘，备份盘满了会跑到 85% 才失败回滚——白跑一趟）。
        let backupRoot = BackupLocations.backupRoot(for: drivePath)
        let backupOnSameVolume = reservesBackupCopy
            && backupRoot == "\(drivePath)/.suishouqian-backup"
        let freeBytes = Int64(st.f_bavail) * Int64(st.f_bsize)

        if !reservesBackupCopy {
            let needed = Self.requiredSingleCopyBytes(appSize: appSize)
            if freeBytes < needed {
                let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                return l10n("目标盘空间不足：%@ 的应用需要约 %@，仅剩 %@", need, total, free)
            }
        } else if backupOnSameVolume {
            let needed = Self.requiredTargetBytes(appSize: appSize)
            if freeBytes < needed {
                let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                return l10n("目标盘空间不足：%@ 的应用需要约 %@（含同盘留底备份），仅剩 %@", need, total, free)
            }
        } else {
            // 目标盘：只要目标副本一份（+5% 余量）
            let targetNeeded = Self.requiredSingleCopyBytes(appSize: appSize)
            if freeBytes < targetNeeded {
                let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: targetNeeded, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                return l10n("目标盘空间不足：%@ 的应用需要约 %@，仅剩 %@", need, total, free)
            }
            // 备份盘：单独预检备份空间（+5% 余量）
            let backupNeeded = Self.requiredSingleCopyBytes(appSize: appSize)
            if let backupFree = Self.freeBytes(at: backupRoot), backupFree < backupNeeded {
                let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: backupNeeded, countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: backupFree, countStyle: .file)
                return l10n("备份盘空间不足：%@ 的应用需要约 %@ 备份空间，备份盘仅剩 %@。可在设置 → 备份 → 备份存放位置中更换备份盘，或清理该盘空间", need, total, free)
            }
            // 备份盘不可读时不硬拦（离线会自动回退同盘，那里已有 2× 兜底逻辑覆盖不到——
            //  conservative：此时按同盘 2× 要求目标盘，避免回退后空间不够）
            if Self.freeBytes(at: backupRoot) == nil {
                let needed = Self.requiredTargetBytes(appSize: appSize)
                if freeBytes < needed {
                    let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                    let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                    return l10n("目标盘空间不足：%@ 的应用需要约 %@（备份盘离线，回退同盘需留备份空间），仅剩 %@", need, total, free)
                }
            }
        }

        return nil
    }

    /// 目标盘需要的可用空间（纯逻辑，供测试）：
    /// 目标副本 1 份 + 同盘留底备份 1 份 + 5% 余量。
    /// 外置盘上应用副本的合法目录（撤销可行性探测与备份清理共用同一口径，
    /// P1-1b：此前 OverviewPanel 只查卷根导致纯搬迁/原住民的副本恒"不在"）
    static let externalAppDirs = ["Applications", "Suishouqian_Apps"]

    static func requiredTargetBytes(appSize: Int64) -> Int64 {
        appSize * 2 + appSize / 20
    }

    /// 只落一份副本时的空间（盘间迁移、skipBackup）：1 份 + 5% 余量。
    static func requiredSingleCopyBytes(appSize: Int64) -> Int64 {
        appSize + appSize / 20
    }
    
    /// 回迁预检：内置盘（根卷）剩余空间是否足够
    func validateInternalFreeSpace(needBytes: Int64) -> String? {
        var st = statfs()
        guard "/".withCString({ statfs($0, &st) }) == 0 else {
            return l10n("无法读取内置盘空间信息")
        }
        let free = Int64(st.f_bavail) * Int64(st.f_bsize)
        if free < needBytes + needBytes / 20 {
            let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return l10n("内置盘空间不足：回迁需要约 %@，仅剩 %@。请先清理空间或保持外置盘使用", need, have)
        }
        return nil
    }

    private func deviceName<T>(of tuple: T) -> String {
        withUnsafeBytes(of: tuple) { buffer in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
    
    func copyWithDitto(from src: String, to dst: String,
                                progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        // 阻塞型 ditto+轮询走 GCD（OffPool），不占协作线程池
        return await OffPool.run { [self] in
            try? FileManager.default.removeItem(atPath: dst)

            // 稳定性：复制期间轮询目标大小，上报真实进度（此前全程 0%、结束直接 1%）
            let totalKB = duKB(src)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [src, dst]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                pollProgress(of: process, copiedPath: dst,
                             totalKB: totalKB, progress: progress)
                guard process.terminationStatus == 0 else {
                    // 失败必须清掉半截副本：留在 dst 会让"链接位被残缺目录占住"，
                    // 后续重建软链接必然失败——回迁失败后应用失去入口的根因
                    try? FileManager.default.removeItem(atPath: dst)
                    return false
                }

                progress(1.0)
                return true
            } catch {
                try? FileManager.default.removeItem(atPath: dst)
                return false
            }
        }
    }

    /// 同步上下文里轮询 ditto 复制进度（Thread.sleep 仅允许在同步方法中使用）
    private func pollProgress(of process: Process, copiedPath: String,
                              totalKB: Int64,
                              progress: @escaping @Sendable (Double) -> Void) {
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.4)
            if totalKB > 0 {
                let copied = duKB(copiedPath)
                progress(min(0.99, Double(copied) / Double(totalKB)))
            }
        }
        process.waitUntilExit()
    }

    /// 目录大小（KB），失败返回 0
    private func duKB(_ path: String) -> Int64 {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "du -sk '\(escaped)' 2>/dev/null | cut -f1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        // 先读至 EOF 再等待退出（项目铁律：先等后读会在输出写满管道时死锁）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 清除 macl/quarantine 隔离属性；仅当签名校验不过时才 ad-hoc 重签。
    /// 此前无条件 codesign --force --deep（--deep 已被 Apple 废弃），
    /// 可能弄坏带特权 Helper/XPC 的复杂应用
    /// P2-1（Muse 审查）：内部串行跑多个子进程（codesign verify 对大应用可达数秒），
    /// 必须整体 OffPool，不占协作线程池。两个调用点（migrate/relocate）都已是 async 上下文。
    func fixAttributes(at path: String) async {
        await OffPool.run { Self.fixAttributesSync(at: path) }
    }

    private static func fixAttributesSync(at path: String) {
        let run = { (args: [String]) -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return -1 }
            p.waitUntilExit()
            return p.terminationStatus
        }
        _ = run(["-d", "com.apple.macl", path])
        _ = run(["-dr", "com.apple.quarantine", path])

        // 签名验证通过就不动它
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", path]
        verify.standardOutput = FileHandle.nullDevice
        verify.standardError = FileHandle.nullDevice
        guard (try? verify.run()) != nil else { return }
        verify.waitUntilExit()
        if verify.terminationStatus == 0 { return }

        // 走到这里说明副本自带的签名已经无效。ad-hoc 重签能让它启动，但会**改掉应用的
        // 代码身份**：keychain ACL、TCC 授权、带 Helper/XPC 的应用内部校验都可能失效。
        // 这是有代价的动作，必须留痕，并在签完后复核（不能签完就走）。
        AuditLog.append("迁移副本签名无效，按既有策略做 ad-hoc 重签：\(path)")
        let resign = Process()
        resign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        resign.arguments = ["--force", "--sign", "-", path]
        resign.standardOutput = FileHandle.nullDevice
        resign.standardError = FileHandle.nullDevice
        guard (try? resign.run()) != nil else {
            AuditLog.append("ad-hoc 重签无法启动：\(path)（应用可能无法启动）")
            return
        }
        resign.waitUntilExit()

        let reverify = Process()
        reverify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        reverify.arguments = ["--verify", path]
        reverify.standardOutput = FileHandle.nullDevice
        reverify.standardError = FileHandle.nullDevice
        if (try? reverify.run()) != nil {
            reverify.waitUntilExit()
            if reverify.terminationStatus == 0 {
                AuditLog.append("ad-hoc 重签完成并复核通过（代码身份已变，首次启动可能重新弹授权/要求重新登录）")
            } else {
                AuditLog.append("ad-hoc 重签后仍未通过校验：\(path)（应用可能无法启动，可在体检页回迁还原）")
            }
        }
    }

    /// 快速校验：文件数 + 逻辑字节总和一致后，再做随机抽样 SHA256。
    /// 逻辑大小（stat %z）跨盘确定，此前用 du 块大小在 APFS 稀疏/克隆
    /// 文件场景下源目标必不相等，造成校验误报。
    /// 抽样哈希把"大小一致"升级为"抽样内容一致"，防位腐烂/静默写坏；
    /// 文件总数 ≤ 抽样上限时自动全量哈希。任一抽样文件读不出哈希即失败。
    func verifyFiles(source: String, target: String) async -> Bool {
        // 阻塞型 find/stat/shasum 走 GCD（OffPool）
        return await OffPool.run { [self] in
            guard let srcInfo = quickCheck(dir: source),
                  let dstInfo = quickCheck(dir: target),
                  srcInfo.count == dstInfo.count,
                  srcInfo.sizeBytes == dstInfo.sizeBytes else {
                return false
            }
            return sampleHashesMatch(source: source, target: target,
                                     totalCount: srcInfo.count)
        }
    }

    /// 随机抽样哈希对比。缺哈希或内容不同都是失败。
    private func sampleHashesMatch(source: String, target: String, totalCount: Int) -> Bool {
        let sampleLimit = 32
        guard totalCount > 0 else { return true }

        guard let files = self.listFiles(under: source), !files.isEmpty else { return false }
        let sample = files.count <= sampleLimit
            ? files
            : Array(files.shuffled().prefix(sampleLimit))

        // 以相对路径为键，分别对源/目标批量哈希
        let srcRoot = source.hasSuffix("/") ? String(source.dropLast()) : source
        let dstRoot = target.hasSuffix("/") ? String(target.dropLast()) : target
        // find 可能把 /var 解析成 /private/var，不能按原字符串裁前缀。
        let paired = sample.compactMap { path -> (rel: String, path: String)? in
            guard let rel = Self.relativePath(path, under: srcRoot) else { return nil }
            return (rel, path)
        }
        guard paired.count == sample.count else { return false }
        let relSample = paired.map(\.rel)
        let srcArgs = paired.map(\.path)
        let dstArgs = relSample.map { "\(dstRoot)/\($0)" }

        return Self.hashesMatch(
            relativePaths: relSample,
            source: Self.digestMap(files: srcArgs, relativeTo: srcRoot),
            target: Self.digestMap(files: dstArgs, relativeTo: dstRoot))
    }

    /// 抽样路径必须在两侧都有哈希，且哈希相同。缺一项就是失败，不能当成通过。
    static func hashesMatch(relativePaths: [String],
                            source: [String: String]?,
                            target: [String: String]?) -> Bool {
        guard !relativePaths.isEmpty else { return true }
        guard let source, let target else { return false }
        for rel in relativePaths {
            guard let left = source[rel], let right = target[rel], left == right else {
                return false
            }
        }
        return true
    }

    /// 逐个文件算 SHA256。读不出或路径对不上根目录时返回 nil，调用方必须判失败。
    /// 不用 `/usr/sbin/shasum`：那条路径在 macOS 上不存在，进程失败会被误当成缺哈希。
    static func digestMap(files: [String], relativeTo root: String) -> [String: String]? {
        guard !files.isEmpty else { return nil }
        var map: [String: String] = [:]
        for file in files {
            guard let rel = relativePath(file, under: root),
                  let hash = sha256Hex(ofFile: file) else { return nil }
            map[rel] = hash
        }
        return map
    }

    /// 流式 SHA256。文件打不开或读到一半出错返回 nil。
    static func sha256Hex(ofFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `/var` 与 `/private/var` 视为同一路径，再取相对路径。对不上返回 nil。
    static func relativePath(_ path: String, under root: String) -> String? {
        func variants(_ raw: String) -> [String] {
            let standardized = (raw as NSString).standardizingPath
            let resolved = (raw as NSString).resolvingSymlinksInPath
            var values = [raw, standardized, resolved]
            for item in [raw, standardized, resolved] {
                if item.hasPrefix("/private/var/") {
                    values.append(String(item.dropFirst("/private".count)))
                } else if item.hasPrefix("/var/") {
                    values.append("/private" + item)
                }
            }
            return values
        }
        for candidate in variants(path) {
            for base in variants(root) {
                if candidate == base { return "" }
                let prefix = base.hasSuffix("/") ? base : base + "/"
                if candidate.hasPrefix(prefix) {
                    return String(candidate.dropFirst(prefix.count))
                }
            }
        }
        return nil
    }

    func listFiles(under dir: String) -> [String]? {
        let escaped = dir.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "find '\(escaped)' -type f -print0 2>/dev/null"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // 管道死锁修复：大应用文件清单可达数 MB，远超管道缓冲(64KB)。
        // 必须"边跑边读"——先读完(阻塞至EOF)再 waitUntilExit；
        // 若先等退出，find 会在写满管道后永久阻塞（CodeBuddy CN 事故根因）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        let files = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return files.isEmpty ? nil : files
    }

    /// 统计文件数与逻辑字节总和（<1秒）
    private func quickCheck(dir: String) -> (count: Int, sizeBytes: Int64)? {
        let escaped = dir.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
            "find '\(escaped)' -type f -print0 2>/dev/null | xargs -0 stat -f %z 2>/dev/null | awk '{s+=$1; n++} END{print n+0, s+0}'"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // 先读至 EOF 再等待退出（项目铁律：先等后读会在输出写满管道时死锁）
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = output.split(separator: " ")
            guard parts.count == 2,
                  let count = Int(parts[0]),
                  let size = Int64(parts[1]) else { return nil }
            return (count, size)
        } catch {
            return nil
        }
    }
    
    func moveItem(from src: String, to dst: String) async -> Bool {
        // 跨卷 move 实为整树复制，大应用要跑几分钟：必须 OffPool，
        // Task.detached 占的是协作线程池（冻结事故根因类别，2026-09-23 审查修）
        return await OffPool.run {
            try? FileManager.default.removeItem(atPath: dst)
            do {
                try FileManager.default.moveItem(atPath: src, toPath: dst)
                return true
            } catch {
                return false
            }
        }
    }
    
    /// 应用是否正在运行（读 Bundle ID 后查 NSRunningApplication，穿透软链接）
    static func runningAppName(matching appPath: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: appPath + "/Contents/Info.plist"),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID.hasPrefix("_") == false else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return running.first?.localizedName
    }

    /// 检查文件是否需要管理员权限（root 所有 + 在受保护目录）
    private func needsAdminPrivilege(for path: String) async -> Bool {
        return await OffPool.run {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attrs[.ownerAccountName] as? String else { return false }
            return owner == "root"
        }
    }
    
    /// 用 osascript 提权删除源应用，`createLink` 为真时再建符号链接（不操作外置盘）。
    /// 删除与建链放在同一次授权里完成，用户只输一次密码。
    private func authenticatedRemove(source: String, linkTarget: String,
                                     createLink: Bool) async -> (success: Bool, error: String?) {
        // osascript 会阻塞等待用户输密码（可能很久）：必须 OffPool，
        // 协作线程池被占死就是两次冻结事故的根因（2026-09-23 审查修）
        return await OffPool.run {
            PrivilegedShell.run(.remove(source: source, linkTarget: linkTarget, createLink: createLink))
        }
    }

    // MARK: - 卸载：root 属主应用的废纸篓兜底

    /// 路径是否允许走提权废纸篓（纯逻辑，供测试）。
    /// 只认系统盘（/Applications 等非 /Volumes 路径）：外置卷的废纸篓是 .Trashes/<uid>
    /// 结构（可能不存在、要补 chown），提权碰它风险大于收益，外置卷保持原安全失败。
    static func trashEligibleForElevation(_ path: String) -> Bool {
        !path.hasPrefix("/Volumes/")
    }

    /// 应用本体是否非当前用户属主（纯判定）：root 属主的 bundle NSWorkspace.recycle
    /// 必失败（Finder 语义就是弹密码），这是卸载提权兜底的触发条件。
    static func isRootOwned(_ path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let owner = attrs?[.ownerAccountName] as? String else { return false }
        return owner != NSUserName()
    }

    /// 生成把应用本体搬进废纸篓的提权 shell 命令（internal 供测试验证转义与重名避让）。
    /// Finder 语义：同卷 mv（系统盘内是 rename，瞬间完成）+ 目标重名时追加 " 2"/" 3"
    /// ——与 TrashRecovery 卸载撤销的变体名规则天然兼容。
    /// 废纸篓目录由 Swift 侧传用户家目录（NSHomeDirectory()），不依赖脚本内的 $HOME
    /// ——提权后 shell 以 root 跑，$HOME 是 /var/root，靠它会把东西搬错地方。
    static func privilegedTrashCommand(sourcePath: String, userTrashDir: String) -> String {
        // 只需 shell 一层转义：命令整体再由 authenticatedTrash 按 AppleScript 规则包引号
        func escShell(_ s: String) -> String {
            s.replacingOccurrences(of: "'", with: "'\\''")
        }
        let src = escShell(sourcePath)
        let dir = escShell(userTrashDir)
        // 重名避让必须发生在目标侧：~/.Trash 已有同名条目时，直接 mv 会把应用嵌进
        // 那个同名目录里而不是改名（mv 语义），卸载撤销就找不到候选了
        return "T='\(dir)'; S='\(src)'; N=\"$(basename \"$S\")\"; D=\"$T/$N\"; i=2"
            + "; while [ -e \"$D\" ]; do D=\"$T/$N $i\"; i=$((i+1)); done; mv \"$S\" \"$D\""
    }

    /// osascript 提权把应用本体移入废纸篓（root 属主应用的卸载兜底，WeRead 实测案例）。
    /// osascript 阻塞等密码：必须 OffPool，协作线程池被占死就是两次冻结事故的根因。
    /// 管道纪律与 authenticatedRemove 相同：stdout 丢弃、stderr 先读后等。
    private func authenticatedTrash(path: String) async -> (success: Bool, error: String?) {
        let trashDir = NSHomeDirectory() + "/.Trash"
        return await OffPool.run {
            PrivilegedShell.run(.trash(source: path, trashDir: trashDir))
        }
    }
}
