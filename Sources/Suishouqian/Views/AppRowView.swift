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
                        .monospacedDigit()

                    if let version = app.version {
                        Text("·")
                        Text("v\(version)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            // 悬停即知这个应用的更新方式，以及搬走后更新会怎样（不占界面、不主动打扰）
            .help("更新方式：\(app.updateMechanism.label)\n\n\(app.updateMechanism.guidance)")

            Spacer()

            statusBadge

            // App Store 应用搬走后被更新顶掉的风险最高，给一个安静但看得见的标记
            if app.updateMechanism == .appStore {
                Image(systemName: "apple.logo")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help(app.updateMechanism.guidance)
            }

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
                .help("""
                迁移：把应用搬到外置盘，并在「应用程序」里留一个链接。

                应用仍会出现在「应用程序」文件夹里，双击、卸载（拖到废纸篓）都和以前一样；\
                启动时链接会被解析到外置盘；自带更新器就地更新（若某次更新后应用不见了，\
                去体检页「从更新缓存恢复」）。
                """)

                // 纯搬迁与「迁移」并列显示，不做成隐藏菜单——它是对
                // "更新会把迁移顶掉"的机制性解法，必须在动手那一刻就看得见
                Button("纯搬迁") {
                    moveToExternal()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(appState.isMigrationActive)
                .help("""
                纯搬迁：把应用搬到外置盘，但不在「应用程序」文件夹留链接。

                好处是从机制上消除"更新把链接顶掉、迁移被悄悄撤销"这个问题——\
                应用就住在它自己的位置，自带更新器会就地更新。

                代价：应用不再出现在「应用程序」里，改用 Spotlight / Dock 启动。

                适合：看不出更新方式的应用，或曾经被更新顶掉过迁移的应用。
                """)

                Button("卸载") {
                    uninstallApp()
                }
                .buttonStyle(.plain)
                .foregroundColor(.red)
                .font(.system(size: 11))
                .disabled(appState.isMigrationActive)
                .help("应用移入废纸篓（可恢复），并顺带排查它在资源库留下的数据")
            } else if app.status == .externalOnly {
                Button("搬回内置盘") {
                    moveBack()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11))
                .disabled(appState.isMigrationActive)

                relocateMenu

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

                    // v3.1 盘间迁移：已在外置盘的应用，可直接搬到另一块在线外置盘，
                    // 不经过内置盘中转。Menu 形态——目标盘数量不确定，按钮放不下。
                    relocateMenu

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
        // App Store 应用先讲清"更新会把迁移顶掉"，用户确认后才继续
        guard MigrationAdvisor.confirmRelocation(of: app, linkBack: true) else { return }
        runRelocation(createLink: true)
    }

    /// 纯搬迁：搬到外置盘但不在「应用程序」留链接（理由见按钮说明）。
    /// 同样要过确认框——对 App Store 应用来说，不留链接的失败形态（下次更新
    /// 可能往「应用程序」再装一份，两份并存）比留链接更糟，这个必须讲清楚
    private func moveToExternal() {
        guard MigrationAdvisor.confirmRelocation(of: app, linkBack: false) else { return }
        runRelocation(createLink: false)
    }

    /// 迁移与纯搬迁走同一条链路（运行检测→空间预检→快照→复制→校验→备份），
    /// 只差"是否在源位置留链接"这一步
    private func runRelocation(createLink: Bool) {
        guard let drive = appState.externalDrive else { return }
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            
            let state = self.appState  // 值类型捕获，避免 Sendable 警告
            let onProgress: @Sendable (Double, String) -> Void = { @Sendable pct, desc in
                Task { @MainActor in
                    state.reportMigrationProgress(pct, desc)
                }
            }

            let result: AppMigrator.MigrationResult
            if createLink {
                result = await state.migrator.migrate(
                    app: app, to: drive.mountPoint,
                    cancellationToken: state.migrationTask?.cancellationToken,
                    progress: onProgress)
            } else {
                result = await state.migrator.moveToExternal(
                    app: app, drivePath: drive.mountPoint, progress: onProgress)
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
                    state.reportMigrationProgress(pct, desc)
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
    // MARK: - v3.1 盘间迁移

    /// 当前应用可搬往的目标盘（在线外置卷，排除所在卷）
    private var relocateTargets: [ManagedVolume] {
        let current = RelocateTargets.currentMount(for: app, volumes: appState.volumeStore.volumes)
        return RelocateTargets.candidates(currentMount: current, volumes: appState.volumeStore.volumes)
    }

    private var relocateMenu: some View {
        Menu("搬到…") {
            ForEach(relocateTargets) { vol in
                Button("\(vol.displayName)（可用 \(vol.info.freeFormatted)）") {
                    relocateApp(to: vol)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 11))
        .disabled(appState.isMigrationActive || relocateTargets.isEmpty)
        .help("盘间迁移：把应用从当前外置盘直接搬到另一块外置盘，不经过内置盘中转。\n目标盘空间不足或离线时不会出现在列表里。")
    }

    /// 盘间迁移执行链：走 migrationTask 通道（全局任务胶囊可见），journal 由
    /// AppMigrator.relocate 内部记录（含 fromUUID/toUUID，撤销可反向搬回）。
    private func relocateApp(to volume: ManagedVolume) {
        guard let fromMount = RelocateTargets.currentMount(
            for: app, volumes: appState.volumeStore.volumes) else { return }
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            appState.migrationTask = MigrationTask(app: app, operation: .relocate)

            let state = self.appState
            let result = await state.migrator.relocate(
                app: app, fromVolume: fromMount, toVolume: volume.info.mountPoint
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    state.reportMigrationProgress(pct, desc)
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
                    state.reportMigrationProgress(pct, desc)
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

    /// 卸载一条龙（v2.13.0）：运行检测 → 应用/备份入废纸篓 → 残留排查（用户确认后清）
    private func uninstallApp() {
        // 运行中的应用不能卸（会留下半删状态与失控的数据写入）
        if let running = AppMigrator.runningAppName(matching: app.path) {
            let alert = NSAlert()
            alert.messageText = "「\(running)」正在运行"
            alert.informativeText = "请先退出应用再卸载。"
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "确认卸载「\(app.name)」？"
        alert.informativeText = """
        应用本体与迁移备份将移入废纸篓（可恢复），台账同步清理。
        卸载完成后还会帮你排查它在「资源库」里留下的数据，由你确认后再清。
        """
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let drivePath = appState.externalDrive?.mountPoint
        let checker = HealthChecker()
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            let result = await appState.migrator.uninstall(app: app, drivePath: drivePath)
            guard result.success else {
                let fail = NSAlert()
                fail.messageText = "卸载未能完成"
                fail.informativeText = result.error ?? "未知错误"
                fail.runModal()
                return
            }

            // 残留排查含 du（阻塞子进程）：OffPool；报给用户、用户点头才清
            let leftovers = await OffPool.run {
                checker.residues(forUninstalledApp: app.name, bundleID: app.bundleID)
            }
            if !leftovers.isEmpty {
                let total = leftovers.reduce(Int64(0)) { $0 + $1.sizeBytes }
                let names = leftovers.prefix(5)
                    .map { "\($0.name)（\($0.sizeFormatted)）" }
                    .joined(separator: "、")
                let ask = NSAlert()
                ask.messageText = "发现 \(leftovers.count) 项残留数据，共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                ask.informativeText = "\(names)\n\n是「\(app.name)」留在资源库里的数据，一并移入废纸篓吗？"
                ask.addButton(withTitle: "一并清理")
                ask.addButton(withTitle: "保留")
                ask.alertStyle = .warning
                if ask.runModal() == .alertFirstButtonReturn {
                    for item in leftovers {
                        _ = await checker.recycleResidue(item)
                    }
                }
            }

            appState.notificationManager.notifyUninstalled(appName: app.name)
            await appState.scanApps()
        }
    }
}
