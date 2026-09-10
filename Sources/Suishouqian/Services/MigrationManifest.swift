import Foundation

/// 迁移台账：软链接之外另存「卷 UUID + 盘内相对路径」。
/// 链接是绝对路径，卷一改名全部断链；台账按 UUID 找卷，改名后可自动重写链接自愈。
/// 写入时机：迁移成功、断链修复、断链自愈、体检回填；移除时机：回迁/卸载成功。
final class MigrationManifest: @unchecked Sendable {
    static let shared = MigrationManifest()

    /// 测试注入：重定向存储目录（单元测试用，业务代码勿动）
    nonisolated(unsafe) static var directoryOverride: URL?

    struct Entry: Codable, Equatable {
        var appName: String        // "X.app"，与 /Applications 里的条目同名
        var linkPath: String       // "/Applications/X.app"
        var volumeUUID: String     // 卷 UUID（统一大写）
        var relativePath: String   // 盘内相对路径，如 "Applications/X.app"
        var migratedAt: Date
        /// nil/"bundle"=应用本体（v2.2 旧台账缺此字段，解码即 nil）；"data"=数据目录
        var kind: String?
    }

    private let queue = DispatchQueue(label: "com.suishouqian.manifest")

    private var fileURL: URL {
        let dir: URL
        if let override = MigrationManifest.directoryOverride {
            dir = override
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
                .appendingPathComponent("随手迁", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("migration-manifest.json")
    }

    // MARK: - 台账操作

    func entry(forAppName name: String) -> Entry? {
        queue.sync { load().apps.first { $0.appName == name } }
    }

    func all() -> [Entry] {
        queue.sync { load().apps }
    }

    func record(appName: String, linkPath: String, volumeUUID: String,
                relativePath: String, kind: String? = nil) {
        queue.sync {
            var manifest = load()
            manifest.apps.removeAll { $0.appName == appName }
            manifest.apps.append(Entry(appName: appName, linkPath: linkPath,
                                       volumeUUID: volumeUUID.uppercased(),
                                       relativePath: relativePath, migratedAt: Date(),
                                       kind: kind))
            save(manifest)
        }
    }

    func remove(appName: String) {
        queue.sync {
            var manifest = load()
            manifest.apps.removeAll { $0.appName == appName }
            save(manifest)
        }
    }

    // MARK: - 卷定位（UUID ↔ 挂载点，卷改名免疫的关键）

    /// 卷的 UUID；路径不在已挂载卷上时返回 nil
    /// （resourceValues 里该值在不同 SDK 上是 UUID 或 String，用 String(describing:) 统一）
    static func volumeUUID(atPath path: String) -> String? {
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeUUIDStringKey]),
            let raw = values.volumeUUIDString else { return nil }
        return String(describing: raw).uppercased()
    }

    /// 按 UUID 找已挂载卷的挂载点——卷改名不影响定位；找不到返回 nil
    static func mountPoint(forUUID uuid: String) -> String? {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            options: [.skipHiddenVolumes]) ?? []
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]),
                  let raw = values.volumeUUIDString else { continue }
            if String(describing: raw).uppercased() == uuid.uppercased() {
                return volume.path
            }
        }
        return nil
    }

    // MARK: - Private

    private struct ManifestFile: Codable {
        var version = 1
        var apps: [Entry] = []
    }

    private func load() -> ManifestFile {
        guard let data = try? Data(contentsOf: fileURL) else { return ManifestFile() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ManifestFile.self, from: data)) ?? ManifestFile()
    }

    private func save(_ manifest: ManifestFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(manifest) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
