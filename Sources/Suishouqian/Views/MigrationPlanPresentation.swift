import Foundation

/// An explicit destination selected for one application in a space-free plan.
struct MigrationPlanAssignment {
    let app: AppItem
    let destination: DriveInfo
}

struct MigrationPlanRequestItem {
    let app: AppItem
    /// Nil means the current primary external drive. A non-nil value preserves
    /// a user-selected destination and is never replaced by the primary drive.
    let requestedDestination: DriveInfo?
}

/// User-facing plan request. An explicit assignment is retained per app so a
/// multi-volume space-free plan can be reviewed and executed without flattening
/// every row onto the primary drive.
struct MigrationPlanRequest: Identifiable {
    let id = UUID()
    let items: [MigrationPlanRequestItem]

    var apps: [AppItem] { items.map(\.app) }

    init(apps: [AppItem]) {
        self.items = apps.map { MigrationPlanRequestItem(app: $0, requestedDestination: nil) }
    }

    init(assignments: [MigrationPlanAssignment]) {
        self.items = assignments.map {
            MigrationPlanRequestItem(app: $0.app, requestedDestination: $0.destination)
        }
    }
}

enum MigrationPlanState: Equatable {
    case blocked(reasons: [String])
    case ready(MigrationPlanSummary)
}

struct MigrationPlanCapacityBudget: Equatable, Identifiable {
    let name: String
    let path: String
    let freeBytes: Int64
    var requiredBytes: Int64
    var isDestination: Bool
    var isBackup: Bool

    var id: String { path }
}

enum MigrationBackupPlacement: Equatable {
    case sameVolume
    case alternateVolume(name: String, path: String)
}

struct MigrationPlanSummary: Equatable {
    let id = UUID()
    let capacityBudgets: [MigrationPlanCapacityBudget]
    let totalFreedBytes: Int64
    let items: [MigrationPlanItem]

    var requiredBytes: Int64 {
        capacityBudgets.reduce(0) { $0 + $1.requiredBytes }
    }

    var destinationName: String { capacityBudgets.first(where: \.isDestination)?.name ?? "" }
    var destinationPath: String { capacityBudgets.first(where: \.isDestination)?.path ?? "" }
    var freeBytes: Int64 { capacityBudgets.first(where: \.isDestination)?.freeBytes ?? 0 }
}

struct MigrationPlanItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let size: Int64
    let sourcePath: String
    let destinationName: String
    let destinationPath: String
    let backupPlacement: MigrationBackupPlacement
    let createsLink: Bool
}

enum MigrationPlanPresentation {

    /// Compatibility convenience for the common single-destination plan.
    static func makePlan(apps: [AppItem], drive: DriveInfo?) -> MigrationPlanState {
        let request = MigrationPlanRequest(apps: apps)
        return makePlan(
            request: request, defaultDrive: drive,
            availableDrives: drive.map { [$0] } ?? [], backupDrive: nil)
    }

    /// Builds an advisory review from current online drive facts. The selected
    /// destination for every request item is resolved against the live drives;
    /// an offline selected destination blocks the plan instead of falling back.
    static func makePlan(
        request: MigrationPlanRequest,
        defaultDrive: DriveInfo?,
        availableDrives: [DriveInfo],
        backupDrive: DriveInfo?
    ) -> MigrationPlanState {
        guard !request.items.isEmpty else {
            return .blocked(reasons: ["没有可迁移的应用"])
        }

        let invalid = request.items.filter { $0.app.status != .normal }
        guard invalid.isEmpty else {
            return .blocked(reasons: invalid.map { "「\($0.app.name)」当前不可迁移" })
        }

        var resolved: [(MigrationPlanRequestItem, DriveInfo)] = []
        for item in request.items {
            if let requested = item.requestedDestination {
                guard let live = currentDrive(matching: requested, among: availableDrives) else {
                    return .blocked(reasons: [
                        "选定目标盘「\(requested.name)」已断开，不能按原方案迁移"
                    ])
                }
                resolved.append((item, live))
            } else {
                guard let defaultDrive,
                      let live = currentDrive(matching: defaultDrive, among: availableDrives) else {
                    return .blocked(reasons: [VolumeOfflineBanner.message(for: nil)])
                }
                resolved.append((item, live))
            }
        }

        let liveBackupDrive = backupDrive.flatMap {
            currentDrive(matching: $0, among: availableDrives)
        }
        let backupMount = liveBackupDrive?.mountPoint
        var items: [MigrationPlanItem] = []
        var budgets: [String: MigrationPlanCapacityBudget] = [:]

        for (requestItem, destination) in resolved {
            let app = requestItem.app
            let backupRoot = BackupLocations.resolveWriteRoot(
                drivePath: destination.mountPoint, alternateMount: backupMount)
            let capacity = AppMigrator.capacityRequirement(
                appSize: app.size, destinationPath: destination.mountPoint,
                backupRoot: backupRoot)

            if destination.freeSize < capacity.destinationBytes {
                let message = capacity.backupIsOnDestination
                    ? "目标盘「\(destination.name)」空间不足以容纳两份空间（副本与同盘留底），需要 \(bytes(capacity.destinationBytes))，可用 \(bytes(destination.freeSize))"
                    : "目标盘「\(destination.name)」空间不足，需要 \(bytes(capacity.destinationBytes))，可用 \(bytes(destination.freeSize))"
                return .blocked(reasons: [message])
            }

            let backupPlacement: MigrationBackupPlacement
            if capacity.backupIsOnDestination {
                backupPlacement = .sameVolume
            } else if let liveBackupDrive, let backupBytes = capacity.backupBytes {
                if liveBackupDrive.freeSize < backupBytes {
                    return .blocked(reasons: [
                        "备份盘「\(liveBackupDrive.name)」空间不足，需要 \(bytes(backupBytes))，可用 \(bytes(liveBackupDrive.freeSize))"
                    ])
                }
                backupPlacement = .alternateVolume(
                    name: liveBackupDrive.name, path: liveBackupDrive.mountPoint)
                addBudget(
                    name: liveBackupDrive.name, path: liveBackupDrive.mountPoint,
                    freeBytes: liveBackupDrive.freeSize, requiredBytes: backupBytes,
                    isDestination: false, isBackup: true, to: &budgets)
            } else {
                // With no live alternate backup volume, BackupLocations falls
                // back to the destination volume, matching the service policy.
                backupPlacement = .sameVolume
            }

            addBudget(
                name: destination.name, path: destination.mountPoint,
                freeBytes: destination.freeSize,
                requiredBytes: capacity.destinationBytes,
                isDestination: true, isBackup: capacity.backupIsOnDestination,
                to: &budgets)
            items.append(MigrationPlanItem(
                id: app.id, name: app.name, size: app.size, sourcePath: app.path,
                destinationName: destination.name, destinationPath: destination.mountPoint,
                backupPlacement: backupPlacement,
                createsLink: !app.updateMechanism.prefersNoLink))
        }

        // Several applications may share one target or backup volume. The
        // per-item check above is useful feedback, but only the aggregate
        // budget proves the entire reviewed plan fits.
        let insufficientBudgets = budgets.values.filter { $0.freeBytes < $0.requiredBytes }
        guard insufficientBudgets.isEmpty else {
            let reasons = insufficientBudgets.map { budget -> String in
                let role: String
                if budget.isDestination && budget.isBackup {
                    role = "目标盘与备份盘（同一卷）"
                } else if budget.isDestination {
                    role = "目标盘"
                } else {
                    role = "备份盘"
                }
                return "\(role)「\(budget.name)」空间不足：整份计划需要 \(bytes(budget.requiredBytes))，"
                    + "可用 \(bytes(budget.freeBytes))"
            }
            return .blocked(reasons: reasons)
        }

        return .ready(MigrationPlanSummary(
            capacityBudgets: budgets.values.sorted { $0.path < $1.path },
            totalFreedBytes: request.items.reduce(0) { $0 + $1.app.size },
            items: items))
    }

    private static func currentDrive(matching requested: DriveInfo, among drives: [DriveInfo])
        -> DriveInfo? {
        if let uuid = requested.volumeUUID {
            // A reused mount path is not the selected volume. Never silently
            // substitute another disk when the plan captured a stable identity.
            return drives.first(where: {
                $0.volumeUUID?.caseInsensitiveCompare(uuid) == .orderedSame
            })
        }
        return drives.first { $0.mountPoint == requested.mountPoint }
    }

    private static func addBudget(
        name: String,
        path: String,
        freeBytes: Int64,
        requiredBytes: Int64,
        isDestination: Bool,
        isBackup: Bool,
        to budgets: inout [String: MigrationPlanCapacityBudget]
    ) {
        if var existing = budgets[path] {
            existing.requiredBytes += requiredBytes
            existing.isDestination = existing.isDestination || isDestination
            existing.isBackup = existing.isBackup || isBackup
            budgets[path] = existing
        } else {
            budgets[path] = MigrationPlanCapacityBudget(
                name: name, path: path, freeBytes: freeBytes,
                requiredBytes: requiredBytes, isDestination: isDestination, isBackup: isBackup)
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    /// Result presentation may say the source is untouched and partial output
    /// was cleaned only for the exact service result that proves that path.
    static func outcome(result: AppMigrator.MigrationResult, appName: String) -> MigrationOutcome {
        if result.cancelled {
            if !result.success, result.error == "已取消" {
                return MigrationOutcome(
                    kind: .cancelled,
                    title: "迁移已安全取消",
                    detail: "「\(appName)」的迁移已安全停止：源应用未动，外置盘上的半截副本已清理。",
                    spaceSaved: result.spaceSaved)
            }
            return MigrationOutcome(
                kind: .recoveryRequired,
                title: "需要检查迁移状态",
                detail: "「\(appName)」的迁移返回取消状态，但未能确认源位置与副本清理结果："
                    + "\(result.error ?? "服务未提供恢复说明")。请先按提示检查并恢复文件，再继续操作。",
                spaceSaved: result.spaceSaved)
        }
        if result.success {
            let freed = ByteCountFormatter.string(
                fromByteCount: result.spaceSaved, countStyle: .file)
            return MigrationOutcome(
                kind: .success,
                title: "迁移完成",
                detail: "「\(appName)」已迁移到外置盘，内置盘释放了 \(freed)。",
                spaceSaved: result.spaceSaved)
        }
        return MigrationOutcome(
            kind: .failure,
            title: "迁移未完成",
            detail: "「\(appName)」迁移未完成：\(result.error ?? "未知错误")。"
                + "请到应用列表确认当前状态后重试。",
            spaceSaved: result.spaceSaved)
    }

    /// Conservative fallback for legacy task producers that do not yet attach a
    /// MigrationResult. A cancelled status alone cannot prove cleanup succeeded.
    static func fallbackOutcome(for task: MigrationTask) -> MigrationOutcome {
        switch task.status {
        case .completed:
            let operation: String
            switch task.operation {
            case .restore: operation = "回迁"
            case .migrate: operation = "迁移"
            case .uninstall: operation = "卸载"
            case .relocate: operation = "盘间迁移"
            }
            return MigrationOutcome(
                kind: .success, title: "\(operation)操作已完成",
                detail: "任务已报告完成。", spaceSaved: 0)
        case .failed(let error):
            return MigrationOutcome(
                kind: .failure, title: "操作未完成",
                detail: "任务失败：\(error)", spaceSaved: 0)
        case .cancelled:
            return MigrationOutcome(
                kind: .recoveryRequired, title: "需要检查迁移状态",
                detail: "任务已结束，但没有服务结果可确认源位置与目标盘状态。"
                    + "请先检查文件和目标盘，再继续操作。",
                spaceSaved: 0)
        case .preparing, .copying, .verifying, .linking:
            return MigrationOutcome(
                kind: .recoveryRequired, title: "未收到任务结果",
                detail: "任务已经结束，但没有可确认的完成或恢复结果。请检查应用列表和目标盘。",
                spaceSaved: 0)
        }
    }

    /// Uses a result only when it belongs to the displayed task. This prevents a
    /// previous task's success card from replacing a legacy task's real terminal state.
    static func displayOutcome(
        task: MigrationTask?,
        outcome: MigrationOutcome?,
        outcomeTaskID: UUID?
    ) -> MigrationOutcome? {
        guard let task else { return outcome }
        guard task.status.isTerminal else { return nil }
        if let outcome, outcomeTaskID == task.id { return outcome }
        return fallbackOutcome(for: task)
    }

    static func batchResults(for items: [MigrationPlanItem]) -> [MigrationBatchItemResult] {
        items.map { MigrationBatchItemResult(id: $0.id, name: $0.name) }
    }

    static func recordBatchOutcome(
        _ outcome: MigrationOutcome,
        itemID: UUID,
        in results: [MigrationBatchItemResult]
    ) -> [MigrationBatchItemResult] {
        results.map { item in
            guard item.id == itemID else { return item }
            var updated = item
            updated.outcome = outcome
            switch outcome.kind {
            case .success: updated.status = .succeeded
            case .cancelled: updated.status = .cancelled
            case .failure, .recoveryRequired: updated.status = .failed
            }
            return updated
        }
    }

    static func markPendingBatchItemsNotStarted(
        in results: [MigrationBatchItemResult]
    ) -> [MigrationBatchItemResult] {
        results.map { item in
            guard item.status == .pending else { return item }
            var updated = item
            updated.status = .notStarted
            return updated
        }
    }
}

enum MigrationExecutionPhase: Equatable {
    case preflight
    case copyAndSwitch
    case verify
    case backupAndSwitch
    case blocked

    init(servicePhase: MigrationPhase) {
        switch servicePhase {
        case .preflight: self = .preflight
        case .copying: self = .copyAndSwitch
        case .verifying: self = .verify
        case .backupAndSwitch: self = .backupAndSwitch
        }
    }

    init(status: MigrationTask.TaskStatus) {
        switch status {
        case .preparing: self = .preflight
        case .copying, .linking: self = .copyAndSwitch
        case .verifying, .completed: self = .verify
        case .cancelled, .failed: self = .blocked
        }
    }
}

struct MigrationOutcome: Equatable {
    enum Kind: Equatable {
        case success
        case cancelled
        case failure
        case recoveryRequired
    }

    let kind: Kind
    let title: String
    let detail: String
    let spaceSaved: Int64
}

struct MigrationBatchItemResult: Equatable, Identifiable {
    enum Status: Equatable {
        case pending
        case succeeded
        case failed
        case cancelled
        case notStarted
    }

    let id: UUID
    let name: String
    var status: Status = .pending
    var outcome: MigrationOutcome?
}
