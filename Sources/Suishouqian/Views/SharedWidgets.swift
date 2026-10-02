import SwiftUI

/// 全局任务胶囊（v3.1 附录 A2，Muse 审查 6.2）：任何面板都能看到正在跑的迁移/回迁/撤销。
/// 自带显隐；点一下直达迁移面板看详情。
struct GlobalTaskCapsule: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let task = appState.migrationTask, !task.status.isTerminal {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(task.currentFile.isEmpty ? task.app.name : task.currentFile)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .frame(maxWidth: 220)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .onTapGesture { appState.activePanel = .migrate }
            .help("正在处理，点击查看进度")
        }
    }
}

/// 「外置盘未连接」统一横幅（v3.1 附录 A4，Muse 审查 6.5）：全应用只此一处文案。
/// 知道盘名时说名字（"「X」未连接"比泛泛的"未检测到"更让人安心），不知道才说无盘。
enum VolumeOfflineBanner {

    static func message(for volumeName: String?) -> String {
        if let volumeName {
            return "「\(volumeName)」未连接，插回后自动恢复"
        }
        return "未检测到外置硬盘，插入后自动识别"
    }

    static func systemImage(for volumeName: String?) -> String {
        volumeName == nil ? "questionmark.circle" : "externaldrive.badge.exclamationmark"
    }
}
