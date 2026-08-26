import Foundation
import AppKit

class AppScanner: @unchecked Sendable {
    
    func scanApplications() async -> [AppItem] {
        let dirs = [
            "/Applications",
            "/System/Applications"
        ]

        var urls: [URL] = []
        for dir in dirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            urls.append(contentsOf: contents.filter { $0.pathExtension == "app" })
        }

        // 体验：并行扫描（此前逐个 du 串行，70 个应用要 5~8 秒）
        return await withTaskGroup(of: AppItem?.self) { group in
            for url in urls {
                group.addTask { await self.scanApp(at: url) }
            }
            var items: [AppItem] = []
            for await item in group {
                if let item { items.append(item) }
            }
            return items
        }
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
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sk", url.path]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let parts = output.split(separator: "\t")
                if let kb = Int64(parts.first ?? "0") {
                    return kb * 1024
                }
            } catch {}
            return 0
        }.value
    }
}
