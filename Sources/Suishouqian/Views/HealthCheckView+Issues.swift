import SwiftUI

/// 体检页 · 问题清理类分区（v2.15.0 拆分）：
/// 迁移被撤销 / 备份审计 / 卸载残留 / 大文件 —— 会动用户数据的分区，
/// 每个动作都有各自的确认弹窗与回滚语义（废纸篓/留底）。
extension HealthCheckView {

    /// 升级回退：链接被应用更新器换回真目录（迁移被悄悄撤销）
    var regressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "迁移被撤销", systemImage: "arrow.uturn.backward.circle")
                Spacer()
                Text("应用升级时替换了链接，内置盘被重新占用")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.regressions) { item in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(item.appName.replacingOccurrences(of: ".app", with: ""))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("重新占用 \(item.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("重新迁移") { remigrate(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("忽略") {
                        checker.ignoreRegression(item)
                        model.regressions.removeAll { $0.id == item.id }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    var backupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("备份可清理（孤儿或超过 \(checker.backupRetentionDays) 天）")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                Button("全部清理") { cleanAllBackups() }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
            }

            ForEach(model.backups) { issue in
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
                        Task { await deleteBackup(issue) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help(issue.isOrphan
                      ? "这个应用在内置盘和外置盘的应用目录里都不存在了（已卸载），这份迁移前备份已经没有用处。删除会移入废纸篓，可恢复。"
                      : "这是迁移「\(issue.appName)」时留的底，已超过保留期。只要应用还能正常打开就可以删。删除会移入废纸篓，可恢复。")
            }
        }
        .cardStyle()
    }

    /// 已卸载应用的 Library 残留（省空间）
    var residueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "已卸载应用残留", systemImage: "trash.slash")
                Spacer()
                Text("移入废纸篓，可恢复")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.residues) { item in
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
                    Button("清理") { Task { await confirmRecycleResidue(item) } }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help("该目录体积 ≥100MB，且没有任何已安装应用认领它——判断为已卸载应用的残留数据。\n位置：\(item.path)\n不确定是什么时，可先点「显示」去 Finder 里看看再决定。")
            }
        }
        .cardStyle()
    }

    private func confirmRecycleResidue(_ item: ResidueItem) async {
        let alert = NSAlert()
        alert.messageText = "清理应用残留"
        alert.informativeText = "将把「\(item.name)」（\(item.sizeFormatted)）移入废纸篓。它不隶属于任何已安装的应用，如无异常可放心清理。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if await checker.recycleResidue(item) {
            model.residues.removeAll { $0.id == item.id }
        }
    }

    /// 内置盘大文件（省空间线索）
    var bigFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = model.bigFiles.reduce(0) { $0 + $1.sizeBytes }
            HStack {
                SectionHeader(title: "大文件 TOP\(model.bigFiles.count)", systemImage: "doc.fill")
                Spacer()
                Text("共 \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
            }

            if !checker.extendedScanEnabled {
                Text("桌面/文稿/下载默认不扫描（避免权限弹窗），当前只扫描「资源库」；需要覆盖全部位置时，到 设置 → 通用 → 「扩展扫描桌面/文稿/下载」开启（开启前先授予完全磁盘访问权限）。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.bigFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.classification.systemManaged
                          ? "lock.shield" : "doc.fill")
                        .foregroundColor(file.classification.systemManaged
                                         ? .secondary : .blue)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(file.classification.label) · \(file.directory)")
                            .font(.system(size: 10))
                            .foregroundColor(file.classification.systemManaged ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.sizeFormatted)
                        .font(.system(size: 11, weight: .semibold))
                    Button("显示") { checker.revealInFinder(file.path) }
                        .controlSize(.small)
                    Button("清理") { Task { await confirmRecycleBigFile(file) } }
                        .controlSize(.small)
                        .disabled(file.classification.systemManaged)
                }
                .padding(.vertical, 2)
                .help(file.classification.systemManaged
                      ? "这是系统管理的数据，随手迁不建议也不允许从这里清理。"
                      : "\(file.path)\n分类：\(file.classification.label)。清理会移入废纸篓，可随时恢复。")
            }
        }
        .cardStyle()
    }

    private func confirmRecycleBigFile(_ file: BigFileItem) async {
        let alert = NSAlert()
        alert.messageText = "清理大文件"
        alert.informativeText = "将把「\(file.name)」（\(file.sizeFormatted)）移入废纸篓，可随时恢复。请确认它不再需要。"
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if await checker.recycleBigFile(file) {
            model.bigFiles.removeAll { $0.id == file.id }
        }
    }

    // MARK: - 问题分区动作

    private func deleteBackup(_ issue: BackupIssue) async {
        if await checker.deleteBackup(issue) {
            model.backups.removeAll { $0.id == issue.id }
        }
    }

    /// 全部清理：这是批量动安全底的操作，必须先二次确认
    private func cleanAllBackups() {
        guard !model.backups.isEmpty else { return }
        let totalBytes = model.backups.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let alert = NSAlert()
        alert.messageText = "清理全部 \(model.backups.count) 份备份？"
        alert.informativeText = """
        合计 \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))。\
        这些是迁移应用时留的兜底副本，全部移入废纸篓（可恢复）。

        若某个应用迁移后一直正常，它的备份确实可以清；但备份是出问题时唯一的退路，
        不确定时建议只清「应用已卸载」的孤儿备份。
        """
        alert.addButton(withTitle: "全部移入废纸篓")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let pending = model.backups
        Task {
            var removed = Set<UUID>()
            for issue in pending {
                if await checker.deleteBackup(issue) { removed.insert(issue.id) }
            }
            let done = removed
            await MainActor.run {
                model.backups.removeAll { done.contains($0.id) }
            }
        }
    }

    /// 重新迁移被撤销的应用（镜像 AppRowView 的单应用迁移流程）
    private func remigrate(_ item: RegressionItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        Task { @MainActor in
            var app = appState.apps.first { $0.path == item.appPath }
            if app == nil {
                await appState.scanApps()
                app = appState.apps.first { $0.path == item.appPath }
            }
            guard let app else {
                let alert = NSAlert()
                alert.messageText = "暂时找不到应用信息"
                alert.informativeText = "请回到迁移页等左侧列表扫描完成后再试。"
                alert.runModal()
                return
            }

            // 与迁移页同一套判断：App Store 应用重新迁移后会再次被更新顶掉，先讲清楚
            guard MigrationAdvisor.confirmRelocation(of: app, linkBack: true) else { return }

            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            let state = appState
            let result = await state.migrator.migrate(
                app: app, to: drive.mountPoint
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    var t = state.migrationTask ?? MigrationTask(app: app, operation: .migrate)
                    t.progress = pct
                    t.currentFile = desc
                    state.migrationTask = t
                }
            }

            if result.success {
                state.migrationTask = nil
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
            } else {
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
            runCheck()
        }
    }
}
