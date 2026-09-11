import Foundation
import AppKit

struct AppItem: Identifiable {
    let id = UUID()
    let name: String
    let bundleName: String
    let path: String
    let version: String?
    let size: Int64
    let isSymlink: Bool
    let symlinkTarget: String?
    var icon: NSImage?
    var status: AppStatus = .normal
    
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

struct MigrationTask: Identifiable {
    let id = UUID()
    let app: AppItem
    let operation: MigrationOperation
    var progress: Double = 0
    var currentFile: String = ""
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var status: TaskStatus = .preparing
    
    enum MigrationOperation {
        case migrate
        case restore
        case uninstall
    }
    
    enum TaskStatus: Equatable {
        case preparing
        case copying
        case verifying
        case linking
        case completed
        case failed(String)
        
        static func == (lhs: TaskStatus, rhs: TaskStatus) -> Bool {
            switch (lhs, rhs) {
            case (.preparing, .preparing): return true
            case (.copying, .copying): return true
            case (.verifying, .verifying): return true
            case (.linking, .linking): return true
            case (.completed, .completed): return true
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
        
        var isTerminal: Bool {
            switch self {
            case .completed, .failed: return true
            default: return false
            }
        }
    }
}
