import AppKit

/// 搬迁前的知情确认。
///
/// 只在**用户主动点搬迁**、且该应用确实有讲得清的后果时才弹窗——不做后台扫描、
/// 不做主动提醒。目的单一：把"这个应用这样搬走后，下次更新会怎样"讲清楚。
enum MigrationAdvisor {

    /// 单个应用：只有 `updateConsequence` 讲得出后果时才确认，其余直接放行（不打扰）。
    /// `linkBack` 决定讲哪种后果——两种搬法的风险不同，不能混为一谈
    @MainActor
    static func confirmRelocation(of app: AppItem, linkBack: Bool) -> Bool {
        guard let consequence = app.updateMechanism.updateConsequence(linkBack: linkBack) else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "「\(app.name)」是 App Store 安装的应用"
        alert.informativeText = """
        \(consequence)

        \(app.updateMechanism.guidance)
        """
        // 用户点的是「迁移」，默认按钮就尊重这个意图；取消后即可改用「纯搬迁」
        alert.addButton(withTitle: linkBack ? "仍然搬走（留链接）" : "仍然纯搬迁（不留链接）")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 批量迁移：批量走的是「留链接」，而其中 App Store 应用更适合用「纯搬迁」。
    /// 返回要迁移的清单；返回 nil 表示用户取消整批操作。
    @MainActor
    static func resolveBatch(_ apps: [AppItem]) -> [AppItem]? {
        let appStoreApps = apps.filter { $0.updateMechanism.prefersNoLink }
        guard !appStoreApps.isEmpty else { return apps }

        let names = appStoreApps.prefix(5).map(\.name).joined(separator: "、")
        let more = appStoreApps.count > 5 ? " 等 \(appStoreApps.count) 个" : ""
        let alert = NSAlert()
        alert.messageText = "其中 \(appStoreApps.count) 个是 App Store 应用"
        alert.informativeText = """
        \(names)\(more)。

        它们更适合用行内的「纯搬迁」（不留链接）：不留链接时 App Store 更新会就地写到\
        外置盘上（本机实测），搬迁不会被撤销。而这里的一键迁移用的是「留链接」，\
        更新有可能把链接换成真目录。

        其余 \(apps.count - appStoreApps.count) 个可以正常一键迁移。
        """
        alert.addButton(withTitle: "跳过这 \(appStoreApps.count) 个，迁移其余")
        alert.addButton(withTitle: "全部迁移（留链接）")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .informational

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return apps.filter { !$0.updateMechanism.prefersNoLink }
        case .alertSecondButtonReturn:
            return apps
        default:
            return nil
        }
    }
}
