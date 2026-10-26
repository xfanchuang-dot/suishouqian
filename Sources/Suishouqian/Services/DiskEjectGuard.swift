import Foundation
import DiskArbitration
import AppKit

/// 拔盘保护：在系统弹出外置卷**之前**拦截的守门员（DiskArbitration 弹出审批）。
///
/// 只拦两类真事故，其余弹出静默放行，不做氛围式打扰：
/// 1. 有应用正从该卷运行——断盘瞬间应用当场崩溃（链接态应用的可执行体在外置盘上）；
/// 2. 有迁移任务正在搬走该卷上的应用真身——拷到一半盘没了（恢复/卸载/盘间
///    迁移的源真身都在外置盘上）。
///
/// 已知边界（v1 有意不拦）：「迁移」把应用复制**到**外置盘的过程中目标盘被拔
/// ——此时无应用受损，半截副本由 copyWithDitto 的失败清理路径安全兜底；
/// MigrationTask 未携带目标盘信息，为此改 10+ 处任务调用点不划算。
final class DiskEjectGuard {
    /// 运行应用的可见信息探针：把 NSWorkspace 的类型挡在外面，纯逻辑才可测
    struct AppProbe: Equatable {
        let name: String
        let executablePath: String
        let isRegular: Bool
    }

    private var session: DASession?
    /// 该卷是否正被迁移任务使用（源真身在卷上）。由 AppState 注入，回调跑在主
    /// RunLoop 上，读主线程状态天然安全。
    private let isVolumeBusy: (String) -> Bool
    /// 拦截后的回调：(卷挂载点, 需要退出的应用名列表)。列表为空 = 仅任务占用。
    private let onVeto: (String, [String]) -> Void

    init(isVolumeBusy: @escaping (String) -> Bool = { _ in false },
         onVeto: @escaping (String, [String]) -> Void = { _, _ in }) {
        self.isVolumeBusy = isVolumeBusy
        self.onVeto = onVeto
    }

    func start() {
        guard session == nil else { return }
        guard let s = DASessionCreate(kCFAllocatorDefault) as DASession? else { return }
        // 审批回调必须把 session 挂在有 RunLoop 的线程上（不支持 dispatch queue），
        // 挂主 RunLoop。C 函数指针不能捕获，self 经 context 指针传入；
        // AppState 持有本守卫到进程结束，passUnretained 不会悬空。
        DARegisterDiskUnmountApprovalCallback(s, nil, { disk, context in
            // DADiskRef 以非可选导入；context 可为空（本注册传了 self，不会为空）
            guard let context else { return nil }
            let owner = Unmanaged<DiskEjectGuard>.fromOpaque(context).takeUnretainedValue()
            // 头文件约定：调用方对返回的 dissenter 隐式 retain 并负责 release
            // ——回调侧 +0 返回，passUnretained 正确
            return owner.approveUnmount(disk: disk).map(Unmanaged.passUnretained)
        }, Unmanaged.passUnretained(self).toOpaque())
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        session = s
    }

    /// session 释放即注销审批回调（DiskArbitration 无独立 unregister API）
    func stop() {
        session = nil
    }

    /// 弹出审批入口：返回 nil = 放行；返回 dissenter = 拦下。
    /// 设置开关每次调用都读，关闭即时生效。
    func approveUnmount(disk: DADisk) -> DADissenter? {
        guard UserDefaults.standard.bool(forKey: "ejectGuardEnabled") else { return nil }
        guard let desc = DADiskCopyDescription(disk),
              let url = (desc as NSDictionary)[kDADiskDescriptionVolumePathKey as String] as? URL
        else {
            return nil   // 拿不到挂载点就不瞎拦
        }
        let mountPath = url.path
        // 只拦外置卷（挂载点都在 /Volumes 下）；内置盘与根卷从不拦
        guard mountPath.hasPrefix("/Volumes/") else { return nil }

        let probes = NSWorkspace.shared.runningApplications.compactMap { app -> AppProbe? in
            guard let exec = app.executableURL?.path else { return nil }
            return AppProbe(name: app.localizedName ?? exec,
                            executablePath: exec,
                            isRegular: app.activationPolicy == .regular)
        }
        let running = DiskEjectGuard.dependentRunningApps(volumePath: mountPath, running: probes)
        let busy = running.isEmpty && isVolumeBusy(mountPath)
        guard !running.isEmpty || busy else { return nil }

        onVeto(mountPath, running)
        // kDAReturnBusy 以匿名枚举常量导入为 Int，DAReturn 是 Int32 别名
        return DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnBusy),
                                 "随手迁拔盘保护" as CFString)
    }

    // MARK: - 纯逻辑（供测试）

    /// 路径是否落在卷内（尾部斜杠归一化；卷根自身算在内）
    static func path(_ p: String, isInsideVolume root: String) -> Bool {
        let normalized = normalizedVolumeRoot(root)
        return p == normalized || p.hasPrefix(normalized + "/")
    }

    /// 该卷上正在运行的常规应用名单（顺序与传入一致）。
    /// executablePath 先解析软链接再判卷：链接态应用在 NSWorkspace 里
    /// executableURL 多半已指向真身，但这条依赖不是契约，resolve 一次才稳。
    /// 「只拦 /Volumes 外置卷」的门在 approveUnmount 把守，这里不重复设卡。
    static func dependentRunningApps(volumePath: String, running: [AppProbe]) -> [String] {
        running
            .filter { $0.isRegular }
            .filter { probe in
                let resolved = (probe.executablePath as NSString).resolvingSymlinksInPath
                return path(resolved, isInsideVolume: volumePath)
            }
            .map(\.name)
    }

    private static func normalizedVolumeRoot(_ root: String) -> String {
        root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
    }
}
