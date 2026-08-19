import Foundation
import AppKit

class DiskMonitor: @unchecked Sendable {
    var builtinDrive: DriveInfo?
    var externalDrive: DriveInfo?
    
    var onMountChange: ((DriveInfo?) -> Void)?
    var onUnmount: ((String) -> Void)?
    
    init() {
        refresh()
        setupNotifications()
    }
    
    private func setupNotifications() {
        let ws = NSWorkspace.shared
        
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        
        ws.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // 记录卸载前的驱动器名
            if let userInfo = notification.userInfo,
               let devicePath = userInfo["NSDevicePath"] as? String {
                let name = (devicePath as NSString).lastPathComponent
                self?.onUnmount?(name)
            }
            self?.refresh()
        }
    }
    
    func refresh() {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                             .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                                             .volumeIsInternalKey],
            options: .skipHiddenVolumes
        ) else { return }

        // bug 修复：此前 onMountChange 在循环内对每个外置卷各触发一次，
        // 多盘/热插拔时会重复通知；改为循环结束后只回调一次
        var externals: [DriveInfo] = []
        var builtin: DriveInfo?

        for url in urls {
            guard let resources = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey, .volumeIsRemovableKey,
                .volumeIsInternalKey
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
                isExternal: isExternal
            )

            if isExternal {
                externals.append(drive)
            } else if !name.hasPrefix("com.apple") && name != "Recovery" {
                builtin = drive
            }
        }

        builtinDrive = builtin
        // 多个外置盘时优先保留上一次的那个（避免切换目标盘），否则取容量最大的
        if externals.count > 1,
           let previous = externalDrive,
           let same = externals.first(where: { $0.mountPoint == previous.mountPoint }) {
            externalDrive = same
        } else {
            externalDrive = externals.max(by: { $0.totalSize < $1.totalSize })
        }

        if let current = externalDrive {
            onMountChange?(current)
        }
    }
    
    func hasExternalDrive(named name: String) -> Bool {
        return externalDrive?.name == name
    }
    
    func findSamsungDrive() -> DriveInfo? {
        return externalDrive
    }
}
