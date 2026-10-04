import Foundation

/// 卸载撤销的废纸篓定位（v3.1 第二梯队）。
///
/// 关键事实：NSWorkspace.recycle 把文件丢进哪个废纸篓取决于**它原来在哪块卷上**——
/// 内置盘文件进 ~/.Trash，外置盘文件进 <卷>/.Trashes/<UID>/。本工具卸载的
/// 应用大多住在外置盘（迁移态的真身/原住民本体），所以只查 ~/.Trash 会
/// 几乎永远找不到候选——撤销按钮形同虚设。这里把两类根目录都查。
///
/// 重名回收时 Finder 会给条目改名（"X.app" → "X 2.app"），精确名之外还要扫变体。
enum TrashRecovery {

    /// 测试注入缝：nil = 用真实废纸篓根目录集合
    nonisolated(unsafe) static var rootsOverride: [String]?

    /// 候选根目录：家废纸篓 + 各在线外置卷的 .Trashes/<UID>（volumeMounts 由调用方给，
    /// 离线卷不在列表里——离线盘上的废纸篓反正也读不到）。
    /// 阻塞 IO（目录枚举），调用方须在 OffPool。
    static func roots(externalMounts: [String]) -> [String] {
        if let rootsOverride { return rootsOverride }
        var roots = [(NSHomeDirectory() as NSString).appendingPathComponent(".Trash")]
        let uid = String(getuid())
        for mount in externalMounts {
            roots.append((mount as NSString).appendingPathComponent(".Trashes/\(uid)"))
        }
        return roots
    }

    /// 在候选根目录里定位某应用的本体。
    /// 顺序：精确名 > bundleID 对得上的变体 > 字典序最小的变体（Finder 重名序号）。
    /// 返回 nil = 所有根目录里都找不到。阻塞 IO，调用方须在 OffPool。
    static func locate(appName: String, bundleID: String?,
                       in roots: [String],
                       fileManager: FileManager = .default) -> String? {
        for root in roots {
            let exact = (root as NSString).appendingPathComponent(appName)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: exact, isDirectory: &isDir),
               isDir.boolValue {
                return exact
            }
        }
        // 精确名没有：扫重名变体（"X 2.app" / "X 3.app" …）
        guard let base = variantBase(appName) else { return nil }
        for root in roots {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            let variants = contents
                .filter { isTrashVariant($0, of: appName) }
                .sorted()
            if variants.isEmpty { continue }
            // bundleID 能对上的优先——同名应用被卸载多次时避免捞错
            if let bundleID, !bundleID.isEmpty {
                for v in variants {
                    let candidate = (root as NSString).appendingPathComponent(v)
                    let plist = (candidate as NSString).appendingPathComponent("Contents/Info.plist")
                    if let dict = NSDictionary(contentsOfFile: plist),
                       (dict["CFBundleIdentifier"] as? String) == bundleID {
                        return candidate
                    }
                }
            }
            let fallback = (root as NSString).appendingPathComponent(variants[0])
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: fallback, isDirectory: &isDir),
               isDir.boolValue {
                return fallback
            }
        }
        return nil
    }

    /// 变体名规则（纯逻辑，供测试）：去 ".app" 后是 "<原名> <数字>"，如 "X.app" → "X 2.app"
    static func isTrashVariant(_ fileName: String, of appName: String) -> Bool {
        guard let base = variantBase(appName) else { return false }
        let suffix = ".app"
        guard fileName.hasPrefix("\(base) "), fileName.hasSuffix(suffix) else { return false }
        let stem = String(fileName.dropFirst(base.count + 1).dropLast(suffix.count))
        return !stem.isEmpty && stem.allSatisfy(\.isNumber)
    }

    /// 应用名去 ".app" 扩展名的安全版：非 ".app" 结尾返回 nil（调用方放弃变体扫描）
    private static func variantBase(_ appName: String) -> String? {
        guard appName.hasSuffix(".app"), appName.count > 4 else { return nil }
        return String(appName.dropLast(4))
    }
}
