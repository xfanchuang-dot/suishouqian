import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

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
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                if appState.activePanel == 0 {
                    MigrationPanel()
                        .padding(.horizontal, 20)
                } else {
                    HealthCheckView()
                        .padding(.horizontal, 20)
                }

                Spacer()
            }
            .frame(minWidth: 300)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            appState.refreshDrives()
            Task { @MainActor in
                await appState.scanApps()
            }
        }
    }
}
