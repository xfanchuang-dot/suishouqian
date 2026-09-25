import Foundation
import AppKit

/// 应用数据迁移：只碰清单内的「安分」大数据目录。
/// 设计红线（北极星=安全稳定）：
/// 1. 偏好设置、沙盒 Containers、各类 Caches 一律不碰；
/// 2. 浏览器/聊天/编辑器等热使用 profile 不入清单——外置盘 IO 拖慢日常使用，拔盘还有分叉风险；
/// 3. 优先引导应用自带的位置设置（零链接风险），链接迁移只做苹果没给入口的（iPhone 备份、HF 缓存）。
final class DataMigrator: @unchecked Sendable {

    private let fileManager = FileManager.default
    private let migrator = AppMigrator()

    // MARK: - 目录清单

    struct DataLocation {
        let id: String                  // 稳定 ASCII 标识（台账/外置盘目录名用）
        let title: String
        let homeRelativePath: String    // 以 ~ 开头
        let ownerBundleID: String?
        let ownerProcessNames: [String] // pgrep 兜底的属主进程
        let relocation: Relocation
        let note: String?

        enum Relocation {
            /// 应用自带位置设置：给指引，不建链接（零风险优先）
            case native(guide: String, launchAppName: String?)
            /// 苹果没给入口，链接迁移
            case symlink
        }
    }

    static let catalog: [DataLocation] = [
        .init(id: "jianying-drafts", title: "剪映草稿与素材",
              homeRelativePath: "~/Movies/JianyingPro",
              ownerBundleID: nil, ownerProcessNames: ["JianyingPro"],
              relocation: .native(
                guide: "剪映 → 左上角「剪映专业版」菜单 → 全局设置 → 草稿位置，改到外置盘上的文件夹，剪映会自己把草稿搬过去。素材随草稿走，无需建链接。",
                launchAppName: "JianyingPro"),
              note: "草稿+素材集中地，GB 级大户"),
        .init(id: "lmstudio-models", title: "LM Studio 模型",
              homeRelativePath: "~/.lmstudio/models",
              ownerBundleID: nil, ownerProcessNames: ["LM Studio"],
              relocation: .native(
                guide: "LM Studio → 右侧边栏设置 → My Models，把模型目录指到外置盘文件夹，已有模型可在应用里重新指向。模型文件几十 GB，让应用自己管理最稳。",
                launchAppName: "LM Studio"),
              note: nil),
        .init(id: "docker-disk", title: "Docker 磁盘镜像",
              homeRelativePath: "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
              ownerBundleID: "com.docker.docker", ownerProcessNames: ["Docker Desktop"],
              relocation: .native(
                guide: "Docker Desktop → Settings → Resources → Disk image location，改到外置盘路径后按提示重启，Docker 会自己迁移数据。",
                launchAppName: "Docker"),
              note: "虚拟磁盘单文件，几十 GB 常见"),
        .init(id: "ollama-models", title: "Ollama 模型",
              homeRelativePath: "~/.ollama/models",
              ownerBundleID: nil, ownerProcessNames: ["ollama"],
              relocation: .native(
                guide: "终端执行：launchctl setenv OLLAMA_MODELS /Volumes/<外置盘>/OllamaModels ，然后重启 ollama（菜单栏骆驼图标→Quit）再拉模型即可。",
                launchAppName: nil),
              note: nil),
        .init(id: "ios-backup", title: "iPhone 备份",
              homeRelativePath: "~/Library/Application Support/MobileSync/Backup",
              ownerBundleID: nil, ownerProcessNames: ["iTunes"],
              relocation: .symlink,
              note: "苹果没给改位置的入口，链接迁移是通用做法；迁移前确保没有正在进行的备份/同步"),
        .init(id: "huggingface-cache", title: "HuggingFace 模型缓存",
              homeRelativePath: "~/.cache/huggingface",
              ownerBundleID: nil, ownerProcessNames: [],
              relocation: .symlink,
              note: nil),
        .init(id: "xcode-derived", title: "Xcode 派生数据",
              homeRelativePath: "~/Library/Developer/Xcode/DerivedData",
              ownerBundleID: nil, ownerProcessNames: ["Xcode"],
              relocation: .native(
                guide: "纯缓存，可整个删掉（Xcode 下次构建自动重建，项目索引会重跑）。想保留就 Xcode → Settings → Locations → Derived Data 改自定义路径到外置盘。",
                launchAppName: "Xcode"),
              note: "纯缓存，删了也无损"),
        .init(id: "steam-library", title: "Steam 游戏库",
              homeRelativePath: "~/Library/Application Support/Steam",
              ownerBundleID: nil, ownerProcessNames: ["steam_osx"],
              relocation: .native(
                guide: "Steam → 设置 → 存储 → 添加外置盘上的库文件夹，再把已装游戏「移动」过去。不要直接搬整个 Steam 目录。",
                launchAppName: "Steam"),
              note: nil),
    ]

    /// 数据目录在台账/备份目录里的命名前缀（checkBackups 据此跳过审计）
    static let manifestPrefix = "Data-"
    static func manifestName(for id: String) -> String { manifestPrefix + id }

    // MARK: - 扫描

    struct DataLocationItem: Identifiable {
        let id: String
        let title: String
        let path: String
        let sizeBytes: Int64
        let isSymlink: Bool       // 已经是链接（我们迁过，或应用自己指向别处）
        let linkBroken: Bool      // 链接指向的目标不存在（盘离线或卷改名）
        let accessible: Bool
        let managedByUs: Bool     // 台账有记录（我们迁移的数据）
        let ownerRunning: Bool    // 属主应用在运行，暂不可迁移
        let relocation: DataLocation.Relocation
        let note: String?

        var isWorthMigrating: Bool {
            sizeBytes >= 100 * 1_048_576   // <100MB 不值得动
        }
    }

    /// 扫描清单：只返回真实存在的位置；du 较慢，调用方放后台
    func scanDataLocations() async -> [DataLocationItem] {
        await OffPool.run { [self] in
            Self.catalog.compactMap { location in
                scanOne(location)
            }
        }
    }

    private func scanOne(_ location: DataLocation) -> DataLocationItem? {
        let path = expandingTilde(location.homeRelativePath)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        let attrs = try? fileManager.attributesOfItem(atPath: path)
        let type = attrs?[.type] as? FileAttributeType
        let isSymlink = type == .typeSymbolicLink
        let accessible = fileManager.isReadableFile(atPath: path)
        let size = accessible ? duSize(path) : 0
        let managed = MigrationManifest.shared
            .entry(forAppName: Self.manifestName(for: location.id)) != nil
        // 链接指向的目标不存在（盘离线或卷改名）→ 面板提示"硬盘未连接"
        var linkBroken = false
        if isSymlink,
           let dest = try? fileManager.destinationOfSymbolicLink(atPath: path) {
            linkBroken = !fileManager.fileExists(atPath: dest)
        }

        return DataLocationItem(
            id: location.id, title: location.title, path: path,
            sizeBytes: size, isSymlink: isSymlink, linkBroken: linkBroken,
            accessible: accessible,
            managedByUs: managed, ownerRunning: isOwnerRunning(location),
            relocation: location.relocation, note: location.note)
    }

    // MARK: - 链接迁移 / 回迁（仅 relocation == .symlink 的条目）

    /// 外置盘数据根目录
    static func dataRoot(on drivePath: String) -> String {
        "\(drivePath)/SuishouqianData"
    }

    func migrateData(item: DataLocationItem, drivePath: String,
                     progress: @escaping @Sendable (Double, String) -> Void)
        async -> (success: Bool, error: String?) {
        let location = Self.catalog.first { $0.id == item.id }
        guard case .symlink = location?.relocation else {
            return (false, "该位置应由应用自带设置搬迁，不做链接迁移")
        }
        guard item.accessible else { return (false, "目录无法读取（可能受系统保护）") }
        guard !item.ownerRunning else { return (false, "请先退出 \(location?.title ?? "相关应用") 再迁移") }
        guard !item.isSymlink else { return (false, "该位置已经是链接，无需重复迁移") }

        let site = item.path
        let externalPath = "\(Self.dataRoot(on: drivePath))/\(item.id)"

        if let reason = migrator.validateTarget(drivePath: drivePath, appSize: item.sizeBytes) {
            AuditLog.append("拒绝数据迁移 \(item.title)：\(reason)")
            return (false, reason)
        }

        return await linkMigrate(title: item.title, site: site, externalPath: externalPath,
                                 drivePath: drivePath,
                                 sizeBytes: item.sizeBytes,
                                 manifestName: Self.manifestName(for: item.id),
                                 progress: progress)
    }

    /// 链接迁移共享核心（清单条目与自选文件夹走同一条路）：
    /// 快照 → 复制 → 校验 → 备份原件 → 切换链接 → 记台账。
    private func linkMigrate(title: String, site: String, externalPath: String,
                             drivePath: String, sizeBytes: Int64, manifestName: String,
                             progress: @escaping @Sendable (Double, String) -> Void)
        async -> (success: Bool, error: String?) {
        // 快照保险（阻塞进程走 OffPool）
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        progress(0.1, "正在复制 \(title)...")
        guard await migrator.copyWithDitto(from: site, to: externalPath, progress: { pct in
            progress(0.1 + pct * 0.6, "复制 \(title)...")
        }) else {
            try? fileManager.removeItem(atPath: externalPath)
            return (false, "复制失败")
        }

        progress(0.7, "正在校验完整性...")
        guard await migrator.verifyFiles(source: site, target: externalPath) else {
            try? fileManager.removeItem(atPath: externalPath)
            AuditLog.append("数据迁移失败 \(title)：校验未通过，已回滚目标副本")
            return (false, "文件校验失败，请重试")
        }

        progress(0.85, "备份原件并切换链接...")
        let backupPath = "\(drivePath)/.suishouqian-backup/\(manifestName)"
        try? fileManager.createDirectory(
            atPath: "\(drivePath)/.suishouqian-backup", withIntermediateDirectories: true)
        guard await migrator.moveItem(from: site, to: backupPath) else {
            try? fileManager.removeItem(atPath: externalPath)
            return (false, "无法移动原目录（可能正在被使用）")
        }
        // 备份 mtime 必须代表"备份时刻"，否则会被 cleanOldBackups 立刻当超龄清掉
        migrator.stampBackupCreation(at: backupPath)
        do {
            try fileManager.createSymbolicLink(atPath: site, withDestinationPath: externalPath)
        } catch {
            _ = await migrator.moveItem(from: backupPath, to: site)
            try? fileManager.removeItem(atPath: externalPath)
            return (false, "创建链接失败：\(error.localizedDescription)")
        }

        if let uuid = MigrationManifest.volumeUUID(atPath: drivePath) {
            MigrationManifest.shared.record(
                appName: manifestName, linkPath: site,
                volumeUUID: uuid,
                relativePath: String(externalPath.dropFirst(drivePath.count + 1)),
                kind: "data")
        }
        AuditLog.append("数据迁移成功 \(title)：\(sizeBytes) 字节 → \(externalPath)")
        progress(1.0, "完成")
        return (true, nil)
    }

    func restoreData(item: DataLocationItem, drivePath: String,
                     progress: @escaping @Sendable (Double, String) -> Void)
        async -> (success: Bool, error: String?) {
        let site = item.path
        guard item.isSymlink, let target = try? fileManager.destinationOfSymbolicLink(atPath: site) else {
            return (false, "该位置不是链接，无需回迁")
        }

        // 回迁写的是内置盘：预检必须针对内置盘空间（此前误用外置盘预检——
        // 外置盘满会被错误拒绝，内置盘满却拦不住，写一半撑爆内置盘）
        if let reason = migrator.validateInternalFreeSpace(needBytes: item.sizeBytes) {
            AuditLog.append("拒绝数据回迁 \(item.title)：\(reason)")
            return (false, reason)
        }
        await OffPool.run { _ = SystemSnapshot.createThrottled() }

        progress(0.1, "删除链接...")
        try? fileManager.removeItem(atPath: site)

        progress(0.2, "正在回迁 \(item.title)...")
        guard await migrator.copyWithDitto(from: target, to: site, progress: { pct in
            progress(0.2 + pct * 0.7, "回迁 \(item.title)...")
        }) else {
            // 先腾空链接位再重建，否则半截副本会把链接位占住、建链失败（应用失去数据入口）
            try? fileManager.removeItem(atPath: site)
            try? fileManager.createSymbolicLink(atPath: site, withDestinationPath: target)
            AuditLog.append("数据回迁失败 \(item.title)：复制未完成，已恢复链接（外置副本保留）")
            return (false, "回迁复制失败")
        }

        progress(0.9, "校验...")
        guard await migrator.verifyFiles(source: target, target: site) else {
            try? fileManager.removeItem(atPath: site)
            try? fileManager.createSymbolicLink(atPath: site, withDestinationPath: target)
            AuditLog.append("数据回迁校验失败 \(item.title)：已恢复链接，外置副本保留")
            return (false, "文件校验失败，已恢复链接")
        }

        try? fileManager.removeItem(atPath: target)
        try? fileManager.removeItem(atPath: "\(drivePath)/.suishouqian-backup/\(Self.manifestName(for: item.id))")
        MigrationManifest.shared.remove(appName: Self.manifestName(for: item.id))
        AuditLog.append("数据回迁成功 \(item.title)：已恢复到内置盘并清理外置副本")
        progress(1.0, "完成")
        return (true, nil)
    }

    // MARK: - 自选文件夹迁移（v2.11.0）

    /// 自选条目的 id 前缀，台账 appName = "Data-custom.<文件夹名>"
    static let customIDPrefix = "custom."

    /// 护栏（纯字符串逻辑，可测）：不允许自选迁移的路径给人话理由，允许则 nil。
    ///
    /// 自选入口是给「库外大文件夹」（~/Movies 的项目、下载的数据集这类）用的。
    /// ~/Library 整个拒掉——偏好/沙盒/缓存/邮件那些高危目录的危险性是设计红线，
    /// 该场景已由内置清单按"最稳做法"覆盖；桌面/文稿/下载是 TCC 保护 + 日常热用，
    /// 链接化既会反复弹授权也拖慢日常，同样拒。
    static func customFolderIssue(forPath path: String, home: String) -> String? {
        let p = (path as NSString).standardizingPath
        // standardizingPath 会把 /private/var/... 规范成 /var/...（符号链接的规范形），
        // 系统根检查必须两种形态都跑，否则 /private 家族会被悄悄放行
        let canonical = (path as NSString).resolvingSymlinksInPath
        if p == "/" { return "不能迁移根目录" }
        if p == home { return "不能迁移整个用户目录" }
        if p.hasSuffix(".app") || p.hasSuffix(".bundle") {
            return "应用请到「迁移」页处理，数据面板只搬普通文件夹"
        }
        let systemRoots = ["/System", "/private", "/var", "/etc", "/tmp",
                           "/usr", "/bin", "/sbin",
                           "/Library", "/Applications", "/Volumes"]
        func hitsSystemRoot(_ q: String) -> Bool {
            systemRoots.contains { q == $0 || q.hasPrefix($0 + "/") }
        }
        if hitsSystemRoot(p) || hitsSystemRoot(canonical) {
            return "系统目录不能迁移"
        }
        // 前缀比对必须带 "/" 边界：/Volumes2 不能误伤 /Volumes 的规则，反之亦然
        let homeLibrary = home + "/Library"
        if p == homeLibrary || p.hasPrefix(homeLibrary + "/") {
            return "资源库（Library）里的数据风险高，工具按内置清单处理，不开放自选"
        }
        for name in ["Desktop", "Documents", "Downloads"] {
            let dir = home + "/" + name
            if p == dir || p.hasPrefix(dir + "/") {
                return "桌面/文稿/下载是日常热用目录，搬外置盘会拖慢日常且反复弹授权，不开放自选"
            }
        }
        return nil
    }

    /// 迁移用户自选的任意文件夹到外置盘（复用清单迁移同一管线与台账约定）。
    /// 先跑护栏与体检式预检，再进 linkMigrate 共享核心。
    func migrateCustomFolder(at rawPath: String, drivePath: String,
                             progress: @escaping @Sendable (Double, String) -> Void)
        async -> (success: Bool, error: String?) {
        let path = (rawPath as NSString).standardizingPath
        let name = (path as NSString).lastPathComponent
        let title = "自选 · \(name)"

        // 护栏与体积预检含 du（阻塞子进程）：OffPool
        let precheck = await OffPool.run { [self] () -> (reason: String?, size: Int64) in
            guard let issue = Self.customFolderIssue(forPath: path, home: NSHomeDirectory()) else {
                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    return ("选中的不是文件夹", 0)
                }
                let attrs = try? fileManager.attributesOfItem(atPath: path)
                if (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink {
                    return ("这个位置已经是链接，无需迁移", 0)
                }
                guard fileManager.isReadableFile(atPath: path) else {
                    return ("文件夹无法读取（可能受系统保护）", 0)
                }
                let size = duSize(path)
                guard size >= 100 * 1_048_576 else {
                    return ("体积小于 100MB，不值得迁移", size)
                }
                return (nil, size)
            }
            return (issue, 0)
        }
        if let reason = precheck.reason {
            AuditLog.append("拒绝自选迁移 \(title)：\(reason)")
            return (false, reason)
        }
        if let reason = migrator.validateTarget(drivePath: drivePath, appSize: precheck.size) {
            AuditLog.append("拒绝自选迁移 \(title)：\(reason)")
            return (false, reason)
        }
        let id = Self.customIDPrefix + name
        let externalPath = "\(Self.dataRoot(on: drivePath))/\(Self.manifestName(for: id))"
        // 外置盘目标重名 = 另一个同名文件夹已迁过：宁可拒绝也不含糊覆盖
        if fileManager.fileExists(atPath: externalPath) {
            return (false, "外置盘已有同名数据文件夹，请先处理旧数据或改用其他名称的文件夹")
        }
        return await linkMigrate(title: title, site: path, externalPath: externalPath,
                                 drivePath: drivePath, sizeBytes: precheck.size,
                                 manifestName: Self.manifestName(for: id),
                                 progress: progress)
    }

    /// 已迁移的自选文件夹条目（台账 kind=data 且 id 以 custom. 开头）。
    /// 与清单条目同型，回迁复用 restoreData。
    func scanCustomItems() async -> [DataLocationItem] {
        await OffPool.run { [self] in
            MigrationManifest.shared.all().compactMap { entry in
                guard entry.kind == "data",
                      entry.appName.hasPrefix(Self.manifestPrefix + Self.customIDPrefix)
                else { return nil }
                let id = String(entry.appName.dropFirst(Self.manifestPrefix.count))
                let path = entry.linkPath
                guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                      let type = attrs[.type] as? FileAttributeType,
                      type == .typeSymbolicLink else { return nil }
                var linkBroken = false
                if let dest = try? fileManager.destinationOfSymbolicLink(atPath: path) {
                    linkBroken = !fileManager.fileExists(atPath: dest)
                }
                let folder = String(id.dropFirst(Self.customIDPrefix.count))
                return DataLocationItem(
                    id: id, title: "自选 · \(folder)", path: path,
                    sizeBytes: duSize(path), isSymlink: true,
                    linkBroken: linkBroken, accessible: true,
                    managedByUs: true, ownerRunning: false,
                    relocation: .symlink, note: "自选文件夹迁移")
            }
        }
    }

    // MARK: - 离线分叉对账（v2.3）

    struct DataDivergence: Identifiable {
        let id = UUID()
        let title: String
        let sitePath: String       // 链接位（现被真目录占据）
        let externalPath: String   // 外置盘上的正本
    }

    /// 拔盘期间应用会在链接位重建真目录 → 插回后"两地分居"。
    /// 检测：台账里的数据链接位现在是真目录，且外置盘正本仍在。
    func checkDivergences() async -> [DataDivergence] {
        await OffPool.run { [self] in
            MigrationManifest.shared.all().compactMap { entry in
                guard entry.kind == "data" else { return nil }
                guard let attrs = try? fileManager.attributesOfItem(atPath: entry.linkPath),
                      let type = attrs[.type] as? FileAttributeType,
                      type == .typeDirectory else { return nil }   // 链接（正常态）不算
                guard let mount = MigrationManifest.mountPoint(forUUID: entry.volumeUUID),
                      fileManager.fileExists(atPath: "\(mount)/\(entry.relativePath)") else {                    return nil
                }
                return DataDivergence(
                    title: entry.appName.hasPrefix(Self.manifestPrefix)
                        ? String(entry.appName.dropFirst(Self.manifestPrefix.count))
                        : entry.appName,
                    sitePath: entry.linkPath,
                    externalPath: "\(mount)/\(entry.relativePath)")
            }
        }
    }

    /// 分叉处置「以外置盘为准」：本地离线重建目录改名隔离，重建链接。
    /// 数据合并风险太高，不自动做——被隔离目录留在原地供用户自行取舍。
    func isolateDivergence(_ divergence: DataDivergence) -> Bool {
        let stamp = DateFormatter()
        stamp.dateFormat = "MMdd-HHmm"
        let isolatedPath = "\(divergence.sitePath)（离线重建 \(stamp.string(from: Date()))）"
        guard (try? fileManager.moveItem(atPath: divergence.sitePath,
                                         toPath: isolatedPath)) != nil else { return false }
        do {
            try fileManager.createSymbolicLink(
                atPath: divergence.sitePath, withDestinationPath: divergence.externalPath)
            AuditLog.append("数据分叉隔离 \(divergence.title)：本地重建目录 → \(isolatedPath)，链接已恢复指向外置盘")
            return true
        } catch {
            try? fileManager.moveItem(atPath: isolatedPath, toPath: divergence.sitePath)
            return false
        }
    }

    // MARK: - 数据链接自愈（v2.3.1 审查补充）

    /// 数据链接的卷改名自愈：healBrokenLinks 只管 /Applications 的程序链接，
    /// ~/... 下的数据链接卷改名后同样会断，这里按台账补齐。
    /// 返回自愈成功的数据名列表（去掉 Data- 前缀）。
    @discardableResult
    func healDataLinks() -> [String] {
        var healed: [String] = []
        for entry in MigrationManifest.shared.all() where entry.kind == "data" {
            // 链接位仍是链接，但指向的目标已不存在（卷改名/换挂载点场景）；
            // 若链接位被真目录占据，那是分叉，交给 checkDivergences
            guard let attrs = try? fileManager.attributesOfItem(atPath: entry.linkPath),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeSymbolicLink,
                  let current = try? fileManager.destinationOfSymbolicLink(atPath: entry.linkPath),
                  !fileManager.fileExists(atPath: current) else { continue }
            guard let mount = MigrationManifest.mountPoint(forUUID: entry.volumeUUID),
                  fileManager.fileExists(atPath: "\(mount)/\(entry.relativePath)") else { continue }

            try? fileManager.removeItem(atPath: entry.linkPath)
            do {
                try fileManager.createSymbolicLink(
                    atPath: entry.linkPath,
                    withDestinationPath: "\(mount)/\(entry.relativePath)")
                AuditLog.append("数据链接自愈 \(entry.appName)：按卷 UUID 重新定位 → \(mount)/\(entry.relativePath)")
                healed.append(entry.appName.hasPrefix(Self.manifestPrefix)
                    ? String(entry.appName.dropFirst(Self.manifestPrefix.count))
                    : entry.appName)
            } catch {
                // 自愈失败保持断链状态，数据面板可见
            }
        }
        return healed
    }

    // MARK: - Private

    private func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func isOwnerRunning(_ location: DataLocation) -> Bool {
        if let bundleID = location.ownerBundleID,
           !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return true
        }
        for name in location.ownerProcessNames where name.isEmpty == false {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil {
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            }
        }
        return false
    }

    private func duSize(_ path: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", "-L", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        process.waitUntilExit()
        if let kb = Int64(output.split(separator: "\t").first ?? "") {
            return kb * 1024
        }
        return 0
    }
}
