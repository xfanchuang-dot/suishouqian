import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HSplitView {
            AppListView()
                .frame(minWidth: 400)

            VStack(spacing: 0) {
                DiskBarView()
                    .padding(.horizontal, 20)
                    .padding(.top, 16)

                Divider()
                    .padding(.vertical, 12)

                Picker("", selection: $appState.activePanel) {
                    Text("迁移").tag(0)
                    Text("体检").tag(1)
                    Text("数据").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                Group {
                    if appState.activePanel == 0 {
                        MigrationPanel()
                            .padding(.horizontal, 20)
                    } else if appState.activePanel == 1 {
                        HealthCheckView()
                            .padding(.horizontal, 20)
                    } else {
                        DataPanelView()
                            .padding(.horizontal, 20)
                    }
                }
                // 面板切换淡入过渡；系统开启"减弱动态效果"时自动跳过
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18),
                           value: appState.activePanel)

                Spacer()
            }
            .frame(minWidth: 300)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("随手迁")
        .navigationSubtitle(subtitle)
        .onAppear {
            appState.refreshDrives()
            Task { @MainActor in
                await appState.scanApps()
            }
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
