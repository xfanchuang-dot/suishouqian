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
                externalDrive = drive
                onMountChange?(drive)
            } else if !name.hasPrefix("com.apple") && name != "Recovery" {
                builtinDrive = drive
            }
        }
    }
    
    func hasExternalDrive(named name: String) -> Bool {
        return externalDrive?.name == name
    }
    
    func findSamsungDrive() -> DriveInfo? {
        return externalDrive
    }
}
