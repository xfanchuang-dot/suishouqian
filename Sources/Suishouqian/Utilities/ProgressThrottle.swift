import Foundation

/// 迁移进度节流器（纯逻辑，可测）。
/// ditto 复制回调每秒触发几十次，直接写 @Published 会让 200+ 列表行跟着重算 body；
/// 这里按"变化幅度 + 时间窗"过滤，进度条平滑（最多 4 次/秒）而观感不变。
/// 时间由调用方注入（App 用真实时钟，测试用假时钟），决策完全确定。
struct ProgressThrottle {
    /// 两次发布之间的最小间隔
    static let minInterval: TimeInterval = 0.25
    /// 进度变化小于该值不算"有变化"
    static let minPctDelta = 0.005
    /// 收尾直通线：progress(1.0) 不吃时间窗，进度条保证走满再落"已完成"
    static let finalThreshold = 0.999

    private(set) var lastPublish = Date.distantPast

    /// 返回 nil = 本次丢弃；非 nil = 应发布的 (progress, file)
    mutating func filtered(pct: Double, file: String,
                           currentProgress: Double, currentFile: String,
                           now: Date) -> (progress: Double, file: String)? {
        let isFinal = pct >= Self.finalThreshold
        let pctChanged = abs(currentProgress - pct) > Self.minPctDelta
        let fileChanged = currentFile != file
        let timeElapsed = now.timeIntervalSince(lastPublish) > Self.minInterval
        guard (pctChanged || fileChanged) && (timeElapsed || isFinal) else { return nil }
        lastPublish = now
        return (pct, file)
    }
}
