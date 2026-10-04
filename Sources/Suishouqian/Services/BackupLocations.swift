import Foundation

/// 备份存放位置：解决「备份与应用本体同盘」的单点故障。
///
/// 背景：备份一直在 `应用所在盘/.suishouqian-backup`。盘体物理损坏时，
/// 应用和备份一起丢失，回迁/恢复无从谈起。
///
/// - 默认（未指定）：备份跟应用同盘——历史行为，零迁移成本；
/// - 用户在设置页指定一块外置盘后：新备份写到该盘 `/.suishouqian-backup`，
///   应用与备份分盘存放，单盘损坏不再是全灭；
/// - 扫描/清理/体检永远看「全部根目录」（同盘 + 指定盘），切换备份盘后
///   旧备份不会变成扫不到的孤儿；
/// - 指定盘离线时自动回退同盘并记审计日志——备份永不因「盘没插」而失败。
enum BackupLocations {

    private static let key = "backupVolumeUUID.v1"

    /// 用户指定的备份盘 UUID（大写）。nil = 跟应用同盘（默认）。
    static var alternateVolumeUUID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v.uppercased(), forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// 写备份的目标根目录（单个）。
    /// 内含卷枚举（阻塞 IO），调用方须在 OffPool / 后台线程。
    static func backupRoot(for drivePath: String) -> String {
        resolveWriteRoot(drivePath: drivePath, alternateMount: alternateMountPoint())
    }

    /// 扫描/清理/体检要看的全部备份根目录（去重，顺序：写目标优先）。
    /// 内含卷枚举（阻塞 IO），调用方须在 OffPool / 后台线程。
    static func backupRoots(for drivePath: String) -> [String] {
        var roots = [backupRoot(for: drivePath)]
        let own = "\(drivePath)/.suishouqian-backup"
        if !roots.contains(own) { roots.append(own) }
        return roots
    }

    /// 指定备份盘的当前挂载点（离线/不存在即 nil）。纯查询，无副作用。
    /// 内含卷枚举（阻塞 IO），调用方须在 OffPool / 后台线程。
    static func alternateMountPoint() -> String? {
        guard let uuid = alternateVolumeUUID, !uuid.isEmpty else { return nil }
        return DiskMonitor.enumerateVolumes().candidates.first {
            $0.volumeUUID?.uppercased() == uuid
        }?.mountPoint
    }

    // MARK: - 纯逻辑（供测试）

    /// 给定「指定盘挂载点（nil 表离线/未指定）」，算写目标。纯函数，可单元测试。
    static func resolveWriteRoot(drivePath: String, alternateMount: String?) -> String {
        if let alt = alternateMount, !alt.isEmpty, alt != drivePath {
            return "\(alt)/.suishouqian-backup"
        }
        return "\(drivePath)/.suishouqian-backup"
    }
}
