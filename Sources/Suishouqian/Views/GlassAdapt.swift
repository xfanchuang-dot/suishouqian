import SwiftUI

/// macOS 27 真·玻璃拟态（Liquid Glass 精修版）。
///
/// ⚠️ 工具链要求：需要 Xcode 26+ / Swift 6.2+（macOS 26 SDK）才能编译。
/// 如果 `swift build` 报错找不到 `glassEffect`：说明工具链太旧，
/// 直接删掉本文件即可——其他改动（CardStyle 精修、圆角统一等）
/// 用的都是兼容 API，不受影响，会自动回退到材质近似。
///
/// 设计原则（Golden Gate 2026  guidance）：玻璃只给"悬浮的瞬态表面"，
/// 不给常驻内容卡片——结构永远是第一设计决策。

@available(macOS 26, *)
enum LiquidGlass {

    /// 悬浮胶囊的玻璃底（任务胶囊、浮动徽章）。interactive 让它响应指针。
    static func capsuleTint(_ tint: Color? = nil) -> Glass {
        let base = Glass.regular.interactive()
        if let tint {
            return base.tint(tint)
        }
        return base
    }

    /// 侧栏选中行的动态玻璃：紫色着色 + 指针交互（随背后内容实时折射）。
    static func sidebarSelection(_ accent: Color) -> Glass {
        Glass.regular.interactive().tint(accent.opacity(0.45))
    }

    /// 侧栏磁盘卡这类常驻小卡：透明玻璃，不额外着色。
    static var sidebarCard: Glass {
        Glass.regular
    }
}

extension View {
    /// 悬浮元素玻璃化（macOS 26+ 真玻璃，低版本走材质回退）。
    /// 用在：GlobalTaskCapsule 这类"浮在内容上"的瞬态表面。
    @ViewBuilder
    func liquidGlassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(LiquidGlass.capsuleTint(tint))
        } else {
            // 回退：材质近似（macOS 14+ 可用）
            self.background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            )
        }
    }

    /// 玻璃按钮（macOS 26+）。
    @ViewBuilder
    func liquidGlassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// 侧栏选中态：macOS 26+ 动态液化玻璃（紫色、响应指针），低版本回退浅紫实底。
    /// 仅当选中时调用方才应应用本修饰（未选中行保持透明）。
    @ViewBuilder
    func sidebarSelectedGlass(accent: Color, cornerRadius: CGFloat = 7) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(
                LiquidGlass.sidebarSelection(accent),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(accent.opacity(0.13))
            )
        }
    }

    /// 侧栏小卡玻璃底（磁盘卡）：macOS 26+ 真玻璃，低版本回退材质近似。
    @ViewBuilder
    func sidebarCardGlass(cornerRadius: CGFloat = 10) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(
                LiquidGlass.sidebarCard,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}
