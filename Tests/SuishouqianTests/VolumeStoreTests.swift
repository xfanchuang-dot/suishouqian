import XCTest
@testable import 随手迁

/// VolumeStore 纯逻辑测试（merge / electPrimary）：不碰真实文件系统，
/// 足迹分由参数传入——这正是 merge 保持纯函数的原因。
final class VolumeStoreTests: XCTestCase {

    private func drive(name: String, mountPoint: String, total: Int64 = 900_000_000_000,
                       uuid: String?) -> DriveInfo {
        DriveInfo(name: name, mountPoint: mountPoint, totalSize: total,
                  freeSize: total / 2, isExternal: true, volumeUUID: uuid)
    }

    private func volume(id: String, mountPoint: String, role: VolumeRole = .secondary,
                        online: Bool = true, footprint: Int = 0,
                        total: Int64 = 900_000_000_000) -> ManagedVolume {
        ManagedVolume(id: id, info: drive(name: id, mountPoint: mountPoint, total: total, uuid: id),
                      role: role, isOnline: online, lastSeen: Date(),
                      footprintScore: footprint)
    }

    // MARK: - merge

    func testNewVolumeJoinsAsSecondary() {
        let merged = VolumeStore.merge(old: [], candidates: [
            drive(name: "SSD", mountPoint: "/Volumes/SSD", uuid: "UUID-A")
        ], footprintScores: ["/Volumes/SSD": 0], persistedPrimaryUUID: nil, now: Date())
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].role, .primary) // 唯一卷即主盘
        XCTAssertEqual(merged[0].id, "UUID-A")
    }

    func testOfflineVolumeIsKeptNotDropped() {
        let now = Date()
        let old = [volume(id: "UUID-A", mountPoint: "/Volumes/A", role: .primary)]
        let merged = VolumeStore.merge(old: old, candidates: [],
                                       footprintScores: [:],
                                       persistedPrimaryUUID: "UUID-A", now: now)
        XCTAssertEqual(merged.count, 1, "离线卷必须保留（台账还指着它）")
        XCTAssertFalse(merged[0].isOnline)
        XCTAssertEqual(merged[0].role, .primary, "主盘离线也不静默换盘")
    }

    func testReconnectedVolumeRefreshesInfo() {
        let oldDate = Date().addingTimeInterval(-86_400)
        let old = [ManagedVolume(id: "UUID-A",
                                 info: drive(name: "A", mountPoint: "/Volumes/A", uuid: "UUID-A"),
                                 role: .primary, isOnline: false, lastSeen: oldDate,
                                 footprintScore: 5)]
        let newDrive = drive(name: "A-renamed", mountPoint: "/Volumes/A new",
                             total: 2_000_000_000_000, uuid: "UUID-A")
        let merged = VolumeStore.merge(old: old, candidates: [newDrive],
                                       footprintScores: ["/Volumes/A new": 5],
                                       persistedPrimaryUUID: "UUID-A", now: Date())
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].isOnline)
        XCTAssertEqual(merged[0].info.name, "A-renamed")
        XCTAssertEqual(merged[0].info.totalSize, 2_000_000_000_000)
    }

    func testCandidateWithoutUUIDIsSkipped() {
        let merged = VolumeStore.merge(old: [], candidates: [
            drive(name: "noUUID", mountPoint: "/Volumes/X", uuid: nil)
        ], footprintScores: ["/Volumes/X": 0], persistedPrimaryUUID: nil, now: Date())
        XCTAssertTrue(merged.isEmpty)
    }

    // MARK: - electPrimary

    func testExistingPrimaryIsKeptEvenWhenOffline() {
        let volumes = [
            volume(id: "UUID-A", mountPoint: "/A", role: .primary, online: false),
            volume(id: "UUID-B", mountPoint: "/B", footprint: 99),
        ]
        XCTAssertEqual(VolumeStore.electPrimary(volumes: volumes, persistedPrimaryUUID: "UUID-B"),
                       "UUID-A", "主盘离线不换盘——灰显，不是静默换盘")
    }

    func testNewVolumeNeverAutoPromotesOverPersisted() {
        let volumes = [
            volume(id: "UUID-OLD", mountPoint: "/old"),
            volume(id: "UUID-NEW", mountPoint: "/new", footprint: 0,
                   total: 4_000_000_000_000),
        ]
        XCTAssertEqual(VolumeStore.electPrimary(volumes: volumes, persistedPrimaryUUID: "UUID-OLD"),
                       "UUID-OLD", "新卷再大也不能顶掉用户记忆的主盘（DMG 顶盘教训）")
    }

    func testFootprintBreaksTieWhenNoPersisted() {
        let volumes = [
            volume(id: "UUID-B", mountPoint: "/b"),
            volume(id: "UUID-A", mountPoint: "/a", footprint: 7),
        ]
        XCTAssertEqual(VolumeStore.electPrimary(volumes: volumes, persistedPrimaryUUID: nil),
                       "UUID-A", "无历史记忆时足迹分高者当选")
    }

    func testCapacityFallbackWhenNoFootprint() {
        let volumes = [
            volume(id: "UUID-SMALL", mountPoint: "/s", total: 100_000_000_000),
            volume(id: "UUID-BIG", mountPoint: "/b", total: 4_000_000_000_000),
        ]
        XCTAssertEqual(VolumeStore.electPrimary(volumes: volumes, persistedPrimaryUUID: nil),
                       "UUID-BIG")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(VolumeStore.electPrimary(volumes: [], persistedPrimaryUUID: "X"))
    }
}
