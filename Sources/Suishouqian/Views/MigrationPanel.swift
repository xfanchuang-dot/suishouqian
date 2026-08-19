import SwiftUI

struct MigrationPanel: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("操作")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            
            if let task = appState.migrationTask {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: taskIcon)
                            .foregroundColor(taskColor)
                        Text(taskTitle)
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        if task.status == .completed {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                    
                    if !task.status.isTerminal {
                        ProgressView(value: task.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                        
                        Text(task.currentFile)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    if case .failed(let msg) = task.status {
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                .padding(16)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text("选择左侧应用开始迁移")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    
                    if appState.externalDrive == nil {
                        HStack(spacing: 6) {
                            Image(systemName: "externaldrive.badge.questionmark")
                                .foregroundColor(.orange)
                            Text("未检测到外置硬盘")
                                .font(.system(size: 12))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    } else {
                        Text("外置盘已连接，可以开始迁移")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
            
            if !appState.apps.isEmpty && appState.externalDrive != nil {
                VStack(spacing: 8) {
                    let movableApps = appState.apps.filter { $0.status == .normal }
                    let migratedApps = appState.apps.filter { $0.status == .migrated }
                    
                    if !movableApps.isEmpty {
                        Button("一键迁移全部 (\(movableApps.count) 个应用)") {
                            migrateAll()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.migrationTask != nil)
                    }
                    
                    if !migratedApps.isEmpty {
                        Button("全部回迁 (\(migratedApps.count) 个应用)") {
                            restoreAll()
                        }
                        .buttonStyle(.bordered)
                        .disabled(appState.migrationTask != nil)
                    }
                }
                .controlSize(.regular)
            }
        }
    }
    
    var taskIcon: String {
        guard let task = appState.migrationTask else { return "" }
        switch task.operation {
        case .migrate: return "arrow.right.circle.fill"
        case .restore: return "arrow.left.circle.fill"
        case .uninstall: return "trash.circle.fill"
        }
    }
    
    var taskColor: Color {
        guard let task = appState.migrationTask else { return .blue }
        switch task.operation {
        case .migrate: return .blue
        case .restore: return .orange
        case .uninstall: return .red
        }
    }
    
    var taskTitle: String {
        guard let task = appState.migrationTask else { return "" }
        let name = task.app.name
        switch task.operation {
        case .migrate: return "迁移 \(name)"
        case .restore: return "回迁 \(name)"
        case .uninstall: return "卸载 \(name)"
        }
    }
    
    private func migrateAll() {
        guard let drive = appState.externalDrive else { return }
        let movableApps = appState.apps.filter { $0.status == .normal }
        
        Task { @MainActor in
            for app in movableApps {
                appState.migrationTask = MigrationTask(app: app, operation: .migrate)
                
                let appState = self.appState  // 值类型捕获
                let result = await appState.migrator.migrate(
                    app: app, to: drive.mountPoint
                ) { @Sendable pct, desc in
                    Task { @MainActor in
                        var t = appState.migrationTask ?? MigrationTask(app: app, operation: .migrate)
                        t.progress = pct
                        t.currentFile = desc
                        appState.migrationTask = t
                    }
                }
                
                if result.success {
                    appState.notificationManager.notifyMigrationComplete(
                        appName: app.name, spaceSaved: result.spaceSaved)
                } else {
                    appState.notificationManager.notifyMigrationFailed(
                        appName: app.name, error: result.error ?? "未知错误")
                }
            }
            
            appState.migrationTask = nil
            await appState.scanApps()
        }
    }
    
    private func restoreAll() {
        guard let drive = appState.externalDrive else { return }
        let migratedApps = appState.apps.filter { $0.status == .migrated }
        
        Task { @MainActor in
            for app in migratedApps {
                appState.migrationTask = MigrationTask(app: app, operation: .restore)
                
                let appState = self.appState  // 值类型捕获
                let result = await appState.migrator.restore(
                    app: app, from: drive.mountPoint
                ) { @Sendable pct, desc in
                    Task { @MainActor in
                        var t = appState.migrationTask ?? MigrationTask(app: app, operation: .restore)
                        t.progress = pct
                        t.currentFile = desc
                        appState.migrationTask = t
                    }
                }
                
                if result.success {
                    appState.notificationManager.notifyMigrationComplete(
                        appName: app.name, spaceSaved: result.spaceSaved)
                } else {
                    appState.notificationManager.notifyMigrationFailed(
                        appName: app.name, error: result.error ?? "未知错误")
                }
            }
            
            appState.migrationTask = nil
            await appState.scanApps()
        }
    }
}
