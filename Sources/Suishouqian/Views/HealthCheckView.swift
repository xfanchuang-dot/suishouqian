import SwiftUI

/// 链接体检面板：软链接状态一览 + 备份审计 + 一键修复/清理
///
/// v2.15.0 拆分：检查结果与装载在 `HealthCheckModel`；
/// 建议类分区（高频/长期未用/自启/Spotlight）在 HealthCheckView+Advisors.swift；
/// 问题类分区（回归/备份/残留/大文件）及其动作在 HealthCheckView+Issues.swift。
struct HealthCheckView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // model / isTogglingSpotlight / runCheck 被拆出的 extension 文件引用，不能 private
    @StateObject var model = HealthCheckModel()

    /// UI 瞬态（Spotlight 开关进行中、本轮手动修复条数），不进 Model
    @State var isTogglingSpotlight = false
    @State private var repairedCount = 0

    let checker = HealthChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                    .entrance(delay: 0)

                // 核心状态板：链接一览（健康态也是信息，常驻显示）
                linkSection
                    .entrance(delay: 0.05)

                // ── 需要行动：应用/盘处于问题状态，各分区都有修复或恢复动作 ──
                if hasActionItems {
                    groupHeader("需要行动", systemImage: "exclamationmark.circle.fill",
                                tint: .orange)
                        .entrance(delay: 0.08)
                    if !model.regressions.isEmpty { regressionSection.entrance(delay: 0.1) }
                    if model.diskHealth.contains(where: \.isCritical) {
                        diskHealthSection.entrance(delay: 0.12)
                    }
                    if !model.speedAlerts.isEmpty { speedAlertSection.entrance(delay: 0.14) }
                    if !model.lostVolumes.isEmpty { lostVolumeSection.entrance(delay: 0.16) }
                    if !model.backups.isEmpty { backupSection.entrance(delay: 0.18) }
                    if !model.residues.isEmpty { residueSection.entrance(delay: 0.2) }
                }

                // ── 仅供参考：顾问建议与机会，不是问题状态 ──
                if hasReferenceItems {
                    groupHeader("仅供参考", systemImage: "info.circle.fill", tint: .secondary)
                        .entrance(delay: 0.22)
                    if !model.usageSuggestions.isEmpty { usageSection.entrance(delay: 0.24) }
                    if !model.unusedApps.isEmpty { unusedSection.entrance(delay: 0.26) }
                    if !model.launchAgents.isEmpty { launchAgentSection.entrance(delay: 0.28) }
                    if model.spotlightIndexing == true {
                        spotlightSection.entrance(delay: 0.3)
                    } else if model.spotlightIndexing == false {
                        spotlightOffSection.entrance(delay: 0.3)
                    }
                    if !model.bigFiles.isEmpty { bigFileSection.entrance(delay: 0.32) }
                }

                if isEmptyPage && !model.isChecking { emptyState }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            runCheck()
            model.computeUsage(apps: appState.apps)
        }
    }

    // MARK: - 页面分组（行动 / 参考）

    /// 有问题状态才显示行动区：各分区本身已按"有问题才渲染"条件挂载
    private var hasActionItems: Bool {
        !model.regressions.isEmpty
            || model.diskHealth.contains(where: \.isCritical)
            || !model.speedAlerts.isEmpty
            || !model.lostVolumes.isEmpty
            || !model.backups.isEmpty
            || !model.residues.isEmpty
    }

    private var hasReferenceItems: Bool {
        !model.usageSuggestions.isEmpty || !model.unusedApps.isEmpty
            || !model.launchAgents.isEmpty || model.spotlightIndexing != nil
            || !model.bigFiles.isEmpty
    }

    private var isEmptyPage: Bool {
        model.links.isEmpty && !hasActionItems && !hasReferenceItems
    }

    /// 分组小标题：比分区标题更轻的一级
    private func groupHeader(_ title: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Spacer()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "体检", systemImage: "stethoscope")
                Spacer()
                if model.isChecking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("扫描中...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .breathe()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    Button("重新扫描") {
                        runCheck()
                        model.computeUsage(apps: appState.apps)
                    }
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            // 扫描中：微光条扫过，比干转的菊花更有"在干活"的感觉
            if model.isChecking {
                ShimmerBar(height: 6)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: model.isChecking)
    }

    private var summary: (healthy: Int, offline: Int, broken: Int) {
        let healthy = model.links.filter { $0.state == .healthy }.count
        let offline = model.links.filter { $0.state == .volumeOffline }.count
        let broken = model.links.filter { $0.state == .broken }.count
        return (healthy, offline, broken)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let s = summary
            HStack(spacing: 8) {
                StatusPill("\(s.healthy) 正常", systemImage: "checkmark.circle.fill", color: .green)
                    .entrance(delay: 0, distance: 8)
                StatusPill("\(s.offline) 硬盘未连接", systemImage: "externaldrive.badge.exclamationmark", color: s.offline > 0 ? .orange : .secondary)
                    .entrance(delay: 0.05, distance: 8)
                StatusPill("\(s.broken) 断链", systemImage: "link.badge.plus", color: s.broken > 0 ? .red : .secondary)
                    .entrance(delay: 0.1, distance: 8)
            }
            .animation(reduceMotion ? nil : Motion.snappy, value: s.healthy + s.offline + s.broken)

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

            if model.healedCount > 0 {
                Text("已按迁移台账自动自愈 \(model.healedCount) 条（卷改名/换挂载点）")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }

            ForEach(model.links) { link in
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

    // MARK: - 链接修复动作

    /// 被 +Issues.swift 的 remigrate 尾部调用，不能 private
    func runCheck() {
        Task {
            await model.refresh(engine: appState.checkEngine,
                                drivePath: appState.externalDrive?.mountPoint,
                                apps: appState.apps)
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
        for link in model.links where link.state == .broken {
            if checker.repair(link) { fixed += 1 }
        }
        repairedCount = fixed
        runCheck()
    }

    private func color(for state: LinkHealth.LinkState) -> Color {
        switch state {
        case .healthy: return .green
        case .volumeOffline: return .orange
        case .broken: return .red
        }
    }
}
