import Foundation

/// 一条「长期未用」建议：住在外置盘、却很久没打开过的应用。
struct UnusedAppInfo: Identifiable {
    let id = UUID()
    let app: AppItem
    let lastUsed: Date

    var daysSinceUse: Int {
        Int(Date().timeIntervalSince(lastUsed) / 86400)
    }
}

/// 长期未用检查（v2.12.0，反向使用频率）。
///
/// 使用频率顾问（v2.9.0）只统计随手迁运行时的启动，天然残缺；
/// 这里改用系统自己的持久元数据 kMDItemLastUsedDate（mdls 读取）——
/// 应用最近一次打开的时刻由系统记账，与随手迁是否在跑无关。
/// 信号方向相反：高频 → 建议搬回；长期不用 → 建议搬回清空盘面（或将来卸载）。
///
/// ⚠️ 自洽性边界（文案已告知用户）：kMDItemLastUsedDate 走 Spotlight 元数据，
/// 若用户采纳建议关掉了这块盘的 Spotlight 索引，本检查会拿不到数据——
/// 拿不到就跳过（宁缺毋滥），不拿陈旧数据冒充新信号。
enum UnusedAppsCheck {

    /// 阈值：30 天没打开过才算"长期未用"
    static let unusedDays = 30

    /// 解析 `mdls -raw -name kMDItemLastUsedDate <路径>` 的输出。
    /// "(null)" / 空串 / 无法解析 → nil（宁缺毋滥，不猜）。
    static func parseLastUsed(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "(null)" else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: s)
    }

    /// 纯逻辑：从 (应用, 最近使用时刻) 里挑出外置盘上 ≥ days 天没用的。
    static func filter(_ candidates: [(app: AppItem, lastUsed: Date?)],
                       days: Int = unusedDays, now: Date = Date()) -> [UnusedAppInfo] {
        candidates.compactMap { pair in
            guard let lastUsed = pair.lastUsed else { return nil }
            let external = pair.app.status == .externalOnly || pair.app.isOnExternal
            guard external else { return nil }
            guard now.timeIntervalSince(lastUsed) >= Double(days) * 86400 else { return nil }
            return UnusedAppInfo(app: pair.app, lastUsed: lastUsed)
        }
        .sorted { $0.lastUsed < $1.lastUsed }   // 最久没用的排前面
    }

    /// 同步版（调用方负责放 OffPool；体检快照/总览都在 OffPool 里调这个）
    static func scanSync(apps: [AppItem], days: Int = unusedDays, now: Date = Date()) -> [UnusedAppInfo] {
        let external = apps.filter { $0.status == .externalOnly || $0.isOnExternal }
        let candidates: [(app: AppItem, lastUsed: Date?)] = external.map { app in
            (app, lastUsedDate(atPath: app.path))
        }
        return filter(candidates, days: days, now: now)
    }

    /// 查单个应用的最近使用时刻。mdls 是阻塞子进程，别在协作线程池上调用。
    static func lastUsedDate(atPath path: String) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-raw", "-name", "kMDItemLastUsedDate", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        return parseLastUsed(out)
    }
}
