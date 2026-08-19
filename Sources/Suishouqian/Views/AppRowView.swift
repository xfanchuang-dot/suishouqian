import SwiftUI

struct AppRowView: View {
    let app: AppItem
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 20))
                        .frame(width: 28, height: 28)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 4) {
                    Text(app.sizeFormatted)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if let version = app.version {
                        Text("·")
                        Text("v\(version)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            statusBadge
                .font(.system(size: 11))
            
            if app.status == .normal && appState.externalDrive != nil {
                Button("迁移") {
                    migrateApp()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
            } else if app.status == .migrated {
                HStack(spacing: 4) {
                    Button("回迁") {
                        restoreApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    
                    Button("卸载") {
                        uninstallApp()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(statusOpacity)
    }
    
    var statusBadge: some View {
        Group {
            switch app.status {
            case .normal:
                EmptyView()
            case .migrated:
                HStack(spacing: 3) {
                    Image(systemName: "externaldrive.fill")
                    Text("已迁移")
                }
                .foregroundColor(appState.externalDrive != nil ? .green : .gray)
            case .migrating:
                HStack(spacing: 3) {
                    ProgressView().scaleEffect(0.5)
                    Text("迁移中")
                }
                .foregroundColor(.blue)
            case .restoring:
                HStack(spacing: 3) {
                    ProgressView().scaleEffect(0.5)
                    Text("回迁中")
                }
                .foregroundColor(.orange)
            case .needsSync:
                HStack(spacing: 3) {
                    Circle().fill(.yellow).frame(width: 6, height: 6)
                    Text("待同步")
                }
                .foregroundColor(.orange)
            case .systemApp:
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text("系统")
                }
                .foregroundColor(.secondary)
            }
        }
    }
    
    var statusOpacity: CGFloat {
        app.status == .migrated && appState.externalDrive == nil ? 0.5 : 1.0
    }
    
    private func migrateApp() {
        guard let drive = appState.externalDrive else { return }
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            
            let state = self.appState  // 值类型捕获，避免 Sendable 警告
            let result = await state.migrator.migrate(
                app: app, to: drive.mountPoint
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    var t = state.migrationTask ?? MigrationTask(app: app, operation: .migrate)
                    t.progress = pct
                    t.currentFile = desc
                    state.migrationTask = t
                }
            }
            
            if result.success {
                var t = state.migrationTask
                t?.status = .completed
                state.migrationTask = nil
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
            } else if var t = state.migrationTask {
                t.status = .failed(result.error ?? "未知错误")
                state.migrationTask = t
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
        }
    }
    
    private func restoreApp() {
        guard let drive = appState.externalDrive else { return }
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.migrationTask = MigrationTask(app: app, operation: .restore)
            
            let state = self.appState  // 值类型捕获，避免 Sendable 警告
            let result = await state.migrator.restore(
                app: app, from: drive.mountPoint
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    var t = state.migrationTask ?? MigrationTask(app: app, operation: .restore)
                    t.progress = pct
                    t.currentFile = desc
                    state.migrationTask = t
                }
            }
            
            if result.success {
                state.migrationTask = nil
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
            } else if var t = state.migrationTask {
                t.status = .failed(result.error ?? "未知错误")
                state.migrationTask = t
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
        }
    }
    
    private func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "确认卸载"
        alert.informativeText = "将删除「\(app.name)」的符号链接和外置盘上的副本。此操作不可撤销。"
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            let result = appState.migrator.uninstall(app: app)
            if result.success {
                Task { @MainActor [weak appState] in
                    await appState?.scanApps()
                }
            }
        }
    }
}
