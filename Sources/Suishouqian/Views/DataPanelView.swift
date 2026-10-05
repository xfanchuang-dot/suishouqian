import SwiftUI

/// 数据面板：已知大数据目录的迁移（原生搬迁指引 / 链接迁移）+ 离线分叉对账
struct DataPanelView: View {
    @EnvironmentObject var appState: AppState

    @State private var items: [DataMigrator.DataLocationItem] = []
    @State private var customItems: [DataMigrator.DataLocationItem] = []
    @State private var divergences: [DataMigrator.DataDivergence] = []
    @State private var isScanning = false
    @State private var activeTaskTitle: String?
    @State private var lastError: String?
    /// 备份总量（所有在线外置卷 .suishouqian-backup 目录的真实大小）
    @State private var backupBytes: Int64 = 0
    /// 备份问题项（孤儿/超期，来自体检引擎 overview 口径）
    @State private var backupIssues: [BackupIssue] = []

    private let dataMigrator = DataMigrator()

    /// 清单条目 + 已迁移的自选文件夹（排在后面）
    private var displayItems: [DataMigrator.DataLocationItem] { items + customItems }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // —— 效果图：数据存储概览（三色分段条 + 圆点图例，全部真实口径）——
                    MockPageTitle(text: "数据存储概览")
                    storageOverview

                    // —— 效果图：备份记录（真实问题项；清理入口在体检页，单一破坏性入口原则）——
                    backupSection

                    header
                    hint

                    if !divergences.isEmpty { divergenceSection }

                    ForEach(displayItems) { item in
                        row(item)
                    }

                    if displayItems.isEmpty && !isScanning {
                        emptyState
                    }

                    if let error = lastError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { rescan() }

            Divider().padding(.horizontal, 4)
            // 效果图底栏摘要（真实口径）
            MockBottomBar(items: bottomItems)
        }
    }

    // MARK: - 数据存储概览（效果图三段条）

    /// 三段：迁移备份（蓝）/ 台账管理的应用数据（紫）/ 其他数据（绿，= 外置盘已用 − 前两项）
    private var storageOverview: some View {
        let dataBytes = displayItems.filter(\.managedByUs).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let externalUsed = appState.externalDrive.map { $0.totalSize - $0.freeSize } ?? 0
        let otherBytes = max(externalUsed - backupBytes - dataBytes, 0)
        let segments = [
            MockSegment(label: "迁移备份", bytes: backupBytes,
                        color: Color(red: 0.23, green: 0.51, blue: 0.96)),
            MockSegment(label: "应用数据", bytes: dataBytes, color: MockTheme.accent),
            MockSegment(label: "其他数据", bytes: otherBytes,
                        color: Color(red: 0.20, green: 0.78, blue: 0.55)),
        ]
        return VStack(alignment: .leading, spacing: 14) {
            MockSegmentedBar(segments: segments)
            HStack(spacing: 20) {
                ForEach(segments) { seg in
                    HStack(spacing: 6) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text("\(seg.label) \(seg.formatted)")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - 备份记录（效果图行样式：图标方块 + 标题/副标题 + 大小 + 箭头）

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("备份记录")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                if !backupIssues.isEmpty {
                    Button("清理残留") { appState.activePanel = .health }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 0.90, green: 0.35, blue: 0.45))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().strokeBorder(
                                Color(red: 0.90, green: 0.35, blue: 0.45).opacity(0.6),
                                lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                        .help("去体检页清理（破坏性操作全软件只保留一个入口）")
                }
            }

            if backupIssues.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(MockTheme.healthGreen)
                    Text(backupBytes > 0
                         ? "备份健康：没有孤儿或超期备份需要清理"
                         : "还没有迁移备份，第一次迁移后会自动留底")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .mockCard()
            } else {
                ForEach(backupIssues) { issue in
                    HStack(spacing: 12) {
                        MockIconSquare(
                            systemImage: "doc.fill",
                            color: issue.isOrphan ? MockTheme.accent : MockTheme.healthGreen,
                            size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.appName)
                                .font(.system(size: 15, weight: .semibold))
                            Text(issue.isOrphan
                                 ? "孤儿备份（应用已不在）· \(issue.ageDays) 天前"
                                 : "超过保留期 · \(issue.ageDays) 天前")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(issue.sizeFormatted)
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .mockCard(padding: 14)
                    .contentShape(Rectangle())
                    .onTapGesture { appState.activePanel = .health }
                }
            }
        }
    }

    private var bottomItems: [String] {
        let releasable = backupIssues.reduce(Int64(0)) { $0 + $1.sizeBytes }
        var items = [
            "共 \(backupIssues.count) 条待清理备份",
            "备份占用 \(ByteCountFormatter.string(fromByteCount: backupBytes, countStyle: .file))",
        ]
        if releasable > 0 {
            items.append("可释放 \(ByteCountFormatter.string(fromByteCount: releasable, countStyle: .file))")
        }
        return items
    }

    private var header: some View {
        HStack {
            SectionHeader(title: "应用数据", systemImage: "shippingbox")
            Spacer()
            if isScanning || activeTaskTitle != nil {
                ProgressView().controlSize(.small)
                Text(activeTaskTitle ?? "扫描中...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Button("迁移其他文件夹…") { pickAndMigrateCustomFolder() }
                    .controlSize(.small)
                Button("重新扫描") { rescan() }
                    .controlSize(.small)
            }
        }
    }

    private var hint: some View {
        Text("列出已知安全的数据目录，优先用应用自带的位置设置（零风险），苹果没给入口的才用链接迁移；也可以用「迁移其他文件夹」自选库外的大文件夹（≥100MB），系统目录、资源库、桌面/文稿/下载会被拦下。浏览器、聊天工具等日常热用的数据不建议搬。")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ item: DataMigrator.DataLocationItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.teal)
                    .font(.system(size: 12))

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))

                Text(item.sizeDisplay)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer()

                if item.managedByUs {
                    if item.linkBroken {
                        StatusPill("硬盘未连接", systemImage: "externaldrive.badge.exclamationmark",
                                   color: .orange)
                    } else {
                        StatusPill("已链接迁移", systemImage: "link", color: .green)
                    }
                } else if item.isSymlink {
                    StatusPill("已是链接", systemImage: "link", color: .secondary)
                } else if item.ownerRunning {
                    StatusPill("应用运行中", systemImage: "bolt.fill", color: .orange)
                }

                actionButtons(item)
            }

            Text(item.path)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let note = item.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if case .symlink = item.relocation,
               !item.isSymlink, !item.managedByUs, !item.isWorthMigrating {
                Text("体积小于 100MB，不值得迁移")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .cardStyle()
    }

    @ViewBuilder
    private func actionButtons(_ item: DataMigrator.DataLocationItem) -> some View {
        let busy = isScanning || activeTaskTitle != nil

        switch item.relocation {
        case .native(_, let launchAppName):
            Button("搬迁指引") { showNativeGuide(item, launchAppName: launchAppName) }
                .controlSize(.small)
                .disabled(busy)
            if item.managedByUs {
                Button("回迁") { restoreData(item) }
                    .controlSize(.small)
                    .disabled(busy)
            }
        case .symlink:
            // 只回迁我们自己接管的链接；用户自建链接（非台账管理）一律不碰
            if item.managedByUs {
                Button("回迁") { restoreData(item) }
                    .controlSize(.small)
                    .disabled(busy)
            } else if !item.isSymlink {
                Button("迁移到外置盘") { migrateData(item) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busy || !item.isWorthMigrating || item.ownerRunning
                              || appState.externalDrive == nil)
            }
        }
    }

    // MARK: - 离线分叉对账

    private var divergenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "数据分叉", systemImage: "arrow.triangle.branch")
                Spacer()
                Text("拔盘期间应用重建了目录，插回后两边都有数据")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(divergences) { divergence in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(divergence.title)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button("以外置盘为准（本地改名隔离）") { isolate(divergence) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }

            Text("处置会把本地重建的目录改名为「××（离线重建 日期）」留在原地，链接恢复指向外置盘；两边的合并请自行确认后手动处理，工具不做自动合并。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28))
                .foregroundStyle(MockTheme.accent)
            Text("没有发现可处理的数据目录")
                .font(.system(size: 13, weight: .semibold))
            Text("装了剪映、LM Studio、Docker 等应用后，这里会自动出现搬迁入口")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            // 6.6（Muse 审查）：扫描失败与"真没有"共用空状态，必须给重试动作
            Button("重新扫描") { rescan() }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(isScanning)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Actions

    private func rescan() {
        isScanning = true
        lastError = nil
        let drive = appState.externalDrive?.mountPoint
        let apps = appState.apps
        let mounts = appState.volumeStore.onlineVolumes.map { $0.info.mountPoint }
        Task {
            // 6.6（Muse 审查）：heal 是同步 IO，OffPool 包一层，不占协作线程池
            _ = await OffPool.run { dataMigrator.healDataLinks() }
            let scanned = await dataMigrator.scanDataLocations()
            let custom = await dataMigrator.scanCustomItems()
            let diverged = await dataMigrator.checkDivergences()
            // 效果图「数据存储概览」需要备份真实总量：逐卷扫 .suishouqian-backup（IO 走 OffPool）
            let backupTotal = await OffPool.run {
                mounts.flatMap { BackupLocations.backupRoots(for: $0) }
                    .reduce(Int64(0)) { $0 + AppScanner.directorySizeBytes(atPath: $1) }
            }
            // 备份问题项：与总览同一引擎口径（overview scope 含备份检查，跳过最慢的两项）
            let report = await appState.checkEngine.run(drivePath: drive, apps: apps, scope: .overview)
            // @State 必须主线程写：Task 里的 await 会把续体切到协作池，
            // 原 MainActor.run 不是多余的（自审：替换 rescan 时曾被误删）
            await MainActor.run {
                items = scanned
                customItems = custom
                divergences = diverged
                backupBytes = backupTotal
                backupIssues = report.backups
                isScanning = false
            }
        }
    }

    // MARK: - 自选文件夹迁移（v2.11.0）

    /// 选一个库外大文件夹迁到外置盘。护栏在 migrateCustomFolder 里，
    /// 这里只负责选目录、知情确认与进度显示。
    private func pickAndMigrateCustomFolder() {
        guard let drive = appState.externalDrive, activeTaskTitle == nil,
              !isScanning, !appState.isMigrationActive else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要搬到外置盘的文件夹（≥100MB；系统目录、资源库、桌面/文稿/下载会被拦下）"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path

        let alert = NSAlert()
        alert.messageText = "把这个文件夹搬到外置盘？"
        alert.informativeText = """
        \(path)

        将复制到外置盘、校验后在原位置建链接指回外置盘，原件留底可回滚。
        迁移前请确认没有程序正在往这个文件夹写数据。
        """
        alert.addButton(withTitle: "开始迁移")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beginDataTask("迁移 自选 · \(url.lastPathComponent)...", operation: .migrate)
        Task { @MainActor in
            let result = await dataMigrator.migrateCustomFolder(
                at: path, drivePath: drive.mountPoint) { _, _ in }
            finishDataTask(error: result.success ? nil : result.error)
            rescan()
        }
    }

    private func showNativeGuide(_ item: DataMigrator.DataLocationItem,
                                 launchAppName: String?) {
        guard case .native(let guide, _) = item.relocation else { return }
        let alert = NSAlert()
        alert.messageText = "「\(item.title)」搬迁指引"
        alert.informativeText = guide + "\n\n让应用自己搬最稳：不建链接、升级不怕、拔盘不分叉。搬完回到这里重新扫描，确认旧位置已清空。"
        alert.addButton(withTitle: launchAppName != nil ? "打开应用" : "知道了")
        if launchAppName != nil { alert.addButton(withTitle: "关闭") }
        let result = alert.runModal()

        if result == .alertFirstButtonReturn, let launchAppName {
            launchApp(named: launchAppName)
            AuditLog.append("原生搬迁指引：\(item.title)（已打开 \(launchAppName)）")
        } else {
            AuditLog.append("原生搬迁指引：\(item.title)")
        }
    }

    /// 打开应用（open -a 按名字解析，外置盘软链应用也能找到）
    private func launchApp(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            process.waitUntilExit()
        }
    }

    private func migrateData(_ item: DataMigrator.DataLocationItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        let alert = NSAlert()
        alert.messageText = "迁移「\(item.title)」到外置硬盘"
        alert.informativeText = """
        将复制 \(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) 到外置盘，校验通过后在原位置建链接，原件留底可回滚。
        请确认相关应用当前没有正在写入数据。
        """
        alert.addButton(withTitle: "开始迁移")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beginDataTask("迁移 \(item.title)...", operation: .migrate)
        Task { @MainActor in
            let result = await dataMigrator.migrateData(
                item: item, drivePath: drive.mountPoint) { _, _ in }
            finishDataTask(error: result.success ? nil : result.error)
            rescan()
        }
    }

    private func restoreData(_ item: DataMigrator.DataLocationItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        // 与迁移方向补上对称的知情确认：回迁会先摘掉原位置的链接，
        // 期间属主应用若在运行，它新建/写入的数据会被复制流程的 removeItem 直接删掉
        let alert = NSAlert()
        alert.messageText = "把「\(item.title)」回迁到内置盘？"
        alert.informativeText = """
        将删除原位置的链接，把外置盘上的数据复制回内置盘，校验通过后清理外置副本。
        回迁期间请勿使用相关应用（属主应用正在运行时，工具会直接拒绝回迁）。
        """
        alert.addButton(withTitle: "开始回迁")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        beginDataTask("回迁 \(item.title)...", operation: .restore)
        Task { @MainActor in
            let result = await dataMigrator.restoreData(
                item: item, drivePath: drive.mountPoint) { _, _ in }
            finishDataTask(error: result.success ? nil : result.error)
            rescan()
        }
    }

    // MARK: - 数据任务与全局任务状态

    /// 数据任务同样要占用 `AppState.migrationTask`。这不是界面装饰：
    /// 它是 ①强退保护（迁移中退出会二次确认）②与迁移页互斥 的唯一依据。
    /// 此前数据面板只设自己的 activeTaskTitle，于是可以边搬 200GB 数据边发起应用迁移，
    /// 数据搬迁期间强退也不受任何拦截。
    private func beginDataTask(_ title: String,
                               operation: MigrationTask.MigrationOperation) {
        activeTaskTitle = title
        let placeholder = AppItem(name: title, bundleName: "data.task", path: "",
                                  version: nil, size: 0, isSymlink: false,
                                  symlinkTarget: nil, icon: nil)
        appState.migrationTask = MigrationTask(app: placeholder, operation: operation)
    }

    private func finishDataTask(error: String?) {
        activeTaskTitle = nil
        appState.migrationTask = nil
        if let error { lastError = error }
    }

    private func isolate(_ divergence: DataMigrator.DataDivergence) {
        let alert = NSAlert()
        alert.messageText = "数据分叉处置"
        alert.informativeText = """
        将把本地重建的「\(divergence.title)」改名隔离（保留在原地），链接恢复指向外置盘正本。
        如果你离线期间产生的数据更重要，请先手动备份，或选择暂不处置。
        """
        alert.addButton(withTitle: "以外置盘为准")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if dataMigrator.isolateDivergence(divergence) {
            divergences.removeAll { $0.id == divergence.id }
        } else {
            lastError = "分叉隔离失败（目录可能被占用）"
        }
    }
}
