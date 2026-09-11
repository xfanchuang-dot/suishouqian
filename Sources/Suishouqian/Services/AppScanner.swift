import Foundation
import AppKit

class AppScanner: @unchecked Sendable {

    /// 扫描应用列表。externalRoots 传外置盘上的应用目录
    /// （如 <盘>/Applications、<盘>/Suishouqian_Apps）：
    /// 一直住在外置盘的应用（如安装时选了外置盘的 WPS）也要出现在列表里。
    /// 去重规则：外置盘候选若与内置盘同名（多半是迁移过去的正本），跳过。
    func scanApplications(externalRoots: [String] = []) async -> [AppItem] {
        let internalDirs = [
            "/Applications",
            "/System/Applications"
        ]

        func listApps(in dir: String) -> [URL] {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return contents.filter { $0.pathExtension == "app" }
        }

        var internalURLs: [URL] = []
        for dir in internalDirs {
            internalURLs.append(contentsOf: listApps(in: dir))
        }
        let internalNames = Set(internalURLs.map(\.lastPathComponent))

        // 外置盘候选：去掉与内置盘同名的（那是迁移正本，/Applications 里已有链接）
        var externalURLs: [URL] = []
        for root in externalRoots {
            for url in listApps(in: root) where !internalNames.contains(url.lastPathComponent) {
                externalURLs.append(url)
            }
        }

        // 体验：并行扫描（此前逐个 du 串行，70 个应用要 5~8 秒）。
        // 并发限 8 且 du 走 OffPool：无界并发 + 协作池内阻塞等待
        // 曾把线程池占死，导致迁移任务冻结（2026-08-26 事故根因）
        var items: [AppItem] = []
        items += await scanChunk(internalURLs)
        items += await scanChunk(externalURLs)
        return items
    }

    private func scanChunk(_ urls: [URL]) async -> [AppItem] {
        let chunkSize = 8
        var index = 0
        var items: [AppItem] = []
        while index < urls.count {
            let chunk = urls[index..<min(index + chunkSize, urls.count)]
            let part = await withTaskGroup(of: AppItem?.self) { group in
                for url in chunk {
                    group.addTask { await self.scanApp(at: url) }
                }
                var arr: [AppItem] = []
                for await item in group {
                    if let item { arr.append(item) }
                }
                return arr
            }
            items += part
            index += chunkSize
        }
        return items
    }

    /// 外置盘候选去重（纯逻辑，供测试）
    static func externalCandidates(_ names: [String], alreadyInternal: Set<String>) -> [String] {
        names.filter { !alreadyInternal.contains($0) }
    }

    /// 轻量清单：/Applications 下的 .app 名单（新应用入住提醒用，不做 du）
    static func quickAppNames() -> [String] {
        return ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
            .filter { $0.hasSuffix(".app") }
    }
    
    private func scanApp(at url: URL) async -> AppItem? {
        let path = url.path
        let bundleName = url.lastPathComponent
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        
        var displayName = bundleName.replacingOccurrences(of: ".app", with: "")
        var version: String?
        
        if let plist = NSDictionary(contentsOf: infoPlist) {
            if let name = plist["CFBundleDisplayName"] as? String {
                displayName = name
            } else if let name = plist["CFBundleName"] as? String {
                displayName = name
            }
            if let ver = plist["CFBundleShortVersionString"] as? String {
                version = ver
            }
        }
        
        let (isSymlink, target) = checkSymlink(path)
        let size = await calculateSize(at: url)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        
        var item = AppItem(
            name: displayName,
            bundleName: bundleName,
            path: path,
            version: version,
            size: size,
            isSymlink: isSymlink,
            symlinkTarget: target,
            icon: icon
        )
        
        if item.isSystemApp {
            item.status = .systemApp
        } else if item.isOnExternal {
            item.status = .migrated
        } else if path.hasPrefix("/Volumes/") {
            // 一直住在外置盘的应用（无链接、内置盘无副本）
            item.status = .externalOnly
        }
        
        return item
    }
    
    private func checkSymlink(_ path: String) -> (Bool, String?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileType = attrs[.type] as? FileAttributeType,
              fileType == .typeSymbolicLink else {
            return (false, nil)
        }
        
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        return (true, target)
    }
    
    private func calculateSize(at url: URL) async -> Int64 {
        let path = url.path
        return await OffPool.run {
            Self.directorySizeBytes(atPath: path)
        }
    }

    /// 目录体积（字节）。
    ///
    /// **必须带 `-L` 跟随符号链接**：已迁移应用的路径是软链接，不带 -L 时
    /// BSD du 只统计链接本身（本机实测 `/Applications/Safari.app` 报 0），
    /// 后果有两个：列表里已迁移应用显示"0 字节"；回迁的空间预检
    /// `validateInternalFreeSpace(needBytes: app.size)` 拿到 0 而永远放行，
    /// 内置盘满时会在复制中途失败。`-L` 对普通目录无影响。
    static func directorySizeBytes(atPath path: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", "-L", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            // 先读至 EOF 再等待退出（防管道写满死锁）
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let kb = Int64(output.split(separator: "\t").first ?? "0") {
                return kb * 1024
            }
        } catch {}
        return 0
    }
}
