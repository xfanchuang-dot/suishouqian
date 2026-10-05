import SwiftUI

struct MigrationPanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var batchSummary: String?
    @State private var showPlanSheet = false
    @State private var showHistory = false
    private let dataMigrator = DataMigrator()
    
    var body: some View {
        // 效果图版：居中大号渐变胶囊主按钮 + 任务进度卡 + 底部任务统计条
        let movableApps = appState.apps.filter { $0.status == .normal }
        let migratedApps = appState.apps.filter { $0.status == .migrated }
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // 页标题（与其他页统一：MockPageTitle 26pt 大标题）
                    HStack {
                        MockPageTitle(text: "迁移")
                        Spacer()
                    }
                    .padding(.top, 4)

                    // 主按钮（效果图：蓝→紫渐变胶囊，居中）
                    if !movableApps.isEmpty && appState.externalDrive != nil {
                        MockGradientButton(
                            title: "一键迁移全部",
                            systemImage: "arrow.right",
                            enabled: appState.migrationTask == nil) {
                            migrateAll()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }

                    // 当前任务卡（效果图：图标+名称+大小 / 进度条+百分比+状态）
                    if let task = appState.migrationTask {
                        taskCard(task)
                    } else if appState.apps.isEmpty || appState.externalDrive == nil {
                        emptyState
                    }

                    if let summary = batchSummary {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    // 次级操作（效果图未覆盖，弱化为小号文字按钮横排）
                    if !appState.apps.isEmpty && appState.externalDrive != nil {
                        HStack(spacing: 14) {
                            Button("迁移历史") { showHistory = true }
                            if !migratedApps.isEmpty {
                                Button("全部回迁（\(migratedApps.count) 个）") { restoreAll() }
                            }
                            Button("一键腾空间…") { showPlanSheet = true }
                                .disabled(appState.volumeStore.onlineVolumes.isEmpty)
                                .help("告诉它想腾出多少空间，引擎自动挑出性价比最高的一批应用并给出理由")
                            Button("盘要退休…") { retireWizard() }
                                .foregroundColor(.orange)
                                .help("换盘、卖盘、盘快不行了？把这块盘上由随手迁管理的内容全部迁回内置盘")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                        .foregroundColor(MockTheme.accent)
                        .disabled(appState.migrationTask != nil)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .sheet(isPresented: $showPlanSheet) {
                SpaceFreePlanSheet { planned in
                    executePlan(planned)
                }
            }
            .sheet(isPresented: $showHistory) {
                MigrationHistoryView()
                    .environmentObject(appState)
            }

            Divider().padding(.horizontal, 4)
            // 效果图底栏：任务统计（真实口径：待迁移/已迁移/可释放）
            MockBottomBar(items: bottomItems(movable: movableApps, migrated: migratedApps))
        }
    }

    /// 任务卡（效果图：左图标 + 名称/大小，右百分比；下进度条 + 状态行）
    private func taskCard(_ task: MigrationTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconContainer(icon: task.app.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(ByteCountFormatter.string(fromByteCount: task.app.size, countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if task.status == .completed {
                    Label("已完成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                    Text("100%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.green)
                } else if task.status == .cancelled {
                    Label("已取消", systemImage: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .help("半截文件已清理，原应用不受影响")
                } else if case .failed = task.status {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(.red)
                } else {
                    Text("\(Int(task.progress * 100))%")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(MockTheme.accent)
                }
            }

            if !task.status.isTerminal {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(MockTheme.primaryGradient)
                                .frame(width: max(8, geo.size.width * task.progress))
                        }
                }
                .frame(height: 8)
                .clipShape(Capsule())
                // 进度跳变时用弹簧跟随，不是一格一格地蹦
                .animation(reduceMotion ? nil : Motion.progress, value: task.progress)

                HStack {
                    Text(task.currentFile)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    // 协作式取消：token 一置位，管道在下个阶段边界停下
                    // 并清理半截副本（源目录未动，无数据风险）
                    Button("取消") {
                        task.cancellationToken.cancel()
                        AuditLog.append("用户取消迁移「\(task.app.name)」")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .help("取消本次迁移：停在当前阶段，清理已复制的半截文件，原应用不受影响")
                }
            }

            if case .failed(let msg) = task.status {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
        }
        .mockCard()
    }

    private func bottomItems(movable: [AppItem], migrated: [AppItem]) -> [String] {
        let savable = movable.reduce(0) { $0 + $1.size }
        var items = ["\(movable.count) 个待迁移", "\(migrated.count) 个已迁移"]
        if savable > 0 {
            items.append("可释放 \(ByteCountFormatter.string(fromByteCount: savable, countStyle: .file))")
        }
        return items
    }

    /// 方案执行链：与 migrateAll 同一套串行安全链（逐应用重跑护栏 + journal 埋点），
    /// createLink 按"更新方式是否更适合不留链接"自动定（App Store 应用走纯搬迁）。
    private func executePlan(_ planned: [(AppItem, String)]) {
        guard appState.migrationTask == nil, !planned.isEmpty else { return }
        let total = planned.count
        Task { @MainActor in
            var okCount = 0
            var failCount = 0
            for (index, pair) in planned.enumerated() {
                let app = pair.0
                let drivePath = pair.1
                appState.migrationTask = MigrationTask(app: app, operation: .migrate)
                let createLink = !app.updateMechanism.prefersNoLink
                let result = await appState.migrator.migrate(
                    app: app, to: drivePath, createLink: createLink,
                    cancellationToken: appState.migrationTask?.cancellationToken
                ) { progress, file in
                    Task { @MainActor in
                        // 方案整体进度 = 已完成个数 + 当前应用进度，再除以总数
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress((Double(index) + progress) / Double(total), file)
                    }
                }
                if result.success {
                    okCount += 1
                    if var t = appState.migrationTask {
                        t.status = .completed
                        appState.migrationTask = t
                    }
                } else if result.cancelled {
                    // 取消不算失败：半截副本已清理，源目录未动，不计入 failCount
                    if var t = appState.migrationTask {
                        t.status = .cancelled
                        appState.migrationTask = t
                    }
                    batchSummary = "已取消「\(app.name)」的迁移"
                    break  // 批量中取消：停掉整批，后面的不再继续
                } else {
                    failCount += 1
                    if var t = appState.migrationTask {
                        t.status = .failed(result.error ?? "未知错误")
                        appState.migrationTask = t
                    }
                }
            }
            batchSummary = failCount == 0
                ? "方案执行完成：\(okCount)/\(total) 全部成功"
                : "方案执行结束：\(okCount) 成功 / \(failCount) 失败"
            appState.migrationTask = nil
        }
    }

    /// 空状态：大图标 + 主副文案 + 硬盘状态提示
    private var emptyState: some View {
        VStack(spacing: 4) {
            EmptyStateView(
                symbol: "externaldrive.badge.plus",
                accentSymbols: ["arrow.right", "sparkles"],
                gradient: [.blue, .cyan],
                title: "把大应用搬到外置硬盘",
                subtitle: "去「应用」页面挑选，点击「迁移」释放内置盘空间",
                reduceMotion: reduceMotion,
                imageName: "empty-migrate"
            )
            .padding(.bottom, -20)

            if appState.externalDrive == nil {
                StatusPill(VolumeOfflineBanner.message(for: nil),
                           systemImage: VolumeOfflineBanner.systemImage(for: nil),
                           color: .orange)
            } else {
                StatusPill("外置硬盘已连接，可以开始迁移",
                           systemImage: "checkmark.circle.fill",
                           color: .green)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    var taskTitle: String {
        guard let task = appState.migrationTask else { return "" }
        let name = task.app.name
        switch task.operation {
        case .migrate: return "迁移 \(name)"
        case .restore: return "回迁 \(name)"
        case .uninstall: return "卸载 \(name)"
        case .relocate: return "盘间迁移 \(name)"
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
                    app: app, to: drive.mountPoint,
                    cancellationToken: appState.migrationTask?.cancellationToken
                ) { @Sendable pct, desc in
                    Task { @MainActor in
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress(pct, desc)
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
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress(pct, desc)
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

    // MARK: - 盘要退休向导（v2.13.0）

    /// 换盘/卖盘/盘出问题前的场景化打包：链接应用、外置原住民、数据目录（含自选）
    /// 全部迁回内置盘，逐项执行互不打断；全部成功后可选清掉盘上的随手迁目录。
    private func retireWizard() {
        guard let drive = appState.externalDrive, appState.migrationTask == nil else { return }
        guard let builtinFree = appState.builtinDrive?.freeSize else { return }
        let migratedApps = appState.apps.filter { $0.status == .migrated }
        let nativeApps = appState.apps.filter { $0.status == .externalOnly }

        Task { @MainActor in
            // 数据条目要扫一遍才知道有哪些（scanDataLocations 内部已走 OffPool）
            let catalogData = await dataMigrator.scanDataLocations()
                .filter { $0.managedByUs && $0.isSymlink }
            let customData = await dataMigrator.scanCustomItems()
            let dataItems = catalogData + customData

            let totalCount = migratedApps.count + nativeApps.count + dataItems.count
            guard totalCount > 0 else {
                let alert = NSAlert()
                alert.messageText = "这块盘上没有随手迁管理的内容"
                alert.informativeText = "没有链接应用、外置盘原住民或已迁移的数据目录需要迁回。"
                alert.runModal()
                return
            }

            let totalBytes = migratedApps.reduce(Int64(0)) { $0 + $1.size }
                + nativeApps.reduce(Int64(0)) { $0 + $1.size }
                + dataItems.reduce(Int64(0)) { $0 + $1.sizeBytes }
            let totalText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)

            // 内置盘放不下就不开始：逐项迁移各自的预检也都在，这里先给总量判断
            guard builtinFree > totalBytes else {
                let alert = NSAlert()
                alert.messageText = "内置盘空间不够"
                alert.informativeText = "全部迁回约需 \(totalText)，内置盘可用仅 \(ByteCountFormatter.string(fromByteCount: builtinFree, countStyle: .file))。请先清理内置盘或改用更大的盘。"
                alert.runModal()
                return
            }

            let confirm = NSAlert()
            confirm.messageText = "把「\(drive.name)」上的内容全部迁回内置盘？"
            confirm.informativeText = """
            将逐项迁回（共 \(totalCount) 项，约 \(totalText)）：
            · 链接迁移应用 \(migratedApps.count) 个
            · 外置盘原住民应用 \(nativeApps.count) 个
            · 数据目录（含自选）\(dataItems.count) 个

            正在运行的应用会被跳过并在最后汇报。全部成功后可选择清掉盘上的随手迁目录。
            """
            confirm.addButton(withTitle: "开始迁回")
            confirm.addButton(withTitle: "取消")
            confirm.alertStyle = .warning
            guard confirm.runModal() == .alertFirstButtonReturn else { return }

            var failures: [(name: String, reason: String)] = []
            var done = 0

            // 任务占位：让顶部进度区显示"（i/N）正在处理谁"
            let taskApp = AppItem(name: "盘要退休", bundleName: "retire.task",
                                  path: drive.mountPoint, version: nil,
                                  size: totalBytes, isSymlink: false,
                                  symlinkTarget: nil, icon: nil)
            appState.migrationTask = MigrationTask(app: taskApp, operation: .restore)

            // 显式 @MainActor 闭包：嵌套 async 函数不继承隔离，读 migrationTask 会报错
            let runRestore: @MainActor (
                _ name: String,
                _ op: @escaping @Sendable () async -> (success: Bool, error: String?)
            ) async -> Void = { name, op in
                done += 1
                if let t = appState.migrationTask {
                    var task = t
                    task.currentFile = "（\(done)/\(totalCount)）\(name)"
                    appState.migrationTask = task
                }
                let r = await op()
                if !r.success { failures.append((name, r.error ?? "未知错误")) }
            }

            for app in migratedApps {
                await runRestore(app.name) { [weak appState] in
                    guard let appState else { return (false, "状态丢失") }
                    let r = await appState.migrator.restore(
                        app: app, from: drive.mountPoint) { _, _ in }
                    return (r.success, r.error)
                }
            }
            for app in nativeApps {
                await runRestore(app.name) { [weak appState] in
                    guard let appState else { return (false, "状态丢失") }
                    let r = await appState.migrator.moveBackToInternal(
                        app: app, drivePath: drive.mountPoint) { _, _ in }
                    return (r.success, r.error)
                }
            }
            for item in dataItems {
                await runRestore(item.title) { [weak appState] in
                    guard let appState else { return (false, "状态丢失") }
                    let r = await appState.dataMigrator.restoreData(
                        item: item, drivePath: drive.mountPoint) { _, _ in }
                    return (r.success, r.error)
                }
            }

            appState.migrationTask = nil
            await appState.scanApps()

            if failures.isEmpty {
                AuditLog.append("盘退休：\(totalCount) 项全部迁回「\(drive.name)」")
                let clean = NSAlert()
                clean.messageText = "全部迁回完成（\(totalCount) 项）"
                clean.informativeText = "要把盘上的随手迁目录也清掉吗？（迁移备份与外置数据正本，共两类目录；确认盘上没有你还需要的其他文件后再清）"
                clean.addButton(withTitle: "清掉随手迁目录")
                clean.addButton(withTitle: "保留")
                clean.alertStyle = .warning
                if clean.runModal() == .alertFirstButtonReturn {
                    let checker = HealthChecker()
                    // 忽略返回值会造成"审计日志说清掉了、实际还在盘上"的假成功
                    // 跨盘备份：备份可能在指定盘上，各根目录都清
                    var notTrashed: [String] = []
                    var backupDirs = BackupLocations.backupRoots(for: drive.mountPoint)
                    backupDirs.append(DataMigrator.dataRoot(on: drive.mountPoint))
                    for dir in backupDirs {
                        guard FileManager.default.fileExists(atPath: dir) else { continue }
                        if !(await checker.recycleToTrash(dir)) { notTrashed.append(dir) }
                    }
                    AuditLog.append(notTrashed.isEmpty
                        ? "盘退休：随手迁目录已入废纸篓"
                        : "盘退休：部分目录未能入废纸篓（\(notTrashed.joined(separator: "、"))）")
                }
            } else {
                let list = failures.prefix(8)
                    .map { "· \($0.name)：\($0.reason)" }
                    .joined(separator: "\n")
                let alert = NSAlert()
                alert.messageText = "迁回完成，但有 \(failures.count) 项未成功"
                alert.informativeText = "\(list)\n\n多半是应用正在运行——退出后再跑一次「盘要退休」即可补齐。"
                alert.runModal()
            }
        }
    }
}
