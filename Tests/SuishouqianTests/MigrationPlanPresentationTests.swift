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

    /// 被拦的计划没有任何可确认的东西：没有 summary，
    /// 「确认并开始」就没有主语——评审界面因此不可能渲染出主操作
    func testBlockedStateContainsNoExecutableSummary() {
        let state = MigrationPlanPresentation.makePlan(
            apps: [app(name: "Xcode", size: gb)], drive: nil)
        guard case .blocked = state else { return XCTFail("expected blocked") }
        XCTAssertNil(state.summary)
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

    /// failed 是阻断态：执行视图里不能把它当成还在推进的阶段
    func testFailedStatusMapsToBlockedPhase() {
        XCTAssertEqual(MigrationExecutionPhase(status: .failed("磁盘已断开")), .blocked)
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
}
