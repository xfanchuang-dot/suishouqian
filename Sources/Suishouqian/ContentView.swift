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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            sidebarRow(l10n("概览"), "house.fill", Studio.blue, .overview)
            sidebarRow(l10n("应用"), "square.grid.2x2.fill", Color.indigo, .apps)
            sidebarRow(l10n("迁移"), "arrow.left.arrow.right", Studio.teal, .migrate)
            sidebarRow(l10n("体检"), "heart.fill", Color.pink, .health)
            sidebarRow(l10n("数据"), "cylinder.split.1x2.fill", Color.purple, .data)
            sidebarRow(l10n("设置"), "gearshape.fill", Color.secondary, .settings)
            Spacer(minLength: 12)
            sidebarDriveNote
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .studioCanvas()
    }

    private func sidebarRow(_ title: String, _ symbol: String, _ tint: Color, _ panel: Panel) -> some View {
        let selected = appState.activePanel == panel
        return Button {
            appState.activePanel = panel
        } label: {
            HStack(spacing: 10) {
                SidebarTile(systemImage: symbol, tint: tint, selected: selected)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Studio.blue : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sidebarDriveNote: some View {
        Button {
            appState.activePanel = .overview
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let builtin = appState.builtinDrive {
                    Label(l10n("已用 %lld%%", Int(builtin.usageRatio * 100)), systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let external = appState.externalDrive {
                    Label(l10n("可用 %@", external.freeFormatted), systemImage: "externaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Label(l10n("外置盘未连接"), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .buttonStyle(.plain)
        .padding(4)
        .studioCard()
        .help(l10n("查看磁盘详情与测速"))
    }

    // MARK: - 内容区

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
        .navigationTitle(l10n("随手迁"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .studioCanvas()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlobalTaskCapsule()
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
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
