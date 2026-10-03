import SwiftUI

/// 菜单栏常驻（v3.1，实验功能，默认关闭）。
/// 只读展示各盘可用空间 + 打开主窗口 / 退出；不做后台轮询，打开菜单时刷新一次。
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let builtin = appState.builtinDrive {
            Text("内置盘：可用 \(builtin.freeFormatted)")
                .font(.system(size: 12))
        }
        ForEach(appState.volumeStore.onlineVolumes) { vol in
            Text("\(vol.displayName)：可用 \(vol.info.freeFormatted)")
                .font(.system(size: 12))
        }
        Divider()
        Button("打开随手迁") { showMainWindow() }
        Button("退出随手迁") { NSApp.terminate(nil) }
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
