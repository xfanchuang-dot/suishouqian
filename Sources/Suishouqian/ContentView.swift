import SwiftUI

/// v3.1 侧边栏改版（对照效果图）：NavigationSplitView——
/// 左侧导航（概览/应用/迁移/体检/数据/设置）+ 左下角磁盘卡；
/// 右侧 detail 是当前页面。应用列表从 HSplitView 左栏升格为独立页面，
/// 设置从独立窗口同步入列（⌘, 窗口保留）。
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .navigationTitle("随手迁")
                .navigationSubtitle(subtitle)
        }
        .onAppear {
            appState.refreshDrives()
            Task { @MainActor in
                await appState.scanApps()
            }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: $appState.activePanel) {
            Label("概览", systemImage: "speedometer").tag(Panel.overview)
            Label("应用", systemImage: "square.grid.2x2.fill").tag(Panel.apps)
            Label("迁移", systemImage: "arrow.left.arrow.right").tag(Panel.migrate)
            Label("体检", systemImage: "stethoscope").tag(Panel.health)
            Label("数据", systemImage: "cylinder.fill").tag(Panel.data)
            Label("设置", systemImage: "gearshape.fill").tag(Panel.settings)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        .safeAreaInset(edge: .bottom) {
            sidebarDiskCard
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    /// 左下角磁盘卡（效果图方向）：内置盘用量条 + 外置盘摘要，点按去概览看全貌
    @ViewBuilder
    private var sidebarDiskCard: some View {
        VStack(spacing: 8) {
            if let builtin = appState.builtinDrive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 12))
                        Text("内置磁盘")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    ProgressView(value: builtin.usageRatio)
                        .tint(.blue)
                    HStack {
                        Spacer()
                        Text("已用 \(Int(builtin.usageRatio * 100))%")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                if let external = appState.externalDrive {
                    Image(systemName: "externaldrive.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text(external.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text("可用 \(external.freeFormatted)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                    Text("外置盘未连接")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture { appState.activePanel = .overview }
        .help("查看磁盘详情与测速")
    }

    // MARK: - 内容区

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            switch appState.activePanel {
            case .apps:
                AppListView()
            case .settings:
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "设置", systemImage: "gearshape.fill")
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    SettingsView()
                        .padding(.horizontal, 24)
                    Spacer()
                }
            default:
                // 概览/迁移/体检/数据保留顶部磁盘横条（SMART 圆点/测速/离线卡都在这）
                VStack(spacing: 0) {
                    DiskBarView()
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    Divider()
                        .padding(.vertical, 12)
                    panelContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 任务胶囊浮在内容区顶部：任何页面（含应用/设置）都能看到在跑的任务
        .overlay(alignment: .top) {
            GlobalTaskCapsule()
                .padding(.top, 8)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: appState.activePanel)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch appState.activePanel {
        case .overview: OverviewPanel().padding(.horizontal, 20)
        case .migrate: MigrationPanel().padding(.horizontal, 20)
        case .health: HealthCheckView().padding(.horizontal, 20)
        case .data: DataPanelView().padding(.horizontal, 20)
        default: EmptyView()
        }
    }

    /// 窗口副标题：外置盘状态一目了然
    private var subtitle: String {
        guard let drive = appState.externalDrive else { return "外置硬盘未连接" }
        // 与列表筛选/底部统计同一口径：链接迁移的与"外置盘原住民"都算在外置盘上
        let offInternal = appState.apps.filter {
            $0.status == .migrated || $0.status == .externalOnly
        }.count
        let savable = appState.apps.filter { $0.status == .normal }.reduce(0) { $0 + $1.size }
        var text = "\(drive.name) · 在外置盘 \(offInternal) 个应用"
        if savable > 0 {
            text += " · 可再省 \(ByteCountFormatter.string(fromByteCount: savable, countStyle: .file))"
        }
        return text
    }
}
