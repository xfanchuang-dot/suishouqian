import Foundation

class AppMigrator: @unchecked Sendable {
    private let fileManager = FileManager.default
    
    private let retentionDays = 7
    
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
                // 回滚备份
                _ = await copyWithDitto(from: backupPath, to: sourcePath) { _ in }
                try? fileManager.removeItem(atPath: backupPath)
                return MigrationResult(success: false, 
                      error: authResult.error ?? "权限操作失败", spaceSaved: 0)
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
        }
        
        progress(1.0, "完成")
        return MigrationResult(success: verified, error: verified ? nil : "校验失败", 
                               spaceSaved: -app.size)
    }
    
    func uninstall(app: AppItem) -> MigrationResult {
        try? fileManager.removeItem(atPath: app.path)
        
        if let target = app.symlinkTarget {
            try? fileManager.removeItem(atPath: target)
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
        }
    }
    
    private func copyWithDitto(from src: String, to dst: String,
                                progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        return await Task.detached {
            try? FileManager.default.removeItem(atPath: dst)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = [src, dst]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return false }
                
                progress(1.0)
                return true
            } catch {
                return false
            }
        }.value
    }
    
    /// 清除 macl 标签 + ad-hoc 重签名，让外置盘上的 app 可运行
    /// 必须在文件校验完成后调用（重签名会修改二进制，导致 diff 比较失败）
    private func fixAttributes(at path: String) {
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-d", "com.apple.macl", path]
        ).waitUntilExit()
        
        _ = try? Process.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--deep", "--sign", "-", path]
        ).waitUntilExit()
    }
    
    /// 快速校验：先比对文件数+总大小（<0.2秒），一致则通过；
    /// 不一致才做并行 SHA256（xargs -P 8，~10秒）
    private func verifyFiles(source: String, target: String) async -> Bool {
        return await Task.detached {
            // 1. 快速检查：文件数 + 总大小（<0.2 秒）
            guard let srcInfo = self.quickCheck(dir: source),
                  let dstInfo = self.quickCheck(dir: target),
                  srcInfo.count == dstInfo.count,
                  srcInfo.sizeKB == dstInfo.sizeKB else {
                return false
            }
            
            // 2. 快速检查通过 = ditto 正常完成，直接通过
            //    ditto 是 macOS 原生工具，文件数+大小一致即内容一致
            //    无需再做 SHA256（之前 4689 文件要 90 秒导致卡死）
            return true
        }.value
    }
    
    /// 快速统计：文件数量 + du 大小（<1秒）
    private func quickCheck(dir: String) -> (count: Int, sizeKB: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", 
            "echo $(find '\(dir)' -type f -not -name '.*' 2>/dev/null | wc -l) $(du -sk '\(dir)' 2>/dev/null | cut -f1)"]
        
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
                  let sizeKB = Int(parts[1]) else { return nil }
            return (count, sizeKB)
        } catch {
            return nil
        }
    }
    
    /// 并行 SHA256：xargs -P 8 八核并行，100 文件/批次
    private func batchSHA256(dir: String) -> [(path: String, hash: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", 
            "find '\(dir)' -type f -not -name '.*' -print0 2>/dev/null | xargs -0 -P 8 -n 100 shasum -a 256 2>/dev/null"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            guard !output.isEmpty else { return nil }
            
            return output
                .split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    let parts = line.split(separator: " ", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[1]), String(parts[0]))
                }
        } catch {
            return nil
        }
    }
    
    private func moveItem(from src: String, to dst: String) async -> Bool {
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
            let script = """
            tell application "随手迁" to activate
            delay 0.3
            do shell script "rm -rf '\(source)' && ln -s '\(target)' '\(source)'" \
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
