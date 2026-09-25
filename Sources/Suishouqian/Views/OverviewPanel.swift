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

    private let checker = HealthChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

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
        let targetPanel: Int?
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
                targetPanel: 2, targetLabel: "去修复"))
        }

        if let drive = appState.externalDrive {
            let movable = appState.apps.filter { $0.status == .normal && !$0.isSystemApp }
            let savable = movable.reduce(0) { $0 + $1.size }
            if !movable.isEmpty {
                out.append(ActionItem(
                    icon: "arrow.up.arrow.down", color: .teal,
                    title: "把 \(movable.count) 个内置盘应用搬到「\(drive.name)」",
                    detail: "可腾出内置盘 \(ByteCountFormatter.string(fromByteCount: savable, countStyle: .file))",
                    targetPanel: 1, targetLabel: "去迁移"))
            }
        }

        if !usageSuggestions.isEmpty {
            out.append(ActionItem(
                icon: "speedometer", color: .orange,
                title: "\(usageSuggestions.count) 个高频应用住在外置盘",
                detail: "近 7 天经常启动却要靠外置盘，建议搬回内置盘",
                targetPanel: 2, targetLabel: "去处理"))
        }

        if !unusedApps.isEmpty {
            out.append(ActionItem(
                icon: "moon.zzz", color: .indigo,
                title: "\(unusedApps.count) 个外置盘应用长期未用",
                detail: "超过 \(UnusedAppsCheck.unusedDays) 天没打开，搬回内置盘把盘面腾出来",
                targetPanel: 2, targetLabel: "去处理"))
        }

        if !launchAgents.isEmpty {
            out.append(ActionItem(
                icon: "powerplug.fill", color: .orange,
                title: "\(launchAgents.count) 条开机自启指向外置盘",
                detail: "盘没插时这些自启会失败，守护项开机必失败",
                targetPanel: 2, targetLabel: "去看看"))
        }

        if spotlightIndexing == true {
            out.append(ActionItem(
                icon: "magnifyingglass", color: .orange,
                title: "Spotlight 正在索引外置盘",
                detail: "搜索会混入外置副本，后台扫描白耗盘和电",
                targetPanel: 2, targetLabel: "去关闭"))
        }

        if !backups.isEmpty {
            let bytes = backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
            out.append(ActionItem(
                icon: "clock.badge.exclamationmark", color: .orange,
                title: "\(backups.count) 份迁移备份可清理",
                detail: "孤儿或超过保留期，共 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))",
                targetPanel: 2, targetLabel: "去清理"))
        }

        if !residues.isEmpty {
            let bytes = residues.reduce(Int64(0)) { $0 + $1.sizeBytes }
            out.append(ActionItem(
                icon: "trash.slash", color: .purple,
                title: "\(residues.count) 项已卸载应用残留",
                detail: "占着内置盘 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))，清理走废纸篓",
                targetPanel: 2, targetLabel: "去清理"))
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
        Task.detached {
            // 与体检页同一套子进程慢活（du/find/mdls/mdutil/diskutil）：OffPool
            let snapshot = await OffPool.run { () -> CheckResult in
                var r = CheckResult()
                _ = checker.healBrokenLinks()
                r.links = checker.checkLinks()
                if let drive {
                    r.backups = checker.checkBackups(drivePath: drive)
                    r.spotlightIndexing = SpotlightCheck.status(for: drive)
                }
                r.residues = checker.checkResidues(drivePath: drive)
                r.launchAgents = checker.checkLaunchAgents()
                r.unusedApps = UnusedAppsCheck.scanSync(apps: apps)
                return r
            }
            await MainActor.run {
                links = snapshot.links
                backups = snapshot.backups
                residues = snapshot.residues
                launchAgents = snapshot.launchAgents
                spotlightIndexing = snapshot.spotlightIndexing
                unusedApps = snapshot.unusedApps
                isChecking = false
            }
        }
    }

    private struct CheckResult {
        var links: [LinkHealth] = []
        var backups: [BackupIssue] = []
        var residues: [ResidueItem] = []
        var launchAgents: [LaunchAgentIssue] = []
        var spotlightIndexing: Bool?
        var unusedApps: [UnusedAppInfo] = []
    }
}
