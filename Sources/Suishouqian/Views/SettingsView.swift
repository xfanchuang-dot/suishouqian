import SwiftUI

/// 设置窗口（⌘,）：通用提醒 / 备份 / 外置盘守护
/// 开关统一走 UserDefaults（App.swift 里注册默认值），
/// 业务侧每轮 tick/发送前读取，改完即时生效、无需重启。
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("spaceGuardEnabled") private var spaceGuard = true
    @AppStorage("newAppReminderEnabled") private var newAppReminder = true
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("backupRetentionDays") private var backupDays = 7
    @State private var daemonOn = LaunchAgentManager.isInstalled

    var body: some View {
        TabView {
            generalForm
                .tabItem { Label("通用", systemImage: "gearshape") }
            backupForm
                .tabItem { Label("备份", systemImage: "archivebox") }
            guardForm
                .tabItem { Label("外置盘守护", systemImage: "bolt.badge.clock") }
        }
        .frame(width: 480)
    }

    // MARK: - 通用

    private var generalForm: some View {
        Form {
            Section("提醒") {
                Toggle("内置盘空间守卫", isOn: $spaceGuard)
                Text("内置盘可用空间低于 40GB 时提醒，并附上可迁移应用清单。")
                    .settingHint()
                Toggle("新装大应用提醒", isOn: $newAppReminder)
                Text("发现新安装的 ≥500MB 应用时，提醒是否搬到外置硬盘。")
                    .settingHint()
                Toggle("系统通知", isOn: $notifications)
                Text("迁移完成/失败、插拔盘、空间告警等通知的总开关。")
                    .settingHint()
            }

            Section("系统授权（各授予一次，更新重装不失效）") {
                authorizationRow(
                    title: "修改其他应用（App Management）",
                    detail: "迁移/回迁/修复都要改动 /Applications。不授予会反复弹「想要修改其他应用程序」。",
                    pane: "com.apple.preference.security?Privacy_AppManagement",
                    statusText: "建议授予")
                authorizationRow(
                    title: "完全磁盘访问",
                    detail: "可选。授予后大文件扫描自动覆盖桌面/文稿/下载；不授予也不影响迁移功能。",
                    pane: "com.apple.preference.security?Privacy_AllFiles",
                    statusText: appState.healthChecker.hasFullDiskAccess ? "已授予" : "未授予（可选）")
                Text("注：迁移系统自带安装的、属于 root 的应用时仍会要求输入一次管理员密码（安全设计，5 分钟内连续迁移只输一次），这是正常的，无法也不应绕过。")
                    .settingHint()
            }
        }
        .formStyle(.grouped)
    }

    private func authorizationRow(title: String, detail: String,
                                  pane: String, statusText: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(statusText)
                    .font(.system(size: 11, weight: statusText.hasPrefix("已") ? .semibold : .regular))
                    .foregroundColor(statusText.hasPrefix("已") ? .green : .secondary)
                Button("去授权") {
                    if let url = URL(string: "x-apple.systempreferences:\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
            Text(detail)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 备份

    private var backupForm: some View {
        Form {
            Section("备份保留") {
                Picker("迁移前备份保留", selection: $backupDays) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                .pickerStyle(.menu)
                Text("每次迁移会在外置盘 .suishouqian-backup 目录留底，超过保留期后在下次扫描时自动清理；回迁成功后对应备份即被回收。")
                    .settingHint()
            }

            Section("审计日志") {
                Button("打开审计日志") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [AuditLog.currentLogURL])
                }
                Text("迁移、回迁、卸载、修复、备份清理的全部操作记录，出问题时可回答“这个应用什么时候被动过”。")
                    .settingHint()
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 外置盘守护

    private var guardForm: some View {
        Form {
            Section("插盘自动打开") {
                Toggle("外置硬盘接入时自动打开随手迁", isOn: $daemonOn)
                    .disabled(appState.externalDrive == nil && !daemonOn)
                    .onChange(of: daemonOn) { _, on in
                        let ok: Bool
                        if on {
                            if let mount = appState.externalDrive?.mountPoint {
                                // 只监听该盘挂载点 + 挂载边沿检测，
                                // 不会因盘上文件变动或 Time Machine 快照误触发
                                ok = LaunchAgentManager.install(watchPath: mount)
                            } else {
                                ok = false
                            }
                        } else {
                            ok = LaunchAgentManager.uninstall()
                        }
                        if ok != on { daemonOn = ok }  // 失败回弹到真实状态
                    }

                if let drive = appState.externalDrive {
                    LabeledContent("当前外置硬盘",
                                   value: "\(drive.name)（\(drive.mountPoint)）")
                } else {
                    LabeledContent("当前外置硬盘", value: "未连接")
                }
                Text(appState.externalDrive == nil && !daemonOn
                     ? "插入外置硬盘后才能开启。"
                     : "仅在“未挂载 → 已挂载”的瞬间唤起一次，应用已在运行时不重复打开。")
                    .settingHint()
            }
        }
        .formStyle(.grouped)
    }
}

/// 设置页说明文字统一小号灰字
private extension View {
    func settingHint() -> some View {
        font(.footnote)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
