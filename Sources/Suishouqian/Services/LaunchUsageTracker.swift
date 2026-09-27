import Foundation

/// 使用频率顾问（v2.9.0，链路体感二期）。
///
/// 定位是「体温计」的续篇：链路体检回答"这块盘快不快"，本模块回答
/// "这块盘你到底有多离不开"——一个应用近 7 天频繁启动却住在外置盘上，
/// 每次启动都在替用户支付盘的体感代价，该提醒搬回内置盘了。
///
/// 数据只在应用**启动那一刻**产生（NSWorkspace didLaunchApplication），
/// 没有后台扫描、没有主动弹窗——与 v2.7.0 确立的原则一致：顾问只陈列，
/// 不打扰。体检面板打开时才把记录与当前扫描结果对上。
///
/// 存储是一份小 JSON（每条应用一个时间戳数组）。启动是低频事件，
/// 同步写盘即可；文件损坏时按空记录重开——使用统计丢得起，主流程赔不起。
struct LaunchUsageEntry: Codable, Equatable {
    /// 关联键。bundleID 在应用更新/改名/搬家中都稳定，比路径和显示名可靠。
    var bundleID: String
    var name: String
    /// 启动时刻（timeIntervalSince1970），升序追加。
    var timestamps: [Double]
}

/// 一条"建议搬回内置盘"的提醒：外置盘上的应用 + 统计窗口内的启动次数。
struct UsageSuggestion: Identifiable {
    let id = UUID()
    let app: AppItem
    let count: Int
    /// 统计窗口（天），文案用
    let days: Int
}

final class LaunchUsageTracker: @unchecked Sendable {
    /// 测试注入：重定向存储目录（与 MigrationManifest.directoryOverride 同款）
    nonisolated(unsafe) static var directoryOverride: URL?

    static let shared = LaunchUsageTracker()

    private let lock = NSLock()
    private(set) var entries: [LaunchUsageEntry] = []

    /// 加锁快照。`entries` 是裸数组（@unchecked Sendable 类型上的可变状态），
    /// 而 `CheckEngine.run` 是 nonisolated async（跑在协作线程池上），
    /// 直接读它与主线程的 record 构成数据竞争。跨线程读一律走这里。
    var entriesSnapshot: [LaunchUsageEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// 统计窗口 7 天、阈值 3 次：一周用不到 3 次的应用，等盘的耐心是值得的。
    static let suggestDays = 7
    static let suggestThreshold = 3
    /// 原始记录留 30 天：窗口和阈值将来要调，历史数据删了就回不来了
    static let retentionDays = 30

    var storeURL: URL {
        if let override = Self.directoryOverride {
            return override.appendingPathComponent("launch-usage.json")
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("随手迁", isDirectory: true)
        return dir.appendingPathComponent("launch-usage.json")
    }

    /// internal 而非 private：测试与 CheckEngine 注入需要能构造独立实例
    init() {
        load()
    }

    /// 记一次启动。超过保留期的旧时间戳顺手裁掉，文件不随年月无限膨胀。
    func record(bundleID: String, name: String, at: Date = Date()) {
        guard !bundleID.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if let idx = entries.firstIndex(where: { $0.bundleID == bundleID }) {
            entries[idx].name = name
            entries[idx].timestamps.append(at.timeIntervalSince1970)
        } else {
            entries.append(LaunchUsageEntry(bundleID: bundleID, name: name,
                                            timestamps: [at.timeIntervalSince1970]))
        }
        pruneLocked(now: at)
        saveLocked()
    }

    /// 某应用在最近 `days` 天内的启动次数。
    func recentLaunchCount(bundleID: String, days: Int, now: Date = Date()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return Self.count(bundleID: bundleID, entries: entries,
                          days: days, now: now)
    }

    /// 丢弃超龄记录（只在保留期边界裁，统计窗口过滤交给 count）。
    func prune(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        saveLocked()
    }

    /// 重新从磁盘加载（测试用）。
    func reload() {
        lock.lock()
        defer { lock.unlock() }
        load()
    }

    // MARK: - 纯逻辑（供测试）

    static func count(bundleID: String, entries: [LaunchUsageEntry],
                      days: Int, now: Date) -> Int {
        let window = Double(days) * 86400
        let cutoff = now.timeIntervalSince1970 - window
        return entries
            .filter { $0.bundleID == bundleID }
            .reduce(0) { $0 + $1.timestamps.filter { $0 >= cutoff }.count }
    }

    /// 对上扫描结果：住在外置盘（原住民或链接迁移态）且近窗口启动达阈值的应用。
    /// 没有 bundleID 的条目无法与启动记录关联，直接跳过——宁缺毋滥，
    /// 拿显示名做模糊匹配会把同名应用误报进建议列表。
    static func suggestions(apps: [AppItem], entries: [LaunchUsageEntry],
                            days: Int = LaunchUsageTracker.suggestDays,
                            threshold: Int = LaunchUsageTracker.suggestThreshold,
                            now: Date = Date()) -> [UsageSuggestion] {
        var out: [UsageSuggestion] = []
        for app in apps {
            let external = app.status == .externalOnly || app.isOnExternal
            guard external, let bid = app.bundleID, !bid.isEmpty else { continue }
            let n = count(bundleID: bid, entries: entries, days: days, now: now)
            if n >= threshold {
                out.append(UsageSuggestion(app: app, count: n, days: days))
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - 存储

    private func pruneLocked(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Double(Self.retentionDays) * 86400
        for idx in entries.indices {
            entries[idx].timestamps.removeAll { $0 < cutoff }
        }
        entries.removeAll { $0.timestamps.isEmpty }
    }

    private func load() {
        // reload 的语义是「内存状态回到磁盘状态」：文件不存在/损坏时必须清空，
        // 而不是保留旧内存记录（否则跨次启动的记录会幽灵累积）
        entries = []
        guard let data = try? Data(contentsOf: storeURL) else { return }
        entries = (try? JSONDecoder().decode([LaunchUsageEntry].self, from: data)) ?? []
    }

    /// 锁内同步写。文件只有几 KB 且启动是低频事件，同步足够；
    /// 若改异步，快速连续启动时两个写入块乱序完成，旧快照会覆盖新记录。
    private func saveLocked() {
        let url = storeURL
        // 使用记录是锦上添花的数据：写失败静默放弃，不弹错不打扰
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {}
    }
}
