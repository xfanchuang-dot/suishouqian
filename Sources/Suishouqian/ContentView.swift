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
                // 顶部整条标题栏去掉（用户反馈）：标题+副标题都不留，
                // 外置盘状态由侧边栏底部磁盘卡承载；侧栏顶部留交通灯安全高度
                .toolbar(.hidden, for: .windowToolbar)
        }
        .onAppear {
            // 无人值守截图通道：SSQ_PANEL=0..5 直接落到指定页面（概览/迁移/体检/数据/应用/设置）
            if let raw = ProcessInfo.processInfo.environment["SSQ_PANEL"],
               let v = Int(raw), let panel = Panel(rawValue: v) {
                appState.activePanel = panel
            }
            appState.refreshDrives()
            Task { @MainActor in
                await appState.scanApps()
            }
            // 锁屏/无头下 screencapture 不可用：SSQ_SHOT=/path.png 时延迟自拍后退出
            if let shot = ProcessInfo.processInfo.environment["SSQ_SHOT"] {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    Self.captureWindow(to: shot)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        // 效果图：选中行是「浅紫底 + 紫图标/紫字」，系统 List 只能给实色 accent 胶囊，
        // 所以侧栏导航改自绘（按钮行 + 圆角浅紫底），行为与 List 选中等价。
        VStack(alignment: .leading, spacing: 9) {
            sidebarRow("概览", icon: "chart.pie", panel: .overview)
            sidebarRow("应用", icon: "square.grid.2x2", panel: .apps)
            sidebarRow("迁移", icon: "arrow.left.arrow.right", panel: .migrate)
            sidebarRow("体检", icon: "checkmark.shield", panel: .health)
            sidebarRow("数据", icon: "cylinder", panel: .data)
            sidebarRow("设置", icon: "gearshape", panel: .settings)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 255)
        // 工具栏隐藏后交通灯悬浮在侧边栏左上，菜单从其下方开始
        .safeAreaInset(edge: .top) {
            Color.clear.frame(height: 30)
        }
        .safeAreaInset(edge: .bottom) {
            // 效果图格局：玻璃卡只装内置盘；外置盘摘要是卡下方的一条纯文本行
            VStack(spacing: 8) {
                sidebarDiskCard
                sidebarExternalRow
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }

    /// 卡下方的外置盘摘要行（效果图：不进卡，纯文字小行）
    @ViewBuilder
    private var sidebarExternalRow: some View {
        HStack(spacing: 6) {
            if let external = appState.externalDrive {
                Image(systemName: "externaldrive.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 12))
                Text(external.name)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("可用 \(external.freeFormatted)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                Text("外置盘未连接")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 4)
        .onTapGesture { appState.activePanel = .overview }
        .help("查看磁盘详情与测速")
    }

    /// 效果图紫：选中行高亮与图标着色统一用它
    private static let sidebarAccent = Color(red: 0.44, green: 0.36, blue: 0.93)

    /// 侧边栏行：未选中＝细线灰图标+深色字；选中＝浅紫圆角底+fill 图标+紫字。
    /// 用户反馈放大：图标 17pt、文字 15pt、行内上下 9pt、左右 12pt
    private func sidebarRow(_ title: String, icon: String, panel: Panel) -> some View {
        let selected = appState.activePanel == panel
        return Button {
            appState.activePanel = panel
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(selected ? Self.sidebarAccent : .secondary)
                    .frame(width: 24, alignment: .center)
                Text(title)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? Self.sidebarAccent : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // 选中行：macOS 26+ 动态液化玻璃（紫色、随指针/背景实时折射）；
            // 低版本回退静态浅紫底。未选中行保持透明。
            .modifier(SidebarSelectionBackground(selected: selected, accent: Self.sidebarAccent))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 无填充变体的符号（如双箭头）保持原样即可
    }

    /// 用量条流动高光：一条斜向白色亮带缓慢循环扫过（reduceMotion 下不渲染）
    private struct FlowingHighlight: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var phase: CGFloat = -0.6

        var body: some View {
            if !reduceMotion {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.35), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.3)
                    .rotationEffect(.degrees(12))
                    .offset(x: phase * geo.size.width)
                    .onAppear {
                        withAnimation(.linear(duration: 2.6).repeatForever(autoreverses: false)) {
                            phase = 1.6
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// 选中行背景：选中才上玻璃/浅紫底，未选中全透明
    private struct SidebarSelectionBackground: ViewModifier {
        let selected: Bool
        let accent: Color
        func body(content: Content) -> some View {
            if selected {
                content.sidebarSelectedGlass(accent: accent)
            } else {
                content
            }
        }
    }

    /// 左下角磁盘卡（效果图格局：卡内只放内置盘 + 用量条 + 已用百分比）
    @ViewBuilder
    private var sidebarDiskCard: some View {
        VStack(spacing: 8) {
            if let builtin = appState.builtinDrive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "internaldrive.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 13))
                        Text("内置磁盘")
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    // 效果图：蓝→紫渐变用量条 + 流动高光（动态感，reduceMotion 下静止）
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
                    .frame(height: 7)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay { FlowingHighlight() }
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    HStack {
                        Spacer()
                        Text("已用 \(Int(builtin.usageRatio * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(12)
        // macOS 26+ 真·玻璃卡（随侧栏背后内容折射）；低版本回退材质近似
        .sidebarCardGlass(cornerRadius: Theme.Corner.card)
        .contentShape(Rectangle())
        .onTapGesture { appState.activePanel = .overview }
        .help("查看磁盘详情与测速")
    }

    // MARK: - 内容区

    @ViewBuilder
    private var detail: some View {
        Group {
            switch appState.activePanel {
            case .apps:
                AppListView()
                    .mockPage()
            case .settings:
                // 设置页也走统一 mockPage 大白卡（此前是手搓 r=12 卡，与设计系统 r=18 不一致）；
                // 底部统计条（效果图元素）保留
                VStack(spacing: 0) {
                    SectionHeader(title: "设置", systemImage: "gearshape.fill")
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                    SettingsView()
                        .padding(.horizontal, 24)
                    Divider().padding(.horizontal, 24)
                    MockBottomBar(items: statsItems)
                }
                .mockPage()
            case .health:
                // 体检页与其他页统一：同样浮在大白卡上（此前是唯一裸在灰底的页，
                // 页间切换容器跳变）。磁盘横条（SMART 圆点/测速/离线卡）保留在卡顶
                VStack(spacing: 14) {
                    DiskBarView()
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    HealthCheckView().padding(.horizontal, 20)
                }
                .mockPage()
            case .overview:
                OverviewPanel()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .mockPage()
            case .migrate:
                MigrationPanel()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .mockPage()
            case .data:
                DataPanelView()
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .mockPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 效果图皮肤：灰窗底，内容浮在白色大圆角卡上
        .background(Color(NSColor.windowBackgroundColor))
        // 任务胶囊浮在内容区顶部：任何页面（含应用/设置）都能看到在跑的任务。
        // 用 safeAreaInset 而非 overlay——胶囊出现时把内容往下推，不压磁盘卡
        .safeAreaInset(edge: .top, spacing: 0) {
            GlobalTaskCapsule()
                .padding(.top, 8)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: appState.activePanel)
    }

    /// 效果图底栏统一口径（应用/设置页共用）：N 个应用 · N 在外置盘 · 可省 N
    private var statsItems: [String] {
        let offInternal = appState.apps.filter {
            $0.status == .migrated || $0.status == .externalOnly
        }.count
        let savable = appState.apps.filter { $0.status == .normal }.reduce(0) { $0 + $1.size }
        var items = ["\(appState.apps.count) 个应用", "\(offInternal) 在外置盘"]
        if savable > 0 {
            items.append("可省 \(ByteCountFormatter.string(fromByteCount: savable, countStyle: .file))")
        }
        return items
    }

    /// 应用内截图（锁屏也能拍：直接渲染窗口内容位图，不走系统截屏服务）
    @MainActor
    private static func captureWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else { return }
        let rect = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
    }
}
