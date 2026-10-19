import Foundation

/// 更新助手会话：记录一次"移回内置盘 → 用户更新 → 搬回外置盘"流程的状态。
///
/// 流程：
/// 1. 用户在已搬走的 App 上点「更新」→ App 被搬回 /Applications，
///    创建 session（state = .movedBack），进入"待更新"状态。
/// 2. 用户在 /Applications 里更新 App（自带更新器 / 官网 DMG）。
/// 3. 用户点「搬回去」→ App 被搬回原外置位置，session 删除，流程结束。
///
/// 持久化到 UserDefaults `updateSessions.v1`（沿用 volumeLastSeen.v1 等
/// 既有 key 的命名习惯）。App 启动时检查未完成的 session，横幅提示继续。
struct UpdateSession: Codable, Identifiable {
    let id: UUID
    /// CFBundleIdentifier（更新/改名/搬家中稳定），用于跨扫描匹配
    let bundleID: String?
    let appName: String
    /// 移回后的位置（/Applications/xxx.app）
    let appPath: String
    /// 外置盘上的原位置（搬回去的目标）
    let originalExternalPath: String
    /// true = 之前是留链接的迁移（搬回去时恢复软链接）；
    /// false = 之前是纯搬迁（搬回去时不留链接）
    let wasMigrated: Bool
    let startedAt: Date

    init(bundleID: String?, appName: String, appPath: String,
         originalExternalPath: String, wasMigrated: Bool) {
        self.id = UUID()
        self.bundleID = bundleID
        self.appName = appName
        self.appPath = appPath
        self.originalExternalPath = originalExternalPath
        self.wasMigrated = wasMigrated
        self.startedAt = Date()
    }

    /// 从原外置路径提取"搬回去"的目标子目录（相对卷根）：
    /// "/Volumes/X/Applications/A.app" → "Applications"；
    /// "…/Suishouqian_Apps/A.app" → "Suishouqian_Apps"；
    /// 卷根直放 → nil（migrate 的 targetSubdir 传 nil 时默认 Applications/，
    /// 但卷根直放的场景其实不该回落 Applications——调用方按 nil 处理为原位直放）。
    /// 原路径不属于该卷（盘换过挂载名等）→ nil，回落默认目录并如实告警由调用方负责。
    static func targetSubdir(of externalPath: String, volumeMount: String) -> String? {
        let path = (externalPath as NSString).standardizingPath
        let mount = (volumeMount as NSString).standardizingPath
        guard path.hasPrefix(mount + "/") else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        let relative = dir.dropFirst(mount.count + 1)
        return relative.isEmpty ? nil : String(relative)
    }
}

/// UpdateSession 的持久化（UserDefaults `updateSessions.v1`）。
/// 纯函数式读写，AppState 持有内存副本并负责 UI 刷新。
enum UpdateSessionStore {
    private static let key = "updateSessions.v1"

    /// 测试缝：注入独立 UserDefaults suite，避免污染真实应用数据
    nonisolated(unsafe) static var defaultsOverride: UserDefaults?

    private static var defaults: UserDefaults { defaultsOverride ?? .standard }

    static func load() -> [UpdateSession] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([UpdateSession].self, from: data)) ?? []
    }

    static func save(_ sessions: [UpdateSession]) {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: key)
        }
    }
}
