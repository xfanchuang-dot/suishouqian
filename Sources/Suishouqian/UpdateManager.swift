import AppKit
import Sparkle

/// 托管 Sparkle 自动更新控制器
///
/// 现状（避免"有个菜单项、点了必报错"的假功能）：
/// 自动更新要三样东西同时到位——公开可访问的 appcast、Info.plist 里的公钥
/// （SUPublicEDKey）、用对应私钥签名的安装包。目前三者都还没有：仓库是私有的，
/// Sparkle 匿名拉不到 releases；v3.0 的发布流程（生成密钥、签名、生成 appcast）
/// 也尚未建立。所以这里在配置缺失时给出明确说明，而不是把 Sparkle 的原始
/// 报错抛给用户——此前 feedURL 还写错了仓库（fan/…）且 URL 形式不合法。
@MainActor
final class UpdateManager: ObservableObject {

    /// appcast 地址。仓库改名/转移时，这里与 build.sh 的 Info.plist 需同步修改
    static let feedURL =
        "https://github.com/xfanchuang-dot/suishouqian/releases/latest/download/appcast.xml"

    private let updaterController: SPUStandardUpdaterController
    private var started = false

    init() {
        // 程序化设置更新源，避免依赖 Info.plist
        UserDefaults.standard.set(Self.feedURL, forKey: "SUFeedURL")

        // 不在启动时启动 updater：通道未配置时只会静默失败并拖慢启动，
        // 改为用户手动点「检查更新」时才启动
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// 更新通道是否已配置（公钥存在且非空才算配好）
    private var channelIsConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 手动检查更新
    func checkForUpdates() {
        guard channelIsConfigured else {
            presentNotConfiguredNotice()
            return
        }
        if !started {
            updaterController.startUpdater()
            started = true
        }
        updaterController.checkForUpdates(nil)
    }

    private func presentNotConfiguredNotice() {
        let alert = NSAlert()
        alert.messageText = "自动更新尚未启用"
        alert.informativeText = """
        当前版本还没有配置更新通道：需要先生成 EdDSA 签名密钥、把公钥写进 Info.plist，\
        并在发布时用私钥签名安装包、生成 appcast（属于 v3.0 发布流程的一部分，
        还需 Developer ID 签名与公证）。

        在通道配好之前，升级方式是重新运行 build.sh 构建安装。
        """
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
