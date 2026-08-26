import Foundation

/// 把阻塞型工作（Process 执行+waitUntilExit、同步 IO）放到 GCD 全局队列执行。
/// Swift 协作线程池线程数固定（≈核心数），阻塞等待会占死池子，
/// 曾导致并行扫描 70 个 du 时迁移任务的 await 永远得不到调度（任务冻结事故）。
enum OffPool {
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: work())
            }
        }
    }
}
