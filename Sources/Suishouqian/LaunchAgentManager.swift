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
    
    private static var plistContent: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>/Applications/随手迁.app</string>
            </array>
            <key>WatchPaths</key>
            <array>
                <string>/Volumes</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>ThrottleInterval</key>
            <integer>10</integer>
        </dict>
        </plist>
        """
    }
    
    /// 是否已安装
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }
    
    /// 安装 LaunchAgent（开机自启）
    static func install() -> Bool {
        do {
            try FileManager.default.createDirectory(
                atPath: agentsDir,
                withIntermediateDirectories: true
            )
            
            try plistContent.write(
                toFile: plistPath,
                atomically: true,
                encoding: .utf8
            )
            
            // 加载到 launchd
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath]
            try process.run()
            process.waitUntilExit()
            
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// 卸载 LaunchAgent
    static func uninstall() -> Bool {
        // 先从 launchd 卸载
        let unloadProcess = Process()
        unloadProcess.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        unloadProcess.arguments = ["unload", plistPath]
        try? unloadProcess.run()
        unloadProcess.waitUntilExit()
        
        // 删除 plist
        try? FileManager.default.removeItem(atPath: plistPath)
        return !FileManager.default.fileExists(atPath: plistPath)
    }
}
