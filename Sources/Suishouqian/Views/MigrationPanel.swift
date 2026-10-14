import SwiftUI

struct MigrationPanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var batchSummary: String?
    /// 最近一条真实 `MigrationResult` 折出的终态呈现（Task 3）：
    /// 每次真实结果返回后、清除 appState.migrationTask 之前赋值；
    /// 新一轮执行开始时清空。
    @State private var lastOutcome: MigrationOutcome?
    @State private var showPlanSheet = false
    @State private var showHistory = false
    private let dataMigrator = DataMigrator()
    
    var body: some View {
        // 冷静控制台版：唯一主操作（实色 accent 胶囊）+ 状态卡 + 底部任务统计条
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

                    // 唯一主操作（Task 5）：实色 accent「生成安全计划」——
                    // 点击后先进全局计划评审 Sheet，看到完整计划并「确认并开始」才执行
                    if !movableApps.isEmpty && appState.externalDrive != nil {
                        PrimaryActionButton(
                            title: "生成安全计划",
                            systemImage: "doc.text.magnifyingglass",
                            enabled: appState.migrationTask == nil) {
                            migrateAll()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                    }

                    // 当前任务 / 终态结果：统一委托给执行视图
                    // （Task 3：阶段时间线 + 协作式取消 + 成功/取消/失败安全文案面）
                    if appState.migrationTask != nil || lastOutcome != nil {
                        MigrationExecutionView(
                            task: appState.migrationTask,
                            outcome: lastOutcome,
                            onOpenApps: { appState.activePanel = .apps },
                            onShowHistory: { showHistory = true })
                            // Task 5：迁移状态卡统一 10pt 圆角（Theme.Corner.card）
                            // + 细边框/阴影，与评审 Sheet 的卡片同一套静观感
                            .cardStyle()
                    } else if appState.apps.isEmpty || appState.externalDrive == nil {
                        emptyState
                    }

                    if let summary = batchSummary {
                        Text(summary)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                    }

                    // 次级命令（Task 5 降级）：文字 + 发丝描边胶囊，权重一律低于
                    // 唯一主操作；「盘要退休」保留橙色文字以携带既有警告语义
                    if !appState.apps.isEmpty && appState.externalDrive != nil {
                        HStack(spacing: 10) {
                            Button("迁移历史") { showHistory = true }
                                .secondaryCommand()
                            if !migratedApps.isEmpty {
                                Button("全部回迁（\(migratedApps.count) 个）") { restoreAll() }
                                    .secondaryCommand()
                            }
                            Button("一键腾空间…") { showPlanSheet = true }
                                .secondaryCommand()
                                .disabled(appState.volumeStore.onlineVolumes.isEmpty)
                                .help("告诉它想腾出多少空间，引擎自动挑出性价比最高的一批应用并给出理由")
                            Button("盘要退休…") { retireWizard() }
                                .secondaryCommand(tint: MockTheme.statOrange)
                                .help("换盘、卖盘、盘快不行了？把这块盘上由随手迁管理的内容全部迁回内置盘")
                        }
                        .buttonStyle(.borderless)
                        .monospacedDigit()
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
            // 效果图底栏：任务统计（真实口径：待迁移/已迁移/可释放）；数字统一等宽
            MockBottomBar(items: bottomItems(movable: movableApps, migrated: migratedApps))
                .monospacedDigit()
        }
        // Task 4：评审通过的计划唯一消费点。
        // onAppear 覆盖「从别的页面确认后切到迁移页」的挂载场景；
        // onChange 覆盖「已在本页（一键迁移全部）确认」的场景。
        // 取走即置 nil：两条路即使同时触发，也只会有一方拿到非 nil 值，
        // 一份计划恰好执行一次。
        .onAppear { consumeApprovedPlan() }
        .onChange(of: appState.approvedMigrationPlan?.id) { _, _ in consumeApprovedPlan() }
    }

    // 旧 taskCard 已移除（Task 3 Step 4）：无法完全委托给 MigrationExecutionView
    // （进度条、取消控制、状态呈现整体迁入执行视图），按计划整卡替换。

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
            lastOutcome = nil  // 新一轮执行开始：清掉上一条终态结果
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
                // Task 3：真实 MigrationResult 先折成终态呈现（必须在清任务之前）
                lastOutcome = MigrationPlanPresentation.outcome(result: result, appName: app.name)
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
                // Task 5：插画氛围光改用唯一强调色的低饱和紫对，去掉蓝→青竞争性渐变
                gradient: [MockTheme.accent, MockTheme.accent.opacity(0.6)],
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
    
    // 任务标题由 MigrationExecutionView 内部按 task.operation 生成。

    /// 一键迁移全部（Task 4）：跑完既有的 App Store 顾问决策后不再直接执行，
    /// 改为构造评审请求——用户在全局计划 Sheet 看到完整计划并点「确认并开始」，
    /// 摘要才会进入 executeReviewedPlan 的安全执行链。
    private func migrateAll() {
        guard appState.externalDrive != nil else { return }
        let movableApps = appState.apps.filter { $0.status == .normal }

        // App Store 应用迁完会被更新顶掉，批量前一次问清是否跳过（只问一次，不打扰）
        guard let targets = MigrationAdvisor.resolveBatch(movableApps) else { return }
        let skipped = movableApps.count - targets.count
        guard !targets.isEmpty else {
            batchSummary = "已跳过全部 \(skipped) 个 App Store 应用，没有需要迁移的应用"
            return
        }

        appState.migrationPlanRequest = MigrationPlanRequest(apps: targets)
    }

    // MARK: - 计划执行（Task 4）

    /// 评审通过的计划的唯一消费者：取走摘要并置 nil，交给执行链恰好一次。
    private func consumeApprovedPlan() {
        guard let summary = appState.approvedMigrationPlan else { return }
        appState.approvedMigrationPlan = nil
        executeReviewedPlan(summary)
    }

    /// 评审通过的执行链：沿用旧批量迁移的同一套串行安全链（逐应用重跑护栏 +
    /// journal 埋点 + 协作式取消），入口多了「按当刻状态复查计划」这一道——
    /// 批准与执行之间盘可能被拔、应用可能被升级顶掉、列表可能重新扫描
    /// （重扫会重建 AppItem，id 全换），任一条目在当刻 apps 里对不上号或
    /// 状态已非 .normal，整批拦下、绝不触碰文件系统；
    /// AppMigrator 自身的执行时校验原样保留，兜住批准之后的盘变化。
    private func executeReviewedPlan(_ summary: MigrationPlanSummary) {
        guard appState.migrationTask == nil, !summary.items.isEmpty else { return }

        // 复查不碰文件系统：只对照内存里的当刻列表
        var freshApps: [AppItem] = []
        for item in summary.items {
            guard let app = appState.apps.first(where: { $0.id == item.id }),
                  app.status == .normal else {
                lastOutcome = MigrationOutcome(
                    kind: .failure,
                    title: "计划已过期，未开始迁移",
                    detail: "「\(item.name)」在计划批准后已不可迁移"
                        + "（可能已被迁移、正在运行或列表已重新扫描），"
                        + "本批迁移未开始，未改动任何文件。请重新发起迁移。",
                    spaceSaved: 0)
                return
            }
            freshApps.append(app)
        }

        let total = freshApps.count
        Task { @MainActor in
            var okCount = 0, failCount = 0
            var cancelledName: String?
            lastOutcome = nil  // 新一轮执行开始：清掉上一条终态结果
            for (index, app) in freshApps.enumerated() {
                appState.migrationTask = MigrationTask(app: app, operation: .migrate)

                let appState = self.appState  // 值类型捕获
                // 建链口径与评审明细同源：!prefersNoLink（App Store 类纯搬迁）
                let createLink = !app.updateMechanism.prefersNoLink
                let result = await appState.migrator.migrate(
                    app: app, to: summary.destinationPath, createLink: createLink,
                    cancellationToken: appState.migrationTask?.cancellationToken
                ) { progress, file in
                    Task { @MainActor in
                        // 整批进度 = 已完成个数 + 当前应用进度，再除以总数；
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress(
                            (Double(index) + progress) / Double(total), file)
                    }
                }

                // 真实 MigrationResult 先折成终态呈现（必须在清任务之前）
                lastOutcome = MigrationPlanPresentation.outcome(result: result, appName: app.name)
                if result.success {
                    okCount += 1
                    if var t = appState.migrationTask {
                        t.status = .completed
                        appState.migrationTask = t
                    }
                    appState.notificationManager.notifyMigrationComplete(
                        appName: app.name, spaceSaved: result.spaceSaved)
                } else if result.cancelled {
                    // 取消不算失败：半截副本已清理，源目录未动；
                    // 批量中取消即停，后面的条目不再继续
                    if var t = appState.migrationTask {
                        t.status = .cancelled
                        appState.migrationTask = t
                    }
                    cancelledName = app.name
                    break
                } else {
                    // 普通失败：记录后继续剩余条目（与既有批量行为一致）
                    failCount += 1
                    if var t = appState.migrationTask {
                        t.status = .failed(result.error ?? "未知错误")
                        appState.migrationTask = t
                    }
                    appState.notificationManager.notifyMigrationFailed(
                        appName: app.name, error: result.error ?? "未知错误")
                }
            }

            // 取消的汇总绝不使用成功口径
            if let cancelledName {
                batchSummary = "已取消「\(cancelledName)」的迁移，本批其余条目未开始"
            } else {
                batchSummary = failCount == 0
                    ? "批量迁移完成：\(okCount) 个全部成功"
                    : "批量迁移结束：\(okCount) 成功 / \(failCount) 失败"
            }
            appState.migrationTask = nil
            await appState.scanApps()
        }
    }
    
    private func restoreAll() {
        guard let drive = appState.externalDrive else { return }
        let migratedApps = appState.apps.filter { $0.status == .migrated }

        Task { @MainActor in
            lastOutcome = nil  // 新一轮执行开始：清掉上一条终态结果
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

                // Task 3：真实 MigrationResult 先折成终态呈现（必须在清任务之前）
                lastOutcome = MigrationPlanPresentation.outcome(result: result, appName: app.name)
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
            lastOutcome = nil  // 该向导不走 MigrationResult 口径，清掉旧结果卡防残留

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
