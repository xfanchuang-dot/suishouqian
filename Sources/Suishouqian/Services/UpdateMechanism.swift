import Foundation

/// 应用的更新方式——决定「这个应用搬到外置盘后，更新会不会把迁移顶掉」。
///
/// 判据全部来自 bundle 内的权威标记，不联网、不启动应用、不做猜测：
/// - `Contents/_MASReceipt/receipt` 是 App Store 安装时写入的收据
///   （本机实测与 Gatekeeper 报出的 `source=Mac App Store` 结论一致）
/// - `Squirrel.framework` / `Sparkle.framework` / Info.plist 的 `SUFeedURL`
///   是应用自带更新器的标记
///
/// 为什么要区分：App Store 的更新由系统组件执行，它按 `/Applications/名字.app`
/// 这个**位置**办事，会把真目录写回那里——如果该位置是迁移留下的软链接，
/// 就被顶掉（迁移被悄悄撤销）。自带更新器则按"应用实际所在位置"更新，
/// 软链接会被解析到外置盘，更新就地写在外置盘上，迁移不受影响。
enum UpdateMechanism: String, Equatable {
    /// App Store 安装：不建议迁移本体（更新会把迁移顶掉）
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

    /// 是否建议把它搬到外置盘（App Store 应用不建议）
    var isSafeToRelocate: Bool { self != .appStore }

    /// 用大白话讲清"搬走之后更新会怎样"，供列表悬停与迁移前确认复用
    var guidance: String {
        switch self {
        case .appStore:
            return """
            这是 App Store 安装的应用。它的更新由系统负责，而系统只认「应用程序」文件夹：\
            更新时会把应用重新装回那里，从而把迁移顶掉（数据不会丢，但腾出来的内置盘空间又被占回去）。

            建议：让它留在内置盘，改用「数据」面板迁移它的大体积数据（数据目录不受应用升级影响）。
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

    /// 该应用按某种方式搬走后，"下次更新会发生什么"。
    /// 只对能讲清后果的 App Store 应用返回文案；其余返回 nil（自带更新器的应用两种
    /// 搬法都正常，看不出更新方式的应用纯搬迁反而更稳，都不需要额外警告）。
    ///
    /// 两种搬法的失败形态不同，必须分开讲：
    /// - 留链接：更新把真目录写回 /Applications 顶掉链接 → 应用回到内置盘、照常能用，
    ///   外置盘剩一份旧副本。**优雅降级**，只是空间白折腾一轮。
    /// - 不留链接：应用不在 /Applications，App Store 视其为"没装" → 更新很可能再装一份到
    ///   /Applications，于是**两份并存**，且外置盘那份旧版本仍会被 Spotlight 搜到。
    func updateConsequence(linkBack: Bool) -> String? {
        guard self == .appStore else { return nil }
        return linkBack
            ? """
              下次 App Store 更新会把应用重新装回「应用程序」文件夹，链接被顶掉：\
              应用回到内置盘、照常能用，外置盘上的旧副本删掉即可。不会丢数据，但空间白折腾一轮。
              """
            : """
              它搬走后就不在「应用程序」里了，App Store 会把它当成"没装"：\
              下次更新很可能往「应用程序」装一份新的，于是内置盘和外置盘各有一份，\
              而外置盘那份旧版本仍会被 Spotlight 搜到。
              """
    }
}
