import SwiftUI

/// 应用委托：迁移进行中拦截退出，杜绝半完成状态的最后一个人为入口
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 仅主线程读写（applicationShouldTerminate 与 AppState.init 均在主线程）
    nonisolated(unsafe) static weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.appState, state.isMigrationActive else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "迁移正在进行中"
        alert.informativeText = """
        「\(state.migrationTask?.app.name ?? "")」正在\(state.migrationTask?.operation == .migrate ? "迁移" : "回迁")，\
        现在强制退出可能留下半完成状态（原件和备份都在，可通过体检页恢复）。
        建议等待完成，通常只需几十秒。
        """
        alert.addButton(withTitle: "等待完成（推荐）")
        alert.addButton(withTitle: "强制退出")
        alert.alertStyle = .warning

        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
}

@main
struct SuishouqianApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateManager = UpdateManager()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("关于随手迁") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
                Button("检查更新...") {
                    updateManager.checkForUpdates()
                }
            }
            CommandMenu("守护") {
                Button(LaunchAgentManager.isInstalled ? "关闭外置盘守护" : "开启外置盘守护") {
                    if LaunchAgentManager.isInstalled {
                        _ = LaunchAgentManager.uninstall()
                    } else {
                        // 只监听当前外置盘挂载点，避免 Time Machine/dmg 等
                        // 其他挂载事件误触发唤醒
                        _ = LaunchAgentManager.install(
                            watchPath: appState.externalDrive?.mountPoint ?? "/Volumes")
                    }
                }
            }
        }
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var externalDrive: DriveInfo?
    @Published var isScanning = false
    @Published var migrationTask: MigrationTask?
    @Published var builtinDrive: DriveInfo?
    
    let scanner = AppScanner()
    let migrator = AppMigrator()
    let diskMonitor = DiskMonitor()
    let notificationManager = NotificationManager()

    /// 是否有迁移/回迁任务正在进行（强退保护依据）
    var isMigrationActive: Bool {
        guard let task = migrationTask else { return false }
        return !task.status.isTerminal
    }

    // MARK: - 空间守卫

    private var lowDiskNotified = false
    private let lowDiskThreshold: Int64 = 40 * 1_073_741_824   // 40GB 警戒线

    private func startSpaceGuard() {
        // 首次运行只记录基线，不弹提醒（避免装完就被打扰）
        if UserDefaults.standard.stringArray(forKey: "knownAppNames") == nil {
            UserDefaults.standard.set(AppScanner.quickAppNames(), forKey: "knownAppNames")
        }

        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.diskMonitor.refresh()
                self.refreshDrives()
                self.checkLowDisk()
                self.checkNewLargeApps()
            }
        }
    }

    private func checkLowDisk() {
        guard let free = builtinDrive?.freeSize else { return }
        if free < lowDiskThreshold && !lowDiskNotified {
            let movable = apps.filter { $0.status == .normal }
            let savable = movable.reduce(0) { $0 + $1.size }
            notificationManager.notifyLowDisk(
                free: free, movableCount: movable.count, totalSavable: savable)
            AuditLog.append("空间告警：内置盘仅剩 \(free / 1_073_741_824)GB")
            lowDiskNotified = true
        } else if free > lowDiskThreshold * 11 / 10 {
            lowDiskNotified = false   // 恢复到 44GB 以上才允许下次告警
        }
    }

    /// 新应用入住提醒：发现 /Applications 里新出现 ≥500MB 的应用就问要不要搬
    private func checkNewLargeApps() {
        let defaults = UserDefaults.standard
        var known = Set(defaults.stringArray(forKey: "knownAppNames") ?? [])
        let current = AppScanner.quickAppNames()
        let fresh = current.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }

        for name in fresh {
            let path = "/Applications/\(name)"
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64, size >= 500 * 1_048_576 else { continue }
            let display = String(name.dropLast(4))
            notificationManager.notifyNewLargeAppInstalled(name: display, size: size)
            AuditLog.append("新应用提醒：\(display)（\(size / 1_048_576)MB）")
        }
        known.formUnion(current)
        defaults.set(Array(known), forKey: "knownAppNames")
    }

    init() {
        AppDelegate.appState = self
        startSpaceGuard()
        diskMonitor.onMountChange = { [weak self] drive in
            guard let self else { return }
            self.externalDrive = drive
            self.refreshDrives()
            self.onDriveChanged(drive)
        }

        diskMonitor.onUnmount = { [weak self] driveName in
            guard let self else { return }
            // 安全：拔盘时若有已迁移应用仍在外置盘上运行，点名提醒
            let stillRunning = NSWorkspace.shared.runningApplications
                .filter { app in
                    guard let exec = app.executableURL?.path else { return false }
                    return exec.hasPrefix("/Volumes/") && app.activationPolicy == .regular
                }
                .compactMap(\.localizedName)
            if stillRunning.isEmpty {
                self.notificationManager.notifyExternalDriveDisconnected(driveName: driveName)
            } else {
                self.notificationManager.notifyUnmountWithRunningApps(
                    driveName: driveName, appNames: stillRunning)
                AuditLog.append("拔盘提醒：\(stillRunning.joined(separator: "、")) 仍在运行")
            }
        }
    }
    
    func scanApps() async {
        isScanning = true
        // 稳定性：不先清空列表，扫描完成原子替换，避免每次扫描整页闪空白
        let scanned = await scanner.scanApplications()
        apps = scanned.sorted { $0.size > $1.size }
        isScanning = false
        
        // P0: 每次扫描顺带清理过期备份（此前 cleanOldBackups 从未被调用，
        // 外置盘上积累了 4 个月前的 1GB 陈旧备份）
        if let mountPoint = externalDrive?.mountPoint {
            migrator.cleanOldBackups(at: mountPoint)
        }
    }
    
    func refreshDrives() {
        builtinDrive = diskMonitor.builtinDrive
        externalDrive = diskMonitor.externalDrive
    }
    
    private func onDriveChanged(_ drive: DriveInfo?) {
        guard let drive else { return }
        
        let movableApps = apps.filter { $0.status == .normal }
        let totalSavable = movableApps.reduce(0) { $0 + $1.size }
        
        notificationManager.notifyExternalDriveConnected(
            driveName: drive.name,
            movableCount: movableApps.count,
            totalSavable: totalSavable
        )
    }
}
