import Foundation

/// 盘间迁移（relocate）的目标盘选择逻辑（v3.1）。
/// 纯函数，与 UI 解耦，可单测。
enum RelocateTargets {

    /// 应用当前所在的卷挂载点。
    /// - 已迁移应用：链接目标所在的卷
    /// - 纯搬迁应用：本体所在的卷
    /// 取最长前缀匹配，避免 "/Volumes/A" 误吞 "/Volumes/AB"。
    static func currentMount(for app: AppItem, volumes: [ManagedVolume]) -> String? {
        let path = ((app.symlinkTarget ?? app.path) as NSString).standardizingPath
        return volumes
            .map { ($0.info.mountPoint as NSString).standardizingPath }
            .filter { mount in path == mount || path.hasPrefix(mount + "/") }
            .max(by: { $0.count < $1.count })
    }

    /// 候选目标盘：在线的外置卷，且排除应用当前所在的卷。
    /// 内置盘不在 VolumeStore 里；防御性要求挂载点以 /Volumes/ 开头。
    static func candidates(currentMount: String?, volumes: [ManagedVolume]) -> [ManagedVolume] {
        let current = (currentMount as NSString?)?.standardizingPath
        return volumes.filter { vol in
            guard vol.isOnline else { return false }
            let mount = (vol.info.mountPoint as NSString).standardizingPath
            guard mount.hasPrefix("/Volumes/") else { return false }
            if let current, mount == current { return false }
            return true
        }
    }
}
