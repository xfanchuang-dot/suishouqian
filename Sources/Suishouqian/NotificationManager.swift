import UserNotifications

/// 系统通知管理
final class NotificationManager: ObservableObject, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    
    init() {
        requestPermission()
    }
    
    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }
    
    /// 迁移完成通知
    func notifyMigrationComplete(appName: String, spaceSaved: Int64) {
        send(
            title: "迁移完成",
            body: "「\(appName)」已迁移到外置硬盘，节省 \(ByteCountFormatter.string(fromByteCount: spaceSaved, countStyle: .file))",
            sound: .default
        )
    }
    
    /// 迁移失败通知
    func notifyMigrationFailed(appName: String, error: String) {
        send(
            title: "迁移失败",
            body: "「\(appName)」迁移失败：\(error)",
            sound: .defaultCritical
        )
    }
    
    /// 外置盘插入提示
    func notifyExternalDriveConnected(driveName: String, movableCount: Int, totalSavable: Int64) {
        let body: String
        if movableCount > 0 {
            body = "检测到「\(driveName)」，\(movableCount) 个应用可迁移，预计节省 \(ByteCountFormatter.string(fromByteCount: totalSavable, countStyle: .file))"
        } else {
            body = "检测到外置硬盘「\(driveName)」"
        }
        
        send(
            title: "外置硬盘已连接",
            body: body,
            sound: nil
        )
    }
    
    /// 外置盘拔出通知
    func notifyExternalDriveDisconnected(driveName: String) {
        send(
            title: "外置硬盘已断开",
            body: "「\(driveName)」已断开连接，已迁移的应用暂时不可用",
            sound: nil
        )
    }
    
    private func send(title: String, body: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sound { content.sound = sound }
        content.categoryIdentifier = "SUISHOUQIAN_MIGRATION"
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // 立即发送
        )
        
        center.add(request)
    }
}
