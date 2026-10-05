import AppKit
import CoreGraphics

// 列出「随手迁」进程的窗口边界（CGWindowList，屏幕坐标，y=0 在主屏顶部）
guard let list = CGWindowListCopyWindowInfo([], kCGNullWindowID)
    as? [[String: Any]] else { fatalError("枚举窗口失败") }
for w in list where (w[kCGWindowOwnerName as String] as? String) == "随手迁" {
    let bounds = w[kCGWindowBounds as String] as! [String: Any]
    let layer = w[kCGWindowLayer as String] as? Int ?? -99
    print("layer=\(layer) x=\(bounds["X"]!) y=\(bounds["Y"]!) w=\(bounds["Width"]!) h=\(bounds["Height"]!)")
}
