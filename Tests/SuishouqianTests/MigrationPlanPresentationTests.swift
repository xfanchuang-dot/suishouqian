import XCTest
@testable import 随手迁

/// 迁移计划/结果演示模型：纯逻辑测试，不碰文件系统、不启动迁移
final class MigrationPlanPresentationTests: XCTestCase {

    private let gb: Int64 = 1_073_741_824

    private func app(name: String, size: Int64) -> AppItem {
        AppItem(
            name: name, bundleName: "\(name).app", path: "/Applications/\(name).app",
            version: nil, size: size, isSymlink: false, symlinkTarget: nil)
    }

    private func drive(freeSize: Int64) -> DriveInfo {
        DriveInfo(
            name: "Backup", mountPoint: "/Volumes/Backup",
            totalSize: freeSize * 2, freeSize: freeSize,
            isExternal: true, volumeUUID: nil)
    }

    private func drive(name: String, mountPoint: String, freeSize: Int64) -> DriveInfo {
        DriveInfo(
            name: name, mountPoint: mountPoint,
            totalSize: freeSize * 2, freeSize: freeSize,
            isExternal: true, volumeUUID: nil)
    }

    // MARK: - 计划状态

    func testMissingExternalDriveBlocksPlan() {
        let state = MigrationPlanPresentation.makePlan(
            apps: [app(name: "Xcode", size: 15 * gb)], drive: nil)
        XCTAssertEqual(state, .blocked(reasons: ["未检测到外置硬盘，插入后自动识别"]))
    }

    func testInsufficientSpaceNamesTwoCopyBudget() {
        let state = MigrationPlanPresentation.makePlan(
            apps: [app(name: "Xcode", size: 10 * gb)],
            drive: drive(freeSize: 20 * gb))
        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("两份空间"))
    }

    func testReadyPlanUsesExistingNoLinkPreference() {
        var storeApp = app(name: "Store", size: gb)
        storeApp.updateMechanism = .appStore
        guard case .ready(let plan) = MigrationPlanPresentation.makePlan(
            apps: [storeApp], drive: drive(freeSize: 10 * gb)) else { return XCTFail("expected ready") }
        XCTAssertFalse(plan.items[0].createsLink)
    }

    func testReviewedPlanPreservesEachSelectedDestination() {
        let first = app(name: "First", size: gb)
        let second = app(name: "Second", size: gb)
        let primary = drive(name: "Primary", mountPoint: "/Volumes/Primary", freeSize: 10 * gb)
        let firstTarget = drive(name: "Target A", mountPoint: "/Volumes/A", freeSize: 10 * gb)
        let secondTarget = drive(name: "Target B", mountPoint: "/Volumes/B", freeSize: 10 * gb)
        let request = MigrationPlanRequest(assignments: [
            MigrationPlanAssignment(app: first, destination: firstTarget),
            MigrationPlanAssignment(app: second, destination: secondTarget)
        ])

        let state = MigrationPlanPresentation.makePlan(
            request: request, defaultDrive: primary,
            availableDrives: [primary, firstTarget, secondTarget], backupDrive: nil)

        guard case .ready(let summary) = state else { return XCTFail("expected ready") }
        XCTAssertEqual(summary.items.map(\.destinationPath), ["/Volumes/A", "/Volumes/B"])
        XCTAssertNotEqual(summary.items.map(\.destinationPath), [primary.mountPoint, primary.mountPoint])
    }

    func testReviewedPlanBlocksWhenASelectedDestinationIsOffline() {
        let app = app(name: "First", size: gb)
        let destination = drive(name: "Planned", mountPoint: "/Volumes/Planned", freeSize: 10 * gb)
        let request = MigrationPlanRequest(assignments: [
            MigrationPlanAssignment(app: app, destination: destination)
        ])

        let state = MigrationPlanPresentation.makePlan(
            request: request, defaultDrive: drive(freeSize: 10 * gb),
            availableDrives: [drive(name: "Primary", mountPoint: "/Volumes/Backup", freeSize: 10 * gb)],
            backupDrive: nil)

        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("Planned"))
        XCTAssertTrue(reasons.joined().contains("断开"))
    }

    func testReviewedPlanDoesNotSubstituteDifferentVolumeAtReusedMountPoint() {
        let app = app(name: "First", size: gb)
        let planned = DriveInfo(
            name: "Planned", mountPoint: "/Volumes/SharedName",
            totalSize: 10 * gb, freeSize: 8 * gb, isExternal: true, volumeUUID: "OLD-UUID")
        let replacement = DriveInfo(
            name: "Replacement", mountPoint: "/Volumes/SharedName",
            totalSize: 10 * gb, freeSize: 8 * gb, isExternal: true, volumeUUID: "NEW-UUID")
        let request = MigrationPlanRequest(assignments: [
            MigrationPlanAssignment(app: app, destination: planned)
        ])

        let state = MigrationPlanPresentation.makePlan(
            request: request, defaultDrive: replacement,
            availableDrives: [replacement], backupDrive: nil)

        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("Planned"))
        XCTAssertTrue(reasons.joined().contains("断开"))
    }

    /// 被拦的计划没有任何可确认的东西：没有 summary，
    /// 「确认并开始」就没有主语——评审界面因此不可能渲染出主操作
    func testBlockedStateContainsNoExecutableSummary() {
        let state = MigrationPlanPresentation.makePlan(
            apps: [app(name: "Xcode", size: gb)], drive: nil)
        guard case .blocked = state else { return XCTFail("expected blocked") }
        XCTAssertNil(state.summary)
    }

    // MARK: - 视觉状态数据保真（Task 5）

    /// UI 等宽渲染拿到的是原始字节值而非预格式化字符串：
    /// summary 只携带 Int64，格式化推迟到渲染层（ByteCountFormatter + monospacedDigit）。
    /// Task 1 的数据保真已保证这一点，本测试把该契约固定下来。
    func testReadyPlanSummaryRetainsExactByteValuesForMonospacedRendering() {
        guard case .ready(let summary) = MigrationPlanPresentation.makePlan(
            apps: [app(name: "Xcode", size: gb)], drive: drive(freeSize: 10 * gb)) else {
            return XCTFail("expected ready")
        }
        XCTAssertEqual(summary.totalFreedBytes, gb)
        XCTAssertEqual(summary.requiredBytes, AppMigrator.requiredTargetBytes(appSize: gb))
    }

    // MARK: - 计划准入（Task 4）

    /// 选中集里混入非 .normal 应用必须在执行前拦下：
    /// 计划准入拒绝它，执行链还会在真正动手前按当刻状态复查一遍
    func testNonNormalSelectedAppBlocksBeforeExecution() {
        var migrated = app(name: "Moved", size: gb)
        migrated.status = .migrated
        let state = MigrationPlanPresentation.makePlan(
            apps: [migrated], drive: drive(freeSize: 10 * gb))
        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("不可迁移"))
    }

    // MARK: - 阶段与结果映射

    /// 取消 ≠ 失败：标题绝不能像成功，正文必须交代源应用未动、半截副本已清理
    func testCancelledOutcomeNeverUsesSuccessCopy() {
        let outcome = MigrationPlanPresentation.outcome(
            result: .init(success: false, error: "已取消", spaceSaved: 0, cancelled: true),
            appName: "Xcode")
        XCTAssertEqual(outcome.title, "迁移已安全取消")
        XCTAssertTrue(outcome.detail.contains("源应用未动"))
        XCTAssertTrue(outcome.detail.contains("已清理"))
    }

    func testCancelledResultWithRecoveryErrorDoesNotClaimSafeCleanup() {
        let error = "已取消，但原件搬回失败——完整原件保留在 /Volumes/Backup，请从该位置手动恢复"
        let outcome = MigrationPlanPresentation.outcome(
            result: .init(success: false, error: error, spaceSaved: 0, cancelled: true),
            appName: "Xcode")

        XCTAssertEqual(outcome.kind, .recoveryRequired)
        XCTAssertEqual(outcome.title, "需要检查迁移状态")
        XCTAssertTrue(outcome.detail.contains(error))
        XCTAssertFalse(outcome.detail.contains("源应用未动"))
        XCTAssertFalse(outcome.detail.contains("半截副本已清理"))
    }

    func testBackupBudgetReflectsSameVolumeAndAlternateVolumeFacts() {
        let app = app(name: "Xcode", size: 1_000_000_000)
        let target = drive(name: "Target", mountPoint: "/Volumes/Target", freeSize: 3_000_000_000)
        let sameVolumeRequest = MigrationPlanRequest(apps: [app])
        let sameVolumeState = MigrationPlanPresentation.makePlan(
            request: sameVolumeRequest, defaultDrive: target,
            availableDrives: [target], backupDrive: nil)

        guard case .ready(let sameVolumePlan) = sameVolumeState else {
            return XCTFail("expected same-volume plan to be ready")
        }
        XCTAssertEqual(sameVolumePlan.items[0].backupPlacement, .sameVolume)
        XCTAssertEqual(sameVolumePlan.capacityBudgets.count, 1)
        XCTAssertEqual(sameVolumePlan.capacityBudgets[0].requiredBytes, 2_050_000_000)
        XCTAssertTrue(sameVolumePlan.capacityBudgets[0].isDestination)
        XCTAssertTrue(sameVolumePlan.capacityBudgets[0].isBackup)

        let alternate = drive(name: "Backup", mountPoint: "/Volumes/Backup", freeSize: 1_500_000_000)
        let alternateState = MigrationPlanPresentation.makePlan(
            request: sameVolumeRequest, defaultDrive: target,
            availableDrives: [target, alternate], backupDrive: alternate)

        guard case .ready(let alternatePlan) = alternateState else {
            return XCTFail("expected alternate-backup plan to be ready")
        }
        guard case .alternateVolume(let name, let path) = alternatePlan.items[0].backupPlacement else {
            return XCTFail("expected an alternate-volume backup")
        }
        XCTAssertEqual(name, "Backup")
        XCTAssertEqual(path, "/Volumes/Backup")
        XCTAssertEqual(alternatePlan.capacityBudgets.count, 2)
        XCTAssertEqual(
            alternatePlan.capacityBudgets.first { $0.path == "/Volumes/Target" }?.requiredBytes,
            1_050_000_000)
        XCTAssertEqual(
            alternatePlan.capacityBudgets.first { $0.path == "/Volumes/Backup" }?.requiredBytes,
            1_050_000_000)
        XCTAssertTrue(alternatePlan.capacityBudgets.first { $0.path == "/Volumes/Backup" }?.isBackup == true)
    }

    func testInsufficientAlternateBackupCapacityBlocksReviewedPlan() {
        let app = app(name: "Xcode", size: 1_000_000_000)
        let target = drive(name: "Target", mountPoint: "/Volumes/Target", freeSize: 1_500_000_000)
        let alternate = drive(name: "Backup", mountPoint: "/Volumes/Backup", freeSize: 1_000_000_000)
        let request = MigrationPlanRequest(apps: [app])

        let state = MigrationPlanPresentation.makePlan(
            request: request, defaultDrive: target,
            availableDrives: [target, alternate], backupDrive: alternate)

        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("备份盘"))
        XCTAssertTrue(reasons.joined().contains("Backup"))
    }

    func testPlanAggregatesAllItemsAgainstSharedDestinationCapacity() {
        let first = app(name: "First", size: 1_000_000_000)
        let second = app(name: "Second", size: 1_000_000_000)
        let target = drive(name: "Target", mountPoint: "/Volumes/Target", freeSize: 3_000_000_000)

        let state = MigrationPlanPresentation.makePlan(
            request: MigrationPlanRequest(apps: [first, second]),
            defaultDrive: target, availableDrives: [target], backupDrive: nil)

        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("Target"))
        XCTAssertTrue(reasons.joined().contains("空间不足"))
    }

    func testPlanAggregatesAllItemsAgainstSharedAlternateBackupCapacity() {
        let first = app(name: "First", size: 1_000_000_000)
        let second = app(name: "Second", size: 1_000_000_000)
        let target = drive(name: "Target", mountPoint: "/Volumes/Target", freeSize: 3_000_000_000)
        let backup = drive(name: "Backup", mountPoint: "/Volumes/Backup", freeSize: 1_500_000_000)

        let state = MigrationPlanPresentation.makePlan(
            request: MigrationPlanRequest(apps: [first, second]),
            defaultDrive: target, availableDrives: [target, backup], backupDrive: backup)

        guard case .blocked(let reasons) = state else { return XCTFail("expected blocked") }
        XCTAssertTrue(reasons.joined().contains("Backup"))
        XCTAssertTrue(reasons.joined().contains("空间不足"))
    }

    /// failed 是阻断态：执行视图里不能把它当成还在推进的阶段
    func testFailedStatusMapsToBlockedPhase() {
        XCTAssertEqual(MigrationExecutionPhase(status: .failed("磁盘已断开")), .blocked)
    }

    func testServiceMigrationPhasesMapToTheFourExecutionStages() {
        XCTAssertEqual(MigrationExecutionPhase(servicePhase: .preflight), .preflight)
        XCTAssertEqual(MigrationExecutionPhase(servicePhase: .copying), .copyAndSwitch)
        XCTAssertEqual(MigrationExecutionPhase(servicePhase: .verifying), .verify)
        XCTAssertEqual(MigrationExecutionPhase(servicePhase: .backupAndSwitch), .backupAndSwitch)
    }

    func testLateProgressCallbackCannotRegressAnAlreadyReachedPhase() {
        XCTAssertEqual(MigrationPhase.verifying.advancing(to: .copying), .verifying)
        XCTAssertEqual(MigrationPhase.copying.advancing(to: .verifying), .verifying)
    }

    func testLegacyProgressMovesTheDisplayedPhasePastPreflight() {
        XCTAssertEqual(MigrationPhase.preflight.advancing(to: .copying), .copying)
        XCTAssertEqual(MigrationPhase.verifying.advancing(to: .copying), .verifying)
    }

    func testTerminalTaskUsesFallbackWhenOutcomeBelongsToAnEarlierTask() {
        var task = MigrationTask(app: app(name: "Xcode", size: gb), operation: .migrate)
        task.status = .cancelled
        let staleSuccess = MigrationPlanPresentation.outcome(
            result: .init(success: true, spaceSaved: gb), appName: "Old app")

        let display = MigrationPlanPresentation.displayOutcome(
            task: task, outcome: staleSuccess, outcomeTaskID: UUID())

        XCTAssertEqual(display?.kind, .recoveryRequired)
        XCTAssertFalse(display?.detail.contains("源应用未动") ?? true)
        XCTAssertFalse(display?.detail.contains("已清理") ?? true)
    }

    func testTerminalFailureTaskFallbackPreservesItsServiceError() {
        var task = MigrationTask(app: app(name: "Xcode", size: gb), operation: .migrate)
        task.status = .failed("目标盘已断开")

        let display = MigrationPlanPresentation.displayOutcome(
            task: task, outcome: nil, outcomeTaskID: nil)

        XCTAssertEqual(display?.kind, .failure)
        XCTAssertTrue(display?.detail.contains("目标盘已断开") ?? false)
    }

    // MARK: - 终态结果映射（Task 3）

    /// 成功终态的唯一准入：服务端返回 success == true，
    /// 释放空间保留原始字节数并进 detail（上层做等宽渲染）。
    /// 计划示例断言字面量 "1 GB"；实测 zh_CN 下 ByteCountFormatter 把
    /// 1 GiB 渲染成 "1.07 GB"——按「以真实为准保持语义」改为断言
    /// 同一 formatter 的产物确实出现在 detail 里。
    func testSuccessfulOutcomeReportsFreedSpace() {
        let outcome = MigrationPlanPresentation.outcome(
            result: .init(success: true, spaceSaved: 1_073_741_824), appName: "Xcode")
        XCTAssertEqual(outcome.kind, .success)
        let freed = ByteCountFormatter.string(
            fromByteCount: 1_073_741_824, countStyle: .file)
        XCTAssertTrue(outcome.detail.contains(freed))
    }

    /// 失败终态必须保留服务端错误原文，不能被笼统文案吞掉
    func testFailureOutcomePreservesServiceError() {
        let outcome = MigrationPlanPresentation.outcome(
            result: .init(success: false, error: "目标盘已断开"), appName: "Xcode")
        XCTAssertEqual(outcome.kind, .failure)
        XCTAssertTrue(outcome.detail.contains("目标盘已断开"))
    }

    func testBatchResultsPreserveFailureSuccessCancellationAndUnstartedItems() {
        let apps = [
            app(name: "Early failure", size: gb),
            app(name: "Later success", size: gb),
            app(name: "Cancelled", size: gb),
            app(name: "Not started", size: gb)
        ]
        guard case .ready(let plan) = MigrationPlanPresentation.makePlan(
            apps: apps, drive: drive(freeSize: 20 * gb)) else {
            return XCTFail("expected ready")
        }
        var results = MigrationPlanPresentation.batchResults(for: plan.items)
        let failed = MigrationPlanPresentation.outcome(
            result: .init(success: false, error: "目标盘已断开"), appName: "Early failure")
        let succeeded = MigrationPlanPresentation.outcome(
            result: .init(success: true, spaceSaved: gb), appName: "Later success")
        let cancelled = MigrationPlanPresentation.outcome(
            result: .init(success: false, error: "已取消", cancelled: true), appName: "Cancelled")

        results = MigrationPlanPresentation.recordBatchOutcome(
            failed, itemID: plan.items[0].id, in: results)
        results = MigrationPlanPresentation.recordBatchOutcome(
            succeeded, itemID: plan.items[1].id, in: results)
        results = MigrationPlanPresentation.recordBatchOutcome(
            cancelled, itemID: plan.items[2].id, in: results)
        results = MigrationPlanPresentation.markPendingBatchItemsNotStarted(in: results)

        XCTAssertEqual(results.map(\.status), [.failed, .succeeded, .cancelled, .notStarted])
        XCTAssertTrue(results[0].outcome?.detail.contains("目标盘已断开") ?? false)
        XCTAssertEqual(results[1].outcome?.kind, .success)
        XCTAssertEqual(results[2].outcome?.kind, .cancelled)
        XCTAssertNil(results[3].outcome)
    }
}
