import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedApps = Set<UUID>()
    @State private var filterMode: FilterMode = .all
    @State private var sortOrder: SortOrder = .size
    @FocusState private var searchFocused: Bool
    
    enum FilterMode: String, CaseIterable {
        case all = "全部"
        case movable = "可迁移"
        case migrated = "已迁移"
        case system = "系统"
    }
    
    enum SortOrder: String, CaseIterable {
        case size = "大小"
        case name = "名称"
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
        case .migrated: apps = apps.filter { $0.status == .migrated }
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
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索应用...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                
                Spacer()
                
                Picker("", selection: $filterMode) {
                    ForEach(FilterMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                
                Picker("", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 80)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { searchFocused = true }
            .onReceive(NotificationCenter.default.publisher(for: .focusAppSearch)) { _ in
                searchFocused = true
            }
            
            Divider()
            
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
            } else if filteredApps.isEmpty {
                VStack {
                    Spacer()
                    Text(searchText.isEmpty ? "未找到可迁移的应用" : "无匹配结果")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(filteredApps) { app in
                    AppRowView(app: app)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
                .listStyle(.plain)
            }
            
            // 底部统计
            HStack(spacing: 12) {
                let migrated = appState.apps.filter { $0.status == .migrated }
                let movable = appState.apps.filter { $0.status == .normal }
                let totalSavable = movable.reduce(0) { $0 + $1.size }

                Label("\(appState.apps.count) 个应用", systemImage: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Label("\(migrated.count) 已迁移", systemImage: "externaldrive.fill")
                    .font(.system(size: 11))
                    .foregroundColor(migrated.isEmpty ? .secondary : .green)

                Spacer()

                if totalSavable > 0 {
                    Label("可省 \(ByteCountFormatter.string(fromByteCount: totalSavable, countStyle: .file))",
                          systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
}
