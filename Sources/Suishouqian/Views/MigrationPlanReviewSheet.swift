import SwiftUI

// MARK: - 计划状态便捷读取（Task 2 契约：扩展放本文件，不回改 Task 1 的模型文件）

extension MigrationPlanState {
    /// 可确认的计划摘要：只有 `.ready` 有值；`.blocked` 必须返回 nil——
    /// 没有 summary，「确认并开始」就没有主语，评审界面因此渲染不出任何主操作。
    var summary: MigrationPlanSummary? {
        guard case .ready(let plan) = self else { return nil }
        return plan
    }

    /// blocked → ready 切换（外置盘中途插入）时的动效触发值。
    /// 不直接拿 state 做动画 value：summary 的 UUID 每次 body 重算都会变。
    var isReady: Bool {
        guard case .ready = self else { return false }
        return true
    }
}

extension MigrationExecutionPhase {
    /// 固定阶段的展示名（评审 sheet 与执行视图共用，文案单一出处）。
    var displayName: String {
        switch self {
        case .preflight: return "预检"
        case .backup: return "备份"
        case .copyAndSwitch: return "复制切换"
        case .verify: return "验证"
        case .blocked: return "已停止"
        }
    }
}

// MARK: - 迁移计划评审 Sheet

/// 用户点击「确认并开始」之前唯一的大门：
/// - 计划在 body 内用 `makePlan` 实时求值——盘被拔掉、应用状态变化都会立刻切换到
///   blocked，绝不拿上一次评审的旧数据渲染，更不会用旧数据启动迁移；
/// - 只有 `.ready` 渲染唯一主按钮「确认并开始」，回调交出 summary 后自行 dismiss；
/// - `.blocked` 只渲染警告（图标 + 文字双通道）、全部原因与「关闭」，无任何主操作。
struct MigrationPlanReviewSheet: View {
    @EnvironmentObject private var appState: AppState
    let request: MigrationPlanRequest
    let onConfirm: (MigrationPlanSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = MigrationPlanPresentation.makePlan(
            apps: request.apps, drive: appState.externalDrive)

        VStack(spacing: 0) {
            header(count: request.apps.count)
            Divider().opacity(0.4)
            content(state)
            Divider().opacity(0.4)
            footer(state)
        }
        .frame(minWidth: 620, idealWidth: 650, maxWidth: 680)
        .frame(minHeight: 460)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.isReady)
    }

    // MARK: 头部

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            DriveIconBox(systemImage: "externaldrive.fill", color: MockTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("迁移计划评审")
                    .font(.system(size: 16, weight: .bold))
                Text("共 \(count) 个应用，确认无误后才会开始")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: 主体（ready / blocked 二选一）

    @ViewBuilder
    private func content(_ state: MigrationPlanState) -> some View {
        switch state {
        case .ready(let plan):
            ScrollView {
                readyContent(plan)
                    .padding(18)
            }
        case .blocked(let reasons):
            blockedContent(reasons)
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: ready：目标盘 / 空间预算 / 逐应用明细 / 固定阶段

    private func readyContent(_ plan: MigrationPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            destinationCard(plan)
            spaceBudgetCard(plan)
            itemsCard(plan)
            stagesCard()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func destinationCard(_ plan: MigrationPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "目标盘", systemImage: "externaldrive")
            HStack(spacing: 6) {
                Text(plan.destinationName)
                    .font(.system(size: 13, weight: .semibold))
                StatusPill("空间充足", systemImage: "checkmark.circle.fill",
                           color: MockTheme.healthGreen)
                Spacer()
            }
            Text(plan.destinationPath)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            labeledRow("剩余空间", bytes(plan.freeBytes))
        }
        .cardStyle()
    }

    private func spaceBudgetCard(_ plan: MigrationPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "空间预算", systemImage: "scalemass")
            labeledRow("需要空间（两份：副本 + 同盘留底，另加 5% 余量）", bytes(plan.requiredBytes))
            labeledRow("预计释放内置盘", bytes(plan.totalFreedBytes))
            Text("迁移完成后内置盘释放的空间以上表「预计释放」为准。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    private func itemsCard(_ plan: MigrationPlanSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "迁移明细", systemImage: "list.bullet.rectangle")
            ForEach(Array(plan.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().opacity(0.5) }
                itemRow(item)
            }
        }
        .cardStyle()
    }

    private func itemRow(_ item: MigrationPlanItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.sourcePath)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(bytes(item.size))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .monospacedDigit()
            StatusPill(item.createsLink ? "建链" : "不建链",
                       systemImage: item.createsLink ? "link" : "link.slash",
                       color: item.createsLink ? MockTheme.accent : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// 四个固定阶段：预检 → 备份 → 复制切换 → 验证。评审时全部未开始；
    /// 备份 = 外置盘上保留一份完整留底（合计两份），出问题仍可找回。
    private func stagesCard() -> some View {
        let stages: [MigrationExecutionPhase] =
            [.preflight, .backup, .copyAndSwitch, .verify]
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "执行阶段（固定四步）", systemImage: "list.number")
            HStack(spacing: 0) {
                ForEach(stages.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(height: 1)
                            .frame(maxWidth: .infinity)
                    }
                    MigrationStageNode(title: stages[index].displayName, state: .pending)
                }
            }
            Text("备份阶段会在外置盘保留一份完整留底（合计两份），单次误操作仍可找回。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    // MARK: blocked：警告图标 + 全部原因 + 关闭，无任何主操作

    private func blockedContent(_ reasons: [String]) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundColor(MockTheme.statOrange)
                .accessibilityHidden(true)
            Text("当前无法开始迁移")
                .font(.system(size: 15, weight: .bold))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(reasons, id: \.self) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(MockTheme.statOrange)
                            .accessibilityHidden(true)
                        Text(reason)
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                    .fill(MockTheme.statOrange.opacity(0.08))
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前无法开始迁移：" + reasons.joined(separator: "；"))
    }

    // MARK: 底部操作条

    @ViewBuilder
    private func footer(_ state: MigrationPlanState) -> some View {
        HStack {
            Spacer()
            switch state {
            case .ready:
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                MockGradientButton(title: "确认并开始", systemImage: "checkmark.seal.fill") {
                    guard let plan = state.summary else { return }
                    onConfirm(plan)
                    dismiss()
                }
            case .blocked:
                Button("关闭") { dismiss() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: 小工具

    private func labeledRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
