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
                
                MigrationPanel()
                    .padding(.horizontal, 20)
                
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
