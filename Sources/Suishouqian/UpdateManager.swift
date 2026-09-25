import AppKit
import Sparkle

/// 探测 feed 是否**匿名**可拉取。
///
/// 特意放在文件作用域（而不是 `UpdateManager` 里）当自由函数：@MainActor 类上的
/// static 成员同样带主线程隔离，在 `nonisolated` 的异步探测里引用会引入隔离检查问题。
/// 自由函数天然 nonisolated，参数进、结论出，没有隔离歧义。
///
/// 返回 `nil` 表示可达；否则返回一句能直接摆给用户看的失败原因。
private func probeUpdateFeed(_ feed: String) async -> String? {
    guard let url = URL(string: feed) else {
        return "更新源地址不合法：\(feed)"
    }
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData

    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return "更新源返回了非 HTTP 响应。"
        }
        if http.statusCode == 404 {
            return """
            更新源返回 404：\(feed)
            最常见的原因是仓库为私有（Sparkle 拉 feed 时不带任何凭证，GitHub 对匿名请求\
            一律返回 404），或者还没有发布过任何正式 Release。两种情况 Sparkle 都拿不到 appcast。
            """
        }
        if !(200..<300).contains(http.statusCode) {
            return "更新源返回 HTTP \(http.statusCode)。"
        }
        return nil
    } catch {
        return "无法连接更新源：\(error.localizedDescription)"
    }
}

/// 托管 Sparkle 自动更新控制器
///
/// 自动更新要三样东西同时到位：
///   ① Info.plist 的 `SUPublicEDKey`（`build.sh` 从仓库根目录 `sparkle_public_key.txt` 写入）
///   ② 用对应私钥签名的安装包（`scripts/make_appcast.sh` + `generate_appcast` 负责）
///   ③ **匿名**可访问的 appcast（Sparkle 拉 feed 不带凭证）
///
/// v3.0 起 ①② 已就位；③ 取决于仓库可见性 —— 仓库私有时匿名请求一律 404。
/// 所以这里在启动 updater **之前先探一次 feed**，把"拉不到"翻译成人话，
/// 而不是把 Sparkle 的原始报错抛给用户（这正是本类存在的理由）。
///
/// 历史遗留提醒：`feedURL` 曾经写错过仓库（`fan/…`）且 URL 形式不合法。
@MainActor
final class UpdateManager: ObservableObject {

    /// appcast 地址。仓库改名/转移时，**三处必须同步**改：
    ///   1. 这里
    ///   2. `build.sh` 写进 Info.plist 的 `SUFeedURL`
    ///   3. `scripts/make_appcast.sh` 的 `URL_PREFIX`
    static let feedURL =
        "https://github.com/xfanchuang-dot/suishouqian/releases/latest/download/appcast.xml"

    private let updaterController: SPUStandardUpdaterController
    private var started = false
    /// 预检进行中，防止用户连点「检查更新」时叠出多个弹窗
    private var probing = false

    init() {
        // 程序化设置更新源，避免依赖 Info.plist（两条路都留着，改仓库时不必重建包）
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
            presentNotice(
                title: "自动更新尚未启用",
                body: """
                当前安装包里没有更新公钥（Info.plist 的 SUPublicEDKey），\
                所以无法校验更新包。

                公钥来自仓库根目录的 sparkle_public_key.txt，由 build.sh 在构建时写入。
                用 bash build.sh 重新构建安装即可带上；在此之前，升级方式就是重新构建。
                """
            )
            return
        }

        guard !probing else { return }
        probing = true
        Task { [weak self] in
            guard let self else { return }
            let failure = await probeUpdateFeed(Self.feedURL)
            self.probing = false

            if let failure {
                self.presentNotice(
                    title: "更新源暂时不可用",
                    body: """
                    \(failure)

                    这不影响当前版本的使用。也可以到项目的 Releases 页面手动下载新版安装包。
                    """
                )
                return
            }

            if !self.started {
                self.updaterController.startUpdater()
                self.started = true
            }
            self.updaterController.checkForUpdates(nil)
        }
    }

    private func presentNotice(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
