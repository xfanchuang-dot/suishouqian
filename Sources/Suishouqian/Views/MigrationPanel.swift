import SwiftUI

struct MigrationPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var batchSummary: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "操作", systemImage: "arrow.left.arrow.right")

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
                .cardStyle()
            } else {
                emptyState
            }

            if let summary = batchSummary {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if !appState.apps.isEmpty && appState.externalDrive != nil {
                VStack(spacing: 8) {
                    let movableApps = appState.apps.filter { $0.status == .normal }
                    let migratedApps = appState.apps.filter { $0.status == .migrated }

                    if !movableApps.isEmpty {
                        Button {
                            migrateAll()
                        } label: {
                            Label("一键迁移全部 (\(movableApps.count) 个应用)",
                                  systemImage: "arrow.right.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(appState.migrationTask != nil)
                    }

                    if !migratedApps.isEmpty {
                        Button {
                            restoreAll()
                        } label: {
                            Label("全部回迁 (\(migratedApps.count) 个应用)",
                                  systemImage: "arrow.uturn.backward.circle.fill")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(appState.migrationTask != nil)
                    }
                }
            }
        }
    }

    /// 空状态：大图标 + 主副文案 + 硬盘状态提示
    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 76, height: 76)
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            Text("把大应用搬到外置硬盘")
                .font(.system(size: 14, weight: .semibold))

            Text("在左侧选择应用，点击「迁移」释放内置盘空间")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            if appState.externalDrive == nil {
                StatusPill("未检测到外置硬盘，插入后自动识别",
                           systemImage: "questionmark.circle",
                           color: .orange)
            } else {
                StatusPill("外置硬盘已连接，可以开始迁移",
                           systemImage: "checkmark.circle.fill",
                           color: .green)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
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

        // App Store 应用迁完会被更新顶掉，批量前一次问清是否跳过（只问一次，不打扰）
        guard let targets = MigrationAdvisor.resolveBatch(movableApps) else { return }
        let skipped = movableApps.count - targets.count
        guard !targets.isEmpty else {
            batchSummary = "已跳过全部 \(skipped) 个 App Store 应用，没有需要迁移的应用"
            return
        }

        Task { @MainActor in
            var okCount = 0, failCount = 0
            for app in targets {
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
                    okCount += 1
                    appState.notificationManager.notifyMigrationComplete(
                        appName: app.name, spaceSaved: result.spaceSaved)
                } else {
                    failCount += 1
                    appState.notificationManager.notifyMigrationFailed(
                        appName: app.name, error: result.error ?? "未知错误")
                }
            }

            batchSummary = (failCount == 0
                ? "批量迁移完成：\(okCount) 个全部成功"
                : "批量迁移结束：\(okCount) 成功 / \(failCount) 失败")
                + (skipped > 0 ? "；已跳过 \(skipped) 个 App Store 应用" : "")
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
