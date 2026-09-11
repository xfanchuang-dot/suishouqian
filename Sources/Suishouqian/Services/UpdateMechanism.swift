import Foundation

/// 应用的更新方式——决定「这个应用搬到外置盘后，更新会怎样」。
///
/// 判据全部来自 bundle 内的权威标记，不联网、不启动应用、不做猜测：
/// - `Contents/_MASReceipt/receipt` 是 App Store 安装时写入的收据
///   （本机实测与 Gatekeeper 报出的 `source=Mac App Store` 结论一致）
/// - `Squirrel.framework` / `Sparkle.framework` / Info.plist 的 `SUFeedURL`
///   是应用自带更新器的标记
enum UpdateMechanism: String, Equatable {
    /// App Store 安装
    case appStore
    /// Electron 系自带更新器（Squirrel.Mac）
    case squirrel
    /// Sparkle 系自带更新器
    case sparkle
    /// 看不出更新方式的（系统应用、Google Keystone 系、自研更新器等）
    case unknown

    var label: String {
        switch self {
        case .appStore: return "App Store"
        case .squirrel, .sparkle: return "自带更新器"
        case .unknown: return "更新方式未知"
        }
    }

    /// 是否更适合用「纯搬迁」（不留链接）。
    ///
    /// App Store 应用更适合。**本机实测**（2026-09-11，QQ音乐，11.8.1 → 11.9.1）：
    /// 一个 App Store 应用被纯搬迁到外置盘（不在 /Applications、LaunchServices 登记的
    /// 就是外置盘路径）之后，App Store **仍把它列为可更新，并且就地更新了外置盘那份**——
    /// 收据时间被刷新，且没有在「应用程序」里另造一份。
    ///
    /// 也就是说 App Store 是跟着应用的实际位置走的，并不强求 /Applications。
    /// 而「留链接」能否扛住更新，本机尚未观测到（不能排除更新把链接换成真目录），
    /// 不留链接这条路已经实测干净，所以这类应用优先推荐纯搬迁。
    var prefersNoLink: Bool { self == .appStore }

    /// 用大白话讲清"这个应用搬走之后更新会怎样"，供列表悬停复用
    var guidance: String {
        switch self {
        case .appStore:
            return """
            这是 App Store 安装的应用。App Store 更新会跟着应用的实际位置走：\
            本机实测把一个 App Store 应用搬到外置盘后，更新就地把它升级（11.8.1 → 11.9.1），\
            没有在「应用程序」里另造一份。所以搬它是可行的，「纯搬迁」（不留链接）实测不受更新影响。

            注意：它一旦离开「应用程序」，就只能用 Spotlight / Dock 启动，\
            也不能再拖到废纸篓卸载（可以在本工具列表里卸载）。
            """
        case .squirrel, .sparkle:
            return """
            这个应用自带更新器。它按应用实际所在位置来更新，而启动时软链接会被解析到外置盘，\
            所以更新会直接写在外置盘那份上，迁移不会被打断。
            """
        case .unknown:
            return """
            从这个应用里看不出它的更新方式。搬到外置盘后请留意第一次更新：\
            若更新后「应用程序」里多出一个同名应用，说明更新把迁移顶掉了，届时可回迁内置盘。
            """
        }
    }

    /// 该应用按某种方式搬走后，"下次更新会发生什么"。
    /// 讲不出具体后果时返回 nil——调用方据此决定是否打扰用户。
    ///
    /// 两种搬法要分开讲：
    /// - 不留链接：**已实测**无影响（App Store 就地更新外置盘那份）→ 不警告
    /// - 留链接：更新会不会把链接换成真目录，本机尚未观测到，属未消除的不确定性 → 提一句
    func updateConsequence(linkBack: Bool) -> String? {
        guard self == .appStore, linkBack else { return nil }
        return """
              「留链接」这条路上有一个尚未消除的不确定性：更新有可能把「应用程序」里的\
             链接换成真目录，迁移就被悄悄撤销（不会丢数据，但腾出的内置盘空间被占回去）。
             这种情况体检页能发现，点「重新迁移」即可。

             想避开这个不确定性，可以取消后用行内的「纯搬迁」（不留链接）——\
             本机实测这条路不受更新影响。
             """
    }

    /// 探测更新方式。
    /// - Parameter infoPlist: 调用方已读过的 Info.plist（扫描器顺手传进来，省一次读盘）
    static func detect(atAppPath path: String, infoPlist: NSDictionary? = nil) -> UpdateMechanism {
        let fm = FileManager.default

        // App Store 优先判定：带收据的应用就该由系统管理，即使它同时捆了自带更新器
        if fm.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") {
            return .appStore
        }
        if fm.fileExists(atPath: path + "/Contents/Frameworks/Squirrel.framework") {
            return .squirrel
        }
        if fm.fileExists(atPath: path + "/Contents/Frameworks/Sparkle.framework") {
            return .sparkle
        }

        let plist = infoPlist ?? NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        if let feed = plist?["SUFeedURL"] as? String, !feed.isEmpty {
            return .sparkle
        }
        return .unknown
    }
}
