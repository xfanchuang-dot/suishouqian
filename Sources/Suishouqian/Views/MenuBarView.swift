import SwiftUI

/// 菜单栏常驻（v3.1，实验功能，默认关闭）。
/// 只读展示各盘可用空间 + 打开主窗口 / 退出；不做后台轮询，打开菜单时刷新一次。
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let builtin = appState.builtinDrive {
                Label(l10n("内置盘：可用 %@", builtin.freeFormatted), systemImage: "internaldrive")
                    .symbolRenderingMode(.hierarchical)
            }
            ForEach(appState.volumeStore.onlineVolumes) { vol in
                Label(l10n("%@：可用 %@", vol.displayName, vol.info.freeFormatted),
                      systemImage: "externaldrive")
                    .symbolRenderingMode(.hierarchical)
            }
            Divider()
            Button { showMainWindow() } label: {
                Label(l10n("打开随手迁"), systemImage: "macwindow")
            }
            .buttonStyle(.borderless)
            Button { NSApp.terminate(nil) } label: {
                Label(l10n("退出随手迁"), systemImage: "power")
            }
            .buttonStyle(.borderless)
        }
        .font(.body)
        .padding(14)
        .frame(minWidth: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Studio.radius, style: .continuous))
        .task {
            await appState.volumeStore.refresh()
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
