import SwiftUI

/// 迁移历史时间线：OperationJournal 的完整 UI 入口。
/// 按天分组，显示每次操作的应用、动作、结果，支持一键撤销。
struct MigrationHistoryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [JournalEntry] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                MockPageTitle(text: "迁移历史")
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("暂无迁移记录")
                        .font(.system(size: 15, weight: .medium))
                    Text("迁移或回迁应用后，这里会显示完整时间线")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedByDay, id: \.day) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    historyRow(entry)
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 4)
                                }
                            } header: {
                                dayHeader(group.day)
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { loadEntries() }
    }

    // MARK: - 数据

    private struct DayGroup {
        let day: Date
        let entries: [JournalEntry]
    }

    private var groupedByDay: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: entries) { entry in
            cal.startOfDay(for: entry.at)
        }
        return grouped.map { DayGroup(day: $0.key, entries: $0.value) }
            .sorted { $0.day > $1.day }
    }

    private func loadEntries() {
        isLoading = true
        Task {
            // 日志读取是文件 IO：走 OffPool（项目铁律，勿占协作线程池）
            let result = await OffPool.run {
                OperationJournal.shared.recent(limit: 200)
            }
            await MainActor.run {
                entries = result
                isLoading = false
            }
        }
    }

    // MARK: - 行

    private func dayHeader(_ day: Date) -> some View {
        HStack {
            Text(dayFormatted(day))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func dayFormatted(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "今天" }
        if cal.isDateInYesterday(day) { return "昨天" }
        let fmt = DateFormatter()
        fmt.dateFormat = "M月d日 EEEE"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: day)
    }

    private func timeFormatted(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }

    private func historyRow(_ entry: JournalEntry) -> some View {
        HStack(spacing: 12) {
            // 操作图标
            Image(systemName: iconFor(entry.op))
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colorFor(entry.op).gradient)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.appName)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(opText(entry.op))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(timeFormatted(entry.at))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Spacer()

            // 状态
            if entry.isUndone {
                Text("已撤销")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            } else if !entry.isOK {
                Text("失败")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.1)))
            } else {
                Text("成功")
                    .font(.system(size: 11))
                    .foregroundColor(MockTheme.healthGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(MockTheme.healthGreen.opacity(0.1)))
            }
        }
        .padding(12)
        .mockCard(padding: 12)
    }

    private func iconFor(_ op: JournalOperation) -> String {
        switch op {
        case .migrate: return "arrow.up.right"
        case .restore: return "arrow.down.left"
        case .moveBack: return "arrow.down.to.line"
        case .uninstall: return "trash"
        case .remigrate: return "arrow.clockwise"
        case .relocate: return "arrow.left.arrow.right"
        case .undo: return "arrow.uturn.backward"
        }
    }

    private func colorFor(_ op: JournalOperation) -> Color {
        switch op {
        case .migrate: return .blue
        case .restore: return .green
        case .moveBack: return .teal
        case .uninstall: return .red
        case .remigrate: return .orange
        case .relocate: return .purple
        case .undo: return .gray
        }
    }

    private func opText(_ op: JournalOperation) -> String {
        switch op {
        case .migrate: return "迁移到外置盘"
        case .restore: return "回迁到内置盘"
        case .moveBack: return "搬回内置盘"
        case .uninstall: return "卸载"
        case .remigrate: return "重新迁移"
        case .relocate: return "盘间迁移"
        case .undo: return "撤销操作"
        }
    }
}
