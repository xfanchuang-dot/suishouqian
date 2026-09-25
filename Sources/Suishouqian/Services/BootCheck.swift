import Foundation

/// 开机自启指向外置盘的问题项（v2.10.0 链路体感三期）。
///
/// 外置盘上的东西被配置成开机自启，是一个"盘没插就出乱子"的固定来源：
/// LaunchDaemon 在开机阶段运行——那时外置盘几乎必然还没挂载；LaunchAgent 在
/// 用户登录时运行——跟盘的上电赛跑，慢一步就失败，还可能弹错误框。
/// 本检测只陈列与指路（Finder 定位 + 登录项设置），不代用户删改别人的
/// launchd 配置——那些 plist 属于别的应用，动它们超出本工具的契约。
struct LaunchAgentIssue: Identifiable {
    /// plist 完整路径，稳定唯一
    let id: String
    /// launchd 标签（plist 文件名去后缀）
    let label: String
    let plistPath: String
    let kind: Kind
    /// 配置里引用的全部 /Volumes 路径
    /// （Program / ProgramArguments / WatchPaths / QueueDirectories）
    let references: [String]
    /// 引用的卷当前是否全部在线
    let volumesOnline: Bool

    enum Kind: String {
        case userAgent    // ~/Library/LaunchAgents：登录时运行
        case globalAgent  // /Library/LaunchAgents：所有用户登录时运行
        case daemon       // /Library/LaunchDaemons：开机即运行（早于任何盘挂载）

        var label: String {
            switch self {
            case .userAgent:   return "用户自启项"
            case .globalAgent: return "全体用户自启项"
            case .daemon:      return "系统守护项"
            }
        }
    }

    /// 一句话诊断。守护项的问题最重：它在挂载外置盘之前就要跑。
    var verdict: (text: String, severe: Bool) {
        if volumesOnline {
            return ("盘在线 · 开机时若盘未就绪会启动失败", false)
        }
        switch kind {
        case .daemon:
            return ("盘未连接 · 开机阶段盘还没挂载，必然启动失败", true)
        default:
            return ("盘未连接 · 登录时启动失败并可能弹错误框", true)
        }
    }
}

/// 开机自启扫描（纯逻辑为主，可注入卷在线状态做测试）
enum BootAgentScanner {

    /// 扫描给定的 launchd plist 目录，返回引用了 /Volumes 的条目。
    /// 读不到/解析不了的 plist 直接跳过——体检绝不能因为一个坏文件中断。
    static func scan(roots: [(path: String, kind: LaunchAgentIssue.Kind)],
                     mountedVolumes: Set<String>) -> [LaunchAgentIssue] {
        var out: [LaunchAgentIssue] = []
        for root in roots {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasSuffix(".plist") {
                let plistPath = "\(root.path)/\(name)"
                guard let data = FileManager.default.contents(atPath: plistPath) else { continue }
                let refs = volumeReferences(plistData: data)
                guard !refs.isEmpty else { continue }
                out.append(LaunchAgentIssue(
                    id: plistPath,
                    label: (name as NSString).deletingPathExtension,
                    plistPath: plistPath,
                    kind: root.kind,
                    references: refs,
                    volumesOnline: volumesOnline(for: refs, mountedVolumes: mountedVolumes)))
            }
        }
        return out.sorted { $0.label < $1.label }
    }

    /// 默认扫描范围：用户级 + 全局 LaunchAgents + LaunchDaemons。
    /// /System/Library 下的全是苹果自己的，不碰。
    static var defaultRoots: [(path: String, kind: LaunchAgentIssue.Kind)] {
        [
            (NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
    }

    /// 从 plist 数据抽取指向 /Volumes 的路径（解析失败返回空）
    static func volumeReferences(plistData: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil),
            let dict = plist as? [String: Any]
        else { return [] }
        return volumeReferences(dict: dict)
    }

    static func volumeReferences(dict: [String: Any]) -> [String] {
        var candidates: [String] = []
        // 单值键与数组键都收，遇到什么收什么，类型不符就跳过
        if let p = dict["Program"] as? String { candidates.append(p) }
        for key in ["ProgramArguments", "WatchPaths", "QueueDirectories"] {
            if let arr = dict[key] as? [String] { candidates.append(contentsOf: arr) }
        }
        return candidates.filter { $0.hasPrefix("/Volumes/") }
    }

    /// 引用里的每个 /Volumes/<卷名> 是否都已挂载。
    /// 卷名取路径首段——判断在线不 stat 文件（离线卷 stat 只会得到"不存在"，
    /// 与"路径写错"无法区分），直接对照挂载名单。
    static func volumesOnline(for references: [String], mountedVolumes: Set<String>) -> Bool {
        references.allSatisfy { mountedVolumes.contains(volumeName(ofPath: $0)) }
    }

    /// "/Volumes/MyDisk/a/b" → "MyDisk"。非 /Volumes 路径一律返回 ""
    /// ——调用方只喂 /Volumes 引用，但守卫放在函数里，误用不会静默给出假卷名
    static func volumeName(ofPath path: String) -> String {
        guard path.hasPrefix("/Volumes/") else { return "" }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return "" }
        return parts[1]
    }
}
