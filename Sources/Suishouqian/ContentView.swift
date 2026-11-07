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
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            detail
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
        // 更新助手向导：activeUpdateSession 非空时弹出
        .sheet(item: $appState.activeUpdateSession) { session in
            UpdateWizardView(session: session, mechanism: appState.activeUpdateMechanism)
                .environmentObject(appState)
        }
    }

    // MARK: - 侧边栏

    private var panelSelection: Binding<Panel?> {
        Binding(
            get: { appState.activePanel },
            set: { if let panel = $0 { appState.activePanel = panel } }
        )
    }

    private var sidebar: some View {
        List(selection: panelSelection) {
            Section {
                sidebarLink(l10n("概览"), "chart.pie", .overview)
                sidebarLink(l10n("应用"), "square.grid.2x2", .apps)
                sidebarLink(l10n("迁移"), "arrow.left.arrow.right", .migrate)
                sidebarLink(l10n("体检"), "checkmark.shield", .health)
                sidebarLink(l10n("数据"), "cylinder", .data)
                sidebarLink(l10n("设置"), "gearshape", .settings)
            }
            Section {
                sidebarDiskRows
            } header: {
                Text(l10n("磁盘"))
            }
        }
        .listStyle(.sidebar)
        .symbolRenderingMode(.hierarchical)
    }

    private func sidebarLink(_ title: String, _ symbol: String, _ panel: Panel) -> some View {
        Label(title, systemImage: symbol)
            .tag(panel)
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var sidebarDiskRows: some View {
        Button {
            appState.activePanel = .overview
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n("内置磁盘"))
                    if let builtin = appState.builtinDrive {
                        Text(l10n("已用 %lld%%", Int(builtin.usageRatio * 100)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } icon: {
                Image(systemName: "internaldrive")
            }
        }
        .buttonStyle(.plain)
        .help(l10n("查看磁盘详情与测速"))

        Button {
            appState.activePanel = .overview
        } label: {
            if let external = appState.externalDrive {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(external.name).lineLimit(1)
                        Text(l10n("可用 %@", external.freeFormatted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(.green)
                }
            } else {
                Label(l10n("外置盘未连接"), systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(l10n("查看磁盘详情与测速"))
    }

    // MARK: - 内容区

    private var panelTitle: String {
        switch appState.activePanel {
        case .overview: return l10n("概览")
        case .apps: return l10n("应用")
        case .migrate: return l10n("迁移")
        case .health: return l10n("体检")
        case .data: return l10n("数据")
        case .settings: return l10n("设置")
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch appState.activePanel {
            case .apps:
                AppListView()
            case .settings:
                SettingsView()
            case .health:
                VStack(spacing: 14) {
                    DiskBarView()
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    HealthCheckView().padding(.horizontal, 20)
                }
            case .overview:
                OverviewPanel()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            case .migrate:
                MigrationPanel()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            case .data:
                DataPanelView()
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        }
        .navigationTitle(panelTitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 任务胶囊浮在内容区顶部：任何页面（含应用/设置）都能看到在跑的任务。
        // 用 safeAreaInset 而非 overlay——胶囊出现时把内容往下推，不压磁盘卡
        .safeAreaInset(edge: .top, spacing: 0) {
            GlobalTaskCapsule()
                .padding(.top, 8)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                   value: appState.activePanel)
        // Task 4：全局唯一的迁移计划评审 Sheet。所有普通应用迁移入口
        // （迁移面板一键 / 应用列表多选 / 应用行「迁移」）只构造
        // migrationPlanRequest，在这里统一评审；「确认并开始」通过后
        // 摘要交给迁移页的唯一消费者 executeReviewedPlan 执行。
        // .sheet(item:) 挂在内容区容器上：应用页、迁移页任何位置发起都走同一扇门。
        .sheet(item: $appState.migrationPlanRequest) { request in
            MigrationPlanReviewSheet(request: request) { summary in
                appState.migrationPlanRequest = nil
                appState.approvedMigrationPlan = summary
                appState.activePanel = .migrate
            }
            .environmentObject(appState)
        }
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
