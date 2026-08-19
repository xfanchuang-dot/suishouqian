import SwiftUI

/// 链接体检面板：软链接状态一览 + 备份审计 + 一键修复/清理
struct HealthCheckView: View {
    @EnvironmentObject var appState: AppState

    @State private var links: [LinkHealth] = []
    @State private var backups: [BackupIssue] = []
    @State private var isChecking = false
    @State private var repairedCount = 0

    private let checker = HealthChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                linkSection
                if !backups.isEmpty { backupSection }
                if links.isEmpty && backups.isEmpty && !isChecking { emptyState }
            }
            .padding(.vertical, 4)
        }
        .onAppear { runCheck() }
    }

    private var header: some View {
        HStack {
            Text("体检")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
            if isChecking {
                ProgressView()
                    .controlSize(.small)
                Text("扫描中...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                Button("重新扫描") { runCheck() }
                    .controlSize(.small)
            }
        }
    }

    private var summary: (healthy: Int, offline: Int, broken: Int) {
        let healthy = links.filter { $0.state == .healthy }.count
        let offline = links.filter { $0.state == .volumeOffline }.count
        let broken = links.filter { $0.state == .broken }.count
        return (healthy, offline, broken)
    }

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let s = summary
            HStack(spacing: 12) {
                Label("\(s.healthy) 正常", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Label("\(s.offline) 硬盘未连接", systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundColor(s.offline > 0 ? .orange : .secondary)
                Label("\(s.broken) 断链", systemImage: "link.badge.plus")
                    .foregroundColor(s.broken > 0 ? .red : .secondary)
            }
            .font(.system(size: 12))

            if s.broken > 0 {
                Button("一键修复断链") { repairAll() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }

            ForEach(links) { link in
                linkRow(link)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func linkRow(_ link: LinkHealth) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color(for: link.state))
                .frame(width: 8, height: 8)

            Text(link.appName.replacingOccurrences(of: ".app", with: ""))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Text(link.state.label)
                .font(.system(size: 11))
                .foregroundColor(color(for: link.state))

            Spacer()

            if link.state == .broken {
                Button("修复") { repairOne(link) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("备份可清理（孤儿或超过 7 天）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                Button("全部清理") { cleanAllBackups() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }

            ForEach(backups) { issue in
                HStack {
                    Image(systemName: issue.isOrphan ? "trash.slash" : "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(issue.appName.replacingOccurrences(of: ".app", with: ""))
                        .font(.system(size: 12))
                    Text("\(issue.sizeFormatted) · \(issue.ageDays) 天前\(issue.isOrphan ? " · 应用已卸载" : "")")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("删除") {
                        checker.deleteBackup(issue)
                        backups.removeAll { $0.id == issue.id }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)
            Text("一切正常，没有发现断链或可清理的备份")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Actions

    private func runCheck() {
        isChecking = true
        let drive = appState.externalDrive?.mountPoint
        Task.detached {
            let l = checker.checkLinks()
            var b: [BackupIssue] = []
            if let drive { b = checker.checkBackups(drivePath: drive) }
            await MainActor.run {
                links = l
                backups = b
                isChecking = false
            }
        }
    }

    private func repairOne(_ link: LinkHealth) {
        if checker.repair(link) {
            runCheck()
        } else {
            let alert = NSAlert()
            alert.messageText = "修复失败"
            alert.informativeText = "在所有已挂载硬盘上都没有找到「\(link.appName)」，请插入对应硬盘或手动回迁。"
            alert.runModal()
        }
    }

    private func repairAll() {
        var fixed = 0
        for link in links where link.state == .broken {
            if checker.repair(link) { fixed += 1 }
        }
        repairedCount = fixed
        runCheck()
    }

    private func cleanAllBackups() {
        for issue in backups {
            checker.deleteBackup(issue)
        }
        backups = []
    }

    private func color(for state: LinkHealth.LinkState) -> Color {
        switch state {
        case .healthy: return .green
        case .volumeOffline: return .orange
        case .broken: return .red
        }
    }
}
