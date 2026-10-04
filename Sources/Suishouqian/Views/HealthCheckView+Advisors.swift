import SwiftUI

/// 体检页 · 建议类分区（v2.15.0 拆分）：
/// 高频应用 / 长期未用 / 开机自启 / Spotlight —— 这些分区"给建议 + 搬回/开关"，
/// 与问题清理类分区（+Issues.swift）分开。
extension HealthCheckView {

    /// 使用频率顾问（v2.9.0）：近 7 天频繁启动、却住在外置盘上的应用。
    /// 只在打开体检面板时陈列，没有后台扫描、没有主动弹窗。
    var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "高频应用 · 建议搬回内置盘", systemImage: "speedometer")
                Spacer()
                Text("近 \(LaunchUsageTracker.suggestDays) 天经常启动，却要靠外置盘才能打开（随手迁运行时的启动才会记账）")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.usageSuggestions) { sug in
                HStack(spacing: 8) {
                    if let icon = sug.app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    Text(sug.app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("近 \(sug.days) 天启动 \(sug.count) 次 · \(sug.app.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("搬回内置盘") { moveBackExternal(sug.app) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isMigrationActive || appState.externalDrive == nil)
                        .help("搬回后应用就在内置盘本地，不再依赖外置盘")
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    /// 长期未用（v2.12.0）：住在外置盘、很久没打开的应用。
    /// 数据来自系统的 kMDItemLastUsedDate；关了盘的 Spotlight 索引后拿不到，自动跳过。
    /// （跨文件 extension：被主文件 body 引用的成员不能标 private）
    var unusedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "长期未用 · 外置盘", systemImage: "moon.zzz")
                Spacer()
                Text("超过 \(UnusedAppsCheck.unusedDays) 天没打开，占着盘面却想不起来用")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.unusedApps) { info in
                HStack(spacing: 8) {
                    if let icon = info.app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "app")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    Text(info.app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("上次打开 \(info.daysSinceUse) 天前 · \(info.app.sizeFormatted)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("搬回内置盘") { moveBackExternal(info.app) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isMigrationActive || appState.externalDrive == nil)
                        .help("既然不常用，搬回内置盘把外置盘空间腾出来")
                }
                .padding(.vertical, 2)
            }

            Text("数据来自系统记录的最近使用时间。若关闭了这块盘的 Spotlight 索引，系统会停止记账，此处以后将不再出现建议。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    /// 开机自启体检（v2.10.0）：launchd 配置里引用了外置盘的条目。
    /// 只陈列与指路，不代用户删改别的应用的启动配置。
    var launchAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "开机自启指向外置盘", systemImage: "powerplug.fill")
                Spacer()
                Text("盘没插时这些自启会失败，守护项更是开机必失败")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            ForEach(model.launchAgents) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.kind == .daemon
                          ? "gearshape.fill" : "person.crop.circle")
                        .foregroundColor(item.volumesOnline ? .orange : .red)
                        .font(.system(size: 11))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(item.kind.label) → \(item.references.first ?? "")")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(item.verdict.text)
                        .font(.system(size: 11))
                        .foregroundColor(item.verdict.severe ? .red : .orange)
                    Menu("处理") {
                        Button("在 Finder 中显示配置文件") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: item.plistPath)])
                        }
                        Button("打开系统设置 · 登录项") {
                            if let url = URL(string:
                                "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("拷贝配置路径") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.plistPath, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .help("随手迁不代改别人的启动配置：可在登录项设置里关闭，或在 Finder 里自行处理")
                }
                .padding(.vertical, 2)
            }
        }
        .cardStyle()
    }

    /// Spotlight 索引指引（v2.10.0）：外置盘被全量索引时给出关闭入口
    var spotlightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Spotlight 正在索引外置盘", systemImage: "magnifyingglass")
                Spacer()
                Button("复制关闭命令") { copySpotlightCommand() }
                    .controlSize(.small)
            }

            Text("搜索应用名时外置盘副本会和内置入口一起出现（两个结果点哪个看运气），后台持续扫描也白耗盘和电。关掉这块盘的索引是外置 SSD 的标准养护；代价是盘上的东西不再出现在 Spotlight 搜索里。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                if isTogglingSpotlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("关闭这块盘的索引（需管理员授权）") { toggleSpotlight(false) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .cardStyle()
    }

    /// 索引已关闭态：一行收尾 + 恢复入口（关闭不该是单行道）
    var spotlightOffSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Spotlight 索引已关闭", systemImage: "checkmark.seal")
                Spacer()
                if isTogglingSpotlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("恢复索引") { toggleSpotlight(true) }
                        .controlSize(.small)
                        .help("恢复后这块盘重新参与 Spotlight 搜索（会重新全盘扫描一段时间）")
                }
            }
            Text("这块盘不参与 Spotlight 搜索，不再被后台扫描（省电护盘）。想恢复随时点上面的按钮。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .cardStyle()
    }

    // MARK: - 建议分区动作

    /// 把当前扫描结果与启动记录对上，得出"高频外置盘应用"。
    /// 纯内存计数，不需要 OffPool。
    func computeUsage() {
        model.computeUsage(apps: appState.apps)
    }

    /// 外置盘原住民/迁移态应用搬回内置盘（流程与 AppRowView.moveBack 一致：
    /// 复制→校验→删外置副本，运行中会被 migrator 拒绝）
    func moveBackExternal(_ app: AppItem) {
        guard let drive = appState.externalDrive, !appState.isMigrationActive else { return }
        Task { @MainActor in
            appState.migrationTask = MigrationTask(app: app, operation: .restore)
            let state = appState
            let result = await state.migrator.moveBackToInternal(
                app: app, drivePath: drive.mountPoint
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    // 节流上报：直接写 migrationTask 会让 200+ 列表行每秒重算 body
                    state.reportMigrationProgress(pct, desc)
                }
            }

            if result.success {
                state.migrationTask = nil
                state.notificationManager.notifyMigrationComplete(
                    appName: app.name, spaceSaved: result.spaceSaved)
                await state.scanApps()
                // 应用已回内置盘：长期未用分区立即摘掉它，不等下次体检
                model.removeUnused(appPath: app.path)
            } else if var t = state.migrationTask {
                t.status = .failed(result.error ?? "未知错误")
                state.migrationTask = t
                state.notificationManager.notifyMigrationFailed(
                    appName: app.name, error: result.error ?? "未知错误")
            }
            // 应用已不在外置盘，重新对账——它应当从建议列表里消失
            model.computeUsage(apps: state.apps)
        }
    }

    // MARK: - Spotlight 动作（v2.10.0）

    /// 关闭/恢复外置盘索引：先知情确认（改的是系统行为，必须讲清代价），
    /// 再提权执行。osascript 会阻塞等密码输入，放 OffPool 不占协作池。
    func toggleSpotlight(_ enable: Bool) {
        guard let drive = appState.externalDrive?.mountPoint, !isTogglingSpotlight else { return }
        let alert = NSAlert()
        alert.messageText = enable ? "恢复这块盘的 Spotlight 索引？"
                                   : "关闭这块盘的 Spotlight 索引？"
        alert.informativeText = enable
            ? "恢复后 Spotlight 会重新扫描整块盘（期间盘会持续读写），盘上内容重新可被搜索。"
            : "关闭后，这块盘上的内容不再出现在 Spotlight 搜索结果里，搜索也不再混入外置盘副本；后台扫描停止。想恢复随时可以再来这里操作。"
        alert.addButton(withTitle: enable ? "恢复索引" : "关闭索引")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isTogglingSpotlight = true
        // osascript 会阻塞等用户输密码（可能很久）：必须走 OffPool，
        // Task.detached 占的是协作线程池——那是冻结事故的根因类别
        Task {
            let result = await OffPool.run {
                SpotlightCheck.setIndexing(enable, mountPoint: drive)
            }
            isTogglingSpotlight = false
            if result.success {
                model.spotlightIndexing = enable
                // 用户主动改了系统行为，进操作台账
                AuditLog.append("Spotlight 索引已\(enable ? "恢复" : "关闭")：\(drive)")
            } else if result.error != "已取消授权" {
                let alert = NSAlert()
                alert.messageText = "没能修改索引设置"
                alert.informativeText = result.error ?? "未知错误"
                alert.runModal()
            }
        }
    }

    func copySpotlightCommand() {
        guard let drive = appState.externalDrive?.mountPoint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SpotlightCheck.commandLine(enabled: false, mountPoint: drive), forType: .string)
    }
}
