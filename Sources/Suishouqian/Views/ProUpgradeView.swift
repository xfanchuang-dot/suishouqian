import SwiftUI
import AppKit

/// Pro 购买 / 试用 / 许可证管理。设置「Pro」页签与全局 Sheet 共用同一份内容。
struct ProUpgradeContent: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var licenseManager = LicenseManager.shared

    @State private var licenseInput = ""
    @State private var licenseMessage: String?
    @State private var showLicenseField = false
    @State private var showDeactivateConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard
            benefitsCard
            actionCard
            footnote
        }
        .onAppear { licenseManager.refreshEntitlement() }
    }

    // MARK: - 状态

    private var statusCard: some View {
        HStack(spacing: 14) {
            MockIconSquare(systemImage: "sparkles", color: MockTheme.accent, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(l10n("随手迁 Pro"))
                        .font(.system(size: 18, weight: .bold))
                    statusPill
                }
                Text(statusSubtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .mockCard()
    }

    @ViewBuilder
    private var statusPill: some View {
        switch licenseManager.entitlement {
        case .pro:
            StatusPill(l10n("已激活"), systemImage: "checkmark.seal.fill",
                       color: MockTheme.healthGreen)
        case .trial(let days):
            StatusPill(l10n("试用中 · 剩 %lld 天", days), systemImage: "hourglass",
                       color: MockTheme.statOrange)
        case .free:
            StatusPill(l10n("免费版"), systemImage: "leaf.fill", color: .secondary)
        }
    }

    private var statusSubtitle: String {
        switch licenseManager.entitlement {
        case .pro(let email, let expiry):
            return l10n("感谢支持！许可证：%@ · %@", email, expiryText(expiry))
        case .trial(let days):
            return l10n("试用还剩 %lld 天，全部 Pro 功能已解锁；到期后自动回到免费版，不扣费。", days)
        case .free:
            return l10n("核心迁移、回迁、体检、备份全部免费。Pro 解锁版本化备份与智能建议。")
        }
    }

    private func expiryText(_ date: Date) -> String {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        if year >= 2090 { return l10n("永久有效") }
        return l10n("%@ 到期", BackupVersionStore.displayText(date))
    }

    // MARK: - 权益

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: l10n("Pro 权益"), systemImage: "gift")
            benefitRow(icon: "clock.arrow.circlepath", feature: .versionedBackup,
                       live: true)
            benefitRow(icon: "wand.and.stars", feature: .smartAdvice, live: true)
            benefitRow(icon: "arrow.triangle.2.circlepath",
                       title: l10n("多 Mac 配置同步"),
                       detail: l10n("一台 Mac 上配好的偏好与备份策略，同步到其它 Mac"),
                       live: false)
        }
        .mockCard()
    }

    private func benefitRow(icon: String, feature: ProFeature, live: Bool) -> some View {
        benefitRow(icon: icon, title: feature.title, detail: feature.detail, live: live)
    }

    private func benefitRow(icon: String, title: String, detail: String, live: Bool) -> some View {
        HStack(spacing: 12) {
            DriveIconBox(systemImage: icon, color: live ? MockTheme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if live {
                StatusPill(l10n("已上线"), systemImage: "checkmark",
                           color: MockTheme.healthGreen)
            } else {
                StatusPill(l10n("开发中"), systemImage: "hammer",
                           color: .secondary)
            }
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch licenseManager.entitlement {
            case .free:
                buyRow
                if !licenseManager.hasUsedTrial {
                    HStack {
                        Button(l10n("免费试用 7 天")) { startTrialWithConfirm() }
                            .buttonStyle(.plain)
                            .secondaryCommand()
                        Spacer()
                    }
                }
                licenseEntry
            case .trial:
                buyRow
                licenseEntry
            case .pro:
                HStack(spacing: 10) {
                    Text(l10n("许可证已在本机生效，换 Mac 时把同一串粘到新机器的输入框即可。"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(l10n("解除激活")) { showDeactivateConfirm = true }
                        .buttonStyle(.plain)
                        .secondaryCommand(tint: .red)
                        .alert(l10n("解除本机 Pro 激活？"), isPresented: $showDeactivateConfirm) {
                            Button(l10n("解除激活"), role: .destructive) {
                                licenseManager.deactivate()
                                licenseMessage = nil
                                AuditLog.append("Pro 许可证已退出")
                            }
                            Button(l10n("取消"), role: .cancel) {}
                        } message: {
                            Text(l10n("解除后本机回到免费版（试用不会重置）。许可证字符串仍在你手里，随时可重新粘贴激活。"))
                        }
                }
            }
        }
        .mockCard()
    }

    private var buyRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n("¥29 · 一次性买断"))
                    .font(.system(size: 16, weight: .bold))
                Text(l10n("支付宝转账（xios.uk），人工发货；不是订阅，不会重复扣费。"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            PrimaryActionButton(title: l10n("购买 Pro"), systemImage: "cart.fill") {
                NSWorkspace.shared.open(PurchaseLinks.proCheckout)
            }
        }
    }

    @ViewBuilder
    private var licenseEntry: some View {
        if showLicenseField {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField(l10n("粘贴许可证"), text: $licenseInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Button(l10n("激活")) {
                        let result = licenseManager.activate(license: licenseInput)
                        licenseMessage = result.message
                        if result.ok {
                            licenseInput = ""
                            showLicenseField = false
                        }
                    }
                    .controlSize(.small)
                }
                if let msg = licenseMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(licenseManager.isPro ? .green : .red)
                }
                Text(l10n("购买后把收到的许可证整行粘贴进来。离线验签，不联网、不上传任何信息。"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        } else {
            HStack {
                Button(l10n("已有许可证？去激活")) {
                    showLicenseField = true
                    licenseMessage = nil
                }
                .buttonStyle(.plain)
                .secondaryCommand()
                Spacer()
            }
        }
    }

    private var footnote: some View {
        Text(l10n("随手迁是 MIT 开源的本地工具：许可证离线验签，不收集数据。Pro 收入用于持续维护与后续功能。"))
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 试用

    private func startTrialWithConfirm() {
        let alert = NSAlert()
        alert.messageText = l10n("开始 7 天 Pro 试用？")
        alert.informativeText = l10n("\n        试用解锁版本化备份与智能迁移建议，全部本地运行。\n        每个许可证/每台机器只能试用一次，到期不扣费、不自动续。\n        ")
        alert.addButton(withTitle: l10n("开始试用"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ok = licenseManager.startTrial()
        licenseMessage = ok ? nil : l10n("本机已用过试用")
    }
}

/// 全局 Pro 升级 Sheet（锁定卡 / 各页面入口共用）
struct ProUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n("升级 Pro"))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n("关闭"))
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            ScrollView {
                ProUpgradeContent()
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
        }
        .frame(width: 620, height: 600)
    }
}

/// 锁定态卡片：未解锁 Pro 的功能统一用它，避免各页面自己拼一套文案与按钮。
struct ProLockedCard: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var licenseManager = LicenseManager.shared

    let icon: String
    let title: String
    let detail: String
    /// 额外提示（如"已保留 N 份历史版本"）
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DriveIconBox(systemImage: icon, color: MockTheme.accent)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    StatusPill(l10n("Pro"), systemImage: "lock.fill",
                               color: MockTheme.accent)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    if !licenseManager.hasUsedTrial {
                        Button(l10n("免费试用 7 天")) { startTrial() }
                            .controlSize(.small)
                    }
                    Button(l10n("升级 Pro")) {
                        appState.showProUpgrade = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .mockCard()
    }

    private func startTrial() {
        let alert = NSAlert()
        alert.messageText = l10n("开始 7 天 Pro 试用？")
        alert.informativeText = l10n("\n        试用解锁版本化备份与智能迁移建议，全部本地运行。\n        每台机器只能试用一次，到期不扣费、不自动续。\n        ")
        alert.addButton(withTitle: l10n("开始试用"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = licenseManager.startTrial()
    }
}
