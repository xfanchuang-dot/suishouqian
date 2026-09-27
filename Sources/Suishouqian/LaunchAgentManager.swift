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
    
    /// 生成守护 plist（internal 供测试验证转义：卷名含 & < > " 时必须仍是合法 plist）
    static func plistContent(watchPath: String) -> String {
        // 用运行时实际路径，此前硬编码 /Applications/随手迁.app，
        // 应用不在该位置时守护指向空路径（曾导致插盘唤醒功能实际失效）
        let appPath = Bundle.main.bundlePath
        // 挂载边沿检测：WatchPaths 对卷目录的任何文件变动都会触发（不只插盘），
        // 用状态文件区分"未挂载→挂载"的边沿，只有该瞬间才唤起，杜绝反复弹窗。
        //
        // 两个路径都从 argv 传入（$1/$2），不拼进脚本文本：这样整份脚本只需做一次
        // XML 转义即可，卷名里的引号、$、反引号也无法破坏脚本（此前只转义了
        // WatchPaths 那处，脚本内嵌的同一路径没转义，卷名含 & 时会生成非法 plist）
        let shell = """
        V="$1"; A="$2"; S="$HOME/.suishouqian-watch-state$(printf '%s' "$V" | tr -c 'A-Za-z0-9' '_')"; \
        if [ -d "$V" ]; then \
          if [ ! -f "$S" ]; then echo ok > "$S"; \
            pgrep -f '随手迁.app/Contents/MacOS' >/dev/null 2>&1 || open "$A"; fi; \
        else rm -f "$S"; fi
        """
        // WatchPaths 监视**父目录**（/Volumes），而不是卷自己的挂载点：
        // 盘拔掉后那个目录本身会消失，"监视一个不存在的路径"在卷重新挂载时
        // 是否还能触发，launchd 并没有文档保证；监视始终存在的父目录最稳。
        // 具体是哪块盘的边沿判定交给脚本里的 `[ -d "$V" ]` + 按卷区分的状态文件。
        //
        // 状态文件名按卷区分（此前是一个全局文件）：换监听盘后，旧盘留下的状态文件
        // 会让新盘的"未挂载→挂载"边沿永不成立，插盘自动打开静默失效。
        let watchRoot = watchPath.hasPrefix("/Volumes/") ? "/Volumes" : watchPath
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
                <string>\(xmlEscape(shell))</string>
                <string>suishouqian-watch</string>
                <string>\(xmlEscape(watchPath))</string>
                <string>\(xmlEscape(appPath))</string>
            </array>
            <key>WatchPaths</key>
            <array>
                <string>\(xmlEscape(watchRoot))</string>
            </array>
            <key>RunAtLoad</key>
            <false/>
            <key>ThrottleInterval</key>
            <integer>30</integer>
        </dict>
        </plist>
        """
    }
    
    /// XML 特殊字符转义（卷名含 & < > " 时防 plist 非法）
    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 是否已安装（磁盘上有没有 plist。launchd 侧的在册状态用 isLoaded 判断）
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 该 label 是否已在 launchd 在册
    static var isLoaded: Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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
        } catch {
            return false
        }

        let uid = getuid()
        // 先 bootout 同 label 的在册任务：否则 bootstrap / load 会以
        // "service already loaded" 失败，而 launchd 里跑着的仍是**旧的** WatchPaths
        // ——换监听盘后界面看起来装好了，实际还在盯旧盘。
        if isLoaded {
            _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        }

        // bootstrap 为现行 API，失败时回退旧版 load；两者都不行再问一次 launchd 的真实状态
        var ok = runLaunchctl(["bootstrap", "gui/\(uid)", plistPath])
        if !ok { ok = runLaunchctl(["load", plistPath]) }
        if !ok { ok = isLoaded }

        if !ok {
            // 失败必须回滚磁盘上的 plist：否则 isInstalled 只看文件存在，
            // 下次打开设置页会显示"已开启"，而 launchd 里根本没有这个任务。
            try? FileManager.default.removeItem(atPath: plistPath)
            AuditLog.append("安装插盘守护失败：launchctl 未能载入 \(label)（已回滚 plist）")
        }
        return ok
    }
    
    /// 卸载 LaunchAgent。**如实返回**：launchd 里还挂着就返回 false，
    /// 不再用"plist 文件删掉了"冒充成功——那会让用户以为插盘唤醒已关闭，
    /// 实际任务仍在，插盘照旧打开应用。
    static func uninstall() -> Bool {
        let uid = getuid()
        if isLoaded {
            // 现行 API bootout 失败才回退旧版 unload（此前是两个无脑依次执行、退出码全丢）
            if !runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
                && !runLaunchctl(["unload", plistPath]) {
                AuditLog.append("卸载插盘守护失败：launchctl 未能卸下 \(label)")
                return false
            }
        }

        // 删除 plist
        try? FileManager.default.removeItem(atPath: plistPath)
        return !FileManager.default.fileExists(atPath: plistPath)
    }
}
