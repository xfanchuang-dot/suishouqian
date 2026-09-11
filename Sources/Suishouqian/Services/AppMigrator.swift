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

    func migrate(app: AppItem, to drivePath: String,
                 progress: @escaping @Sendable (Double, String) -> Void) async -> MigrationResult {

        let appName = app.bundleName
        let sourcePath = app.path
        let targetDir = "\(drivePath)/Applications"
        let targetPath = "\(targetDir)/\(appName)"
        let backupPath = "\(drivePath)/.suishouqian-backup/\(appName)"

        // 稳定性：应用正在运行时移动/替换会导致半完成状态，直接拒绝
        if let runningName = Self.runningAppName(matching: sourcePath) {
            AuditLog.append("拒绝迁移 \(appName)：应用正在运行")
            return MigrationResult(success: false,
                  error: "「\(runningName)」正在运行，请先退出后再迁移", spaceSaved: 0)
        }

        // P0: 目标必须是真实挂载的独立卷。历史上发生过目标卷未挂载时
        // createDirectory 把数据全写进内置盘 /Volumes 的事故，此处硬性拦截
        if let reason = validateTarget(drivePath: drivePath, appSize: app.size) {
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
        
        progress(0.1, "正在复制 \(app.name)...")
        let copyOk = await copyWithDitto(from: sourcePath, to: targetPath) { pct in
            progress(0.1 + pct * 0.6, "复制 \(app.name)...")
        }
        guard copyOk else {
            return MigrationResult(success: false, 
                  error: "复制失败", spaceSaved: 0)
        }
        
        progress(0.7, "正在校验完整性...")
        let verified = await verifyFiles(source: sourcePath, target: targetPath)
        guard verified else {
            AuditLog.append("迁移失败 \(appName)：校验未通过，已回滚目标副本")
            try? fileManager.removeItem(atPath: targetPath)
            return MigrationResult(success: false,
                  error: "文件校验失败，请重试", spaceSaved: 0)
        }
        
        // 校验通过后才修复属性（必须在校验之后，因为 codesign 会修改二进制导致 diff 不一致）
        progress(0.8, "修复文件属性...")
        fixAttributes(at: targetPath)
        
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
                return MigrationResult(success: false, 
                      error: "备份失败", spaceSaved: 0)
            }
            
            // 删原件 + 建符号链接（需要 admin，但只操作 /Applications 不写外置盘）
            progress(0.9, "需要管理员权限...")
            let authResult = await authenticatedRemoveAndSymlink(
                source: sourcePath, target: targetPath)
            guard authResult.success else {
                try? fileManager.removeItem(atPath: targetPath)
                // 回滚原件：恢复成功才删备份；恢复失败必须保留备份兜底，
                // 否则「原件已不在 + 备份被删」就是真丢数据
                let restored = await copyWithDitto(from: backupPath, to: sourcePath) { _ in }
                if restored {
                    try? fileManager.removeItem(atPath: backupPath)
                } else {
                    AuditLog.append("迁移失败 \(appName)：授权回滚未完成，原件备份保留于 \(backupPath)")
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
                return MigrationResult(success: false, 
                      error: "无法移动原文件（可能正在运行或权限不足）", spaceSaved: 0)
            }
            do {
                try fileManager.createSymbolicLink(atPath: sourcePath, 
                                                   withDestinationPath: targetPath)
            } catch {
                _ = await moveItem(from: backupPath, to: sourcePath)
                try? fileManager.removeItem(atPath: targetPath)
                return MigrationResult(success: false, 
                      error: "创建符号链接失败: \(error.localizedDescription)", spaceSaved: 0)
            }
        }
        
        progress(1.0, "完成")
        AuditLog.append("迁移成功 \(appName)：\(app.size) 字节 → \(targetPath)")

        // v2.2: 记录卷 UUID 台账——卷改名后按 UUID 找卷自动重写链接（自愈）
        if targetPath.hasPrefix(drivePath + "/") {
            if let uuid = MigrationManifest.volumeUUID(atPath: drivePath) {
                MigrationManifest.shared.record(
                    appName: appName, linkPath: sourcePath, volumeUUID: uuid,
                    relativePath: String(targetPath.dropFirst(drivePath.count + 1)))
            }
        }
        return MigrationResult(success: true, error: nil, spaceSaved: app.size)
    }
    
    func restore(app: AppItem, from drivePath: String,
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

        progress(0.1, "删除符号链接...")
        try? fileManager.removeItem(atPath: sourcePath)
        
        progress(0.2, "正在回迁 \(app.name)...")
        let copyOk = await copyWithDitto(from: externalPath, to: sourcePath) { pct in
            progress(0.2 + pct * 0.7, "回迁 \(app.name)...")
        }
        guard copyOk else {
            try? fileManager.createSymbolicLink(atPath: sourcePath, withDestinationPath: externalPath)
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
    func moveBackToInternal(app: AppItem, drivePath: String,
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
        MigrationManifest.shared.remove(appName: app.bundleName)
        AuditLog.append("搬回内置盘成功 \(app.bundleName)：\(app.size) 字节 ← \(sourcePath)")
        progress(1.0, "完成")
        return MigrationResult(success: true, error: nil, spaceSaved: -app.size)
    }

    func uninstall(app: AppItem, drivePath: String? = nil) -> MigrationResult {
        AuditLog.append("卸载 \(app.bundleName)（链接+\(app.symlinkTarget ?? "无外置副本")）")
        try? fileManager.removeItem(atPath: app.path)
        MigrationManifest.shared.remove(appName: app.bundleName)
        
        if let target = app.symlinkTarget {
            try? fileManager.removeItem(atPath: target)
        }
        
        // P0: 顺带清掉对应备份，否则卸载后备份成为孤儿（如 4 个月前的豆包备份）
        if let drivePath {
            try? fileManager.removeItem(atPath: "\(drivePath)/.suishouqian-backup/\(app.bundleName)")
        }
        
        return MigrationResult(success: true, error: nil, spaceSaved: app.size)
    }
    
    func cleanOldBackups(at drivePath: String) {
        let backupDir = "\(drivePath)/.suishouqian-backup"
        guard let contents = try? fileManager.contentsOfDirectory(atPath: backupDir) else { return }
        
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        
        for item in contents {
            let fullPath = "\(backupDir)/\(item)"
            guard let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate < cutoff else { continue }
            try? fileManager.removeItem(atPath: fullPath)
            if !fileManager.fileExists(atPath: fullPath) {
                AuditLog.append("清理过期备份：\(item)（超过 \(retentionDays) 天）")
            }
        }
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
        
        // 空间检查：需要 app 大小 + 5% 余量
        let freeBytes = Int64(st.f_bavail) * Int64(st.f_bsize)
        if freeBytes < appSize + appSize / 20 {
            let need = ByteCountFormatter.string(fromByteCount: appSize, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            return "目标盘空间不足：需要约 \(need)，仅剩 \(free)"
        }
        
        return nil
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
                guard process.terminationStatus == 0 else { return false }

                progress(1.0)
                return true
            } catch {
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
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        return Int64(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// 清除 macl/quarantine 隔离属性；仅当签名校验不过时才 ad-hoc 重签。
    /// 此前无条件 codesign --force --deep（--deep 已被 Apple 废弃），
    /// 可能弄坏带特权 Helper/XPC 的复杂应用
    private func fixAttributes(at path: String) {
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

        let resign = Process()
        resign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        resign.arguments = ["--force", "--sign", "-", path]
        resign.standardOutput = FileHandle.nullDevice
        resign.standardError = FileHandle.nullDevice
        if (try? resign.run()) != nil {
            resign.waitUntilExit()
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
    private func shasum(files: [String], relativeTo root: String) -> [String: String]? {        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/shasum")
        process.arguments = ["-a", "256"] + files
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
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
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
        return await Task.detached {
            try? FileManager.default.removeItem(atPath: dst)
            do {
                try FileManager.default.moveItem(atPath: src, toPath: dst)
                return true
            } catch {
                return false
            }
        }.value
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
        return await Task.detached {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attrs[.ownerAccountName] as? String else { return false }
            return owner == "root"
        }.value
    }
    
    /// 用 osascript 提权删除源文件并创建符号链接（不操作外置盘）
    private func authenticatedRemoveAndSymlink(source: String,
                                               target: String) async -> (success: Bool, error: String?) {
        return await Task.detached {
            // 稳定性：路径进入 shell 单引号串必须转义单引号，否则命令拼坏
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "'", with: "'\\''")
            }
            let script = """
            tell application "随手迁" to activate
            delay 0.3
            do shell script "rm -rf '\(esc(source))' && ln -s '\(esc(target))' '\(esc(source))'" \
            with administrator privileges
            """
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus == 0 {
                    return (true, nil)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
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
        }.value
    }
}
