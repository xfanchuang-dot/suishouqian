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

    /// 拔盘时仍有已迁移应用在运行的提醒
    func notifyUnmountWithRunningApps(driveName: String, appNames: [String]) {
        let list = appNames.prefix(5).joined(separator: "、")
        let more = appNames.count > 5 ? " 等 \(appNames.count) 个" : ""
        send(
            title: "外置硬盘已拔出，仍有应用在运行",
            body: "\(list)\(more) 正在外置盘上运行，强制使用可能异常，建议尽快保存并退出",
            sound: .default
        )
    }

    /// 断链自愈完成提示（按台账卷 UUID 重写链接，卷改名也能接上）
    func notifyLinksHealed(appNames: [String]) {
        let list = appNames.prefix(5).joined(separator: "、")
        let more = appNames.count > 5 ? " 等 \(appNames.count) 条" : ""
        send(
            title: "断链已自动修复",
            body: "硬盘已连接（卷名可能变过），按迁移台账自动接上：\(list)\(more)",
            sound: nil
        )
    }

    /// 新装大应用提醒（防复发：新住户主动问要不要搬）
    func notifyNewLargeAppInstalled(name: String, size: Int64) {
        send(
            title: "检测到新安装的大应用",
            body: "「\(name)」占用 \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))，要迁移到外置硬盘吗？",
            sound: nil
        )
    }
    
    /// 内置盘空间告警（空间守卫）
    func notifyLowDisk(free: Int64, movableCount: Int, totalSavable: Int64) {
        let freeText = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        let body: String
        if movableCount > 0 {
            let savable = ByteCountFormatter.string(fromByteCount: totalSavable, countStyle: .file)
            body = "仅剩 \(freeText)。\(movableCount) 个应用可迁移到外置硬盘，预计腾出 \(savable)"
        } else {
            body = "仅剩 \(freeText)，建议清理大文件或检查废纸篓"
        }
        send(title: "内置盘空间不足", body: body, sound: .default)
    }

    private func send(title: String, body: String, sound: UNNotificationSound?) {
        // 设置页「系统通知」总开关（默认开）
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }

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
