import Foundation

/// 迁移计划的「纯演示模型」：把选中的应用集合 + 目标盘信息，折叠成
/// 可执行（ready）或被拦（blocked）的计划评审状态，以及执行后的结果文案。
///
/// 纪律（Task 1 约束）：
/// - 全部是值类型 + static func，无类、无单例、无副作用、不碰文件系统；
/// - 文件改动永远只归 `AppMigrator` 管，这里只负责"讲清楚要发生什么/发生过什么"。
struct MigrationPlanRequest: Identifiable {
    let id = UUID()
    let apps: [AppItem]
}

enum MigrationPlanState: Equatable {
    /// 被拦：reasons 逐条说明为什么现在不能开始
    case blocked(reasons: [String])
    /// 可执行：summary 是用户确认前要看到的全量计划
    case ready(MigrationPlanSummary)
}

struct MigrationPlanSummary: Equatable {
    let id = UUID()
    let destinationName: String
    let destinationPath: String
    let freeBytes: Int64
    /// 目标盘预算（副本 1 份 + 同盘留底 1 份 + 5% 余量），逐应用累加
    let requiredBytes: Int64
    /// 全部搬完后内置盘预计释放的字节数
    let totalFreedBytes: Int64
    let items: [MigrationPlanItem]
}

struct MigrationPlanItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let size: Int64
    let sourcePath: String
    /// `false` = 纯搬迁不留链接（App Store 类应用按既有偏好）
    let createsLink: Bool
}

enum MigrationPlanPresentation {

    /// 计划评审的准入规则（与实现计划逐条对应）：
    /// 1. 没有外置盘 → 用 `VolumeOfflineBanner` 的统一文案拦下；
    /// 2. 空列表 → 「没有可迁移的应用」；
    /// 3. 任何非 `.normal` 的应用 → 逐个点名「当前不可迁移」；
    /// 4. 目标盘放不下 `requiredTargetBytes`（两份 + 5%）→ 点名「两份空间」不足；
    /// 5. 否则 ready，`createsLink` 沿用 `updateMechanism.prefersNoLink` 的既有偏好。
    static func makePlan(apps: [AppItem], drive: DriveInfo?) -> MigrationPlanState {
        guard let drive else {
            return .blocked(reasons: [VolumeOfflineBanner.message(for: nil)])
        }
        guard !apps.isEmpty else {
            return .blocked(reasons: ["没有可迁移的应用"])
        }
        let invalid = apps.filter { $0.status != .normal }
        guard invalid.isEmpty else {
            return .blocked(reasons: invalid.map { "「\($0.name)」当前不可迁移" })
        }
        let required = apps.reduce(Int64(0)) {
            $0 + AppMigrator.requiredTargetBytes(appSize: $1.size)
        }
        guard drive.freeSize >= required else {
            return .blocked(reasons: ["外置盘剩余空间不足以容纳两份空间（副本与备份）"])
        }
        return .ready(MigrationPlanSummary(
            destinationName: drive.name, destinationPath: drive.mountPoint,
            freeBytes: drive.freeSize, requiredBytes: required,
            totalFreedBytes: apps.reduce(0) { $0 + $1.size },
            items: apps.map { MigrationPlanItem(
                id: $0.id, name: $0.name, size: $0.size, sourcePath: $0.path,
                createsLink: !$0.updateMechanism.prefersNoLink) }))
    }

    /// 把真实 `MigrationResult` 折叠成结果文案。纪律：
    /// - cancelled 必须与失败区分开，正文交代「源应用未动、半截副本已清理」，
    ///   标题绝不使用成功口径；
    /// - failed 保留服务端错误原文，**不声称回滚已成功**（只引导用户去确认现状）；
    /// - 成功才允许出现"迁移完成"，释放空间保留原始字节数由上层做等宽渲染。
    static func outcome(result: AppMigrator.MigrationResult, appName: String) -> MigrationOutcome {
        if result.cancelled {
            return MigrationOutcome(
                kind: .cancelled,
                title: "迁移已安全取消",
                detail: "「\(appName)」的迁移已安全停止：源应用未动，外置盘上的半截副本已清理。",
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
}

/// 执行进度条上的固定阶段。`backup` 只出现在阶段清单里：
/// 现有 `MigrationTask.TaskStatus` 没有独立的备份阶段，status 映射不会产出它。
enum MigrationExecutionPhase: Equatable {
    case preflight
    case backup
    case copyAndSwitch
    case verify
    /// 终止且非成功：已取消 / 已失败
    case blocked

    init(status: MigrationTask.TaskStatus) {
        switch status {
        case .preparing:
            self = .preflight
        case .copying, .linking:
            self = .copyAndSwitch
        case .verifying, .completed:
            self = .verify
        case .cancelled, .failed:
            self = .blocked
        }
    }
}

/// 一次迁移（或批量中的一项）的终态呈现。纯值类型，随 `MigrationResult` 生成。
struct MigrationOutcome: Equatable {
    enum Kind: Equatable {
        case success
        case cancelled
        case failure
    }

    let kind: Kind
    let title: String
    let detail: String
    let spaceSaved: Int64
}
