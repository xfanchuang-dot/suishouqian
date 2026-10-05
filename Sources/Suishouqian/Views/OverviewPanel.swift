import SwiftUI

/// 总览（v2.12.0）：把体检/迁移/数据三个面板的结论收拢成一张待办清单。
///
/// 设计取舍（安全优先）：总览负责"陈列 + 直达"，一键直达对应面板；
/// 涉及删除/移动数据的操作（备份清理、残留清理、搬回）仍只在原面板执行——
/// 破坏性动作全软件只保留一个入口，避免两处代码各自演化出不同的确认与回滚行为。
struct OverviewPanel: View {
    @EnvironmentObject var appState: AppState

    @State private var links: [LinkHealth] = []
    @State private var backups: [BackupIssue] = []
    @State private var residues: [ResidueItem] = []
    @State private var launchAgents: [LaunchAgentIssue] = []
    @State private var spotlightIndexing: Bool?
    @State private var usageSuggestions: [UsageSuggestion] = []
    @State private var unusedApps: [UnusedAppInfo] = []
    @State private var isChecking = false
    /// 健康分（v3.0）：总览检查跑完顺带出分，只读派生
    @State private var healthScore: HealthScore.Result?
    /// 最近操作（v3.0 OperationJournal）：时间线 + 撤销按钮
    @State private var recentOps: [JournalEntry] = []
    /// 每条操作的撤销可行性（runCheck 时统一在 OffPool 算好，key=entry.id）
    @State private var undoPlans: [UUID: UndoPlanner.UndoPlan] = [:]
    /// TM 重复备份待排除的目录（nil=还没查过）
    @State private var tmMissingDirs: [String]?
    @State private var tmDismissed = UserDefaults.standard.bool(forKey: "tmExclusionDismissed")
    @State private var isUndoing = false
    @State private var isExcludingTM = false

    /// 外置盘测速状态（概览页磁盘卡内嵌，DiskBarView 的轻量版）
    @State private var overviewSpeedText: String?
    @State private var overviewSpeedRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // —— 效果图头部：大标题 + 双盘卡 + 三统计卡 + 健康评分横幅 ——
                titleRow
                diskCardsRow
                statCardsRow
                if let score = healthScore {
                    healthBanner(score)
                }

                if let missing = tmMissingDirs, !missing.isEmpty, !tmDismissed {
                    tmCard(missing)
                }

                if isChecking {
                    Text("正在检查……")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                } else if actions.isEmpty {
                    allClear
                } else {
                    ForEach(actions) { action in
                        row(action)
                    }
                }

                if !recentOps.isEmpty {
                    timelineSection
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { runCheck() }
        // 附录 A4→6.4：在体检页修完断链切回来，待办必须是最新的，不是上次的快照
        .onChange(of: appState.activePanel) { _, panel in
            if panel == .overview { runCheck() }
        }
    }

    // MARK: - 效果图头部组件

    private var titleRow: some View {
        HStack {
            MockPageTitle(text: "概览")
            if isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button { runCheck() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新检查")
            }
        }
    }

    /// 双盘卡（效果图：内置盘紫条 / 外置盘绿条，已用百分比 + 用量/总量）
    private var diskCardsRow: some View {
        HStack(spacing: 16) {
            if let builtin = appState.builtinDrive {
                diskCard(
                    icon: "internaldrive.fill", iconColor: MockTheme.accent,
                    name: "内置磁盘",
                    detail: "已用 \(Int(builtin.usageRatio * 100))% · \(usedText(builtin)) / \(builtin.totalFormatted)",
                    ratio: builtin.usageRatio, bar: MockTheme.builtinBar)
            }
            if let external = appState.externalDrive {
                externalDiskCard(external)
            } else {
                diskCard(
                    icon: "externaldrive.badge.exclamationmark", iconColor: .secondary,
                    name: "外置盘未连接",
                    detail: "接入后这里显示用量与剩余空间",
                    ratio: 0, bar: MockTheme.externalBar)
            }
        }
    }

    private func usedText(_ drive: DriveInfo) -> String {
        ByteCountFormatter.string(fromByteCount: drive.totalSize - drive.freeSize, countStyle: .file)
    }

    private func diskCard(icon: String, iconColor: Color, name: String,
                          detail: String, ratio: Double, bar: LinearGradient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MockIconSquare(systemImage: icon, color: iconColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            MockUsageBar(ratio: ratio, gradient: bar, height: 10)
        }
        .mockCard()
    }

    /// 外置盘卡（含测速按钮）：新 UI 下 DiskBarView 只在体检页，概览页需要测速入口
    private func externalDiskCard(_ drive: DriveInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                MockIconSquare(systemImage: "externaldrive.fill", color: MockTheme.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("已用 \(Int(drive.usageRatio * 100))% · \(usedText(drive)) / \(drive.totalFormatted)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // 测速按钮
                Button {
                    runOverviewSpeedTest(mount: drive.mountPoint)
                } label: {
                    HStack(spacing: 4) {
                        if overviewSpeedRunning {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                                .font(.system(size: 11))
                        }
                        Text(overviewSpeedRunning ? "测速中" : "测速")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(overviewSpeedRunning)
                .help("实测外置盘读写速度（写入几百 MB，需几秒）")
            }
            MockUsageBar(ratio: drive.usageRatio, gradient: MockTheme.externalBar, height: 10)
            if let speed = overviewSpeedText {
                Text(speed)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .mockCard()
    }

    private func runOverviewSpeedTest(mount: String) {
        guard !mount.isEmpty, !overviewSpeedRunning else { return }
        overviewSpeedRunning = true
        overviewSpeedText = nil
        Task {
            let result = await OffPool.run { DiskSpeedTest.run(mountPoint: mount) }
            await MainActor.run {
                overviewSpeedRunning = false
                overviewSpeedText = result.map {
                    "写入 \(Int($0.writeMBps)) · 读取 \(Int($0.readMBps)) MB/s"
                } ?? "测速失败（盘可能只读或已满）"
                // 与体检页 DiskBarView 的测速同口径：喂速度基线（塌陷告警靠样本）
                if let result,
                   let uuid = appState.volumeStore.volumes
                       .first(where: { $0.info.mountPoint == mount })?.id {
                    VolumeSpeedBaseline.record(volumeUUID: uuid, readMBps: result.readMBps)
                }
            }
        }
    }

    /// 三统计卡（效果图：图标方块 + 大数字 + 小标签）
    private var statCardsRow: some View {
        let offInternal = appState.apps.filter {
            $0.status == .migrated || $0.status == .externalOnly
        }.count
        let savable = appState.apps.filter { $0.status == .normal }.reduce(0) { $0 + $1.size }
        return HStack(spacing: 16) {
            statCard(icon: "square.grid.2x2.fill", color: MockTheme.accent,
                     value: "\(appState.apps.count)", unit: nil, label: "应用总数")
            statCard(icon: "arrow.up.right", color: MockTheme.statOrange,
                     value: "\(offInternal)", unit: nil, label: "已迁移")
            statCard(icon: "leaf.fill", color: MockTheme.healthGreen,
                     value: Self.shortValue(savable), unit: Self.shortUnit(savable), label: "可省空间")
        }
    }

    /// 统计卡的体积值：数字与单位分离（"9.3"+"GB"），数字保持 26pt 不被压缩，
    /// 解决"9.28 GB"长文本被 minimumScaleFactor 压小导致三卡字号不齐
    private static func shortValue(_ bytes: Int64) -> String {
        bytes >= 1_073_741_824
            ? String(format: "%.1f", Double(bytes) / 1_073_741_824)
            : "\(bytes / 1_048_576)"
    }

    private static func shortUnit(_ bytes: Int64) -> String {
        bytes >= 1_073_741_824 ? "GB" : "MB"
    }

    private func statCard(icon: String, color: Color, value: String, unit: String?, label: String) -> some View {
        VStack(spacing: 8) {
            MockIconSquare(systemImage: icon, color: color, size: 44)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .mockCard()
    }

    /// 健康评分横幅（效果图：浅绿渐变底，盾勾图标 + 标题/副标题 + 右侧大分数）
    private func healthBanner(_ score: HealthScore.Result) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 26))
                .foregroundColor(MockTheme.healthGreen)
            VStack(alignment: .leading, spacing: 3) {
                Text("健康评分")
                    .font(.system(size: 16, weight: .semibold))
                Text(score.topAction ?? "系统运行良好，无异常")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(score.score)分")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(scoreColor(score.score))
                Text("评级 \(score.grade)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: MockTheme.Corner.card, style: .continuous)
                .fill(MockTheme.healthBanner)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MockTheme.Corner.card, style: .continuous)
                .strokeBorder(MockTheme.healthGreen.opacity(0.25))
        )
        .hoverLift()
        .contentShape(Rectangle())
        .onTapGesture { appState.activePanel = .health }
        .help("查看体检明细")
    }

    // MARK: - 建议动作模型

    struct ActionItem: Identifiable {
        let id = UUID()
        let icon: String
        let color: Color
        let title: String
        let detail: String
        /// 目标面板：nil = 无需处理入口（纯提示）
        let targetPanel: Panel?
        let targetLabel: String
    }

    private var actions: [ActionItem] {
        var out: [ActionItem] = []

        let brokenCount = links.filter { $0.state == .broken }.count
        if brokenCount > 0 {
            out.append(ActionItem(
                icon: "link.badge.plus", color: .red,
                title: "\(brokenCount) 条断链",
                detail: "链接指向的应用找不到了（卷在线但目标丢失），可在体检页修复或回迁",
                targetPanel: .health, targetLabel: "去修复"))
        }

        if let drive = appState.externalDrive {
            let movable = appState.apps.filter { $0.status == .normal && !$0.isSystemApp }
            let savable = movable.reduce(0) { $0 + $1.size }
            if !movable.isEmpty {
                out.append(ActionItem(
                    icon: "arrow.up.arrow.down", color: .teal,
                    title: "把 \(movable.count) 个内置盘应用搬到「\(drive.name)」",
                    detail: "可腾出内置盘 \(ByteCountFormatter.string(fromByteCount: savable, countStyle: .file))",
                    targetPanel: .migrate, targetLabel: "去迁移"))
            }
        }

        if !usageSuggestions.isEmpty {
            out.append(ActionItem(
                icon: "speedometer", color: .orange,
                title: "\(usageSuggestions.count) 个高频应用住在外置盘",
                detail: "近 7 天经常启动却要靠外置盘，建议搬回内置盘",
                targetPanel: .health, targetLabel: "去处理"))
        }

        if !unusedApps.isEmpty {
            out.append(ActionItem(
                icon: "moon.zzz", color: .indigo,
                title: "\(unusedApps.count) 个外置盘应用长期未用",
                detail: "超过 \(UnusedAppsCheck.unusedDays) 天没打开，搬回内置盘把盘面腾出来",
                targetPanel: .health, targetLabel: "去处理"))
        }

        if !launchAgents.isEmpty {
            out.append(ActionItem(
                icon: "powerplug.fill", color: .orange,
                title: "\(launchAgents.count) 条开机自启指向外置盘",
                detail: "盘没插时这些自启会失败，守护项开机必失败",
                targetPanel: .health, targetLabel: "去看看"))
        }

        if spotlightIndexing == true {
            out.append(ActionItem(
                icon: "magnifyingglass", color: .orange,
                title: "Spotlight 正在索引外置盘",
                detail: "搜索会混入外置副本，后台扫描白耗盘和电",
                targetPanel: .health, targetLabel: "去关闭"))
        }

        if !backups.isEmpty {
            let bytes = backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
            out.append(ActionItem(
                icon: "clock.badge.exclamationmark", color: .orange,
                title: "\(backups.count) 份迁移备份可清理",
                detail: "孤儿或超过保留期，共 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                targetPanel: .health, targetLabel: "去清理"))
        }

        if !residues.isEmpty {
            let bytes = residues.reduce(Int64(0)) { $0 + $1.sizeBytes }
            out.append(ActionItem(
                icon: "trash.slash", color: .purple,
                title: "\(residues.count) 项已卸载应用残留",
                detail: "占着内置盘 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))，清理走废纸篓",
                targetPanel: .health, targetLabel: "去清理"))
        }

        return out
    }

    // MARK: - 视图

    private func row(_ action: ActionItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(action.color)
                .font(.system(size: 13))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.system(size: 13, weight: .medium))
                Text(action.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if let panel = action.targetPanel {
                Button(action.targetLabel) { appState.activePanel = panel }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent)
            Text("一切正常")
                .font(.system(size: 13, weight: .semibold))
            Text("没有待处理的事项。断链、备份、残留、自启、盘面都检查过了")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - 检查

    private func runCheck() {
        isChecking = true
        let drive = appState.externalDrive?.mountPoint
        let apps = appState.apps
        Task {
            // 总览只要结论项：跳过大文件扫描与回归明细（最慢的两项）
            let report = await appState.checkEngine.run(
                drivePath: drive, apps: apps, scope: .overview)
            links = report.links
            backups = report.backups
            residues = report.residues
            launchAgents = report.launchAgents
            spotlightIndexing = report.spotlightIndexing
            unusedApps = report.unusedApps
            usageSuggestions = report.usageSuggestions
            // v3.0 健康分：同一份报告顺带出分（只读派生，不落历史——落历史只在体检页全量跑时做）
            let usb2Roots = Set(appState.volumeStore.onlineVolumes
                .filter { $0.linkTier == .usb2 }
                .map { HealthScoreInputFactory.volumeRoot(of: $0.info.mountPoint) }
                .compactMap { $0 })
            healthScore = HealthScore.score(
                HealthScoreInputFactory.input(from: report, usb2VolumeRoots: usb2Roots))
            // 最近操作：journal 是小文件，但仍是磁盘读，按铁律走 OffPool
            let ops = await OffPool.run { OperationJournal.shared.recent(limit: 10) }
            recentOps = ops
            undoPlans = await computeUndoPlans(ops)
            // TM 重复备份检查（每目录一次 tmutil 子进程，批量 OffPool）
            if let drive = drive, !tmDismissed {
                tmMissingDirs = await OffPool.run {
                    var missing = TimeMachineCoordinator.missingExclusions(on: drive)
                    // 跨盘备份：备份盘的 .suishouqian-backup 也要排除，
                    // 否则 Time Machine 白白备份备份（只关心备份目录，不碰该盘其它目录）
                    if let altMount = BackupLocations.alternateMountPoint(),
                       altMount != drive {
                        missing += TimeMachineCoordinator.missingExclusions(on: altMount)
                            .filter { $0.hasSuffix(".suishouqian-backup") }
                    }
                    return missing
                }
            }
            isChecking = false
        }
    }

    /// 批量算每条操作的撤销可行性。撤销是 TOCTOU 高发区：这里算的只是"按钮亮不亮"，
    /// 执行前 executor 仍走完整安全链（migrate/restore 内部会再验一遍）
    private func computeUndoPlans(_ ops: [JournalEntry]) async -> [UUID: UndoPlanner.UndoPlan] {
        let runningNames = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let apps = appState.apps
        let builtinFree = appState.builtinDrive?.freeSize ?? 0
        let volumes = appState.volumeStore.volumes   // OffPool 前抓快照
        let onlineUUIDs = Set(volumes.filter(\.isOnline).map(\.id))
        let externalMounts = volumes.filter(\.isOnline).map(\.info.mountPoint)

        return await OffPool.run {
            var out: [UUID: UndoPlanner.UndoPlan] = [:]
            for entry in ops {
                let app = apps.first { $0.bundleName == entry.appName }
                // P1-1c（Muse 审查）：relocate 撤销的空间门槛在源盘（fromUUID），不是主盘
                let externalFree: Int64 = {
                    if entry.op == .relocate, let fromUUID = entry.params["fromUUID"],
                       let origin = volumes.first(where: { $0.id == fromUUID }) {
                        return origin.info.freeSize
                    }
                    return volumes.first { $0.role == .primary }?.info.freeSize
                        ?? appState.externalDrive?.freeSize ?? 0
                }()
                let ctx = UndoPlanner.UndoContext(
                    appRunning: runningNames.contains(
                        (entry.appName as NSString).deletingPathExtension),
                    // 卸载撤销候选定位：家废纸篓 + 各在线外置卷的 .Trashes/<UID>
                    // （外置盘应用卸载后真身进卷废纸篓，只查 ~/.Trash 会几乎永远找不到）
                    trashContainsApp: TrashRecovery.locate(
                        appName: entry.appName, bundleID: entry.params["bundleID"],
                        in: TrashRecovery.roots(externalMounts: externalMounts)) != nil,
                    // P1-1b：副本住在卷的 Applications/ 或 Suishouqian_Apps/ 子目录，不在卷根
                    externalCopyExists: externalMounts.contains { mount in
                        AppMigrator.externalAppDirs.contains {
                            FileManager.default.fileExists(atPath: "\(mount)/\($0)/\(entry.appName)")
                        }
                    } || (app?.symlinkTarget.map { FileManager.default.fileExists(atPath: $0) } ?? false),
                    internalCopyExists: {
                        let p = "/Applications/\(entry.appName)"
                        return FileManager.default.fileExists(atPath: p)
                            && ((try? FileManager.default.destinationOfSymbolicLink(atPath: p)) == nil)
                    }(),
                    linkUsable: app?.isSymlink == true,
                    originVolumeOnline: entry.params["fromUUID"].map { onlineUUIDs.contains($0) } ?? false,
                    internalFreeBytes: builtinFree,
                    externalFreeBytes: externalFree,
                    appSize: app?.size ?? 0)
                out[entry.id] = UndoPlanner.plan(entry: entry, context: ctx)
            }
            return out
        }
    }

    // MARK: - 健康分

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 90...: return .green
        case 70..<90: return .teal
        case 50..<70: return .orange
        default: return .red
        }
    }

    // MARK: - 最近操作时间线（只读陈列）

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "最近操作", systemImage: "clock.arrow.circlepath")
            ForEach(recentOps) { entry in
                HStack(spacing: 10) {
                    Image(systemName: Self.opIcon(entry.op))
                        .foregroundColor(entry.isOK ? .secondary : .red)
                        .font(.system(size: 12))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(Self.opLabel(entry.op)) \(entry.appName)")
                            .font(.system(size: 12, weight: .medium))
                        Text(entry.isOK
                             ? Self.timeText(entry.at)
                             : "\(Self.timeText(entry.at)) · \(entry.result)")
                            .font(.system(size: 10))
                            .foregroundColor(entry.isOK ? .secondary : .red)
                            .lineLimit(1)
                    }

                    Spacer()

                    // 撤销：可行性实时重验过才亮（uninstall 走废纸篓特殊路径也在此列）
                    if let plan = undoPlans[entry.id], plan.feasible,
                       !entry.isUndone, !isUndoing {
                        Button("撤销") { undo(entry) }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help(plan.message)
                    }

                    Circle()
                        .fill(entry.isOK ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .cardStyle()
            }
        }
    }

    // MARK: - TM 重复备份卡

    private func tmCard(_ missing: [String]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "timemachine")
                .foregroundColor(.orange)
                .font(.system(size: 13))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Time Machine 在重复备份外置盘应用")
                    .font(.system(size: 13, weight: .medium))
                Text("建议排除，省备份空间（已有三重保护，不影响恢复）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .help("这些目录在备份盘上还有一整份副本。排除后省的是备份盘空间，"
                + "不影响本机的快照、留底与台账三重保护")

            Spacer()

            if isExcludingTM {
                ProgressView().controlSize(.small)
            } else {
                Button("一键排除") { excludeTM(missing) }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                Button("不再提示") {
                    tmDismissed = true
                    UserDefaults.standard.set(true, forKey: "tmExclusionDismissed")
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle()
    }

    private func excludeTM(_ missing: [String]) {
        isExcludingTM = true
        Task {
            let ok = await TimeMachineCoordinator.authenticatedAddExclusions(missing)
            AuditLog.append(ok
                ? "TM 排除：已为 \(missing.count) 个目录加入 Time Machine 排除"
                : "TM 排除失败（未授权或 tmutil 出错），不影响任何数据")
            if ok { tmMissingDirs = nil } else { tmMissingDirs = missing }
            isExcludingTM = false
        }
    }

    // MARK: - 撤销执行链

    /// 采集实时上下文并执行撤销。撤销本身就是一次受控迁移/回迁，走完整安全链。
    /// P1-2（Muse 审查）：走 migrationTask 通道 + 实时进度回写——几分钟的撤销
    /// 不能让界面毫无动静；TOCTOU 纪律：按钮亮时的 plan 只作展示，执行前重算。
    private func undo(_ entry: JournalEntry) {
        Task { @MainActor in
            let fresh = await computeUndoPlans([entry])
            guard let plan = fresh[entry.id], plan.feasible,
                  appState.migrationTask == nil else { return }
            // 无逆操作的特殊路径：目前只有卸载撤销（废纸篓恢复），不走迁移任务通道
            guard let inverseOp = plan.inverseOp else {
                await undoUninstallFromTrash(entry)
                return
            }
            guard let app = appState.apps.first(where: { $0.bundleName == entry.appName }) else { return }

            let primaryMount = appState.volumeStore.primary?.info.mountPoint
                ?? appState.externalDrive?.mountPoint
            let volumeMounts = Dictionary(uniqueKeysWithValues:
                appState.volumeStore.volumes.map { ($0.id, $0.info.mountPoint) })

            let taskOp: MigrationTask.MigrationOperation
            switch inverseOp {
            case .restore: taskOp = .restore
            case .relocate: taskOp = .relocate
            default: taskOp = .migrate
            }
            appState.migrationTask = MigrationTask(app: app, operation: taskOp)
            let progress: @Sendable (Double, String) -> Void = { pct, file in
                Task { @MainActor in
                    // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                    appState.reportMigrationProgress(pct, file)
                }
            }

            isUndoing = true
            let result: AppMigrator.MigrationResult
            switch inverseOp {
            case .restore:
                guard let from = app.symlinkTarget.map({
                    (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                }) else {
                    appState.migrationTask = nil
                    isUndoing = false
                    return
                }
                result = await appState.migrator.restore(app: app, from: from, progress: progress)
            case .migrate, .moveBack, .remigrate:
                guard let to = primaryMount else {
                    appState.migrationTask = nil
                    isUndoing = false
                    return
                }
                result = await appState.migrator.migrate(
                    app: app, to: to, createLink: true,
                    cancellationToken: appState.migrationTask?.cancellationToken,
                    progress: progress)
            case .relocate:
                guard let origin = entry.params["fromUUID"].flatMap({ volumeMounts[$0] }),
                      let current = entry.params["toUUID"].flatMap({ volumeMounts[$0] }) else {
                    appState.migrationTask = nil
                    isUndoing = false
                    return
                }
                result = await appState.migrator.relocate(
                    app: app, fromVolume: current, toVolume: origin, progress: progress)
            case .uninstall, .undo:
                // 不可达：uninstall 已在入口分流到 undoUninstallFromTrash，
                // .undo 的按钮永不亮。留个防御兜底并说明原因
                appState.migrationTask = nil
                isUndoing = false
                return
            }

            if var t = appState.migrationTask {
                t.status = result.success ? .completed : .failed(result.error ?? "未知错误")
                appState.migrationTask = t
            }
            if result.success {
                let undoID = OperationJournal.shared.record(
                    op: .undo, appName: entry.appName,
                    params: ["undoneID": entry.id.uuidString],
                    result: "ok")
                OperationJournal.shared.markUndone(id: entry.id, by: undoID)
            }
            appState.migrationTask = nil
            refreshTimeline()
            isUndoing = false
        }
    }

    /// 卸载撤销：从废纸篓恢复应用本体到 /Applications。
    /// 不走 migrationTask 通道（恢复通常是同卷 rename，秒级；跨卷也没有细粒度进度可报），
    /// isUndoing 挡并发；成功记 .undo + markUndone，失败弹窗说明原因（废纸篓原件不动）。
    private func undoUninstallFromTrash(_ entry: JournalEntry) async {
        isUndoing = true
        defer { isUndoing = false }
        let mounts = appState.volumeStore.volumes.filter(\.isOnline).map { $0.info.mountPoint }
        let result = await appState.migrator.restoreFromTrash(
            appName: entry.appName, bundleID: entry.params["bundleID"],
            externalMounts: mounts)
        if result.success {
            let undoID = OperationJournal.shared.record(
                op: .undo, appName: entry.appName,
                params: ["undoneID": entry.id.uuidString, "via": "trash"],
                result: "ok")
            OperationJournal.shared.markUndone(id: entry.id, by: undoID)
        } else {
            let alert = NSAlert()
            alert.messageText = "撤销失败"
            alert.informativeText = result.error ?? "未知原因"
            alert.runModal()
        }
        refreshTimeline()
    }

    /// 重载时间线与撤销可行性（撤销成功/失败后立即刷新）
    private func refreshTimeline() {
        Task {
            let ops = await OffPool.run { OperationJournal.shared.recent(limit: 10) }
            recentOps = ops
            undoPlans = await computeUndoPlans(ops)
        }
    }

    private static func opIcon(_ op: JournalOperation) -> String {
        switch op {
        case .migrate: return "arrow.up.arrow.down"
        case .restore: return "arrow.down.circle"
        case .moveBack: return "arrow.uturn.backward"
        case .uninstall: return "trash"
        case .remigrate: return "arrow.clockwise"
        case .relocate: return "externaldrive.connected.to.line.below"
        case .undo: return "arrow.uturn.backward.circle"
        }
    }

    private static func opLabel(_ op: JournalOperation) -> String {
        switch op {
        case .migrate: return "迁移"
        case .restore: return "回迁"
        case .moveBack: return "搬回内置盘"
        case .uninstall: return "卸载"
        case .remigrate: return "重新迁移"
        case .relocate: return "盘间迁移"
        case .undo: return "撤销"
        }
    }

    private static func timeText(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }
}
