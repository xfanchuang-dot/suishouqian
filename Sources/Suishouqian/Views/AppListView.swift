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
    
    /// 选中操作条（附录 A1）：有选中才出现
    @ViewBuilder
    private var selectionBar: some View {
        let chosen = appState.apps.filter { selectedApps.contains($0.id) }
        if !chosen.isEmpty {
            let bytes = chosen.reduce(0) { $0 + $1.size }
            HStack(spacing: 10) {
                Text("已选 \(chosen.count) 个（\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))）")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("迁移选中") { runSelected(migrate: true) }
                    .controlSize(.small)
                    .disabled(appState.externalDrive == nil || appState.migrationTask != nil
                              || chosen.allSatisfy { $0.status != .normal })
                Button("回迁选中") { runSelected(migrate: false) }
                    .controlSize(.small)
                    .disabled(appState.externalDrive == nil || appState.migrationTask != nil
                              || chosen.allSatisfy { $0.status != .migrated })
                Button("取消选择") { selectedApps.removeAll() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    /// 选中批量执行：与 migrateAll 同一套串行安全链（逐个走 migrator 入口，护栏与 journal 都在）
    private func runSelected(migrate: Bool) {
        guard let drive = appState.externalDrive else { return }
        // 重扫会重建 AppItem（id 是新 UUID），执行时按"当刻 apps ∩ 选中"取交集
        let targets = appState.apps.filter {
            selectedApps.contains($0.id)
                && (migrate ? $0.status == .normal : $0.status == .migrated)
        }
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            for app in targets {
                let op: MigrationTask.MigrationOperation = migrate ? .migrate : .restore
                appState.migrationTask = MigrationTask(app: app, operation: op)
                let progress: @Sendable (Double, String) -> Void = { pct, file in
                    Task { @MainActor in
                        // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                        appState.reportMigrationProgress(pct, file)
                    }
                }
                if migrate {
                    _ = await appState.migrator.migrate(
                        app: app, to: drive.mountPoint,
                        cancellationToken: appState.migrationTask?.cancellationToken,
                        progress: progress)
                } else {
                    _ = await appState.migrator.restore(app: app, from: drive.mountPoint, progress: progress)
                }
            }
            appState.migrationTask = nil
            selectedApps.removeAll()
            await appState.scanApps()
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
                    TextField("搜索应用…", text: $searchText)
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

                // 分段筛选（对照效果图：米色选中药丸 + 分隔线，非原生分段样式）
                HStack(spacing: 0) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Button { filterMode = mode } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 13, weight: filterMode == mode ? .medium : .regular))
                                .foregroundColor(filterMode == mode ? .primary : .secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(filterMode == mode
                                        // 效果图：暖米色选中（非系统灰）
                                        ? Color(red: 0.90, green: 0.86, blue: 0.78)
                                        : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        if mode != FilterMode.allCases.last {
                            Divider().frame(height: 16)
                        }
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))

                Spacer(minLength: 8)

                // 排序（对照效果图：“排序 ⌄”药丸按钮）
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button(order.rawValue) { sortOrder = order }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("排序")
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
                    Text("正在扫描应用...")
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
                        title: "还没有可迁移的应用",
                        subtitle: "连接外置磁盘后，这里会列出可以迁移的应用",
                        actionTitle: "重新扫描",
                        action: { Task { await appState.scanApps() } },
                        reduceMotion: reduceMotion,
                        imageName: "empty-apps"
                    )
                } else {
                    EmptyStateView(
                        symbol: "magnifyingglass",
                        accentSymbols: [],
                        gradient: [.blue, .cyan],
                        title: "无匹配结果",
                        subtitle: "换个关键词试试",
                        reduceMotion: reduceMotion,
                        imageName: "empty-search"
                    )
                }
            } else {
                List(apps, selection: $selectedApps) { app in
                    AppRowView(app: app)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
                .listStyle(.plain)
                // 白卡上的列表：隐藏 List 自带底色，行直接坐在卡面上
                .scrollContentBackground(.hidden)
                // 搜索/排序/筛选变化时，行变更用弹簧过渡（List 行级动画由系统处理）
                .animation(reduceMotion ? nil : Motion.snappy, value: apps.map(\.id))
            }

            // 6.3（Muse 审查附录 A1）：选中操作条——批量迁部分应用与"一键全部"同一执行链
            selectionBar

            Divider()
                .padding(.horizontal, 16)

            // 底部统计（对照效果图：纯灰文本 · 分隔，无图标无彩色）
            HStack(spacing: 8) {
                // 与「在外置盘」筛选口径一致：链接迁移的 + 外置盘原住民都算
                let offInternal = appState.apps.filter {
                    $0.status == .migrated || $0.status == .externalOnly
                }
                let movable = appState.apps.filter { $0.status == .normal }
                let totalSavable = movable.reduce(0) { $0 + $1.size }

                Spacer()

                Text("\(appState.apps.count) 个应用")
                Text("·")
                Text("\(offInternal.count) 在外置盘")
                if totalSavable > 0 {
                    Text("·")
                    Text("可省 \(ByteCountFormatter.string(fromByteCount: totalSavable, countStyle: .file))")
                }

                Spacer()
            }
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        // 大白卡由 ContentView 的 .mockPage() 统一提供，本页不再自包
    }
}
