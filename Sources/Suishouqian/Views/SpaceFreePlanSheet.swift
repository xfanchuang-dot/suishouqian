import SwiftUI

/// 一键腾空间方案 sheet（v3.0 能力二 UI）。
/// 引擎（MigrationPlanner）是纯计算零副作用；这里只负责「输入目标 → 展示方案 → 勾选 → 执行」。
/// 执行走 MigrationPanel 的串行安全链（逐应用重跑护栏，TOCTOU 由执行侧兜底）。
struct SpaceFreePlanSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// 目标：把内置盘腾到剩余多少 GB（方案按差值算）
    @State private var targetGB: Double = 40
    @State private var plan: MigrationPlanner.MigrationPlan?
    /// 勾选中、将被执行的应用（bundleName 集合）
    @State private var selected: Set<String> = []
    @State private var showExcluded = false
    @State private var isPlanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "一键腾空间", systemImage: "wand.and.stars")
                Spacer()
                Button("取消") { dismiss() }
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text("把内置盘腾到剩余")
                    .font(.system(size: 12))
                TextField("40", value: $targetGB, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                Text("GB")
                    .font(.system(size: 12))
                Button("生成方案") { regenerate() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(isPlanning || appState.volumeStore.onlineVolumes.isEmpty)
                if isPlanning { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let plan {
                summaryLine(plan)

                if plan.moves.isEmpty {
                    let freeGB = (appState.builtinDrive?.freeSize ?? 0) / 1_073_741_824
                    if plan.targetMet, freeGB >= Int(targetGB) {
                        Text("内置盘剩余 \(freeGB) GB，已经高于目标 \(Int(targetGB)) GB，无需腾空间。"
                             + "想要更多余量，把目标改大后重新生成方案")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("没有可搬迁的候选（目标盘空间不足或所有应用都被排除了，见下方排除说明）")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 16)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    ForEach(plan.moves, id: \.app.bundleName) { move in
                        moveRow(move)
                    }
                }

                if !plan.excluded.isEmpty {
                    excludedSection(plan.excluded)
                }

                HStack {
                    Spacer()
                    Button("按方案执行（\(selected.count) 个）") {
                        executeSelected()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selected.isEmpty || appState.migrationTask != nil)
                }
            } else if !isPlanning {
                Text("输入目标后点「生成方案」：引擎按体积 × 更新方式风险 × 使用频率排序，"
                     + "自动挑出性价比最高的一批，被排除的应用都会说明原因")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear { regenerate() }
    }

    // MARK: - 行

    private func summaryLine(_ plan: MigrationPlanner.MigrationPlan) -> some View {
        let freed = ByteCountFormatter.string(fromByteCount: plan.totalFreedBytes, countStyle: .file)
        let minutes = Int(plan.estimatedSeconds / 60)
        return HStack(spacing: 6) {
            Image(systemName: plan.targetMet ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(plan.targetMet ? .green : .orange)
                .font(.system(size: 12))
            if plan.moves.isEmpty {
                Text("没有纳入方案的应用")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text(plan.targetMet
                     ? "预计腾出 \(freed)，达标；约需 \(max(minutes, 1)) 分钟（串行逐个搬，每步都有校验与备份）"
                     : "预计只能腾出 \(freed)，未达标（候选不够或目标盘空间不足）")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func moveRow(_ move: MigrationPlanner.PlannedMove) -> some View {
        let isSelected = selected.contains(move.app.bundleName)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .teal : .secondary)
                .font(.system(size: 14))
                .onTapGesture { toggle(move.app.bundleName) }

            VStack(alignment: .leading, spacing: 2) {
                Text(move.app.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(move.reason) → \(move.volumeName)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .cardStyle()
        .contentShape(Rectangle())
        .onTapGesture { toggle(move.app.bundleName) }
    }

    private func excludedSection(_ excluded: [MigrationPlanner.ExcludedApp]) -> some View {
        DisclosureGroup("\(excluded.count) 个应用不参与方案（点开看原因）", isExpanded: $showExcluded) {
            ForEach(excluded, id: \.app.bundleName) { item in
                HStack(alignment: .top, spacing: 6) {
                    Text(item.app.name)
                        .font(.system(size: 11, weight: .medium))
                    Text(item.reason)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .font(.system(size: 11))
    }

    // MARK: - 逻辑

    private func toggle(_ bundleName: String) {
        if selected.contains(bundleName) {
            selected.remove(bundleName)
        } else {
            selected.insert(bundleName)
        }
    }

    private func regenerate() {
        isPlanning = true
        let runningNames = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        let candidates = appState.apps.filter { $0.status == .normal }.map { app in
            MigrationPlanner.AppCandidate(
                name: app.name,
                bundleName: app.bundleName,
                size: app.size,
                mechanism: app.updateMechanism,
                launchesLast7Days: app.bundleID.map {
                    LaunchUsageTracker.shared.recentLaunchCount(bundleID: $0, days: 7)
                } ?? 0,
                isRunning: runningNames.contains(app.name),
                isSystemApp: app.isSystemApp,
                alreadyExternal: false)
        }
        let volumes = appState.volumeStore.onlineVolumes.map { volume in
            MigrationPlanner.VolumeCandidate(
                uuid: volume.id, name: volume.info.name,
                freeBytes: volume.info.freeSize,
                tier: volume.linkTier, measuredMBps: volume.measuredMBps)
        }
        let targetBytes = Int64(targetGB * 1_073_741_824)
            - (appState.builtinDrive?.freeSize ?? 0)
        plan = MigrationPlanner.plan(.init(
            apps: candidates, volumes: volumes,
            targetFreeBytes: max(0, targetBytes)))
        selected = Set(plan?.moves.map(\.app.bundleName) ?? [])
        isPlanning = false
    }

    /// 把选中的 moves 交给迁移面板的串行执行链（sheet 只挑人选，不自己搬）
    private func executeSelected() {
        guard let plan else { return }
        let moves = plan.moves.filter { selected.contains($0.app.bundleName) }
        let volumeUUIDs = Dictionary(uniqueKeysWithValues:
            appState.volumeStore.volumes.map { ($0.id, $0.info.mountPoint) })
        let planned = moves.compactMap { move -> (AppItem, String)? in
            guard let mount = volumeUUIDs[move.volumeUUID],
                  let app = appState.apps.first(where: { $0.bundleName == move.app.bundleName })
            else { return nil }
            return (app, mount)
        }
        dismiss()
        onExecute(planned)
    }

    /// 执行回调（由宿主 MigrationPanel 提供，走它的串行安全链）
    let onExecute: ([(AppItem, String)]) -> Void
}
