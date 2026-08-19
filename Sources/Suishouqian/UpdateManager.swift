import Sparkle

/// 托管 Sparkle 自动更新控制器
@MainActor
final class UpdateManager: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    
    init() {
        // 程序化设置更新源，避免依赖 Info.plist
        let feedURL = "https://github.com/fan/suishouqian/releases/download/appcast.xml"
        UserDefaults.standard.set(feedURL, forKey: "SUFeedURL")
        
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
    
    /// 手动检查更新
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
