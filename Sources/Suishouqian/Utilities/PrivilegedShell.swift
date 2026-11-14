import Foundation

/// 管理员授权的 shell 调用。
///
/// 路径只作为 `osascript` 的 argv 传入，AppleScript 源里用 `quoted form of`
/// 再交给 shell。路径里的引号、反斜杠、换行不会出现在脚本文本里，也就不能
/// 把 `do shell script "..."` 的引号提前闭合。
enum PrivilegedShell {

    struct Invocation: Equatable {
        var script: String
        var paths: [String]
    }

    enum Command: Equatable {
        case remove(source: String, linkTarget: String, createLink: Bool)
        case rewriteLink(link: String, target: String)
        case trash(source: String, trashDir: String)
        case spotlight(enabled: Bool, mount: String)
        case addExclusions([String])
    }

    static func invocation(for command: Command) -> Invocation {
        switch command {
        case .remove(let source, let linkTarget, true):
            return Invocation(
                script: wrap("""
                set src to quoted form of (item 1 of argv)
                set dst to quoted form of (item 2 of argv)
                do shell script "rm -rf " & src & " && ln -s " & dst & " " & src with administrator privileges
                """),
                paths: [source, linkTarget])
        case .remove(let source, _, false):
            return Invocation(
                script: wrap("""
                set src to quoted form of (item 1 of argv)
                do shell script "rm -rf " & src with administrator privileges
                """),
                paths: [source])
        case .rewriteLink(let link, let target):
            return Invocation(
                script: wrap("""
                set dst to quoted form of (item 1 of argv)
                set linkPath to quoted form of (item 2 of argv)
                do shell script "ln -sfn " & dst & " " & linkPath with administrator privileges
                """),
                paths: [target, link])
        case .trash(let source, let trashDir):
            return Invocation(
                script: wrap("""
                set src to quoted form of (item 1 of argv)
                set dir to quoted form of (item 2 of argv)
                do shell script "T=" & dir & "; S=" & src & "; N=$(basename \\"$S\\"); D=\\"$T/$N\\"; i=2; while [ -e \\"$D\\" ]; do D=\\"$T/$N $i\\"; i=$((i+1)); done; mv \\"$S\\" \\"$D\\"" with administrator privileges
                """),
                paths: [source, trashDir])
        case .spotlight(let enabled, let mount):
            let flag = enabled ? "on" : "off"
            return Invocation(
                script: wrap("""
                set flag to item 1 of argv
                if flag is not "on" and flag is not "off" then error "bad flag"
                set mount to quoted form of (item 2 of argv)
                do shell script "mdutil -i " & flag & " " & mount with administrator privileges
                """),
                paths: [flag, mount])
        case .addExclusions(let paths):
            return Invocation(
                script: wrap("""
                set cmd to ""
                repeat with p in argv
                    set piece to "tmutil addexclusion " & quoted form of (contents of p)
                    if cmd is "" then
                        set cmd to piece
                    else
                        set cmd to cmd & " && " & piece
                    end if
                end repeat
                do shell script cmd with administrator privileges
                """),
                paths: paths)
        }
    }

    static func arguments(for invocation: Invocation) -> [String] {
        ["-e", invocation.script, "--"] + invocation.paths
    }

    /// 脚本源是否把某个路径原文拼进去了。非空路径才检查。
    static func scriptEmbeds(paths: [String], script: String) -> Bool {
        paths.contains { path in
            !path.isEmpty && script.contains(path)
        }
    }

    static func run(_ command: Command) -> (success: Bool, error: String?) {
        let invocation = invocation(for: command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments(for: invocation)
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

    private static func wrap(_ body: String) -> String {
        """
        tell application "随手迁" to activate
        delay 0.3
        on run argv
        \(body)
        end run
        """
    }
}
