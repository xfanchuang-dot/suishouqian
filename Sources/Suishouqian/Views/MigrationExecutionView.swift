import SwiftUI

/// 执行视图（Task 3）：把既有 `MigrationTask` 的推进过程与真实 `MigrationResult`
/// 折出的 `MigrationOutcome` 终态，呈现成「阶段感知」的安全流程。
///
/// 纪律（实现计划 Step 3）：
/// - `task` 非终态 → 服务提供阶段时显示对应阶段；只有旧式进度回调时显示
///   泛化的「正在传输」，不把未知阶段误报成复制、校验或切换；
/// - 「取消迁移」只置位 token 并把附近文案切到「正在安全停止，等待清理完成…」，
///   **绝不清 appState.migrationTask**——收尾（清理半截副本）由管道在阶段边界自己完成；
/// - 终态只由 `MigrationOutcome` 驱动：success 只可能来自服务端 `success == true`
///   （工厂保证，UI 无第二入口）；cancelled 必须交代「源应用未动、半截副本已清理」
///   且只给「迁移历史」；failed 保留服务端错误原文，「关闭」是纯展示层动作，不碰任何文件。
struct MigrationExecutionView: View {
    let task: MigrationTask?
    let outcome: MigrationOutcome?
    let outcomeTaskID: UUID?
    let batchResults: [MigrationBatchItemResult]
    let onOpenApps: () -> Void
    let onShowHistory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 「取消迁移」按下后的本地文案状态；`token.isCancelled` 是第二重信号
    /// （其他路径触发取消时文案同样正确切换）
    @State private var stopRequested = false
    /// 失败终态的「关闭」：纯展示层，收起结果卡，不动任何文件
    @State private var outcomeDismissed = false

    /// 固定四阶段（与评审 sheet 同一顺序、同一节点组件）。
    private let stages: [MigrationExecutionPhase] =
        [.preflight, .copyAndSwitch, .verify, .backupAndSwitch]

    var body: some View {
        let displayOutcome = MigrationPlanPresentation.displayOutcome(
            task: task, outcome: outcome, outcomeTaskID: outcomeTaskID)
        Group {
            if let task, !task.status.isTerminal {
                VStack(alignment: .leading, spacing: 12) {
                    runningBody(task)
                    if !batchResults.isEmpty {
                        batchResultsBody(batchResults)
                    }
                }
            } else if !batchResults.isEmpty {
                batchResultsBody(batchResults)
            } else if let displayOutcome, !outcomeDismissed {
                outcomeBody(displayOutcome)
            }
        }
        // 新一轮执行开始（面板换上新 MigrationTask）：清掉上一轮的取消文案状态
        .onChange(of: task?.id) { _, _ in stopRequested = false }
        // 同一位置渲染出新结果（上一条失败被「关闭」过）：恢复可展示
        .onChange(of: outcome) { _, _ in outcomeDismissed = false }
    }

    // MARK: - 运行中：阶段时间线 + 进度 + 协作式取消

    private func runningBody(_ task: MigrationTask) -> some View {
        let states = stageStates(current: MigrationExecutionPhase(servicePhase: task.phase))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconContainer(icon: task.app.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(task))
                        .font(.system(size: 15, weight: .semibold))
                    Text(ByteCountFormatter.string(
                        fromByteCount: task.app.size, countStyle: .file))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Text("\(Int(task.progress * 100))%")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(MockTheme.accent)
            }

            if MigrationExecutionPhase(servicePhase: task.phase) == .transfer {
                Label(l10n("正在传输"), systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(MockTheme.accent)
            } else {
                HStack(spacing: 0) {
                    ForEach(stages.indices, id: \.self) { index in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 1)
                                .frame(maxWidth: .infinity)
                        }
                        MigrationStageNode(title: stages[index].displayName, state: states[index])
                    }
                }
            }

            GeometryReader { geo in
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(MockTheme.primaryGradient)
                            .frame(width: max(8, geo.size.width * task.progress))
                    }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            // 进度跳变时用弹簧跟随，不是一格一格地蹦
            .animation(reduceMotion ? nil : Motion.progress, value: task.progress)

            HStack {
                Text(task.currentFile)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                stopControl(task)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n("%@，进度 %lld%%", title(task), Int(task.progress * 100)))
    }

    /// 取消控制：按下只置位 token 并等待服务返回最终文件状态，不清 appState.migrationTask。
    @ViewBuilder
    private func stopControl(_ task: MigrationTask) -> some View {
        if stopRequested || task.cancellationToken.isCancelled {
            Label(l10n("正在请求停止，等待文件状态确认…"), systemImage: "hourglass")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .help(l10n("等待迁移服务返回源位置与目标副本状态"))
        } else {
            Button(l10n("取消迁移")) {
                stopRequested = true
                task.cancellationToken.cancel()
                AuditLog.append("用户取消迁移「\(task.app.name)」")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundColor(.red)
            .help(l10n("请求迁移服务在安全检查点停止；最终结果会说明源文件与目标副本状态"))
        }
    }

    /// 由迁移服务实际阶段推出节点状态：当前节点高亮，之前的标完成，
    /// 之后的未开始。`.blocked`（已取消/已失败）到不了这里——非终态分支保证。
    private func stageStates(current: MigrationExecutionPhase) -> [MigrationStageVisualState] {
        guard let index = stages.firstIndex(of: current) else {
            return stages.map { _ in .pending }
        }
        return stages.indices.map {
            $0 < index ? .done : ($0 == index ? .active : .pending)
        }
    }

    private func title(_ task: MigrationTask) -> String {
        let name = task.app.name
        switch task.operation {
        case .migrate: return l10n("迁移 %@", name)
        case .restore: return l10n("回迁 %@", name)
        case .uninstall: return l10n("卸载 %@", name)
        case .relocate: return l10n("盘间迁移 %@", name)
        }
    }

    // MARK: - 终态：成功 / 已取消 / 已失败

    @ViewBuilder
    private func outcomeBody(_ outcome: MigrationOutcome) -> some View {
        switch outcome.kind {
        case .success: successBody(outcome)
        case .cancelled: cancelledBody(outcome)
        case .failure, .recoveryRequired: failureBody(outcome)
        }
    }

    // MARK: - Batch results

    private func batchResultsBody(_ results: [MigrationBatchItemResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n("本批逐项结果"))
                .font(.system(size: 13, weight: .semibold))
            ForEach(results) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        let status = batchStatus(item)
                        Label(status.title, systemImage: status.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(status.color)
                        Text(item.name)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 4)
                    }
                    if let outcome = item.outcome {
                        Text(outcome.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.id != results.last?.id {
                    Divider().opacity(0.5)
                }
            }
            let actions: [(title: String, action: () -> Void)] =
                MigrationPlanPresentation.shouldOfferOpenAppsAction(for: results)
                ? [(l10n("查看应用"), onOpenApps), (l10n("迁移历史"), onShowHistory)]
                : [(l10n("迁移历史"), onShowHistory)]
            outcomeActions(actions)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n("本批逐项结果"))
    }

    private func batchStatus(_ item: MigrationBatchItemResult)
        -> (title: String, symbol: String, color: Color) {
        switch item.status {
        case .pending:
            return (l10n("等待处理"), "clock", .secondary)
        case .succeeded:
            return (l10n("已完成"), "checkmark.circle.fill", MockTheme.healthGreen)
        case .failed:
            if item.outcome?.kind == .recoveryRequired {
                return (l10n("需要检查"), "exclamationmark.triangle.fill", MockTheme.statOrange)
            }
            return (l10n("失败"), "xmark.octagon.fill", .red)
        case .cancelled:
            return (l10n("安全取消"), "exclamationmark.triangle.fill", MockTheme.statOrange)
        case .notStarted:
            return (l10n("未开始"), "minus.circle", .secondary)
        }
    }

    /// 成功终态：标题「迁移完成」+「已释放 <格式化字节>」（等宽数字），
    /// 动作 = 查看应用 + 迁移历史。只有服务端 success == true 才会走到这里。
    private func successBody(_ outcome: MigrationOutcome) -> some View {
        let freed = outcome.reportedFreedBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }
        return VStack(alignment: .leading, spacing: 10) {
            // 图标 + 文字双通道：成功语义不单靠颜色
            HStack(spacing: 12) {
                Label(outcome.title, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(MockTheme.healthGreen)
                Spacer()
                if let freed {
                    Text(l10n("已释放 %@", freed))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(MockTheme.healthGreen)
                }
            }
            Text(outcome.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            outcomeActions([(l10n("查看应用"), onOpenApps), (l10n("迁移历史"), onShowHistory)])
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(freed.map { l10n("%@，已释放 %@", outcome.title, $0) } ?? outcome.title)
    }

    /// 取消终态：安全文案只由服务明确返回简单安全取消时生成；否则走恢复提示。
    private func cancelledBody(_ outcome: MigrationOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(outcome.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(MockTheme.statOrange)
            Text(outcome.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            outcomeActions([(l10n("迁移历史"), onShowHistory)])
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outcome.title)：\(outcome.detail)")
    }

    /// 失败终态：保留服务端错误原文（outcome.detail），动作 = 迁移历史 +
    /// 非破坏「关闭」（只收起结果卡，不清理、不重试、不碰文件）。
    private func failureBody(_ outcome: MigrationOutcome) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(outcome.title, systemImage: "xmark.octagon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.red)
            Text(outcome.detail)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
            outcomeActions([(l10n("迁移历史"), onShowHistory),
                            (l10n("关闭"), { outcomeDismissed = true })])
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(outcome.title)：\(outcome.detail)")
    }

    private func outcomeActions(_ actions: [(title: String, action: () -> Void)]) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, item in
                Button(item.title) { item.action() }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundColor(MockTheme.accent)
    }
}
