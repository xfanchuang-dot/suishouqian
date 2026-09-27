import SwiftUI

struct MigrationPanel: View {
    @EnvironmentObject var appState: AppState
    @State private var batchSummary: String?
    @State private var showPlanSheet = false
    private let dataMigrator = DataMigrator()
    
    var body: some View {
        // v3.0: 包上 ScrollView（与总览/体检/数据三面板一致）——
        // 此前操作按钮越加越多，盘要退休按钮已贴着窗口下沿，新按钮直接被裁掉够不着
        ScrollView {
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

                    Button {
                        retireWizard()
                    } label: {
                        Label("盘要退休…（全部迁回内置盘）",
                              systemImage: "arrow.uturn.backward.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.orange)
                    .disabled(appState.migrationTask != nil)
                    .help("换盘、卖盘、盘快不行了？把这块盘上由随手迁管理的内容全部迁回内置盘")

                    // v3.0 一键腾空间：输入目标 → 方案 → 勾选 → 串行执行（可见性优先，不藏菜单）
                    Button {
                        showPlanSheet = true
                    } label: {
                        Label("一键腾空间…（按方案智能搬迁）",
                              systemImage: "wand.and.stars")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.teal)
                    .disabled(appState.migrationTask != nil
                              || appState.volumeStore.onlineVolumes.isEmpty)
                    .help("告诉它想腾出多少空间，引擎自动挑出性价比最高的一批应用并给出理由")
                }
            }
        }
        .sheet(isPresented: $showPlanSheet) {
            SpaceFreePlanSheet { planned in
                executePlan(planned)
            }
        }
        }
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
                    app: app, to: drivePath, createLink: createLink) { progress, file in
                    Task { @MainActor in
                        guard var t = appState.migrationTask else { return }
                        // 方案整体进度 = 已完成个数 + 当前应用进度，再除以总数
                        t.progress = (Double(index) + progress) / Double(total)
                        t.currentFile = file
                        appState.migrationTask = t
                    }
                }
                if result.success {
                    okCount += 1
                    if var t = appState.migrationTask {
                        t.status = .completed
                        appState.migrationTask = t
                    }
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
                    var notTrashed: [String] = []
                    for dir in ["\(drive.mountPoint)/.suishouqian-backup",
                                DataMigrator.dataRoot(on: drive.mountPoint)] {
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
