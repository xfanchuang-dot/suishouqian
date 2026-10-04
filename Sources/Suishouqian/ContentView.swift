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
        // 效果图：选中行是「浅紫底 + 紫图标/紫字」，系统 List 只能给实色 accent 胶囊，
        // 所以侧栏导航改自绘（按钮行 + 圆角浅紫底），行为与 List 选中等价。
        VStack(alignment: .leading, spacing: 2) {
            sidebarRow("概览", icon: "chart.pie", panel: .overview)
            sidebarRow("应用", icon: "square.grid.2x2", panel: .apps)
            sidebarRow("迁移", icon: "arrow.left.arrow.right", panel: .migrate)
            sidebarRow("体检", icon: "checkmark.shield", panel: .health)
            sidebarRow("数据", icon: "cylinder", panel: .data)
            sidebarRow("设置", icon: "gearshape", panel: .settings)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        .safeAreaInset(edge: .bottom) {
            sidebarDiskCard
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
    }

    /// 效果图紫：选中行高亮与图标着色统一用它
    private static let sidebarAccent = Color(red: 0.44, green: 0.36, blue: 0.93)

    /// 侧边栏行：未选中＝细线灰图标+深色字；选中＝浅紫圆角底+fill 图标+紫字
    private func sidebarRow(_ title: String, icon: String, panel: Panel) -> some View {
        let selected = appState.activePanel == panel
        return Button {
            appState.activePanel = panel
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(selected ? Self.sidebarAccent : .secondary)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Self.sidebarAccent : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? Self.sidebarAccent.opacity(0.13) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 无填充变体的符号（如双箭头）保持原样即可
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
                    // 效果图：蓝→紫渐变用量条
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [.blue, .purple],
                                        startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * builtin.usageRatio))
                            }
                    }
                    .frame(height: 6)
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
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05))
                        )
                        .padding(.horizontal, 12)
                    Spacer()
                }
            default:
                // 概览/迁移/体检/数据保留顶部磁盘横条（SMART 圆点/测速/离线卡都在这）
                VStack(spacing: 14) {
                    DiskBarView()
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    panelContent
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 效果图皮肤：灰窗底，内容浮在白色卡片上（各页自己包卡）
        .background(Color(NSColor.windowBackgroundColor))
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
