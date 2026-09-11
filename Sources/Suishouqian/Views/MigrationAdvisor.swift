import AppKit

/// 迁移前的知情确认。
///
/// 只在**用户主动点迁移**时出现，不做任何后台扫描或主动提醒——
/// 目的单一：把"这个应用搬走后更新会怎样"讲清楚，避免用户踩了坑才知道。
enum MigrationAdvisor {

    /// 单个应用：App Store 应用先确认；其余直接放行（不打扰）
    @MainActor
    static func confirmRelocation(of app: AppItem) -> Bool {
        guard !app.updateMechanism.isSafeToRelocate else { return true }

        let alert = NSAlert()
        alert.messageText = "「\(app.name)」是 App Store 安装的应用"
        alert.informativeText = """
        \(app.updateMechanism.guidance)

        仍然要搬到外置盘吗？
        """
        alert.addButton(withTitle: "留在内置盘（推荐）")
        alert.addButton(withTitle: "仍然搬走")
        alert.alertStyle = .warning
        // 默认按钮是"留在内置盘"：误按回车时走安全的一侧
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// 批量迁移：只提示其中会被更新顶掉的 App Store 应用，让用户决定是否跳过。
    /// 返回要迁移的清单；返回 nil 表示用户取消整批操作。
    @MainActor
    static func resolveBatch(_ apps: [AppItem]) -> [AppItem]? {
        let risky = apps.filter { !$0.updateMechanism.isSafeToRelocate }
        guard !risky.isEmpty else { return apps }

        let names = risky.prefix(5).map(\.name).joined(separator: "、")
        let more = risky.count > 5 ? " 等 \(risky.count) 个" : ""
        let alert = NSAlert()
        alert.messageText = "其中 \(risky.count) 个是 App Store 应用"
        alert.informativeText = """
        \(names)\(more)。

        它们的更新由系统负责，更新时会把应用重新装回「应用程序」文件夹，\
        从而把迁移顶掉（不会丢数据，但腾出来的空间又被占回去）。\
        建议让它们留在内置盘，改用「数据」面板迁移它们的大体积数据。

        其余 \(apps.count - risky.count) 个可以正常迁移。
        """
        alert.addButton(withTitle: "跳过这 \(risky.count) 个，迁移其余")
        alert.addButton(withTitle: "全部迁移")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return apps.filter { $0.updateMechanism.isSafeToRelocate }
        case .alertSecondButtonReturn:
            return apps
        default:
            return nil
        }
    }
}
