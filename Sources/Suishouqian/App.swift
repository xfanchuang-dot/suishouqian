import SwiftUI

@main
struct SuishouqianApp: App {
    @StateObject private var appState = AppState()
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
                        _ = LaunchAgentManager.install()
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
    
    init() {
        diskMonitor.onMountChange = { [weak self] drive in
            guard let self else { return }
            self.externalDrive = drive
            self.refreshDrives()
            self.onDriveChanged(drive)
        }
        
        diskMonitor.onUnmount = { [weak self] driveName in
            guard let self else { return }
            self.notificationManager.notifyExternalDriveDisconnected(driveName: driveName)
        }
    }
    
    func scanApps() async {
        isScanning = true
        apps = []
        let scanned = await scanner.scanApplications()
        apps = scanned.sorted { $0.size > $1.size }
        isScanning = false
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
