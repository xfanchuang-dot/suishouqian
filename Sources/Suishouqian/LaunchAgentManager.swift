import Foundation

/// 管理 LaunchAgent 守护进程
/// 功能：外置盘插入时自动唤醒/打开随手迁
final class LaunchAgentManager {
    private static let label = "com.suishouqian.disk-watcher"
    private static let plistName = "\(label).plist"
    
    private static var agentsDir: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/LaunchAgents"
    }
    
    private static var plistPath: String {
        "\(agentsDir)/\(plistName)"
    }
    
    private static func plistContent(watchPath: String) -> String {
        // 用运行时实际路径，此前硬编码 /Applications/随手迁.app，
        // 应用不在该位置时守护指向空路径（曾导致插盘唤醒功能实际失效）
        let appPath = Bundle.main.bundlePath
        // 已在运行则不重复唤起；路径进入 shell 单引号串需转义
        let escAppPath = appPath.replacingOccurrences(of: "'", with: "'\\''")
        let shell = "pgrep -f '随手迁.app/Contents/MacOS' >/dev/null 2>&1 || open '\(escAppPath)'"
        // 卷名可能含 & < > 等 XML 特殊字符，未转义会生成非法 plist
        let escapedWatch = xmlEscape(watchPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/sh</string>
                <string>-c</string>
                <string>\(shell)</string>
            </array>
            <key>WatchPaths</key>
            <array>
                <string>\(escapedWatch)</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>ThrottleInterval</key>
            <integer>30</integer>
        </dict>
        </plist>
        """
    }
    
    /// XML 特殊字符转义（卷名含 & < > 时防 plist 非法）
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 是否已安装
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
    
    /// 安装 LaunchAgent（开机自启）
    /// watchPath：只监听该挂载点（盘插上/拔出才触发）；传 "/Volumes" 为旧行为，
    /// 但会导致 Time Machine 每小时备份挂载快照卷等事件误唤醒本应用
    static func install(watchPath: String = "/Volumes") -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: agentsDir,
                withIntermediateDirectories: true
            )

            try plistContent(watchPath: watchPath).write(
                toFile: plistPath,
                atomically: true,
                encoding: .utf8
            )
            
            // 加载到 launchd（bootstrap 为现行 API，失败时回退旧版 load）
            let uid = getuid()
            let bootstrap = Process()
            bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootstrap.arguments = ["bootstrap", "gui/\(uid)", plistPath]
            bootstrap.standardError = FileHandle.nullDevice
            bootstrap.standardOutput = FileHandle.nullDevice
            var ok = false
            if (try? bootstrap.run()) != nil {
                bootstrap.waitUntilExit()
                ok = bootstrap.terminationStatus == 0
            }
            if !ok {
                let legacy = Process()
                legacy.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                legacy.arguments = ["load", plistPath]
                legacy.standardError = FileHandle.nullDevice
                legacy.standardOutput = FileHandle.nullDevice
                if (try? legacy.run()) != nil {
                    legacy.waitUntilExit()
                    ok = legacy.terminationStatus == 0
                }
            }
            return ok
        } catch {
            return false
        }
    }
    
    /// 卸载 LaunchAgent
    static func uninstall() -> Bool {
        let uid = getuid()
        // 先用现行 API bootout，失败回退旧版 unload
        for args in [["bootout", "gui/\(uid)/\(label)"], ["unload", plistPath]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = args
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            if (try? process.run()) != nil {
                process.waitUntilExit()
            }
        }
        
        // 删除 plist
        try? FileManager.default.removeItem(atPath: plistPath)
        return !FileManager.default.fileExists(atPath: plistPath)
    }
}
