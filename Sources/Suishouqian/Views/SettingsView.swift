import SwiftUI
import AppKit

/// 设置（效果图版）：顶部胶囊页签（通用/备份/外置盘守护）+ 标题/副标题/右侧开关行。
/// 侧栏设置页与 ⌘, 独立窗口共用本视图。
/// 开关统一走 UserDefaults（App.swift 里注册默认值），
/// 业务侧每轮 tick/发送前读取，改完即时生效、无需重启。
struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("spaceGuardEnabled") private var spaceGuard = true
    @AppStorage("newAppReminderEnabled") private var newAppReminder = true
    @AppStorage("notificationsEnabled") private var notifications = true
    @AppStorage("backupRetentionDays") private var backupDays = 7
    @AppStorage("bigFileExtendedScanEnabled") private var bigFileExtended = false
    /// 菜单栏常驻（v3.1 实验开关，默认关）
    @AppStorage("menuBarExtraEnabled") private var menuBarExtra = false
    /// 备份盘选择（"" = 与应用同盘，默认；否则为卷 UUID）
    @State private var backupVolume: String =
        BackupLocations.alternateVolumeUUID ?? ""
    /// 升级顶掉自动重迁（opt-in，默认关）
    @AppStorage(AutoRemigrateService.enabledKey) private var autoRemigrate = false
    @State private var daemonOn = LaunchAgentManager.isInstalled
    @State private var tab: Tab = .general

    enum Tab: Hashable { case general, backup, watch, about }

    /// 检查更新用（懒启动：点按钮才拉 Sparkle，无启动开销；两实例各自持有无妨）
    @State private var updateManager = UpdateManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MockCapsuleTabs(
                tabs: [(.general, "通用"), (.backup, "备份"), (.watch, "外置盘守护"),
                       (.about, "关于")],
                selection: $tab)

            ScrollView {
                VStack(spacing: 0) {
                    switch tab {
                    case .general: generalRows
                    case .backup: backupRows
                    case .watch: watchRows
                    case .about: aboutRows
                    }
                }
            }
        }
        .padding(4)
    }

    // MARK: - 行组件（效果图：粗标题 + 灰副标题 + 右侧控件，行间发丝分隔线）

    private func switchRow(_ title: String, _ subtitle: String,
                           isOn: Binding<Bool>, disabled: Bool = false,
                           onChange: ((Bool) -> Void)? = nil) -> some View {
        row(title, subtitle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(.blue)  // 效果图：开启态为蓝色开关
                .disabled(disabled)
                .onChange(of: isOn.wrappedValue) { _, new in onChange?(new) }
        }
    }

    private func row<Control: View>(_ title: String, _ subtitle: String,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 14)
    }

    private var rowDivider: some View {
        Divider().opacity(0.6)
    }

    // MARK: - 通用

    @ViewBuilder
    private var generalRows: some View {
        switchRow("内置盘空间守卫",
                  "内置盘可用空间低于 40GB 时提醒，并附上可迁移应用清单",
                  isOn: $spaceGuard)
        rowDivider
        switchRow("新装大应用提醒",
                  "发现新安装的 ≥500MB 应用时，提醒是否搬到外置硬盘",
                  isOn: $newAppReminder)
        rowDivider
        switchRow("系统通知",
                  "迁移完成/失败、插拔盘、空间告警等通知的总开关",
                  isOn: $notifications)
        rowDivider
        switchRow("升级顶掉后自动重新迁移",
                  "应用自带更新器会把软链接换回真目录；开启后启动/插盘时自动检测并重迁（App Store 应用需手动）",
                  isOn: $autoRemigrate) { on in
            AuditLog.append("自动重迁开关：\(on ? "开" : "关")")
        }
        rowDivider
        switchRow("扩展扫描桌面/文稿/下载",
                  "默认只扫「资源库」零权限弹窗；开启前请先在下方授予完全磁盘访问权限",
                  isOn: $bigFileExtended) { on in
            if on { confirmExtendedScan() }
        }
        rowDivider
        row("修改其他应用（App Management）",
            "迁移/回迁/修复都要改动 /Applications；不授予会反复弹「想要修改其他应用程序」。迁移系统自带 root 应用时仍会要一次管理员密码（安全设计，无法也不应绕过）") {
            Button("去授权") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppManagement") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }

    /// 开启扩展扫描前的知情确认（无法静默探测授权状态，用引导代替）
    private func confirmExtendedScan() {
        let alert = NSAlert()
        alert.messageText = "开启前请先授予完全磁盘访问权限"
        alert.informativeText = "请在 系统设置 → 隐私与安全性 → 完全磁盘访问权限 中勾选「随手迁」，否则桌面/文稿/下载扫描不到内容，且可能反复弹授权框。"
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "仍要开启")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            bigFileExtended = false
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            break
        default:
            bigFileExtended = false
        }
    }

    // MARK: - 备份

    @ViewBuilder
    private var backupRows: some View {
        row("迁移前备份保留",
            "每次迁移在外置盘 .suishouqian-backup 留底，超期后下次扫描自动清理；回迁成功即回收") {
            Picker("", selection: $backupDays) {
                Text("7 天").tag(7)
                Text("14 天").tag(14)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }
            .pickerStyle(.menu)
            .frame(width: 110)
        }
        rowDivider
        row("备份存放位置",
            "放另一块外置盘：盘体物理损坏时应用与备份不同时丢失。只影响新备份；指定盘离线自动回退同盘") {
            Picker("", selection: $backupVolume) {
                Text("与应用同盘").tag("")
                ForEach(appState.volumeStore.onlineVolumes) { vol in
                    Text(vol.displayName).tag(vol.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
            .onChange(of: backupVolume) { _, new in
                BackupLocations.alternateVolumeUUID = new.isEmpty ? nil : new
                if new.isEmpty {
                    AuditLog.append("备份存放位置：改回「与应用同盘」")
                } else {
                    let name = appState.volumeStore.volumes
                        .first { $0.id == new }?.displayName ?? new
                    AuditLog.append("备份存放位置：指定为「\(name)」")
                }
            }
        }
        rowDivider
        row("审计日志",
            "迁移、回迁、卸载、修复、备份清理的全部操作记录，可回答「这个应用什么时候被动过」") {
            Button("打开日志") {
                NSWorkspace.shared.activateFileViewerSelecting([AuditLog.currentLogURL])
            }
            .controlSize(.small)
        }
    }

    // MARK: - 外置盘守护

    @ViewBuilder
    private var watchRows: some View {
        switchRow("外置硬盘接入时自动打开随手迁",
                  appState.externalDrive == nil && !daemonOn
                    ? "插入外置硬盘后才能开启"
                    : "仅在「未挂载 → 已挂载」瞬间唤起一次，应用已在运行时不重复打开",
                  isOn: $daemonOn,
                  disabled: appState.externalDrive == nil && !daemonOn) { on in
            let ok: Bool
            if on {
                if let mount = appState.externalDrive?.mountPoint {
                    ok = LaunchAgentManager.install(watchPath: mount)
                } else {
                    ok = false
                }
            } else {
                ok = LaunchAgentManager.uninstall()
            }
            if ok != on { daemonOn = ok }  // 失败回弹到真实状态
        }
        rowDivider
        row("当前外置硬盘",
            appState.externalDrive.map { "\($0.name)（\($0.mountPoint)）" } ?? "未连接") {
            Image(systemName: appState.externalDrive == nil
                  ? "externaldrive.badge.exclamationmark" : "externaldrive.fill")
                .foregroundColor(appState.externalDrive == nil ? .secondary : .green)
        }
        rowDivider
        switchRow("在菜单栏显示随手迁（实验）",
                  "只显示各盘可用空间和打开/退出入口，不做后台轮询",
                  isOn: $menuBarExtra)
    }

    // MARK: - 关于

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
    }

    @ViewBuilder
    private var aboutRows: some View {
        // 头部：应用图标 + 名称 + 版本 + 一句话定位
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text("随手迁")
                    .font(.system(size: 18, weight: .bold))
                Text("版本 \(Self.appVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("把内置盘上的大应用安全搬到外置磁盘，释放空间")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 16)
        rowDivider
        row("检查更新...",
            "通过 Sparkle 更新通道检查新版本（未配置通道时会说明原因）") {
            Button("检查") { updateManager.checkForUpdates() }
                .buttonStyle(.bordered)
        }
        rowDivider
        row("关于面板",
            "系统标准的应用信息与版权面板") {
            Button("打开") { NSApp.orderFrontStandardAboutPanel(nil) }
                .buttonStyle(.bordered)
        }
        rowDivider
        Text("© 2026 随手迁 · 为个人 Mac 打造的应用迁移工具")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
    }
}
