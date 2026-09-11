import Foundation
import AppKit

class DiskMonitor: @unchecked Sendable {
    var builtinDrive: DriveInfo?
    var externalDrive: DriveInfo?
    
    var onMountChange: ((DriveInfo?) -> Void)?
    var onUnmount: ((String) -> Void)?
    
    /// 用户选定的外置盘卷 UUID（持久化）。多个外置盘并列时优先认它，
    /// 避免目标盘在"取容量最大"的平局里随枚举顺序漂移
    private static let selectedUUIDKey = "selectedExternalVolumeUUID"
    /// 同一块盘物理拔出会产生多条卸载通知（多分区/重复投递），5 秒内只提示一次
    private var lastUnmountNoticeAt: Date?
    
    init() {
        refresh()
        setupNotifications()
    }
    
    private func setupNotifications() {
        let ws = NSWorkspace.shared
        
        // 挂载事件：真正的边沿，可按变化通知
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh(notifyChanges: true)
        }
        
        // 卸载事件：只对「我们正在用的那块盘」作反应。
        // 此前不看卷归属，同一物理盘上的 Time Machine 备份卷每次卸载都会
        // 误报"外置硬盘已拔出"（本机实测两块卷同在 disk7 上）
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let devicePath = (notification.userInfo?["NSDevicePath"] as? String) ?? ""
            if let tracked = self.externalDrive?.mountPoint, devicePath == tracked {
                self.notifyUnmountOnce(devicePath: devicePath)
            }
            self.refresh(notifyChanges: true)
        }
    }
    
    private func notifyUnmountOnce(devicePath: String) {
        if let last = lastUnmountNoticeAt, Date().timeIntervalSince(last) < 5 { return }
        lastUnmountNoticeAt = Date()
        onUnmount?((devicePath as NSString).lastPathComponent)
    }
    
    /// 重新枚举磁盘。
    ///
    /// `notifyChanges` 是语义开关：**只有真实发生的挂载边沿才回调**。
    /// 定时器与常规刷新必须传 false——此前 refresh() 无条件回调 onMountChange，
    /// 导致每 10 分钟的定时刷新都误报一次"外置硬盘已连接"，并连带全量重扫与大文件自愈；
    /// Time Machine 备份卷每次挂载/卸载也会各触发一轮。
    func refresh(notifyChanges: Bool = false) {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                             .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                                             .volumeIsInternalKey, .volumeUUIDStringKey],
            options: .skipHiddenVolumes
        ) else { return }
        
        var candidates: [DriveInfo] = []
        var builtin: DriveInfo?
        
        for url in urls {
            guard let resources = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                .volumeIsInternalKey, .volumeUUIDStringKey
            ]) else { continue }
            
            guard let name = resources.volumeName,
                  let total = resources.volumeTotalCapacity,
                  let free = resources.volumeAvailableCapacity else { continue }
            
            let isExternal = resources.volumeIsRemovable == true ||
                             resources.volumeIsInternal == false
            
            let drive = DriveInfo(
                name: name,
                mountPoint: url.path,
                totalSize: Int64(total),
                freeSize: Int64(free),
                isExternal: isExternal,
                volumeUUID: resources.volumeUUIDString.map { String(describing: $0).uppercased() }
            )
            
            if isExternal {
                // Time Machine 备份盘绝不作为迁移目标：系统清理旧备份时会销毁放上去的应用
                if VolumeClassifier.isOnTimeMachineVolume(path: url.path) { continue }
                candidates.append(drive)
            } else if !name.hasPrefix("com.apple") && name != "Recovery" {
                builtin = drive
            }
        }
        
        var footprintScores: [String: Int] = [:]
        for candidate in candidates {
            footprintScores[candidate.mountPoint] =
                VolumeClassifier.footprintScore(volumeRoot: candidate.mountPoint)
        }
        
        let persistedUUID = UserDefaults.standard.string(forKey: Self.selectedUUIDKey)
        let previousMountPoint = externalDrive?.mountPoint
        let picked = Self.pickExternalDrive(candidates: candidates,
                                            persistedUUID: persistedUUID,
                                            footprintScores: footprintScores)
        
        builtinDrive = builtin
        externalDrive = picked
        
        if let picked, picked.volumeUUID != persistedUUID {
            UserDefaults.standard.set(picked.volumeUUID, forKey: Self.selectedUUIDKey)
            if let previousMountPoint, previousMountPoint != picked.mountPoint {
                AuditLog.append("迁移目标盘切换：\(previousMountPoint) → \(picked.mountPoint)")
            }
        }
        
        if notifyChanges, previousMountPoint != picked?.mountPoint {
            onMountChange?(picked)
        }
    }
    
    /// 选目标盘（纯逻辑，供测试）：用户上次选定的盘 > 带随手迁足迹的盘 > 容量最大。
    /// 调用方已把 Time Machine 备份盘从 candidates 里剔除。
    static func pickExternalDrive(candidates: [DriveInfo],
                                  persistedUUID: String?,
                                  footprintScores: [String: Int]) -> DriveInfo? {
        guard !candidates.isEmpty else { return nil }
        
        if let persistedUUID,
           let remembered = candidates.first(where: { $0.volumeUUID == persistedUUID }) {
            return remembered
        }
        
        let scored = candidates.compactMap { candidate -> (DriveInfo, Int)? in
            let score = footprintScores[candidate.mountPoint] ?? 0
            return score > 0 ? (candidate, score) : nil
        }
        if let best = scored.max(by: { $0.1 < $1.1 })?.0 { return best }
        
        return candidates.max(by: { $0.totalSize < $1.totalSize })
    }
}
