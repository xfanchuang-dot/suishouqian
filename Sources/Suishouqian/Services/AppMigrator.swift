import Foundation
import AppKit

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
                                "无法替换链接 \(linkPath)（\(String(cString: strerror(errno)))）"])
        }
    }

    /// 提权改写链接（链接位属 root 时 swapSymlink 会被 EPERM 挡）。
    /// osascript 阻塞等密码：必须 OffPool。管道纪律与 authenticatedRemove 相同：
    /// stdout 丢弃、stderr 先读后等。
    private func authenticatedRewriteLink(linkPath: String, toTarget target: String) async
        -> (success: Bool, error: String?) {
        return await OffPool.run {
            func escShell(_ s: String) -> String {
                s.replacingOccurrences(of: "'", with: "'\\''")
            }
            func escAppleScript(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }
            // ln -sfn：先摘旧链接再建新的（提权场景无 rename(2) 可用，窗口极小且
            // 失败时旧链接仍在——ln 失败不会删源）
            let command = "ln -sfn '\(escShell(target))' '\(escShell(linkPath))'"
            let script = "tell application \"随手迁\" to activate\ndelay 0.3\n"
                + "do shell script \"\(escAppleScript(command))\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            do {
                try process.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return (true, nil) }
                let errMsg = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
                if errMsg.contains("User canceled") { return (false, "已取消授权") }
                return (false, errMsg)
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }

    /// 盘间迁移（v3.0）：A 盘 → B 盘，**不经过内置盘中转**（中转要两份空间，违背省空间初衷）。
    /// 流程：A→B 复制 → 字节校验 → 修属性 → 原子改写链接（有链接才改）→ 台账更新 → 删 A 副本。
    /// 安全关键：A 副本在链接改写成功前**绝不删**——任一步失败，应用仍从 A 盘完整可用。
    /// 失败清场只动 B 盘上的半截副本。
    func relocate(app: AppItem, fromVolume: String, toVolume: String,
                  progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
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
            return finish(false, "应用副本不在源盘上（\(sourcePath) 不在 \(from)），已取消")
        }
        guard from != to else {
            return finish(false, "源盘与目标盘相同，无需迁移")
        }
        if let runningName = Self.runningAppName(matching: sourcePath) {
            return finish(false, "「\(runningName)」正在运行，请先退出后再搬")
        }
        guard fileManager.fileExists(atPath: sourcePath) else {
            return finish(false, "源盘上的应用副本不存在（\(sourcePath)）")
        }
        // 目标盘三重验证（挂载点/空间两份+5%/TM 排除），阻塞调用走 OffPool
        let targetIssue = await OffPool.run { [self] in
            validateTarget(drivePath: to, appSize: app.size)
        }
        if let reason = targetIssue {
            return finish(false, reason)
        }
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        // 护栏全过后交给 core（core 是可测入口，自己记 journal——护栏路径用 finish 记，
        // core 路径由 core 记，两边不会重复）
        return await relocateCore(app: app, sourcePath: sourcePath,
                                  fromVolume: from, toVolume: to, progress: progress)
    }

    // MARK: - 目标占用与迁移标记（高-3 × 中断恢复的和解）

    /// 区分"上次迁移/盘间迁移中断的遗留副本"与"目标盘上无关的同名应用"：
    /// 复制开始前先在目标旁边落标记文件，进程崩溃必然留下"半截副本+标记"成对存在。
    /// 重试见标记 → 清掉遗留重搬（收敛）；无标记 → 外来应用，拒绝。
    static let relocationMarkerSuffix = ".suishouqian-relocating"

    /// 返回 nil = 目标可用（标记已就位）；返回文案 = 拒绝原因
    static func prepareTargetForCopy(_ fm: FileManager, targetPath: String) -> String? {
        let marker = targetPath + relocationMarkerSuffix
        if fm.fileExists(atPath: targetPath) {
            guard fm.fileExists(atPath: marker) else {
                return "目标盘已存在同名应用（\(targetPath)），为避免覆盖已中止"
            }
            // 上次中断的遗留：副本与标记成对清掉
            try? fm.removeItem(atPath: targetPath)
            try? fm.removeItem(atPath: marker)
        }
        // 空盘没有 Applications/ 目录，而 createFile 不建中间目录——先补上
        // （ditto 本来也会建，提前建只为让标记有地方落）
        let parentDir = (targetPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        if !fm.createFile(atPath: marker, contents: nil) {
            return "无法写入迁移标记文件（\(marker)），已中止"
        }
        return nil
    }

    /// 目标副本被删除或转正时同步摘标记——保持"标记 ⟺ 我方副本在目标盘"不变量，
    /// 防止陈旧标记让日后的外来同名应用被误判成遗留而遭覆盖
    static func clearRelocationMarker(_ fm: FileManager, targetPath: String) {
        try? fm.removeItem(atPath: targetPath + relocationMarkerSuffix)
    }

    /// 盘间迁移核心（可测入口：不做卷级护栏，路径全由调用方保证）。
    /// 单一出口记 journal；测试注入 temp 目录即可全流程验证。
    func relocateCore(app: AppItem, sourcePath: String, fromVolume: String, toVolume: String,
                      linkDirectory: String = "/Applications",
                      progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let appName = app.bundleName
        let relative = (sourcePath as NSString).lastPathComponent
        // 保持源盘上的相对布局（Applications/ 或 Suishouqian_Apps/ 原样带到目标盘）
        let parentName = (sourcePath as NSString).deletingLastPathComponent
            .replacingOccurrences(of: fromVolume + "/", with: "")
        let targetPath = "\(toVolume)/\(parentName)/\(relative)"
        let linkPath = "\(linkDirectory)/\(appName)"
        let hadLink = (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil
        // P2-3 漂移护栏必须在复制之前：中止越早，目标盘越干净（复制后才查会留下整份副本）
        if hadLink {
            // 合法现状只有两个——还指着源（没动过）或已指着目标（上次中断在改写后，
            // 重跑幂等）；指向第三处说明链接已被回归/自愈改写，必须中止
            let currentLink = try? fileManager.destinationOfSymbolicLink(atPath: linkPath)
            guard currentLink == sourcePath || currentLink == targetPath else {
                return done(false, "链接指向已变化（当前指向 \(currentLink ?? "未知")），已中止以免误改")
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
        if let reject = Self.prepareTargetForCopy(fileManager, targetPath: targetPath) {
            return done(false, reject)
        }

        progress(0.1, "正在复制 \(app.name) 到目标盘...")
        let copyOk = await copyWithDitto(from: sourcePath, to: targetPath) { pct in
            progress(0.1 + pct * 0.5, "复制 \(app.name)...")
        }
        guard copyOk else {
            try? fileManager.removeItem(atPath: targetPath)   // 清半截副本，A 不动
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return done(false, "复制到目标盘失败")
        }

        progress(0.65, "正在校验完整性...")
        let verified = await verifyFiles(source: sourcePath, target: targetPath)
        guard verified else {
            try? fileManager.removeItem(atPath: targetPath)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return done(false, "文件校验失败，已回滚目标副本（源盘副本未动）")
        }

        progress(0.75, "修复文件属性...")
        await fixAttributes(at: targetPath)

        // 链接改写（有 /Applications 链接才做；externalOnly 原住民跳过）
        if hadLink {
            progress(0.85, "改写应用链接...")
            do {
                try Self.swapSymlink(at: linkPath, to: targetPath)
            } catch {
                // 链接仍指向 A（应用可用）；常见原因是链接位属 root → 走提权
                let auth = await authenticatedRewriteLink(linkPath: linkPath, toTarget: targetPath)
                guard auth.success else {
                    return done(false, "链接改写失败：\(auth.error ?? "未知错误")（应用仍从源盘运行，两盘副本都在）")
                }
            }
            // 回读确认改写生效（覆盖 rename 与提权两条路径），确认无误才允许删源。
            // 自审发现：此护栏最初被插进 guard-else 分支 return 之后，是永不执行的死代码
            guard (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) == targetPath else {
                return done(false, "链接改写后校验未通过，源盘副本未动")
            }
        }

        // 台账：有链接才记（与 migrate 的纯搬迁语义一致）
        if hadLink, let uuid = MigrationManifest.volumeUUID(atPath: toVolume) {
            MigrationManifest.shared.record(
                appName: appName, linkPath: linkPath, volumeUUID: uuid,
                relativePath: "\(parentName)/\(relative)",
                volumeRole: nil)
        }

        progress(0.95, "清理源盘副本...")
        do {
            try fileManager.removeItem(atPath: sourcePath)
        } catch {
            // 链接已指向 B，应用可用；源盘残留如实上报
            AuditLog.append("盘间迁移 \(appName)：源盘副本删除失败（\(error.localizedDescription)），"
                + "链接已指向目标盘，可稍后手动清理 \(sourcePath)")
        }

        progress(1.0, "完成")
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
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let result = await migrateInternal(app: app, to: drivePath,
                                           createLink: createLink, progress: progress)
        OperationJournal.shared.record(
            op: .migrate, appName: app.bundleName,
            params: ["createLink": createLink ? "1" : "0",
                     "volumeUUID": MigrationManifest.volumeUUID(atPath: drivePath) ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "未知原因")")
        return result
    }

    /// 回迁
    func restore(app: AppItem, from drivePath: String,
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        let result = await restoreInternal(app: app, from: drivePath, progress: progress)
        OperationJournal.shared.record(
            op: .restore, appName: app.bundleName,
            params: ["volumeUUID": MigrationManifest.volumeUUID(atPath: drivePath) ?? ""],
            result: result.success ? "ok" : "failed: \(result.error ?? "未知原因")")
        return result
    }

    /// 外置盘原住民搬回内置盘
    func moveBackToInternal(app: AppItem, drivePath: String,
                            progress: @escaping @Sendable (Double, String) -> Void)
        async -> MigrationResult {
        let result = await moveBackToInternalInternal(app: app, drivePath: drivePath,
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
            params: [:],
            result: result.success ? "ok" : "failed: \(result.error ?? "部分失败")")
        return result
    }

    func migrateInternal(app: AppItem, to drivePath: String, createLink: Bool = true,
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {

        let appName = app.bundleName
        let sourcePath = app.path
        let targetDir = "\(drivePath)/Applications"
        let targetPath = "\(targetDir)/\(appName)"
        let backupPath = "\(drivePath)/.suishouqian-backup/\(appName)"

        // 硬护栏：源与目标不能是同一个位置。copyWithDitto 的第一步是 removeItem(dst)，
        // 若 dst 就是应用自身（外置盘原住民被误走"迁移"入口），等于直接删库。
        // UI 目前按 status 分流不会走到这里，但这条语义必须由 API 自己守住。
        if (sourcePath as NSString).standardizingPath == (targetPath as NSString).standardizingPath {
            return MigrationResult(success: false,
                  error: "「\(appName)」已经在这个目录里，无需再次迁移（若要搬回内置盘请用「搬回内置盘」）",
                  spaceSaved: 0)
        }

        // 稳定性：应用正在运行时移动/替换会导致半完成状态，直接拒绝
        if let runningName = Self.runningAppName(matching: sourcePath) {
            AuditLog.append("拒绝迁移 \(appName)：应用正在运行")
            return MigrationResult(success: false,
                  error: "「\(runningName)」正在运行，请先退出后再迁移", spaceSaved: 0)
        }

        // P0: 目标必须是真实挂载的独立卷。历史上发生过目标卷未挂载时
        // createDirectory 把数据全写进内置盘 /Volumes 的事故，此处硬性拦截。
        // validateTarget 里有 statfs + tmutil + resourceValues，全部是阻塞调用 → OffPool
        let targetIssue = await OffPool.run { [self] in
            validateTarget(drivePath: drivePath, appSize: app.size)
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
                  error: "无法创建目标目录: \(error.localizedDescription)", spaceSaved: 0)
        }
        
        // 高-3（2026-10-04 审计）：复制前检查目标路径占用（copyWithDitto 首句就是删目标）。
        // 无标记的同名应用是目标盘上的无关应用，拒绝；带标记的是上次中断的遗留，
        // 清掉重搬——崩溃后重试必须能收敛。口径与 moveBackToInternalInternal 一致。
        if let reject = Self.prepareTargetForCopy(fileManager, targetPath: targetPath) {
            AuditLog.append("拒绝迁移 \(appName)：\(reject)")
            return MigrationResult(success: false, error: reject, spaceSaved: 0)
        }

        progress(0.1, "正在复制 \(app.name)...")
        let copyOk = await copyWithDitto(from: sourcePath, to: targetPath) { pct in
            progress(0.1 + pct * 0.6, "复制 \(app.name)...")
        }
        guard copyOk else {
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)  // 半截副本已由 copyWithDitto 清掉
            return MigrationResult(success: false,
                  error: "复制失败", spaceSaved: 0)
        }

        progress(0.7, "正在校验完整性...")
        let verified = await verifyFiles(source: sourcePath, target: targetPath)
        guard verified else {
            AuditLog.append("迁移失败 \(appName)：校验未通过，已回滚目标副本")
            try? fileManager.removeItem(atPath: targetPath)
            Self.clearRelocationMarker(fileManager, targetPath: targetPath)
            return MigrationResult(success: false,
                  error: "文件校验失败，请重试", spaceSaved: 0)
        }
        
        // 校验通过后才修复属性（必须在校验之后，因为 codesign 会修改二进制导致 diff 不一致）
        progress(0.8, "修复文件属性...")
        await fixAttributes(at: targetPath)
        
        progress(0.85, "备份原件...")
        try? fileManager.createDirectory(atPath: "\(drivePath)/.suishouqian-backup", 
              withIntermediateDirectories: true)
        
        // 检查是否需要管理员权限（/Applications 下的 root 所有文件）
        let needsAuth = await needsAdminPrivilege(for: sourcePath)
        
        if needsAuth {
            // 备份到外置盘（普通 ditto，不需要 admin；osascript admin 写不了外置盘）
            progress(0.85, "备份原件...")
            let backupOk = await copyWithDitto(from: sourcePath, to: backupPath) { _ in }
            guard backupOk else {
                try? fileManager.removeItem(atPath: targetPath)
                Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                return MigrationResult(success: false,
                      error: "备份失败", spaceSaved: 0)
            }
            // 备份 mtime 必须代表"备份时刻"，否则刚建好就被当超龄清掉
            stampBackupCreation(at: backupPath)
            
            // 删原件（按需再建符号链接，需要 admin；只操作 /Applications 不写外置盘）
            progress(0.9, "需要管理员权限...")
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
                          error: authResult.error ?? "权限操作失败", spaceSaved: 0)
                }
                let restored = await copyWithDitto(from: backupPath, to: sourcePath) { _ in }
                if restored {
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    try? fileManager.removeItem(atPath: backupPath)
                } else {
                    // 回滚未完成：目标副本与备份都保留（两份都能拿来人工恢复）
                    AuditLog.append("迁移失败 \(appName)：授权回滚未完成，"
                        + "目标副本与原件备份都保留（\(targetPath) / \(backupPath)）")
                }
                return MigrationResult(success: false,
                      error: restored ? (authResult.error ?? "权限操作失败")
                                      : "权限操作失败且回滚未完成，原件备份保留在外置盘 .suishouqian-backup，可从体检页恢复",
                      spaceSaved: 0)
            }
        } else {
            let moved = await moveItem(from: sourcePath, to: backupPath)
            guard moved else {
                try? fileManager.removeItem(atPath: targetPath)
                Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                return MigrationResult(success: false,
                      error: "无法移动原文件（可能正在运行或权限不足）", spaceSaved: 0)
            }
            // 备份 mtime 必须代表"备份时刻"（move 会保留原应用的安装时间）
            stampBackupCreation(at: backupPath)
            if createLink {
                do {
                    try fileManager.createSymbolicLink(atPath: sourcePath,
                                                       withDestinationPath: targetPath)
                } catch {
                    _ = await moveItem(from: backupPath, to: sourcePath)
                    try? fileManager.removeItem(atPath: targetPath)
                    Self.clearRelocationMarker(fileManager, targetPath: targetPath)
                    return MigrationResult(success: false,
                          error: "创建符号链接失败: \(error.localizedDescription)", spaceSaved: 0)
                }
            }
        }
        
        progress(1.0, "完成")
        AuditLog.append(createLink
            ? "迁移成功 \(appName)：\(app.size) 字节 → \(targetPath)"
            : "纯搬迁成功 \(appName)：\(app.size) 字节 → \(targetPath)（未在 /Applications 留链接）")

        // 台账只在留链接时需要——它的用途是"卷改名后按 UUID 重写链接"。
        // 纯搬迁没有链接可修，而且台账校准会把 linkPath 不存在的条目当幽灵清掉，
        // 所以不记录才是正确的（这类应用由扫描 <盘>/Applications 识别为「在外置盘」）
        if createLink, targetPath.hasPrefix(drivePath + "/") {
            if let uuid = MigrationManifest.volumeUUID(atPath: drivePath) {
                MigrationManifest.shared.record(
                    appName: appName, linkPath: sourcePath, volumeUUID: uuid,
                    relativePath: String(targetPath.dropFirst(drivePath.count + 1)))
            }
        }
        Self.clearRelocationMarker(fileManager, targetPath: targetPath)
        return MigrationResult(success: true, error: nil, spaceSaved: app.size)
    }

    /// 纯搬迁：把应用搬到外置盘，但**不在 /Applications 留链接**。
    ///
    /// 适合自带更新器、且不需要出现在「应用程序」文件夹的应用。
    /// 对这类应用它比"迁移"更稳：更新器破坏的对象就是那个链接（App Store /
    /// 安装器会往 /Applications 写真目录把链接顶掉），没有链接就没有这个故障模式。
    func moveToExternal(app: AppItem, drivePath: String,
                        progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        await migrate(app: app, to: drivePath, createLink: false, progress: progress)
    }
    
    func restoreInternal(app: AppItem, from drivePath: String,
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {
        
        guard let target = app.symlinkTarget else {
            return MigrationResult(success: false, error: "未找到外置盘上的应用", spaceSaved: 0)
        }
        
        let appName = app.bundleName
        let sourcePath = app.path
        let externalPath = target
        let backupDir = "\(drivePath)/.suishouqian-backup/\(appName)"

        // 稳定性：回迁同样要求应用未在运行
        if let runningName = Self.runningAppName(matching: sourcePath) {
            return MigrationResult(success: false,
                  error: "「\(runningName)」正在运行，请先退出后再回迁", spaceSaved: 0)
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
                error: "该位置已不是软链接（可能已被应用更新替换为真目录），请重新扫描后再操作",
                spaceSaved: 0)
        }

        progress(0.1, "删除符号链接...")
        try? fileManager.removeItem(atPath: sourcePath)
        
        progress(0.2, "正在回迁 \(app.name)...")
        let copyOk = await copyWithDitto(from: externalPath, to: sourcePath) { pct in
            progress(0.2 + pct * 0.7, "回迁 \(app.name)...")
        }
        guard copyOk else {
            // 复制失败也要保证应用仍有入口：先腾空链接位（半截副本已由
            // copyWithDitto 清掉，这里再兜一次），再重建软链接
            try? fileManager.removeItem(atPath: sourcePath)
            try? fileManager.createSymbolicLink(atPath: sourcePath, withDestinationPath: externalPath)
            AuditLog.append("回迁失败 \(appName)：复制未完成，已恢复软链接（外置副本保留）")
            return MigrationResult(success: false, error: "回迁复制失败", spaceSaved: 0)
        }
        
        progress(0.9, "校验...")
        let verified = await verifyFiles(source: externalPath, target: sourcePath)
        
        if verified {
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

        progress(1.0, "完成")
        return MigrationResult(success: verified, error: verified ? nil : "校验失败",
                               spaceSaved: -app.size)
    }

    /// 把「一直住在外置盘」的应用搬回内置盘（无链接语义：复制→校验→删外置副本）
    func moveBackToInternalInternal(app: AppItem, drivePath: String,
                            progress: @escaping @Sendable (Double, String) -> Void)
        async -> MigrationResult {
        let sourcePath = app.path
        let destPath = "/Applications/\(app.bundleName)"

        if let runningName = Self.runningAppName(matching: sourcePath) {
            return MigrationResult(success: false,
                  error: "「\(runningName)」正在运行，请先退出后再搬回", spaceSaved: 0)
        }
        if fileManager.fileExists(atPath: destPath) {
            return MigrationResult(success: false,
                  error: "内置盘已存在同名应用，无法搬回", spaceSaved: 0)
        }
        if let reason = validateInternalFreeSpace(needBytes: app.size) {
            AuditLog.append("拒绝搬回 \(app.bundleName)：\(reason)")
            return MigrationResult(success: false, error: reason, spaceSaved: 0)
        }

        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        progress(0.1, "正在复制 \(app.name)...")
        guard await copyWithDitto(from: sourcePath, to: destPath, progress: { pct in
            progress(0.1 + pct * 0.7, "复制 \(app.name)...")
        }) else {
            try? fileManager.removeItem(atPath: destPath)
            return MigrationResult(success: false, error: "复制失败", spaceSaved: 0)
        }

        progress(0.9, "校验...")
        guard await verifyFiles(source: sourcePath, target: destPath) else {
            try? fileManager.removeItem(atPath: destPath)
            AuditLog.append("搬回失败 \(app.bundleName)：校验未通过，外置副本保留")
            return MigrationResult(success: false, error: "文件校验失败，请重试", spaceSaved: 0)
        }

        try? fileManager.removeItem(atPath: sourcePath)
        // 与回迁一致：应用回到内置盘了，搬迁时的留底备份即可回收
        try? fileManager.removeItem(atPath: "\(drivePath)/.suishouqian-backup/\(app.bundleName)")
        MigrationManifest.shared.remove(appName: app.bundleName)
        AuditLog.append("搬回内置盘成功 \(app.bundleName)：\(app.size) 字节 ← \(sourcePath)")
        progress(1.0, "完成")
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
                AuditLog.append("卸载 \(app.bundleName) 失败：应用本体未能移入废纸篓（入口与台账保持原样）")
                return MigrationResult(success: false,
                      error: "应用本体移入废纸篓失败（可能需要管理员权限）。"
                           + "可在 Finder 里手动拖入废纸篓后再重试；此时入口与台账都保持原样",
                      spaceSaved: 0)
            }
        }

        // 第二步：真身已收走，链接位（无数据）直接摘；若已是断链也一并清掉
        if app.isSymlink {
            try? fileManager.removeItem(atPath: app.path)
        }

        // 第三步：迁移备份同样是数据，同样走废纸篓。失败只记账，
        // 不改变"应用本体已卸载"这个事实（备份是额外兜底，不是入口）
        if let drivePath {
            let backup = "\(drivePath)/.suishouqian-backup/\(app.bundleName)"
            if fileManager.fileExists(atPath: backup),
               !(await checker.recycleToTrash(backup)) {
                failures.append("迁移备份移入废纸篓失败（仍留在 \(backup)）")
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
        let backupDir = "\(drivePath)/.suishouqian-backup"
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
                    + "但对应数据当前没有其它可用副本，可能是唯一退路，请在体检页人工确认）")
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
    func validateTarget(drivePath: String, appSize: Int64) -> String? {
        var st = statfs()
        guard drivePath.withCString({ statfs($0, &st) }) == 0 else {
            return "目标路径无法访问（硬盘未插入？），已阻止迁移以免误写内置盘"
        }
        
        // 与根卷比较挂载设备：相同说明"目标盘"其实落在了内置盘上
        var root = statfs()
        _ = "/".withCString({ statfs($0, &root) })
        let targetDev = deviceName(of: st.f_mntfromname)
        let rootDev = deviceName(of: root.f_mntfromname)
        if targetDev == rootDev {
            return "目标路径不是已挂载的外置硬盘（卷名可能已变更），已阻止迁移以免数据写入内置盘"
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
                return "目标路径落在内置盘上（目标卷未挂载？），已阻止迁移以免数据写入内置盘"
            }
            if values.volumeIsLocal == false {
                return "目标是网络共享/云盘卷：共享断线后所有链接会失效，不能用于存放应用"
            }
            if values.volumeIsReadOnly == true {
                return "目标是只读卷，无法写入"
            }
        }

        // Time Machine 备份盘不能当目标：系统清理旧备份时会把放上去的应用一起销毁。
        // 这里的缓存最多容忍 60 秒——迁移是低频且高代价的操作，宁可多跑一次 tmutil，
        // 也不要拿"应用启动时的旧快照"去判断备份盘（TM 目标可能刚被改动）。
        // tmutil 是阻塞调用，调用方已把整个 validateTarget 放进 OffPool。
        VolumeClassifier.ensureCachePrimed(maxAge: 60)
        if VolumeClassifier.isOnTimeMachineVolume(path: drivePath) {
            return "目标是 Time Machine 备份盘，系统空间紧张时会自动清理其中的旧备份，不能用于存放应用"
        }
        
        // 空间检查：目标盘上要同时落【两份】——目标副本 + 同盘留底备份
        // （needsAuth 分支是两次 ditto；非 auth 分支是 ditto + 跨卷 move，move 同样是整树复制）。
        // 此前按一份体积 + 5% 校验，会在第二步备份时把盘写满、迁移失败。
        let needed = Self.requiredTargetBytes(appSize: appSize)
        let freeBytes = Int64(st.f_bavail) * Int64(st.f_bsize)
        if freeBytes < needed {
            let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            return "目标盘空间不足：\(need) 的应用需要约 \(total)（含同盘留底备份），仅剩 \(free)"
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
    
    /// 回迁预检：内置盘（根卷）剩余空间是否足够
    func validateInternalFreeSpace(needBytes: Int64) -> String? {
        var st = statfs()
        guard "/".withCString({ statfs($0, &st) }) == 0 else {
            return "无法读取内置盘空间信息"
        }
        let free = Int64(st.f_bavail) * Int64(st.f_bsize)
        if free < needBytes + needBytes / 20 {
            let need = ByteCountFormatter.string(fromByteCount: needBytes, countStyle: .file)
            let have = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "内置盘空间不足：回迁需要约 \(need)，仅剩 \(have)。请先清理空间或保持外置盘使用"
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
    /// 文件总数 ≤ 抽样上限时自动全量哈希。抽样失败（如个别文件无读权限）
    /// 不降级整体结果——以字节对比为准，避免误报。
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

    /// 随机抽样哈希对比；返回 false 仅当两侧均成功读出且内容确有差异
    private func sampleHashesMatch(source: String, target: String, totalCount: Int) -> Bool {
        let sampleLimit = 32
        guard totalCount > 0 else { return true }

        guard let files = self.listFiles(under: source), !files.isEmpty else { return true }
        let sample = files.count <= sampleLimit
            ? files
            : Array(files.shuffled().prefix(sampleLimit))

        // 以相对路径为键，分别对源/目标批量哈希
        let srcRoot = source.hasSuffix("/") ? String(source.dropLast()) : source
        let dstRoot = target.hasSuffix("/") ? String(target.dropLast()) : target
        let relSample = sample.map { String($0.dropFirst(srcRoot.count + 1)) }
        let srcArgs = relSample.map { "\(srcRoot)/\($0)" }
        let dstArgs = relSample.map { "\(dstRoot)/\($0)" }

        guard let srcMap = self.shasum(files: srcArgs, relativeTo: srcRoot), !srcMap.isEmpty,
              let dstMap = self.shasum(files: dstArgs, relativeTo: dstRoot), !dstMap.isEmpty else {
            return true    // 读不出（权限等）→ 信任字节对比，不误报
        }

        return relSample.allSatisfy { rel in
            guard let a = srcMap[rel], let b = dstMap[rel] else { return true }
            return a == b
        }
    }

    /// 批量 shasum，返回 相对路径(去根前缀) → 哈希；进程失败返回 nil
    private func shasum(files: [String], relativeTo root: String) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/shasum")
        process.arguments = ["-a", "256"] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // 先读至 EOF 再等待退出（项目铁律：先等后读会在输出写满管道时死锁）
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: data, encoding: .utf8) ?? ""
        var map: [String: String] = [:]
        let prefix = root + "/"
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0])
            let path = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            map[rel] = hash
        }
        return map.isEmpty ? nil : map
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
            // 两层转义：先按 shell 单引号串转义，再按 AppleScript 双引号串转义。
            // 路径要穿过 AppleScript → shell 两层，只做一层会在含引号的路径上拼坏命令
            func escShell(_ s: String) -> String {
                s.replacingOccurrences(of: "'", with: "'\\''")
            }
            func escAppleScript(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }

            let command = createLink
                ? "rm -rf '\(escShell(source))' && ln -s '\(escShell(linkTarget))' '\(escShell(source))'"
                : "rm -rf '\(escShell(source))'"
            let script = "tell application \"随手迁\" to activate\ndelay 0.3\n"
                + "do shell script \"\(escAppleScript(command))\" with administrator privileges"
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            // stdout 直接丢弃：这条命令的 stdout 我们不读，若接成管道又没人读，
            // 一旦写满 64KB 缓冲，进程会永久阻塞在写上（本项目被烧过两次的死锁形态）。
            // 只有 stderr 需要读——读至 EOF 再等待退出，顺序不能颠倒
            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe
            
            do {
                try process.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    return (true, nil)
                } else {
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "未知错误"
                    // 用户取消了密码弹窗
                    if errMsg.contains("User canceled") {
                        return (false, "已取消授权")
                    }
                    return (false, errMsg)
                }
            } catch {
                return (false, error.localizedDescription)
            }
        }
    }
}
