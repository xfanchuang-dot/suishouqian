import Foundation
import AppKit

struct AppItem: Identifiable {
    let id = UUID()
    let name: String
    let bundleName: String
    let path: String
    let version: String?
    /// CFBundleIdentifier：使用频率顾问用它把启动记录与扫描结果对上
    /// （bundleID 在更新/改名/搬家中都稳定）。plist 读不到时为 nil，
    /// 这类应用不参与使用统计。
    var bundleID: String? = nil
    let size: Int64
    let isSymlink: Bool
    let symlinkTarget: String?
    var icon: NSImage?
    var status: AppStatus = .normal
    /// 更新方式（扫描时探测）：决定"搬到外置盘后更新会不会把迁移顶掉"
    var updateMechanism: UpdateMechanism = .unknown
    
    enum AppStatus: Equatable {
        case normal
        case migrated
        case migrating
        case restoring
        case needsSync
        case systemApp
        /// 一直住在外置盘的应用（无符号链接、内置盘无副本）
        case externalOnly
    }
    
    var isSystemApp: Bool {
        let systemPaths = [
            "/System/Applications",
            "/System/Library/CoreServices"
        ]
        return systemPaths.contains { path.hasPrefix($0) }
    }
    
    var isOnExternal: Bool {
        return isSymlink && (symlinkTarget?.hasPrefix("/Volumes/") ?? false)
    }
    
    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct DriveInfo {
    let name: String
    let mountPoint: String
    let totalSize: Int64
    let freeSize: Int64
    let isExternal: Bool
    /// 卷 UUID（统一大写）。多盘并列时用它认住「用户上次选定的那块盘」，
    /// 否则同容量的两块盘之间目标盘会随枚举顺序漂移
    let volumeUUID: String?
    var isConnected: Bool { mountPoint != "" }
    
    var freeFormatted: String {
        ByteCountFormatter.string(fromByteCount: freeSize, countStyle: .file)
    }
    
    var totalFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
    
    var usageRatio: Double {
        guard totalSize > 0 else { return 0 }
        return Double(totalSize - freeSize) / Double(totalSize)
    }
}

/// 协作式取消令牌（class 引用语义：MigrationTask 是 struct，
/// 进度回调里 `var t = state.migrationTask ?? ...` 会拷贝，
/// 用 class 才能保证取消信号不被拷贝稀释）。
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.withLock { _cancelled }
    }

    func cancel() {
        lock.withLock { _cancelled = true }
    }
}

struct MigrationTask: Identifiable {
    let id = UUID()
    let app: AppItem
    let operation: MigrationOperation
    var progress: Double = 0
    var currentFile: String = ""
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var status: TaskStatus = .preparing
    /// 取消令牌：UI 点取消 → token.cancel() → 管道各阶段检查即停
    let cancellationToken = CancellationToken()
    
    enum MigrationOperation {
        case migrate
        case restore
        case uninstall
        case relocate   // 盘间迁移/撤销（v3.0）
    }
    
    enum TaskStatus: Equatable {
        case preparing
        case copying
        case verifying
        case linking
        case completed
        case failed(String)
        /// 用户主动取消（非失败：半截副本已清理，源目录未动）
        case cancelled
        
        static func == (lhs: TaskStatus, rhs: TaskStatus) -> Bool {
            switch (lhs, rhs) {
            case (.preparing, .preparing): return true
            case (.copying, .copying): return true
            case (.verifying, .verifying): return true
            case (.linking, .linking): return true
            case (.completed, .completed): return true
            case (.cancelled, .cancelled): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
        
        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }
}
