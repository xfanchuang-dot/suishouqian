import Foundation

/// 按卷保存的实测速度历史 + 塌陷告警（v3.1 第二梯队）。
///
/// 背景：SMART 探测在 USB 硬盘盒上普遍读不到（DiskHealthProbe 标灰），
/// 那批用户的"盘死预警"不能靠 SMART。盘体故障的另一个前兆是**吞吐塌陷**——
/// 坏道重映射增多、USB 桥退化时实测速度会显著低于它自己的历史水平。
/// 用已有的手动测速（DiskSpeedTest）喂历史，评估纯函数出告警。
///
/// 只做相对比较：绝对速度低（USB2 机械盘 30-40MB/s）是正常水平不是故障，
/// 拿绝对线告警会冤枉慢盘。
enum VolumeSpeedBaseline {

    struct Sample: Codable, Equatable {
        let at: Date
        let mbps: Double
    }

    struct Alert: Equatable {
        let latestMBps: Double
        let baselineMBps: Double
        /// 塌陷到基线的百分比（0-100，展示用）
        var percentOfBaseline: Int {
            baselineMBps > 0 ? Int(latestMBps / baselineMBps * 100) : 0
        }
    }

    private static let key = "volumeSpeedHistory.v1"
    /// 每卷最多留几次实测（太老的盘况对当前已无参考意义）
    static let maxSamples = 5
    /// 判塌陷前基线至少要这么多样本（不含最新一次）
    static let minPriorSamples = 3
    /// 最新实测低于基线的这个比例算塌陷
    static let collapseRatio = 0.4
    /// 基线低于该值（USB2 档，与档位判定口径一致）不判塌陷——
    /// 慢盘的吞吐百分比抖动失真，10→35 的"塌陷"多半是线缆/盒子抽风而非盘坏，宁缺毋滥
    static let minBaselineMBps = 50.0

    /// 测试注入缝：nil = UserDefaults.standard
    nonisolated(unsafe) static var defaultsOverride: UserDefaults?

    private static var defaults: UserDefaults { defaultsOverride ?? .standard }

    // MARK: - 记录与读取

    /// 记录一次实测（**读速度为准**：坏道对读的影响比写更直接）。
    /// 每卷保留最近 maxSamples 次。UserDefaults 同步写，量极小无性能顾虑。
    static func record(volumeUUID: String, readMBps: Double, now: Date = Date()) {
        let uuid = volumeUUID.uppercased()
        var all = loadAll()
        var history = all[uuid] ?? []
        history.append(Sample(at: now, mbps: readMBps))
        if history.count > maxSamples {
            history = Array(history.suffix(maxSamples))
        }
        all[uuid] = history
        save(all)
    }

    static func history(volumeUUID: String) -> [Sample] {
        loadAll()[volumeUUID.uppercased()] ?? []
    }

    // MARK: - 评估（纯函数，供测试）

    /// 评估最新的实测是否构成塌陷告警。history 是**含最新一次**的完整序列。
    /// 规则：去掉最新后至少 minPriorSamples 次历史、基线（中位数）≥ minBaselineMBps、
    /// 最新 < 基线 × collapseRatio。任一不满足返回 nil（不告警）。
    static func assess(history: [Sample]) -> Alert? {
        guard let latest = history.last else { return nil }
        let prior = history.dropLast().map(\.mbps).sorted()
        guard prior.count >= minPriorSamples else { return nil }
        let mid = prior.count / 2
        let baseline = prior.count.isMultiple(of: 2)
            ? (prior[mid - 1] + prior[mid]) / 2
            : prior[mid]
        guard baseline >= minBaselineMBps else { return nil }
        guard latest.mbps < baseline * collapseRatio else { return nil }
        return Alert(latestMBps: latest.mbps, baselineMBps: baseline)
    }

    // MARK: - 私有

    private static func loadAll() -> [String: [Sample]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ all: [String: [Sample]]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }
}
