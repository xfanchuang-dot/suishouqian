import Foundation
import SwiftUI

/// 被随手迁管理的卷（v3.0 多盘第一公民）。
/// 一块物理盘的多个分区是多个独立卷，各自独立管理。
struct ManagedVolume: Identifiable, Equatable {
    /// 卷 UUID（统一大写），全局唯一键
    let id: String
    /// 最新一次枚举到的卷信息（容量/挂载点随 refresh 更新；离线时保留最后一次的值）
    var info: DriveInfo
    var role: VolumeRole
    /// 是否在线（按 UUID 在当前挂载表里找得到）
    var isOnline: Bool
    /// 链路档位（由链路体检回填，未知时为 .unknown）
    var linkTier: LinkTier = .unknown
    /// 实测写入速度 MB/s（DiskSpeedTest 回填；无则按档位保守估算）
    var measuredMBps: Double?
    /// 最新健康分（体检后回填）
    var healthScore: Int?
    /// 磁盘物理健康（SMART 探测回填，未知时为 nil）
    var diskHealth: DiskHealth?
    /// 上次在线时刻（离线卷灰显展示用）
    var lastSeen: Date
    /// 随手迁足迹分（VolumeClassifier.footprintScore，认"一直在用的那块盘"）
    var footprintScore: Int

    var displayName: String { info.name }

    /// 相等判定只看稳定字段，避免刷新时容量微变触发无谓的视图动画
    static func == (lhs: ManagedVolume, rhs: ManagedVolume) -> Bool {
        lhs.id == rhs.id
            && lhs.role == rhs.role
            && lhs.isOnline == rhs.isOnline
    }
}

enum VolumeRole: String, Codable {
    case primary
    case secondary
}

enum LinkTier: String, Codable {
    case thunderbolt
    case usb3
    case usb2
    case unknown

    /// 无实测时的保守估算写速（MB/s），仅用于方案耗时估算，不做准
    var conservativeMBps: Double {
        switch self {
        case .thunderbolt: return 700
        case .usb3: return 300
        case .usb2: return 30
        case .unknown: return 100
        }
    }

    var label: String {
        switch self {
        case .thunderbolt: return "雷电"
        case .usb3: return "USB 3"
        case .usb2: return "USB 2"
        case .unknown: return "未知链路"
        }
    }
}

/// 多盘存储（@MainActor，AppState 持有）。
/// DiskMonitor 职责收敛为"枚举 + 挂载事件"；选盘、主盘规则、离线保留归这里。
/// 铁律：新出现的卷永远不能自动顶掉主盘（v2.15 修过 DMG 顶掉用户选定盘的 bug）；
/// 离线卷不删除——台账条目按 UUID 关联，插回即恢复。
@MainActor
final class VolumeStore: ObservableObject {
    @Published private(set) var volumes: [ManagedVolume] = []

    /// 老键：DiskMonitor 独管（单盘口径），本类只读不写——双写会互相覆盖打乒乓
    private static let primaryUUIDKey = "selectedExternalVolumeUUID"
    /// P2-2（Muse 审查）：用户显式指定主盘的独立键。DiskMonitor.refresh 在
    /// "picked 带足迹"时会改写老键，若显式指定也写老键，用户的选择会被自动逻辑
    /// 静默推翻；独立键一旦存在就永远优先于老键
    private static let explicitPrimaryKey = "primaryVolumeUUID.v3"

    /// 主盘（离线时仍返回，调用方看 isOnline 决定灰显；不要静默换盘）
    var primary: ManagedVolume? {
        volumes.first { $0.role == .primary }
    }

    var onlineVolumes: [ManagedVolume] {
        volumes.filter(\.isOnline)
    }

    /// 刷新卷列表。卷枚举与足迹分都是阻塞 IO（网络卷上可能卡数秒），整体走 OffPool；
    /// 回主线程后做纯合并（merge 是纯逻辑，可测）。
    /// 调用方须保证先刷过 Time Machine 目的盘缓存（VolumeClassifier.refreshTimeMachineCache），
    /// 否则过滤用的还是旧快照——顺序约定与 AppState 定时器一致。
    /// 注意：refresh 只做内存中的主盘选举，**不写** selectedExternalVolumeUUID——
    /// 该键仍由 DiskMonitor 按单盘口径管理（v2.x 语义），两边都写会互相覆盖；
    /// 本类的持久化入口只有 setPrimary（用户显式指定）。
    func refresh() async {
        let (candidates, scores) = await OffPool.run { () -> ([DriveInfo], [String: Int]) in
            let candidates = DiskMonitor.enumerateVolumes().candidates
            let scores = Dictionary(uniqueKeysWithValues: candidates.map {
                ($0.mountPoint, VolumeClassifier.footprintScore(volumeRoot: $0.mountPoint))
            })
            return (candidates, scores)
        }
        let persisted = UserDefaults.standard.string(forKey: Self.explicitPrimaryKey)
            ?? UserDefaults.standard.string(forKey: Self.primaryUUIDKey)
        let now = Date()
        volumes = Self.merge(old: volumes, candidates: candidates,
                             footprintScores: scores,
                             persistedPrimaryUUID: persisted, now: now)
        // 持久化每块盘最后在线时刻（死卷检测用；内存 lastSeen 重启即丢）
        Self.persistLastSeen(volumes: volumes, now: now)
    }

    /// 用户显式指定主盘（设置页/迁移面板）。这是唯一能改变主盘的人为入口，
    /// 新卷出现、定时刷新都无权调用它。
    func setPrimary(uuid: String) {
        guard volumes.contains(where: { $0.id == uuid }) else { return }
        for i in volumes.indices {
            volumes[i].role = (volumes[i].id == uuid) ? .primary : .secondary
        }
        UserDefaults.standard.set(uuid, forKey: Self.explicitPrimaryKey)
        AuditLog.append("用户指定迁移主盘：\(volumes.first { $0.id == uuid }?.info.name ?? uuid)")
    }

    /// 回填链路档位 / 实测速度 / 健康分 / 磁盘物理健康（各服务体检后调用，互不干扰）
    func updateMetadata(uuid: String, tier: LinkTier? = nil,
                        mbps: Double? = nil, healthScore: Int? = nil,
                        diskHealth: DiskHealth? = nil) {
        guard let i = volumes.firstIndex(where: { $0.id == uuid }) else { return }
        if let tier { volumes[i].linkTier = tier }
        if let mbps { volumes[i].measuredMBps = mbps }
        if let healthScore { volumes[i].healthScore = healthScore }
        if let diskHealth { volumes[i].diskHealth = diskHealth }
    }

    /// 死卷检测用：每块盘最后一次在线时刻（内存的 lastSeen 重启即丢，必须持久化）。
    /// 在 refresh() 里随合并一起写；读走 lastSeenMap()。
    private nonisolated static let lastSeenKey = "volumeLastSeen.v1"

    nonisolated static func lastSeenMap() -> [String: Date] {
        let raw = UserDefaults.standard.dictionary(forKey: lastSeenKey) as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.key, Date(timeIntervalSince1970: $0.value)) })
    }

    private nonisolated static func persistLastSeen(volumes: [ManagedVolume], now: Date) {
        var raw = UserDefaults.standard.dictionary(forKey: lastSeenKey) as? [String: Double] ?? [:]
        for v in volumes where v.isOnline {
            raw[v.id] = now.timeIntervalSince1970
        }
        UserDefaults.standard.set(raw, forKey: lastSeenKey)
    }

    // MARK: - 纯逻辑（供测试）

    /// 合并：按 UUID 对齐；新卷加入（secondary）；消失的卷标离线但保留；
    /// 回来的卷恢复在线并刷新 info/lastSeen。主盘按 electPrimary 规则定。
    /// 足迹分由调用方在 OffPool 算好按挂载点传入——本函数不碰文件系统，是纯函数。
    nonisolated static func merge(old: [ManagedVolume], candidates: [DriveInfo],
                                  footprintScores: [String: Int],
                                  persistedPrimaryUUID: String?, now: Date) -> [ManagedVolume] {
        var merged: [ManagedVolume] = []
        let candidateIDs = Set(candidates.compactMap(\.volumeUUID))

        for c in candidates {
            guard let uuid = c.volumeUUID else { continue }
            let score = footprintScores[c.mountPoint] ?? 0
            if let existing = old.first(where: { $0.id == uuid }) {
                var v = existing
                v.info = c
                v.isOnline = true
                v.lastSeen = now
                v.footprintScore = score
                merged.append(v)
            } else {
                merged.append(ManagedVolume(
                    id: uuid, info: c, role: .secondary, isOnline: true,
                    lastSeen: now, footprintScore: score))
            }
        }
        // 离线保留：台账还指着这些 UUID，自愈/体检需要它们
        for v in old where !candidateIDs.contains(v.id) {
            var offline = v
            offline.isOnline = false
            merged.append(offline)
        }

        let primaryID = electPrimary(volumes: merged, persistedPrimaryUUID: persistedPrimaryUUID)
        for i in merged.indices {
            merged[i].role = (merged[i].id == primaryID) ? .primary : .secondary
        }
        // 排序：主盘第一，在线优先，其次按足迹分（UI 稳定不跳）
        merged.sort {
            if $0.role != $1.role { return $0.role == .primary }
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.footprintScore > $1.footprintScore
        }
        return merged
    }

    /// 主盘选举（纯逻辑）：已有主盘保持 > 用户记忆 > 足迹 > 容量。
    /// 铁律：已经有主盘时，新卷永远不能自动上位；主盘离线也不换（灰显，不静默换盘）。
    nonisolated static func electPrimary(volumes: [ManagedVolume],
                                         persistedPrimaryUUID: String?) -> String? {
        guard !volumes.isEmpty else { return nil }
        if let current = volumes.first(where: { $0.role == .primary }) {
            return current.id
        }
        if let persisted = persistedPrimaryUUID,
           volumes.contains(where: { $0.id == persisted }) {
            return persisted
        }
        if let footprint = volumes.max(by: { $0.footprintScore < $1.footprintScore }),
           footprint.footprintScore > 0 {
            return footprint.id
        }
        return volumes.max(by: { $0.info.totalSize < $1.info.totalSize })?.id
    }
}
