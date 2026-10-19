import SwiftUI
import AppKit

/// 更新助手共用的退出引导（第一步「更新」与第三步「搬回去」都要过这道闸）：
/// 应用在运行时弹窗提供「帮我退出」（terminate + 轮询最多 10 秒）或「我自己退出」。
/// 返回 true = 可以继续搬运。
@MainActor
enum UpdateQuitPrompt {
    static func ensureNotRunning(appPath: String) -> Bool {
        guard let running = AppMigrator.runningAppName(matching: appPath) else { return true }
        let alert = NSAlert()
        alert.messageText = "「\(running)」正在运行"
        alert.informativeText = "需要完全退出 App 才能继续。可以让我帮你退出（未保存的内容会先弹 App 自己的保存框），也可以你自己按 ⌘Q 退出后重试。"
        alert.addButton(withTitle: "帮我退出")
        alert.addButton(withTitle: "我自己退出")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let instance = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == running
        }) {
            instance.terminate()
            for _ in 0..<50 where !instance.isTerminated {
                usleep(200_000)   // 最多等 10 秒
            }
        }
        if AppMigrator.runningAppName(matching: appPath) != nil {
            let still = NSAlert()
            still.messageText = "「\(running)」还没有退出"
            still.informativeText = "可能是它在等你确认保存。退出后重试。"
            still.runModal()
            return false
        }
        return true
    }
}

/// 更新助手向导：三步流程的展示与操作入口。
///
/// 步骤：
/// 1. 移回内置盘（已完成，进入向导时 App 已经在 /Applications）
/// 2. 去更新（当前步骤：按 updateMechanism 自适应指引）
/// 3. 搬回去（用户点按钮触发）
///
/// 由 AppState.activeUpdateSession 驱动显示；关闭 = 取消流程（App 留在内置盘，session 保留可继续）。
struct UpdateWizardView: View {
    let session: UpdateSession
    let mechanism: UpdateMechanism
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新「\(session.appName)」")
                        .font(.system(size: 15, weight: .semibold))
                    Text("已搬回内置盘，更新完成后搬回去")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // 三步指示器
            HStack(spacing: 0) {
                stepView(number: 1, title: "移回内置盘", state: .done)
                stepConnector()
                stepView(number: 2, title: "去更新", state: .current)
                stepConnector()
                stepView(number: 3, title: "搬回去", state: .todo)
            }
            .padding(.vertical, 4)

            Divider()

            // 第二步指引（按更新方式自适应）
            VStack(alignment: .leading, spacing: 8) {
                Text("现在去更新 App")
                    .font(.system(size: 13, weight: .medium))
                Text(updateGuidance)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            Spacer()

            // 操作按钮
            HStack {
                // 取消：App 留在内置盘，session 保留，下次可继续
                Button("稍后") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                // 放弃：删除会话（App 留在内置盘，去留由用户自行决定）
                Button("放弃此次") {
                    abandonSession()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                Spacer()

                if mechanism == .squirrel || mechanism == .sparkle {
                    Button("打开 App 检查更新") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: session.appPath))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Button("已更新，搬回去") {
                    moveBackToExternal()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(appState.isMigrationActive)
            }
        }
        .padding(20)
        .frame(width: 440, height: 340)
    }

    /// 按更新方式自适应的第二步文案
    private var updateGuidance: String {
        switch mechanism {
        case .squirrel, .sparkle:
            return "「\(session.appName)」自带更新器。点「打开 App 检查更新」，在 App 内完成更新后完全退出 App（⌘Q），回到这里点「已更新，搬回去」。"
        case .unknown:
            return "去官网下载「\(session.appName)」的新版 DMG，覆盖安装到「应用程序」里的版本（已在内置盘）。完成后完全退出 App（⌘Q），回到这里点「已更新，搬回去」。\n\n也可以先打开 App 看看有没有「检查更新」菜单。"
        case .appStore:
            // 更新助手入口已过滤 appStore，这里防御性兜底
            return "App Store 应用请直接在 App Store 里更新。"
        }
    }

    private enum StepState { case done, current, todo }

    private func stepView(number: Int, title: String, state: StepState) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(state == .todo ? Color.secondary.opacity(0.15) : Color.accentColor)
                    .frame(width: 24, height: 24)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(state == .todo ? .secondary : .white)
                }
            }
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(state == .current ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepConnector() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
            .padding(.horizontal, 2)
            .offset(y: -10)
    }

    /// 放弃此次更新助手：删会话并关向导。App 已在内置盘，之后想回外置盘用普通迁移即可
    private func abandonSession() {
        let alert = NSAlert()
        alert.messageText = "放弃「\(session.appName)」的更新助手流程？"
        alert.informativeText = "会话记录会被删除。App 现在留在「应用程序」（内置盘），之后想搬回外置盘可以用列表里的「迁移」或「纯搬迁」。"
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "继续流程")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            appState.abandonUpdateSession(session)
            dismiss()
        }
    }

    /// 第三步：搬回外置盘（纯搬迁：跳过备份，直接移动）
    private func moveBackToExternal() {
        // 运行预检：迁移引擎本身会拦，但那是在 sheet 关闭之后，用户只看到任务失败
        guard UpdateQuitPrompt.ensureNotRunning(appPath: session.appPath) else { return }

        guard let drive = appState.externalDrive else {
            let alert = NSAlert()
            alert.messageText = "未检测到外置盘"
            alert.informativeText = "「\(session.appName)」要搬回外置盘，请先连接磁盘后再点「已更新，搬回去」。"
            alert.runModal()
            return
        }
        // 外置盘必须在线：目标是 session 里记录的原位置
        let targetDir = (session.originalExternalPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: targetDir) else {
            let alert = NSAlert()
            alert.messageText = "外置盘未挂载"
            alert.informativeText = "「\(session.appName)」原来的位置在外置盘上（\(targetDir)），请先插入该磁盘再搬回去。"
            alert.runModal()
            return
        }

        dismiss()

        // 构造一个临时的 AppItem（指向 /Applications 里的版本）
        // restore/migrate 需要 AppItem；用 bundleID 从最新扫描结果里找，找不到就用 session 信息构造
        Task { @MainActor [weak appState] in
            guard let appState else { return }
            // 先重新扫描拿到最新状态
            await appState.scanApps()
            guard let app = appState.apps.first(where: {
                $0.bundleID == session.bundleID && $0.path == session.appPath
            }) ?? appState.apps.first(where: { $0.path == session.appPath }) else {
                let alert = NSAlert()
                alert.messageText = "找不到「\(session.appName)」"
                alert.informativeText = "它可能已被移动或删除。是结束这次更新助手（删除会话记录），还是保留记录稍后再试？"
                alert.addButton(withTitle: "保留记录")
                alert.addButton(withTitle: "结束并删除记录")
                if alert.runModal() == .alertSecondButtonReturn {
                    // 用放弃语义：此时 App 并没有搬回外置盘，不能记成"完成"
                    appState.abandonUpdateSession(session)
                }
                return
            }

            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            let state = appState
            let onProgress: @Sendable (Double, String) -> Void = { @Sendable pct, desc in
                Task { @MainActor in
                    state.reportMigrationProgress(pct, desc)
                }
            }
            // 搬回去：纯搬迁模式（跳过备份）＋ 按原来是否有链接决定 createLink
            // 子目录按原位置相对卷根提取，精确还原（Applications/、Suishouqian_Apps/、卷根直放）
            let subdir = UpdateSession.targetSubdir(of: session.originalExternalPath,
                                                    volumeMount: drive.mountPoint)
            let result = await state.migrator.migrate(
                app: app, to: drive.mountPoint,
                createLink: session.wasMigrated,
                skipBackup: true,
                targetSubdir: subdir,
                progress: onProgress)

            if result.success {
                state.migrationTask = nil
                await state.finishUpdateSession(session, completed: true)
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
            } else if var t = state.migrationTask {
                t.status = .failed(result.error ?? "未知错误")
                state.migrationTask = t
            }
        }
    }
}
