import SwiftUI

/// 体检页 · 问题清理类分区（v2.15.0 拆分）：
/// 迁移被撤销 / 备份审计 / 卸载残留 / 大文件 —— 会动用户数据的分区，
/// 每个动作都有各自的确认弹窗与回滚语义（废纸篓/留底）。
extension HealthCheckView {

    /// 升级回退：链接被应用更新器换回真目录（迁移被悄悄撤销）
    var regressionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: l10n("迁移被撤销"), systemImage: "arrow.uturn.backward.circle")
                Spacer()
                Text(l10n("应用升级时替换了链接，内置盘被重新占用"))
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
                    Text(l10n("重新占用 %@", item.sizeFormatted))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(l10n("重新迁移")) { remigrate(item) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(l10n("忽略")) {
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
                Text(l10n("备份可清理（孤儿或超过 %lld 天）", checker.backupRetentionDays))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                Button(l10n("全部清理")) { cleanAllBackups() }
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
                    Text(l10n("%@ · %lld 天前%@", issue.sizeFormatted, issue.ageDays, issue.isOrphan ? l10n(" · 应用已卸载") : ""))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button(l10n("删除")) {
                        Task { await deleteBackup(issue) }
                    }
                    .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help(issue.isOrphan
                      ? l10n("这个应用在内置盘和外置盘的应用目录里都不存在了（已卸载），这份迁移前备份已经没有用处。删除会移入废纸篓，可恢复。")
                      : l10n("这是迁移「%@」时留的底，已超过保留期。只要应用还能正常打开就可以删。删除会移入废纸篓，可恢复。", issue.appName))
            }
        }
        .cardStyle()
    }

    /// 已卸载应用的 Library 残留（省空间）
    var residueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: l10n("已卸载应用残留"), systemImage: "trash.slash")
                Spacer()
                Text(l10n("移入废纸篓，可恢复"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                // v3.1 深清理：残留按体积倒序，一键全清省得逐项点
                if !model.residues.isEmpty {
                    Button(l10n("全部清理")) { Task { await confirmRecycleAllResidues() } }
                        .controlSize(.small)
                }
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
                    Button(l10n("清理")) { Task { await confirmRecycleResidue(item) } }
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
                .help(l10n("该目录体积 ≥100MB，且没有任何已安装应用认领它——判断为已卸载应用的残留数据。\n位置：%@\n不确定是什么时，可先点「显示」去 Finder 里看看再决定。", item.path))
            }
        }
        .cardStyle()
    }

    private func confirmRecycleResidue(_ item: ResidueItem) async {
        let alert = NSAlert()
        alert.messageText = l10n("清理应用残留")
        alert.informativeText = l10n("将把「%@」（%@）移入废纸篓。它不隶属于任何已安装的应用，如无异常可放心清理。", item.name, item.sizeFormatted)
        alert.addButton(withTitle: l10n("移入废纸篓"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if await checker.recycleResidue(item) {
            model.residues.removeAll { $0.id == item.id }
        }
    }

    /// 批量清理全部残留：一次确认，逐项入废纸篓；中途失败的项留在列表里。
    private func confirmRecycleAllResidues() async {
        let items = model.residues
        guard !items.isEmpty else { return }
        let total = items.reduce(0) { $0 + $1.sizeBytes }
        let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = l10n("清理全部应用残留")
        alert.informativeText = l10n("将把 %lld 项残留（共 %@）逐项移入废纸篓。它们都不隶属于任何已安装的应用。", items.count, totalStr)
        alert.addButton(withTitle: l10n("全部移入废纸篓"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var done = 0
        for item in items {
            if await checker.recycleResidue(item) {
                model.residues.removeAll { $0.id == item.id }
                done += 1
            }
        }
        AuditLog.append("批量清理应用残留：\(done)/\(items.count) 项已入废纸篓")
    }

    /// 内置盘大文件（省空间线索）
    var bigFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = model.bigFiles.reduce(0) { $0 + $1.sizeBytes }
            HStack {
                SectionHeader(title: l10n("大文件 TOP%lld", model.bigFiles.count), systemImage: "doc.fill")
                Spacer()
                Text(l10n("共 %@", ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.blue)
            }

            if !checker.extendedScanEnabled {
                Text(l10n("桌面/文稿/下载默认不扫描（避免权限弹窗），当前只扫描「资源库」；需要覆盖全部位置时，到 设置 → 通用 → 「扩展扫描桌面/文稿/下载」开启（开启前先授予完全磁盘访问权限）。"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.bigFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.classification.cleanupDisabled
                          ? "lock.shield" : "doc.fill")
                        .foregroundColor(file.classification.systemManaged
                                         ? .secondary : (file.classification.protected ? .orange : .blue))
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(file.classification.label) · \(file.directory)")
                            .font(.system(size: 10))
                            .foregroundColor(file.classification.cleanupDisabled ? .orange : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(file.sizeFormatted)
                        .font(.system(size: 11, weight: .semibold))
                    Button(l10n("显示")) { checker.revealInFinder(file.path) }
                        .controlSize(.small)
                    Button(l10n("清理")) { Task { await confirmRecycleBigFile(file) } }
                        .controlSize(.small)
                        .disabled(file.classification.cleanupDisabled)
                }
                .padding(.vertical, 2)
                .help(bigFileHelp(file))
            }
        }
        .cardStyle()
    }

    /// 大文件条目的悬浮说明：把"为什么不能从这里清"讲清楚
    private func bigFileHelp(_ file: BigFileItem) -> String {
        if file.classification.protected {
            return l10n("%@\n%@。这是不可再生的高价值数据，", file.path, file.classification.label)
                 + l10n("随手迁不提供一键清理；确认确实不需要时请到 Finder 里自行删除。")
        }
        if file.classification.systemManaged {
            return l10n("这是系统管理的数据，随手迁不建议也不允许从这里清理。")
        }
        return l10n("%@\n分类：%@。清理会移入废纸篓，可随时恢复。", file.path, file.classification.label)
    }

    private func confirmRecycleBigFile(_ file: BigFileItem) async {
        let alert = NSAlert()
        alert.messageText = l10n("清理大文件")
        alert.informativeText = l10n("将把「%@」（%@）移入废纸篓，可随时恢复。请确认它不再需要。", file.name, file.sizeFormatted)
        alert.addButton(withTitle: l10n("移入废纸篓"))
        alert.addButton(withTitle: l10n("取消"))
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
        alert.messageText = l10n("清理全部 %lld 份备份？", model.backups.count)
        alert.informativeText = l10n("\n        合计 %@。\n        这些是迁移应用时留的兜底副本，全部移入废纸篓（可恢复）。\n\n        若某个应用迁移后一直正常，它的备份确实可以清；但备份是出问题时唯一的退路，\n        不确定时建议只清「应用已卸载」的孤儿备份。\n        ", ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
        alert.addButton(withTitle: l10n("全部移入废纸篓"))
        alert.addButton(withTitle: l10n("取消"))
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
        guard appState.externalDrive != nil, !appState.isMigrationActive else { return }
        Task { @MainActor in
            var app = appState.apps.first { $0.path == item.appPath }
            if app == nil {
                await appState.scanApps()
                app = appState.apps.first { $0.path == item.appPath }
            }
            guard let app else {
                let alert = NSAlert()
                alert.messageText = l10n("暂时找不到应用信息")
                alert.informativeText = l10n("请回到迁移页等左侧列表扫描完成后再试。")
                alert.runModal()
                return
            }

            // 手动重迁由统一计划审阅一次性呈现目标、空间与链接策略。
            appState.migrationPlanRequest = MigrationPlanRequest(apps: [app])
        }
    }

    // MARK: - 磁盘物理健康（SMART）

    /// 每块在线外置盘的 SMART 状态；failing 是最高优先级告警
    var diskHealthSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: l10n("外置盘健康"), systemImage: "heart.text.square")
                Spacer()
                Text(l10n("SMART 自检；硬盘盒读不到时以体检为准"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.diskHealth) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isCritical
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundColor(item.isCritical ? .red : .green)
                        .font(.system(size: 11))
                    Text(item.volumeName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(diskHealthText(item))
                        .font(.system(size: 11))
                        .foregroundColor(item.isCritical ? .red : .secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.vertical, 2)
                .help(item.info.rawStatus.map { "SMART: \($0)" } ?? "")
            }
        }
        .cardStyle()
    }

    private func diskHealthText(_ item: DiskHealthIssue) -> String {
        switch item.info.health {
        case .verified:
            return l10n("SMART 自检通过")
        case .failing:
            return l10n("SMART 报警！盘可能即将损坏——请尽快把该盘上的应用迁回内置盘或另一块外置盘")
        case .unsupported:
            return l10n("读不到 SMART（硬盘盒不支持），暂无异常信号")
        case .unknown:
            return l10n("未能探测")
        }
    }

    // MARK: - 实测速度塌陷

    /// 最近一次实测显著低于自身历史基线（不依赖 SMART 的盘况预警）
    var speedAlertSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: l10n("实测速度异常"), systemImage: "speedometer")
                Spacer()
                Text(l10n("与该盘自己的历史测速对比"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            ForEach(model.speedAlerts) { item in
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11))
                    Text(item.volumeName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(speedAlertText(item))
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(3)
                    Spacer()
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func speedAlertText(_ item: SpeedAlertIssue) -> String {
        var text = l10n("最近实测 %lld MB/s，只有历史基线", Int(item.alert.latestMBps))
            + l10n("（%lld MB/s）的 %@%", Int(item.alert.baselineMBps), item.alert.percentOfBaseline)
        if let at = item.measuredAt {
            text += l10n("（%@ 测得）", at.formatted(date: .abbreviated, time: .shortened))
        }
        text += l10n("。速度塌陷常是盘体故障前兆——请尽快备份数据，考虑更换盘体或硬盘盒")
        return text
    }

    // MARK: - 失联的卷

    /// 台账里有、但超过 90 天没再出现过的卷（≠ 只是没插盘）
    var lostVolumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: l10n("失联的卷"), systemImage: "externaldrive.badge.xmark")
                Spacer()
                Text(l10n("超过 90 天没再出现过的盘"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text(l10n("这些盘上的应用可能已随盘丢失。可以清理指向它们的死链接，然后重装应用。"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            ForEach(model.lostVolumes) { vol in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(l10n("卷 %@…", vol.volumeUUID.prefix(8)))
                            .font(.system(size: 12, weight: .medium))
                        if let seen = vol.lastSeen {
                            Text(l10n("最后出现 %@", seen.formatted(date: .abbreviated, time: .omitted)))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(l10n("清理死链接")) {
                            confirmCleanupLostVolume(vol)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                    }
                    Text(vol.appNames.joined(separator: "、"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    private func confirmCleanupLostVolume(_ vol: LostVolumeInfo) {
        let alert = NSAlert()
        alert.messageText = l10n("清理失联卷的死链接")
        alert.informativeText = l10n("将删除 %@ 条指向该卷的死链接并清理台账（%@%@）。链接目标已不存在，删除是安全的；之后可重装这些应用。", vol.appNames.count, vol.appNames.prefix(5).joined(separator: "、"), vol.appNames.count > 5 ? "…" : "")
        alert.addButton(withTitle: l10n("清理"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let cleaned = await OffPool.run { checker.cleanupLostVolume(uuid: vol.volumeUUID) }
            await MainActor.run {
                model.lostVolumes.removeAll { $0.id == vol.id }
                if !cleaned.isEmpty {
                    AuditLog.append("失联卷清理完成：\(cleaned.count) 条死链接已删")
                }
                runCheck()
            }
        }
    }
}
