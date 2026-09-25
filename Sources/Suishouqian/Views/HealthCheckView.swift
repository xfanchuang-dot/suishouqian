import SwiftUI

/// 链接体检面板：软链接状态一览 + 备份审计 + 一键修复/清理
struct HealthCheckView: View {
    @EnvironmentObject var appState: AppState

    @State private var links: [LinkHealth] = []
    @State private var backups: [BackupIssue] = []
    @State private var residues: [ResidueItem] = []
    @State private var bigFiles: [BigFileItem] = []
    @State private var regressions: [RegressionItem] = []
    @State private var usageSuggestions: [UsageSuggestion] = []
    @State private var launchAgents: [LaunchAgentIssue] = []
    @State private var spotlightIndexing: Bool?
    @State private var unusedApps: [UnusedAppInfo] = []
    @State private var isTogglingSpotlight = false
    @State private var isChecking = false
    @State private var repairedCount = 0
    @State private var healedCount = 0

    private let checker = HealthChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                linkSection
                if !usageSuggestions.isEmpty { usageSection }
                if !unusedApps.isEmpty { unusedSection }
                if !launchAgents.isEmpty { launchAgentSection }
                if spotlightIndexing == true {
                    spotlightSection
                } else if spotlightIndexing == false {
                    spotlightOffSection
                }
                if !regressions.isEmpty { regressionSection }
                if !backups.isEmpty { backupSection }
                if !residues.isEmpty { residueSection }
                if !bigFiles.isEmpty { bigFileSection }
                if links.isEmpty && backups.isEmpty && residues.isEmpty
                    && bigFiles.isEmpty && regressions.isEmpty
                    && usageSuggestions.isEmpty && launchAgents.isEmpty
                    && unusedApps.isEmpty && !isChecking { emptyState }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            runCheck()
            computeUsage()
        }
    }

    private var header: some View {
        HStack {
            SectionHeader(title: "体检", systemImage: "stethoscope")
            Spacer()
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("扫描中...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Button("重新扫描") {
                    runCheck()
                    computeUsage()
                }
                    .controlSize(.small)
            }
        }
    }

    private var summary: (healthy: Int, offline: Int, broken: Int) {
        let healthy = links.filter { $0.state == .healthy }.count
        let offline = links.filter { $0.state == .volumeOffline }.count
        let broken = links.filter { $0.state == .broken }.count
        return (healthy, offline, broken)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let s = summary
            HStack(spacing: 8) {
                StatusPill("\(s.healthy) 正常", systemImage: "checkmark.circle.fill", color: .green)
                StatusPill("\(s.offline) 硬盘未连接", systemImage: "externaldrive.badge.exclamationmark", color: s.offline > 0 ? .orange : .secondary)
                StatusPill("\(s.broken) 断链", systemImage: "link.badge.plus", color: s.broken > 0 ? .red : .secondary)
            }

            if s.broken > 0 {
                Button {
                    repairAll()
                } label: {
                    Label("一键修复断链", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            if repairedCount > 0 {
                Text("上次修复：\(repairedCount) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if healedCount > 0 {
                Text("已按迁移台账自动自愈 \(healedCount) 条（卷改名/换挂载点）")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }

            ForEach(links) { link in
                linkRow(link)
            }
        }
        .cardStyle()
    }

    private func linkRow(_ link: LinkHealth) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: link.state))
                .frame(width: 8, height: 8)

            Text(link.appName.replacingOccurrences(of: ".app", with: ""))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Text(link.state.label)
                .font(.system(size: 11))
                .foregroundColor(color(for: link.state))

            Spacer()

            if link.state == .broken {
                Button("修复") { repairOne(link) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    /// 使用频率顾问（v2.9.0）：近 7 天频繁启动、却住在外置盘上的应用。
    /// 只在打开体检面板时陈列，没有后台扫描、没有主动弹窗。
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "高频应用 · 建议搬回内置盘", systemImage: "speedometer")
                Spacer()
                Text("近 \(LaunchUsageTracker.suggestDays) 天经常启动，却要靠外置盘才能打开（随手迁运行时的启动才会记账）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(usageSuggestions) { sug in
                HStack(spacing: 8) {
                    if let icon = sug.app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    Text(sug.app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("近 \(sug.days) 天启动 \(sug.count) 次 · \(sug.app.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("搬回内置盘") { moveBackExternal(sug.app) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isMigrationActive || appState.externalDrive == nil)
                        .help("搬回后应用就在内置盘本地，不再依赖外置盘")
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    /// 长期未用（v2.12.0）：住在外置盘、很久没打开的应用。
    /// 数据来自系统的 kMDItemLastUsedDate；关了盘的 Spotlight 索引后拿不到，自动跳过。
    private var unusedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "长期未用 · 外置盘", systemImage: "moon.zzz")
                Spacer()
                Text("超过 \(UnusedAppsCheck.unusedDays) 天没打开，占着盘面却想不起来用")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(unusedApps) { info in
                HStack(spacing: 8) {
                    if let icon = info.app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    Text(info.app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("上次打开 \(info.daysSinceUse) 天前 · \(info.app.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("搬回内置盘") { moveBackExternal(info.app) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isMigrationActive || appState.externalDrive == nil)
                        .help("既然不常用，搬回内置盘把外置盘空间腾出来")
                }
                .padding(.vertical, 2)
            }

            Text("数据来自系统记录的最近使用时间。若关闭了这块盘的 Spotlight 索引，系统会停止记账，此处以后将不再出现建议。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    /// 开机自启体检（v2.10.0）：launchd 配置里引用了外置盘的条目。
    /// 只陈列与指路，不代用户删改别的应用的启动配置。
    private var launchAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "开机自启指向外置盘", systemImage: "powerplug.fill")
                Spacer()
                Text("盘没插时这些自启会失败，守护项更是开机必失败")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(launchAgents) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .daemon
                          ? "gearshape.fill" : "person.crop.circle")
                        .foregroundColor(item.volumesOnline ? .orange : .red)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(item.kind.label) → \(item.references.first ?? "")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.verdict.text)
                        .font(.system(size: 11))
                        .foregroundColor(item.verdict.severe ? .red : .orange)
                    Menu("处理") {
                        Button("在 Finder 中显示配置文件") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: item.plistPath)])
                        }
                        Button("打开系统设置 · 登录项") {
                            if let url = URL(string:
                                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("拷贝配置路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.plistPath, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .help("随手迁不代改别人的启动配置：可在登录项设置里关闭，或在 Finder 里自行处理")
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    /// Spotlight 索引指引（v2.10.0）：外置盘被全量索引时给出关闭入口
    private var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Spotlight 正在索引外置盘", systemImage: "magnifyingglass")
                Spacer()
                Button("复制关闭命令") { copySpotlightCommand() }
                    .controlSize(.small)
            }

            Text("搜索应用名时外置盘副本会和内置入口一起出现（两个结果点哪个看运气），后台持续扫描也白耗盘和电。关掉这块盘的索引是外置 SSD 的标准养护；代价是盘上的东西不再出现在 Spotlight 搜索里。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if isTogglingSpotlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("关闭这块盘的索引（需管理员授权）") { toggleSpotlight(false) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .cardStyle()
    }

    /// 索引已关闭态：一行收尾 + 恢复入口（关闭不该是单行道）
    private var spotlightOffSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Spotlight 索引已关闭", systemImage: "checkmark.seal")
                Spacer()
                if isTogglingSpotlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("恢复索引") { toggleSpotlight(true) }
                        .controlSize(.small)
                        .help("恢复后这块盘重新参与 Spotlight 搜索（会重新全盘扫描一段时间）")
                }
            }
            Text("这块盘不参与 Spotlight 搜索，不再被后台扫描（省电护盘）。想恢复随时点上面的按钮。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    /// 升级回退：链接被应用更新器换回真目录（迁移被悄悄撤销）
    private var regressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "迁移被撤销", systemImage: "arrow.uturn.backward.circle")
                Spacer()
                Text("应用升级时替换了链接，内置盘被重新占用")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(regressions) { item in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(item.appName.replacingOccurrences(of: ".app", with: ""))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("重新占用 \(item.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("重新迁移") { remigrate(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("忽略") {
                        checker.ignoreRegression(item)
                        regressions.removeAll { $0.id == item.id }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("备份可清理（孤儿或超过 \(checker.backupRetentionDays) 天）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                Button("全部清理") { cleanAllBackups() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }

            ForEach(backups) { issue in
                HStack {
                    Image(systemName: issue.isOrphan ? "trash.slash" : "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(issue.appName.replacingOccurrences(of: ".app", with: ""))
                        .font(.system(size: 12))
                    Text("\(issue.sizeFormatted) · \(issue.ageDays) 天前\(issue.isOrphan ? " · 应用已卸载" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("删除") {
                        Task { await deleteBackup(issue) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help(issue.isOrphan
                      ? "这个应用在内置盘和外置盘的应用目录里都不存在了（已卸载），这份迁移前备份已经没有用处。删除会移入废纸篓，可恢复。"
                      : "这是迁移「\(issue.appName)」时留的底，已超过保留期。只要应用还能正常打开就可以删。删除会移入废纸篓，可恢复。")
            }
        }
        .cardStyle()
    }

    /// 已卸载应用的 Library 残留（省空间）
    private var residueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "已卸载应用残留", systemImage: "trash.slash")
                Spacer()
                Text("移入废纸篓，可恢复")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(residues) { item in
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.purple)
                        .font(.system(size: 11))
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("\(item.sizeFormatted) · \(item.location)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("清理") { Task { await confirmRecycleResidue(item) } }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help("该目录体积 ≥100MB，且没有任何已安装应用认领它——判断为已卸载应用的残留数据。\n位置：\(item.path)\n不确定是什么时，可先点「显示」去 Finder 里看看再决定。")
            }
        }
        .cardStyle()
    }

    private func confirmRecycleResidue(_ item: ResidueItem) async {
        let alert = NSAlert()
        alert.messageText = "清理应用残留"
        alert.informativeText = "将把「\(item.name)」（\(item.sizeFormatted)）移入废纸篓。它不隶属于任何已安装的应用，如无异常可放心清理。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if await checker.recycleResidue(item) {
            residues.removeAll { $0.id == item.id }
        }
    }

    /// 内置盘大文件（省空间线索）
    private var bigFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = bigFiles.reduce(0) { $0 + $1.sizeBytes }
            HStack {
                SectionHeader(title: "大文件 TOP\(bigFiles.count)", systemImage: "doc.fill")
                Spacer()
                Text("共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
            }

            if !checker.extendedScanEnabled {
                Text("桌面/文稿/下载默认不扫描（避免权限弹窗），当前只扫描「资源库」；需要覆盖全部位置时，到 设置 → 通用 → 「扩展扫描桌面/文稿/下载」开启（开启前先授予完全磁盘访问权限）。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(bigFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.classification.systemManaged
                          ? "lock.shield" : "doc.fill")
                        .foregroundColor(file.classification.systemManaged
                                         ? .secondary : .blue)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(file.classification.label) · \(file.directory)")
                            .font(.system(size: 10))
                            .foregroundColor(file.classification.systemManaged ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.sizeFormatted)
                        .font(.system(size: 11, weight: .semibold))
                    Button("显示") { checker.revealInFinder(file.path) }
                        .controlSize(.small)
                    Button("清理") { Task { await confirmRecycleBigFile(file) } }
                        .controlSize(.small)
                        .disabled(file.classification.systemManaged)
                }
                .padding(.vertical, 2)
                .help(file.classification.systemManaged
                      ? "这是系统管理的数据，随手迁不建议也不允许从这里清理。"
                      : "\(file.path)\n分类：\(file.classification.label)。清理会移入废纸篓，可随时恢复。")
            }
        }
        .cardStyle()
    }

    private func confirmRecycleBigFile(_ file: BigFileItem) async {
        let alert = NSAlert()
        alert.messageText = "清理大文件"
        alert.informativeText = "将把「\(file.name)」（\(file.sizeFormatted)）移入废纸篓，可随时恢复。请确认它不再需要。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if await checker.recycleBigFile(file) {
            bigFiles.removeAll { $0.id == file.id }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent)
            Text("一切正常")
                .font(.system(size: 13, weight: .semibold))
            Text("没有发现断链或可清理的备份")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Actions

    /// 体检快照改为消费 CheckEngine 的 CheckReport（v2.14.0 起编排只此一份）
    private func runCheck() {
        isChecking = true
        let drive = appState.externalDrive?.mountPoint
        let apps = appState.apps
        Task {
            // 引擎内部已把所有子进程慢活放进 OffPool 并行跑，这里只等结果
            let report = await appState.checkEngine.run(
                drivePath: drive, apps: apps, scope: .full)
            links = report.links
            backups = report.backups
            regressions = report.regressions
            residues = report.residues
            bigFiles = report.bigFiles
            launchAgents = report.launchAgents
            spotlightIndexing = report.spotlightIndexing
            unusedApps = report.unusedApps
            usageSuggestions = report.usageSuggestions
            healedCount = report.healedCount
            isChecking = false
        }
    }

    private func deleteBackup(_ issue: BackupIssue) async {
        if await checker.deleteBackup(issue) {
            backups.removeAll { $0.id == issue.id }
        }
    }

    /// 把当前扫描结果与启动记录对上，得出"高频外置盘应用"。
    /// 纯内存计数，不需要 OffPool。
    private func computeUsage() {
        usageSuggestions = LaunchUsageTracker.suggestions(
            apps: appState.apps,
            entries: LaunchUsageTracker.shared.entries
        )
    }

    /// 外置盘原住民/迁移态应用搬回内置盘（流程与 AppRowView.moveBack 一致：
    /// 复制→校验→删外置副本，运行中会被 migrator 拒绝）
    private func moveBackExternal(_ app: AppItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        Task { @MainActor in
            appState.migrationTask = MigrationTask(app: app, operation: .restore)
            let state = appState
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
                // 应用已回内置盘：两个建议分区都要立即摘掉它，不等下次体检
                unusedApps.removeAll { $0.app.path == app.path }
            } else if var t = state.migrationTask {
                t.status = .failed(result.error ?? "未知错误")
                state.migrationTask = t
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
            // 应用已不在外置盘，重新对账——它应当从建议列表里消失
            computeUsage()
        }
    }

    // MARK: - Spotlight 动作（v2.10.0）

    /// 关闭/恢复外置盘索引：先知情确认（改的是系统行为，必须讲清代价），
    /// 再提权执行。osascript 会阻塞等密码输入，放 OffPool 不占协作池。
    private func toggleSpotlight(_ enable: Bool) {
        guard let drive = appState.externalDrive?.mountPoint, !isTogglingSpotlight else { return }
        let alert = NSAlert()
        alert.messageText = enable ? "恢复这块盘的 Spotlight 索引？"
                                   : "关闭这块盘的 Spotlight 索引？"
        alert.informativeText = enable
            ? "恢复后 Spotlight 会重新扫描整块盘（期间盘会持续读写），盘上内容重新可被搜索。"
            : "关闭后，这块盘上的内容不再出现在 Spotlight 搜索结果里，搜索也不再混入外置盘副本；后台扫描停止。想恢复随时可以再来这里操作。"
        alert.addButton(withTitle: enable ? "恢复索引" : "关闭索引")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isTogglingSpotlight = true
        // osascript 会阻塞等用户输密码（可能很久）：必须走 OffPool，
        // Task.detached 占的是协作线程池——那是冻结事故的根因类别
        Task {
            let result = await OffPool.run {
                SpotlightCheck.setIndexing(enable, mountPoint: drive)
            }
            isTogglingSpotlight = false
            if result.success {
                spotlightIndexing = enable
                // 用户主动改了系统行为，进操作台账
                AuditLog.append("Spotlight 索引已\(enable ? "恢复" : "关闭")：\(drive)")
            } else if result.error != "已取消授权" {
                let alert = NSAlert()
                alert.messageText = "没能修改索引设置"
                alert.informativeText = result.error ?? "未知错误"
                alert.runModal()
            }
        }
    }

    private func copySpotlightCommand() {
        guard let drive = appState.externalDrive?.mountPoint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SpotlightCheck.commandLine(enabled: false, mountPoint: drive), forType: .string)
    }

    /// 重新迁移被撤销的应用（镜像 AppRowView 的单应用迁移流程）
    private func remigrate(_ item: RegressionItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        Task { @MainActor in
            var app = appState.apps.first { $0.path == item.appPath }
            if app == nil {
                await appState.scanApps()
                app = appState.apps.first { $0.path == item.appPath }
            }
            guard let app else {
                let alert = NSAlert()
                alert.messageText = "暂时找不到应用信息"
                alert.informativeText = "请回到迁移页等左侧列表扫描完成后再试。"
                alert.runModal()
                return
            }

            // 与迁移页同一套判断：App Store 应用重新迁移后会再次被更新顶掉，先讲清楚
            guard MigrationAdvisor.confirmRelocation(of: app, linkBack: true) else { return }

            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            let state = appState
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
                state.migrationTask = nil
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
            } else {
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
            runCheck()
        }
    }

    private func repairOne(_ link: LinkHealth) {
        if checker.repair(link) {
            runCheck()
            return
        }
        // 修复找不到同名应用：可能不是盘没插，而是更新器把应用本体弄丢了
        //（实测：VS Code 的更新进程写外置盘被系统权限拒绝，旧版移走、新版没写入）
        if let failure = checker.recoverVanishedTarget(link) {
            let alert = NSAlert()
            alert.messageText = "修复失败"
            alert.informativeText = """
            在所有已挂载硬盘上都没有找到「\(link.appName)」，更新缓存里也没有可恢复的新版本。

            \(failure)。请插入对应硬盘、重新安装该应用，或手动回迁。
            """
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "已从更新缓存恢复「\(link.appName.replacingOccurrences(of: ".app", with: ""))」"
            alert.informativeText = """
            这个应用的更新曾中途失败（更新进程写外置盘被系统权限拒绝，应用本体被移走了）。\
            已把更新缓存里的新版本放回原位，链接已接通。

            提示：这类失败与"迁移/纯搬迁"无关，是更新器写外置盘缺权限；\
            若再次发生，可先回迁内置盘完成更新，再迁移出去。
            """
            alert.runModal()
            runCheck()
        }
    }

    private func repairAll() {
        var fixed = 0
        for link in links where link.state == .broken {
            if checker.repair(link) { fixed += 1 }
        }
        repairedCount = fixed
        runCheck()
    }

    /// 全部清理：这是批量动安全底的操作，必须先二次确认
    private func cleanAllBackups() {
        guard !backups.isEmpty else { return }
        let totalBytes = backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let alert = NSAlert()
        alert.messageText = "清理全部 \(backups.count) 份备份？"
        alert.informativeText = """
        合计 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))。\
        这些是迁移应用时留的兜底副本，全部移入废纸篓（可恢复）。

        若某个应用迁移后一直正常，它的备份确实可以清；但备份是出问题时唯一的退路，
        不确定时建议只清「应用已卸载」的孤儿备份。
        """
        alert.addButton(withTitle: "全部移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pending = backups
        Task {
            var removed = Set<UUID>()
            for issue in pending {
                if await checker.deleteBackup(issue) { removed.insert(issue.id) }
            }
            let done = removed
            await MainActor.run {
                backups.removeAll { done.contains($0.id) }
            }
        }
    }

    private func color(for state: LinkHealth.LinkState) -> Color {
        switch state {
        case .healthy: return .green
        case .volumeOffline: return .orange
        case .broken: return .red
        }
    }
}
