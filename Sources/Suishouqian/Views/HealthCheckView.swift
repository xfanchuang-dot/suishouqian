import SwiftUI

/// 链接体检面板：软链接状态一览 + 备份审计 + 一键修复/清理
struct HealthCheckView: View {
    @EnvironmentObject var appState: AppState

    @State private var links: [LinkHealth] = []
    @State private var backups: [BackupIssue] = []
    @State private var residues: [ResidueItem] = []
    @State private var bigFiles: [BigFileItem] = []
    @State private var isChecking = false
    @State private var repairedCount = 0

    private let checker = HealthChecker()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                linkSection
                if !backups.isEmpty { backupSection }
                if !residues.isEmpty { residueSection }
                if !bigFiles.isEmpty { bigFileSection }
                if links.isEmpty && backups.isEmpty && residues.isEmpty
                    && bigFiles.isEmpty && !isChecking { emptyState }
            }
            .padding(.vertical, 4)
        }
        .onAppear { runCheck() }
    }

    private var header: some View {
        HStack {
            SectionHeader(title: "体检", systemImage: "stethoscope")
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
            HStack(spacing: 8) {
                StatusPill("\(s.healthy) 正常", systemImage: "checkmark.circle.fill", color: .green)
                StatusPill("\(s.offline) 硬盘未连接", systemImage: "externaldrive.badge.exclamationmark", color: s.offline > 0 ? .orange : .secondary)
                StatusPill("\(s.broken) 断链", systemImage: "link.badge.plus", color: s.broken > 0 ? .red : .secondary)
            }

            if s.broken > 0 {
                Button {
                    repairAll()
                } label: {
                    Label("一键修复断链", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            }

            if repairedCount > 0 {
                Text("上次修复：\(repairedCount) 条")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(links) { link in
                linkRow(link)
            }
        }
        .cardStyle()
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
        .cardStyle()
    }

    /// 已卸载应用的 Library 残留（省空间）
    private var residueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "已卸载应用残留", systemImage: "trash.slash")
                Spacer()
                Text("移入废纸篓，可恢复")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(residues) { item in
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.purple)
                        .font(.system(size: 11))
                    Text(item.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("\(item.sizeFormatted) · \(item.location)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("清理") { recycleResidue(item) }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func recycleResidue(_ item: ResidueItem) {
        let alert = NSAlert()
        alert.messageText = "清理应用残留"
        alert.informativeText = "将把「\(item.name)」（\(item.sizeFormatted)）移入废纸篓。它不隶属于任何已安装的应用，如无异常可放心清理。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if checker.recycleResidue(item) {
            residues.removeAll { $0.id == item.id }
        }
    }

    /// 内置盘大文件（省空间线索）
    private var bigFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = bigFiles.reduce(0) { $0 + $1.sizeBytes }
            HStack {
                SectionHeader(title: "大文件 TOP\(bigFiles.count)", systemImage: "doc.fill")
                Spacer()
                Text("共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
            }

            ForEach(bigFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(file.directory)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.sizeFormatted)
                        .font(.system(size: 11, weight: .semibold))
                    Button("显示") { checker.revealInFinder(file.path) }
                        .controlSize(.small)
                    Button("清理") { recycleBigFile(file) }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func recycleBigFile(_ file: BigFileItem) {
        let alert = NSAlert()
        alert.messageText = "清理大文件"
        alert.informativeText = "将把「\(file.name)」（\(file.sizeFormatted)）移入废纸篓，可随时恢复。请确认它不再需要。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if checker.recycleBigFile(file) {
            bigFiles.removeAll { $0.id == file.id }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.accent)
            Text("一切正常")
                .font(.system(size: 13, weight: .semibold))
            Text("没有发现断链或可清理的备份")
                .font(.system(size: 11))
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
            let r = checker.checkResidues(drivePath: drive)
            let f = checker.scanBigFiles()
            await MainActor.run {
                links = l
                backups = b
                residues = r
                bigFiles = f
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
