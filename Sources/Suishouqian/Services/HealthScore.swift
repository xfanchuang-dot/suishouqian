import Foundation

/// 健康分（v3.0 能力三）：把体检结果翻译成 0-100 的数字 + 扣分明细。
/// 纯逻辑、只读派生：分数绝不反向驱动任何自动动作
/// （"分数低就自动删备份"这种事不许发生）。
enum HealthScore {

    /// 评分输入（调用方从 CheckReport 组装，零新增扫描成本）
    struct Input {
        /// 修不好的断链条数（healthy / volumeOffline / broken 三态里的 broken）
        var brokenLinks: Int = 0
        /// 有应用在上面、但当前离线的卷数
        var offlineVolumesWithApps: Int = 0
        /// 更新回归（链接被更新器顶掉）条数
        var regressions: Int = 0
        /// 数据分叉（两地分居）条数
        var dataForks: Int = 0
        /// 备份孤儿/超龄条数
        var backupIssues: Int = 0
        /// 已卸载应用残留条数
        var residues: Int = 0
        /// 有应用在住的卷里是否有 USB2 链路（体感上限低）
        var hasUSB2VolumeWithApps: Bool = false
    }

    struct Deduction: Equatable {
        let points: Int
        let reason: String
    }

    struct Result: Equatable {
        let score: Int
        let deductions: [Deduction]
        let grade: String
        /// 每档给一个最优先待办，把分数变成行动；满分时为 nil
        let topAction: String?
    }

    // 扣分表（v3.0 初版；上限防止单项把分数打穿，调参空间留给真实数据）
    private static let brokenLinkPerItem = 15
    private static let brokenLinkCap = 45
    private static let offlineVolumePenalty = 20
    private static let regressionPerItem = 10
    private static let regressionCap = 30
    private static let dataForkPerItem = 10
    private static let dataForkCap = 30
    private static let backupPerItem = 2
    private static let backupCap = 10
    private static let residuePerItem = 1
    private static let residueCap = 5
    private static let usb2Penalty = 5

    static func score(_ input: Input) -> Result {
        var deductions: [Deduction] = []
        var total = 0

        func apply(_ raw: Int, _ cap: Int, _ reason: String) {
            let points = min(raw, cap)
            guard points > 0 else { return }
            total += points
            deductions.append(Deduction(points: points, reason: reason))
        }

        apply(input.brokenLinks * brokenLinkPerItem, brokenLinkCap,
              "\(input.brokenLinks) 条修不好的断链")
        apply(input.offlineVolumesWithApps * offlineVolumePenalty, offlineVolumePenalty * 2,
              "\(input.offlineVolumesWithApps) 块存有应用的盘处于离线状态")
        apply(input.regressions * regressionPerItem, regressionCap,
              "\(input.regressions) 条迁移被更新顶掉（回归）")
        apply(input.dataForks * dataForkPerItem, dataForkCap,
              "\(input.dataForks) 处数据两地分居（需对账）")
        apply(input.backupIssues * backupPerItem, backupCap,
              "\(input.backupIssues) 条备份孤儿/超龄")
        apply(input.residues * residuePerItem, residueCap,
              "\(input.residues) 项卸载残留")
        if input.hasUSB2VolumeWithApps {
            apply(usb2Penalty, usb2Penalty, "有应用住在 USB2 链路的盘上（体感上限低）")
        }

        let value = max(0, 100 - total)
        let (grade, topAction) = gradeAndAction(for: value, deductions: deductions)
        return Result(score: value, deductions: deductions,
                      grade: grade, topAction: topAction)
    }

    private static func gradeAndAction(for score: Int,
                                       deductions: [Deduction]) -> (String, String?) {
        let grade: String
        switch score {
        case 90...: grade = "很健康"
        case 70..<90: grade = "良好"
        case 50..<70: grade = "需要关注"
        default: grade = "建议处理"
        }
        // 最优先待办 = 扣分最多的那一项（把分数变成行动）
        let top = deductions.max { $0.points < $1.points }
        return (grade, top.map { "先处理：\($0.reason)，可回 \($0.points) 分" })
    }
}

/// 健康分历史（每天首次体检追加一条，只留 90 天）。
/// 文件损坏按空处理——丢得起的数据，沿用 LaunchUsageTracker 的哲学。
enum HealthHistory {

    struct Record: Codable, Equatable {
        let date: String        // yyyy-MM-dd（每天只记一条）
        let volumeUUID: String
        let score: Int
    }

    nonisolated(unsafe) static var directoryOverride: URL?

    private static var fileURL: URL {
        let dir: URL
        if let directoryOverride {
            dir = directoryOverride
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
                .appendingPathComponent("随手迁", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("health-history.json")
    }

    static func loadAll() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        return records
    }

    /// 记录当天该卷的分数；同一天已有记录则覆盖（取当天最后一次体检）。
    /// 超过 90 天的旧记录顺带清掉（prune 纯函数另行测试）。
    static func append(volumeUUID: String, score: Int, now: Date = Date()) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let today = df.string(from: now)

        var records = loadAll().filter { $0.date != today || $0.volumeUUID != volumeUUID }
        records.append(Record(date: today, volumeUUID: volumeUUID, score: score))

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        records = prune(records: records, before: cutoff)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 只保留 cutoff 当天及以后的记录；日期解析不了的视为坏数据清掉（纯函数，供测试）
    static func prune(records: [Record], before cutoff: Date,
                      calendar: Calendar = .current) -> [Record] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = calendar.timeZone
        return records.filter { record in
            guard let d = df.date(from: record.date) else { return false }
            return d >= cutoff
        }
    }

    /// 近 N 天某卷的分数序列（时间线 UI 用；缺天不补）
    static func recent(volumeUUID: String, days: Int, now: Date = Date()) -> [Record] {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
        return loadAll()
            .filter { $0.volumeUUID == volumeUUID }
            .compactMap { record -> Record? in
                guard let d = df.date(from: record.date), d >= cutoff else { return nil }
                return record
            }
            .sorted { $0.date < $1.date }
    }
}
