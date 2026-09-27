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
    /// 最近操作（v3.0 OperationJournal）：只读陈列，撤销执行链另批接入
    @State private var recentOps: [JournalEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if let score = healthScore {
                    healthCard(score)
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

    private var header: some View {
        HStack {
            SectionHeader(title: "总览", systemImage: "list.clipboard")
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button("重新检查") { runCheck() }
                    .controlSize(.small)
            }
        }
    }

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
            healthScore = HealthScore.score(HealthScoreInputFactory.input(from: report))
            // 最近操作：journal 是小文件，但仍是磁盘读，按铁律走 OffPool
            recentOps = await OffPool.run { OperationJournal.shared.recent(limit: 10) }
            isChecking = false
        }
    }

    // MARK: - 健康分卡

    private func healthCard(_ score: HealthScore.Result) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(scoreColor(score.score).opacity(0.2), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(score.score) / 100)
                    .stroke(scoreColor(score.score), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score.score)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("外置盘健康分 · \(score.grade)")
                    .font(.system(size: 13, weight: .medium))
                if let action = score.topAction {
                    Text(action)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Text("断链、备份、残留、链路都查过了，没有扣分项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("去体检") { appState.activePanel = .health }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .cardStyle()
    }

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
