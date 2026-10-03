import XCTest
@testable import 随手迁

/// v3.1 批次测试：残留深清理扫描根 + 盘间迁移目标盘选择（纯逻辑）。
final class Volume31Tests: XCTestCase {

    // MARK: - 残留深清理：扫描根

    func testResidueScanRootsCoverDeepLocations() {
        let subs = Set(HealthChecker.residueScanRoots.map(\.subpath))
        XCTAssertTrue(subs.contains("Library/Application Support"))
        XCTAssertTrue(subs.contains("Library/Caches"))
        XCTAssertTrue(subs.contains("Library/Containers"))
        XCTAssertTrue(subs.contains("Library/Group Containers"))
        XCTAssertTrue(subs.contains("Library/Saved Application State"))
    }

    func testResidueScanRootsHaveUniqueLocations() {
        let locs = HealthChecker.residueScanRoots.map(\.location)
        XCTAssertEqual(locs.count, Set(locs).count, "location 展示名必须唯一，UI 分组依赖它")
    }

    // MARK: - 盘间迁移：目标盘候选

    private func makeVolume(mount: String, online: Bool = true,
                            role: VolumeRole = .secondary) -> ManagedVolume {
        ManagedVolume(
            id: mount.uppercased(), info: DriveInfo(name: mount, mountPoint: mount,
                                                   totalSize: 1_000, freeSize: 500,
                                                   isExternal: true, volumeUUID: nil),
            role: role, isOnline: online, lastSeen: Date(), footprintScore: 0)
    }

    private func makeApp(path: String, symlinkTarget: String? = nil) -> AppItem {
        AppItem(name: "T", bundleName: "T.app", path: path, version: "1.0",
                size: 1_048_576, isSymlink: symlinkTarget != nil,
                symlinkTarget: symlinkTarget, icon: nil)
    }

    func testCandidatesExcludeCurrentAndOfflineVolumes() {
        let vols = [
            makeVolume(mount: "/Volumes/A", role: .primary),
            makeVolume(mount: "/Volumes/B"),
            makeVolume(mount: "/Volumes/C", online: false),
        ]
        let got = RelocateTargets.candidates(currentMount: "/Volumes/A", volumes: vols)
        XCTAssertEqual(got.map(\.info.mountPoint), ["/Volumes/B"])
    }

    func testCandidatesKeepAllWhenCurrentUnknown() {
        let vols = [makeVolume(mount: "/Volumes/A"), makeVolume(mount: "/Volumes/B")]
        let got = RelocateTargets.candidates(currentMount: nil, volumes: vols)
        XCTAssertEqual(got.count, 2)
    }

    func testCurrentMountPrefersSymlinkTargetVolume() {
        let vols = [makeVolume(mount: "/Volumes/A"), makeVolume(mount: "/Volumes/B")]
        let app = makeApp(path: "/Applications/T.app",
                          symlinkTarget: "/Volumes/B/Applications/T.app")
        XCTAssertEqual(RelocateTargets.currentMount(for: app, volumes: vols), "/Volumes/B")
    }

    func testCurrentMountFallsBackToAppPath() {
        let vols = [makeVolume(mount: "/Volumes/A")]
        let app = makeApp(path: "/Volumes/A/Suishouqian_Apps/T.app")
        XCTAssertEqual(RelocateTargets.currentMount(for: app, volumes: vols), "/Volumes/A")
    }

    func testCurrentMountUsesLongestPrefixMatch() {
        // "/Volumes/AB" 不能被 "/Volumes/A" 误吞
        let vols = [makeVolume(mount: "/Volumes/A"), makeVolume(mount: "/Volumes/AB")]
        let app = makeApp(path: "/Volumes/AB/Applications/T.app")
        XCTAssertEqual(RelocateTargets.currentMount(for: app, volumes: vols), "/Volumes/AB")
    }

    func testCurrentMountNilWhenNoVolumeMatches() {
        let vols = [makeVolume(mount: "/Volumes/A")]
        let app = makeApp(path: "/Applications/T.app")
        XCTAssertNil(RelocateTargets.currentMount(for: app, volumes: vols))
    }
}
