import SwiftUI

/// 跨视图 UI 事件（菜单命令 → 列表搜索框聚焦等）
extension Notification.Name {
    static let focusAppSearch = Notification.Name("com.suishouqian.focusAppSearch")
}

/// 右侧面板（v2.14.0 起用枚举，替代散布各处的 0/1/2/3 魔法数字）
enum Panel: Int {
    case overview = 0
    case migrate = 1
    case health = 2
    case data = 3
}

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

    // MARK: Dock 菜单（右键 Dock 图标直达常用操作）

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "随手迁")
        let defs: [(title: String, tag: Int)] = [
            ("立即扫描", 0), ("总览面板", 1), ("迁移面板", 2), ("体检面板", 3), ("数据面板", 4),
        ]
        for (title, tag) in defs {
            let item = NSMenuItem(title: title,
                                  action: #selector(dockAction(_:)),
                                  keyEquivalent: "")
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @MainActor @objc private func dockAction(_ sender: NSMenuItem) {
        guard let state = Self.appState else { return }
        switch sender.tag {
        case 0:
            Task { await state.scanApps() }
        case 1: state.activePanel = .overview
        case 2: state.activePanel = .migrate
        case 3: state.activePanel = .health
        case 4: state.activePanel = .data
        default: break
        }
    }
}

@main
struct SuishouqianApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let updateManager = UpdateManager()
    /// 菜单栏常驻（v3.1 实验开关，默认关）
    @AppStorage("menuBarExtraEnabled") private var menuBarExtraEnabled = false
    
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
            CommandMenu("操作") {
                Button("重新扫描应用") {
                    Task { @MainActor in await appState.scanApps() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(appState.isScanning)

                Button("搜索应用") {
                    NotificationCenter.default.post(name: .focusAppSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("总览面板") { appState.activePanel = .overview }
                    .keyboardShortcut("0", modifiers: .command)
                Button("迁移面板") { appState.activePanel = .migrate }
                    .keyboardShortcut("1", modifiers: .command)
                Button("体检面板") { appState.activePanel = .health }
                    .keyboardShortcut("2", modifiers: .command)
                Button("数据面板") { appState.activePanel = .data }
                    .keyboardShortcut("3", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("关于随手迁") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
                Button("检查更新...") {
                    updateManager.checkForUpdates()
                }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        // v3.1 菜单栏常驻：实验开关，默认关闭；只读展示 + 打开/退出
        MenuBarExtra("随手迁", systemImage: "externaldrive.fill", isInserted: $menuBarExtraEnabled) {
            MenuBarView()
                .environmentObject(appState)
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
    /// 右侧面板（⌘0~⌘3 可切，ContentView 绑定）
    @Published var activePanel: Panel = .overview

    let scanner = AppScanner()
    let migrator = AppMigrator()
    let diskMonitor = DiskMonitor()
    let notificationManager = NotificationManager()
    let healthChecker = HealthChecker()
    let dataMigrator = DataMigrator()
    /// 检查引擎：体检页与总览页共用的唯一编排（v2.14.0）
    let checkEngine = CheckEngine()
    /// 多盘存储（v3.0）：DiskMonitor 管"单盘选定"，VolumeStore 管"多卷聚合"，
    /// 枚举走同一个 enumerateVolumes() 口径；主盘只读 DiskMonitor 的键，不回写
    let volumeStore = VolumeStore()
    /// 启动监听令牌：addObserver(forName:) 的返回值必须持有，
    /// 否则令牌释放后回调静默失效（经典坑，编译器不报）
    private var launchObserver: NSObjectProtocol?

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
                // 卷枚举 + 每个候选的 fileExists 都是阻塞 IO（网络卷上可能卡住），
                // 连同 Time Machine 目的盘缓存一起放 OffPool，别占主线程。
                // 顺序有意义：先刷 TM 缓存，目标盘过滤才不会拿旧快照做判断。
                let monitor = self.diskMonitor
                await OffPool.run {
                    _ = VolumeClassifier.refreshTimeMachineCache()
                    monitor.refresh()
                }
                await self.volumeStore.refresh()
                self.refreshDrives()
                self.checkLowDisk()
                self.checkNewLargeApps()
            }
        }
    }

    private func checkLowDisk() {
        // 设置页可关（每次 tick 读取，关闭即时生效于下一轮）
        guard UserDefaults.standard.bool(forKey: "spaceGuardEnabled") else { return }
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
        guard UserDefaults.standard.bool(forKey: "newAppReminderEnabled") else { return }
        let defaults = UserDefaults.standard
        var known = Set(defaults.stringArray(forKey: "knownAppNames") ?? [])
        let current = AppScanner.quickAppNames()
        let fresh = current.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }

        // 先记账再测量：测量要跑 du，别让期间的重复 tick 反复提醒同一批应用
        known.formUnion(current)
        defaults.set(Array(known), forKey: "knownAppNames")

        Task.detached(priority: .utility) { [weak self] in
            for name in fresh {
                // .app 是目录：attributesOfItem 的 .size 只有几十字节（目录条目本身），
                // 拿它比 500MB 永远不成立——旧版提醒功能因此从未生效过。
                // 必须递归量体积，且 du 要带 -L（这里应用可能是迁移后的软链接）。
                // du 是阻塞子进程：放 OffPool，不占协作线程池
                let bytes = await OffPool.run {
                    AppScanner.directorySizeBytes(atPath: "/Applications/\(name)")
                }
                guard bytes >= 500 * 1_048_576 else { continue }
                let display = String(name.dropLast(4))
                await MainActor.run {
                    self?.notificationManager.notifyNewLargeAppInstalled(
                        name: display, size: bytes)
                }
                AuditLog.append("新应用提醒：\(display)（\(bytes / 1_048_576)MB）")
            }
        }
    }

    init() {
        AppDelegate.appState = self
        // 设置页各开关的默认值（注册一次，@AppStorage 与 bool 读取共用）
        UserDefaults.standard.register(defaults: [
            "spaceGuardEnabled": true,
            "newAppReminderEnabled": true,
            "notificationsEnabled": true,
            "backupRetentionDays": 7,
            "bigFileExtendedScanEnabled": false,
        ])
        startSpaceGuard()

        // v2.2: 启动即尝试断链自愈 + 给历史迁移补台账
        // （补账后，卷改名场景在下次插盘时就能自动接上，无需用户打开体检）
        // v2.3.1: 数据链接（~/... 下的）同样纳入自愈
        // v3.0.1: 这几步都是同步文件 IO，必须整体走 OffPool ——
        // Task.detached 占的是协作线程池，正是两次冻结事故的根因类别
        let bootChecker = healthChecker
        let bootDataMigrator = dataMigrator
        Task {
            await OffPool.run {
                _ = bootChecker.healBrokenLinks()
                _ = bootDataMigrator.healDataLinks()
                bootChecker.backfillManifest()
                bootChecker.pruneStaleManifestEntries()
            }
        }

        // Time Machine 目标盘缓存：只认本地挂载点。tmutil 是阻塞调用，走 OffPool。
        // 缓存建立后再重算一次目标盘：DiskMonitor 初始化时缓存还是空的，
        // 那一轮可能把 TM 备份盘当成候选（写盘边界还有第二道闸，但界面不该显示错目标）。
        let bootMonitor = diskMonitor
        let bootStore = volumeStore
        Task {
            await OffPool.run { _ = VolumeClassifier.refreshTimeMachineCache() }
            // v3.0 多盘聚合（内部自带 OffPool 枚举；TM 缓存已就绪，过滤口径正确）
            await bootStore.refresh()
            await OffPool.run { bootMonitor.refresh() }
            refreshDrives()
        }

        // v2.9.0 使用频率顾问：只记「住在外置盘上的应用」的启动时刻。
        // bundleURL 是软链接解析后的真身路径，所以链接迁移态与外置盘原住民都会命中；
        // 内置盘应用的启动零记录——顾问只关心"外置盘有多离不开"。
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  let path = app.bundleURL?.path,
                  path.hasPrefix("/Volumes/"),
                  let bid = app.bundleIdentifier, !bid.isEmpty
            else { return }
            LaunchUsageTracker.shared.record(
                bundleID: bid,
                name: app.localizedName ?? (path as NSString).lastPathComponent
            )
            // 不写 AuditLog：那是迁移/回迁/卸载/修复的操作台账，
            // 使用记录有自己的 launch-usage.json，混进来会稀释审计日志的契约
        }

        diskMonitor.onMountChange = { [weak self] drive in
            guard let self else { return }
            self.externalDrive = drive
            self.refreshDrives()
            self.onDriveChanged(drive)

            // v2.2: 插盘即自愈——按台账里的卷 UUID 重写断链，卷改名也能接上
            // v2.3.1: 数据链接一并自愈
            if drive != nil {
                let checker = self.healthChecker
                let dataMigrator = self.dataMigrator
                Task {
                    // 自愈是同步文件 IO：走 OffPool，不占协作线程池
                    let healed = await OffPool.run { () -> ([String], [String]) in
                        (checker.healBrokenLinks(), dataMigrator.healDataLinks())
                    }
                    if !healed.0.isEmpty || !healed.1.isEmpty {
                        self.notificationManager.notifyLinksHealed(
                            appNames: healed.0 + healed.1)
                    }
                }
                // v2.4.2: 插盘后重扫列表，外置盘原住民应用立即可见
                Task { @MainActor [weak self] in
                    await self?.scanApps()
                }
                // v3.0: 插盘/拔盘后多卷列表要跟着变（离线卷灰显、新卷入列）
                let store = self.volumeStore
                Task { await store.refresh() }
            }
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
        // v2.4.2: 外置盘接入时连带扫描盘上 Applications（外置盘原住民应用）
        var roots: [String] = []
        if let mount = externalDrive?.mountPoint {
            roots = ["\(mount)/Applications", "\(mount)/Suishouqian_Apps"]
        }
        let scanned = await scanner.scanApplications(externalRoots: roots)
        apps = scanned.sorted { $0.size > $1.size }
        isScanning = false

        // 台账校准：应用被绕过本工具删掉后，台账会留下"幽灵记录"，
        // 顺手清掉（lstat 语义，断链但盘离线的情况不会误清）
        healthChecker.pruneStaleManifestEntries()
        
        // P0: 每次扫描顺带清理过期备份（此前 cleanOldBackups 从未被调用，
        // 外置盘上积累了 4 个月前的 1GB 陈旧备份）
        if let mountPoint = externalDrive?.mountPoint {
            await migrator.cleanOldBackups(at: mountPoint)
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
