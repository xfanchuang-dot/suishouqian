import Foundation
import AppKit

struct Permissions {
    
    /// 检查是否有写入权限
    static func canWrite(_ path: String) -> Bool {
        return FileManager.default.isWritableFile(atPath: path)
    }
    
    /// 检查文件所有者
    static func isOwnedByRoot(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attrs[.ownerAccountName] as? String else {
            return false
        }
        return owner == "root"
    }
    
    /// 需要管理员权限才能操作
    static func needsAdmin(for path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return !canWrite(parent) || (FileManager.default.fileExists(atPath: path) && !canWrite(path))
    }
    
    /// 通过系统弹窗获取管理员权限执行命令
    /// macOS 会弹出 Touch ID / 密码验证对话框
    static func executeWithAdmin(command: String, reason: String = "随手迁需要权限来完成操作") async -> Bool {
        return await Task.detached {
            let script = """
            tell application "随手迁" to activate
            delay 0.3
            do shell script "\(command)" with administrator privileges
            """
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
    
    /// 安全删除（自动判断是否需要管理员权限）
    static func safeRemove(_ path: String) async -> Bool {
        // 1. 先用普通权限尝试
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            // 2. 失败则用管理员权限
            return await executeWithAdmin(command: "rm -rf '\(path)'")
        }
    }
    
    /// 安全移动（自动判断是否需要管理员权限）
    static func safeMove(from src: String, to dst: String) async -> Bool {
        do {
            try FileManager.default.moveItem(atPath: src, toPath: dst)
            return true
        } catch {
            return await executeWithAdmin(command: "mv '\(src)' '\(dst)'")
        }
    }
}
