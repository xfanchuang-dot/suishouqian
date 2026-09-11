import SwiftUI

struct AppRowView: View {
    let app: AppItem
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 10) {
            IconContainer(icon: app.icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(app.sizeFormatted)
                        .font(.system(size: 11, weight: .medium))
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

            if app.status == .normal && appState.externalDrive != nil {
                Button("迁移") {
                    migrateApp()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
                // 迁移/回迁/卸载都是会动文件的互斥操作，任务进行中必须禁用，
                // 否则并发触发会互相覆盖 migrationTask 状态、留下半完成副本
                .disabled(appState.isMigrationActive)
            } else if app.status == .externalOnly {
                Button("搬回内置盘") {
                    moveBack()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(appState.isMigrationActive)

                Button("卸载") {
                    uninstallApp()
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.system(size: 11))
                .disabled(appState.isMigrationActive)
            } else if app.status == .migrated {
                HStack(spacing: 4) {
                    Button("回迁") {
                        restoreApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .disabled(appState.isMigrationActive)

                    Button("卸载") {
                        uninstallApp()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.system(size: 11))
                    .disabled(appState.isMigrationActive)
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
                StatusPill("已迁移",
                           systemImage: "externaldrive.fill",
                           color: appState.externalDrive != nil ? .green : .gray)
            case .migrating:
                StatusPill("迁移中", color: .blue)
            case .restoring:
                StatusPill("回迁中", color: .orange)
            case .needsSync:
                StatusPill("待同步", systemImage: "clock.fill", color: .orange)
            case .systemApp:
                StatusPill("系统", systemImage: "lock.fill", color: .secondary)
            case .externalOnly:
                StatusPill("在外置盘", systemImage: "externaldrive",
                           color: appState.externalDrive != nil ? .teal : .gray)
            }
        }
    }
    
    var statusOpacity: CGFloat {
        let livesOnExternal = app.status == .migrated || app.status == .externalOnly
        return livesOnExternal && appState.externalDrive == nil ? 0.5 : 1.0
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
    
    /// 外置盘原住民：复制回内置盘、校验、删外置副本
    private func moveBack() {
        guard let drive = appState.externalDrive else { return }
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.migrationTask = MigrationTask(app: app, operation: .restore)

            let state = self.appState
            let result = await state.migrator.moveBackToInternal(
                app: app, drivePath: drive.mountPoint
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
        if app.status == .externalOnly {
            alert.messageText = "确认卸载"
            alert.informativeText = "将删除外置盘上的「\(app.name)」。此操作不可撤销。"
        } else {
            alert.messageText = "确认卸载"
            alert.informativeText = "将删除「\(app.name)」的符号链接和外置盘上的副本。此操作不可撤销。"
        }
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        
        if alert.runModal() == .alertFirstButtonReturn {
            let result = appState.migrator.uninstall(
                app: app, drivePath: appState.externalDrive?.mountPoint)
            if result.success {
                Task { @MainActor [weak appState] in
                    await appState?.scanApps()
                }
            }
        }
    }
}
