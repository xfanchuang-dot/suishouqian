import Foundation

/// 升级顶掉自动重迁（opt-in，默认关闭）。
///
/// 背景：应用自带更新器（App Store / Sparkle / Squirrel）升级时，
/// 会把 /Applications 里的软链接替换回真目录——迁移被悄悄撤销，
/// 内置盘空间又被占回去。体检能发现，但要手动一个个点"重新迁移"。
///
/// 开启后：App 启动 / 插盘时自动检测"迁移被撤销"，逐个重新迁移。
/// 安全护栏：
/// - App Store 应用跳过（下次更新还会顶掉，自动重迁会形成死循环，手动处理）；
/// - 正在运行的应用跳过（迁移入口本身也会拒绝，双保险）；
/// - 有迁移任务在跑时不启动（串行，避免资源争抢）；
/// - 每次只处理本轮检测到的，不循环重试（失败的等下次触发）。
enum AutoRemigrateService {

    static let enabledKey = "autoRemigrateOnRegression"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 检查并自动重迁。必须在 @MainActor 调用（内部读写 appState）。
    /// - Returns: (成功, 失败, 跳过) 的应用名
    @MainActor
    static func run(appState: AppState) async -> (succeeded: [String],
                                                  failed: [String],
                                                  skipped: [String]) {
        guard isEnabled else { return ([], [], []) }
        guard let drivePath = appState.externalDrive?.mountPoint,
              !drivePath.isEmpty else { return ([], [], []) }
        guard !appState.isMigrationActive else { return ([], [], []) }

        // 回归检测是同步文件 IO，走 OffPool
        let regressions = await OffPool.run {
            appState.healthChecker.checkRegressions(drivePath: drivePath)
        }
        guard !regressions.isEmpty else { return ([], [], []) }

        AuditLog.append("自动重迁启动：检测到 \(regressions.count) 个被升级顶掉的应用")
        await appState.scanApps()

        var succeeded: [String] = []
        var failed: [String] = []
        var skipped: [String] = []

        for item in regressions {
            guard let app = appState.apps.first(where: { $0.path == item.appPath }) else {
                skipped.append(item.appName)
                continue
            }
            // App Store 应用：下次更新还会顶掉，自动重迁=死循环，跳过并记账
            if app.updateMechanism == .appStore {
                skipped.append(app.name)
                AuditLog.append("自动重迁跳过「\(app.name)」：App Store 应用更新会再次顶掉链接，请手动处理")
                continue
            }
            // 正在运行：迁移入口会拒绝，这里提前跳过
            if AppMigrator.runningAppName(matching: app.path) != nil {
                skipped.append(app.name)
                AuditLog.append("自动重迁跳过「\(app.name)」：应用正在运行")
                continue
            }

            appState.migrationTask = MigrationTask(app: app, operation: .migrate)
            let state = appState
            let result = await state.migrator.migrate(
                app: app, to: drivePath,
                cancellationToken: state.migrationTask?.cancellationToken
            ) { @Sendable pct, desc in
                Task { @MainActor in
                    var t = state.migrationTask ?? MigrationTask(app: app, operation: .migrate)
                    t.progress = pct
                    t.currentFile = desc
                    state.migrationTask = t
                }
            }
            state.migrationTask = nil

            if result.success {
                succeeded.append(app.name)
                AuditLog.append("自动重迁成功「\(app.name)」：升级顶掉链接后自动恢复")
            } else {
                failed.append(app.name)
                AuditLog.append("自动重迁失败「\(app.name)」：\(result.error ?? "未知原因")")
            }
        }

        await appState.scanApps()

        if !succeeded.isEmpty || !failed.isEmpty {
            appState.notificationManager.notifyAutoRemigrate(
                succeeded: succeeded, failed: failed, skipped: skipped)
        }
        return (succeeded, failed, skipped)
    }
}
