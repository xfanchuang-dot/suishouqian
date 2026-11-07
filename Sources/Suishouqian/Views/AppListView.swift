import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedApps = Set<UUID>()
    @State private var filterMode: FilterMode = .all
    @State private var sortOrder: SortOrder = .size
    @FocusState private var searchFocused: Bool
    
    enum FilterMode: String, CaseIterable {
        case all = "全部"
        case movable = "可迁移"
        /// 一切"不在内置盘上"的应用：链接迁移的 + 本来就装在外置盘的。
        /// 早先这里只筛链接迁移的，导致那批"外置盘原住民"应用（Word/微信/Xcode…）
        /// 除了「全部」之外无处可查——纯搬迁产生的应用也会落入这一类
        case offInternal = "在外置盘"
        case system = "系统"
    }
    
    enum SortOrder: String, CaseIterable {
        case size = "大小"
        case name = "名称"
    }

    /// 视图模式：列表 / 大小横条图
    enum ViewMode: String, CaseIterable {
        case list = "列表"
        case chart = "大小"
    }
    @State private var viewMode: ViewMode = .list
    
    /// 选中操作条（附录 A1）：有选中才出现
    @ViewBuilder
    private var selectionBar: some View {
        let chosen = appState.apps.filter { selectedApps.contains($0.id) }
        if !chosen.isEmpty {
            let bytes = chosen.reduce(0) { $0 + $1.size }
            HStack(spacing: 10) {
                Text(l10n("已选 %lld 个（%@）", chosen.count, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                Spacer()
                Button(l10n("迁移选中")) { runSelected(migrate: true) }
                    .controlSize(.small)
                    .disabled(appState.externalDrive == nil || appState.isMigrationActive
                              || chosen.allSatisfy { $0.status != .normal })
                Button(l10n("回迁选中")) { runSelected(migrate: false) }
                    .controlSize(.small)
                    .disabled(appState.externalDrive == nil || appState.isMigrationActive
                              || chosen.allSatisfy { $0.status != .migrated })
                Button(l10n("取消选择")) { selectedApps.removeAll() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    /// 选中操作：迁移走全局计划评审，回迁保持原有直接执行链
    private func runSelected(migrate: Bool) {
        guard let drive = appState.externalDrive else { return }
        // 重扫会重建 AppItem（id 是新 UUID），执行时按"当刻 apps ∩ 选中"取交集
        let targets = appState.apps.filter {
            selectedApps.contains($0.id)
                && (migrate ? $0.status == .normal : $0.status == .migrated)
        }
        guard !targets.isEmpty else { return }

        if migrate {
            // Task 4：普通应用迁移一律先进计划评审，这里只构造请求、不动任何文件；
            // 「确认并开始」后由迁移页的 executeReviewedPlan 统一执行
            appState.migrationPlanRequest = MigrationPlanRequest(apps: targets)
            return
        }

        Task { @MainActor in
            for app in targets {
                let task = MigrationTask(app: app, operation: .restore)
                let taskID = task.id
                appState.migrationTask = task
                let progress: @Sendable (Double, String) -> Void = { pct, file in
                    Task { @MainActor in
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress(pct, file, taskID: taskID)
                    }
                }
                let result = await appState.migrator.restore(
                    app: app, from: drive.mountPoint,
                    phaseProgress: { update in
                        Task { @MainActor in
                            appState.reportMigrationProgress(update, taskID: taskID)
                        }
                    },
                    progress: progress)
                if var current = appState.migrationTask {
                    current.status = result.success
                        ? .completed : .failed(result.error ?? l10n("未知错误"))
                    appState.migrationTask = current
                }
            }
            appState.migrationTask = nil
            selectedApps.removeAll()
            await appState.scanApps()
        }
    }

    /// 大小横条图：按大小降序，横条长度正比于大小，一眼定位巨无霸
    private func sizeChartView(apps: [AppItem]) -> some View {
        let sorted = apps.sorted { $0.size > $1.size }
        let maxSize = max(sorted.first?.size ?? 1, 1)
        // 只显示前 30，避免超长列表卡顿
        let top = Array(sorted.prefix(30))
        return ScrollView {
            VStack(spacing: 8) {
                ForEach(top) { app in
                    HStack(spacing: 10) {
                        // 应用图标
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 28, height: 28)
                                .cornerRadius(6)
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Image(systemName: "app.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                )
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(app.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                                    .overlay(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(barColor(for: app))
                                            .frame(width: max(4, geo.size.width * CGFloat(app.size) / CGFloat(maxSize)))
                                    }
                            }
                            .frame(height: 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .mockCard(padding: 0)
                    .padding(.horizontal, 16)
                }
                if sorted.count > 30 {
                    Text(l10n("仅显示最大的 30 个，共 %lld 个", sorted.count))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 12)
        }
    }

    /// 横条颜色：>5GB 红 / >1GB 橙 / 其他蓝紫渐变
    private func barColor(for app: AppItem) -> LinearGradient {
        let gb = Double(app.size) / 1_073_741_824
        if gb >= 5 {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        } else if gb >= 1 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        } else {
            return MockTheme.builtinBar
        }
    }

    var filteredApps: [AppItem] {
        var apps = appState.apps
        
        // 搜索过滤
        if !searchText.isEmpty {
            apps = apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        
        // 分类过滤
        switch filterMode {
        case .all: break
        case .movable: apps = apps.filter { $0.status == .normal }
        case .offInternal:
            apps = apps.filter { $0.status == .migrated || $0.status == .externalOnly }
        case .system: apps = apps.filter { $0.status == .systemApp }
        }
        
        // 排序
        switch sortOrder {
        case .size: apps.sort { $0.size > $1.size }
        case .name: apps.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
        
        return apps
    }
    
    var body: some View {
        // filteredApps 在一次 body 求值里被用 3 次（isEmpty/List/animation），
        // 先算一次存局部变量，避免过滤+排序跑 3 遍
        let apps = filteredApps
        // 整页浮在一张白色大圆角卡上（对照效果图）：灰窗底 + 白卡 + 圆角搜索 + 胶囊筛选
        return VStack(spacing: 0) {
            // 工具栏（对照效果图：搜索左 / 筛选中 / 排序右）
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField(l10n("搜索应用…"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                        .frame(minWidth: 110)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                )
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = true }
                .frame(width: 210)

                Spacer(minLength: 8)

                Picker(l10n("筛选"), selection: $filterMode) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 8)

                // 视图切换：列表 / 大小横条图
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Image(systemName: mode == .list ? "list.bullet" : "chart.bar.fill")
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 72)
                .help(l10n("切换列表/大小图表"))
                .accessibilityLabel(l10n("切换列表或大小图表"))

                // 排序（对照效果图：“排序 ⌄”药丸按钮）
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button(order.rawValue) { sortOrder = order }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(l10n("排序"))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .onReceive(NotificationCenter.default.publisher(for: .focusAppSearch)) { _ in
                searchFocused = true
            }

            // 列表
            if appState.isScanning {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(l10n("正在扫描应用..."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                if searchText.isEmpty {
                    EmptyStateView(
                        symbol: "externaldrive.fill",
                        accentSymbols: ["doc.fill", "music.note", "message.fill",
                                        "cloud.fill", "video.fill", "gearshape.fill"],
                        gradient: [.blue, .purple],
                        title: l10n("还没有可迁移的应用"),
                        subtitle: l10n("连接外置磁盘后，这里会列出可以迁移的应用"),
                        actionTitle: l10n("重新扫描"),
                        action: { Task { await appState.scanApps() } },
                        reduceMotion: reduceMotion,
                        imageName: "empty-apps"
                    )
                } else {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        accentSymbols: [],
                        gradient: [.blue, .cyan],
                        title: l10n("无匹配结果"),
                        subtitle: l10n("换个关键词试试"),
                        reduceMotion: reduceMotion,
                        imageName: "empty-search"
                    )
                }
            } else if viewMode == .chart {
                // 大小横条图：一眼看出巨无霸
                sizeChartView(apps: apps)
            } else {
                List(apps, selection: $selectedApps) { app in
                    AppRowView(app: app)
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.thinMaterial)
                                .padding(.vertical, 3)
                        )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // 白卡上的列表：隐藏 List 自带底色，行直接坐在卡面上
                .scrollContentBackground(.hidden)
                // 搜索/排序/筛选变化时，行变更用弹簧过渡（List 行级动画由系统处理）
                .animation(reduceMotion ? nil : Motion.snappy, value: apps.map(\.id))
            }

            // 6.3（Muse 审查附录 A1）：选中操作条——批量迁部分应用与"一键全部"同一执行链
            selectionBar
        }
        // 底部统计条已按用户要求移除；列表直贴卡底，裁进大白卡圆角内防穿角
        .clipShape(RoundedRectangle(cornerRadius: MockTheme.Corner.page, style: .continuous))
        // 大白卡由 ContentView 的 .mockPage() 统一提供，本页不再自包
    }
}
