import SwiftUI

/// 全应用动效语言：高级感 = 克制 + 物理感 + 有目的。
/// - 全部弹簧曲线，拒绝线性/生硬；
/// - 全部尊重 accessibilityReduceMotion（开启动效全部直达终态）；
/// - 入场用 stagger（30-60ms 级差），hover 用 lift，加载用呼吸/微光。

// MARK: - 标准曲线

enum Motion {
    /// 入场：柔和弹簧
    static var entrance: Animation {
        .spring(response: 0.55, dampingFraction: 0.82)
    }
    /// hover/状态切换：更快更脆
    static var snappy: Animation {
        .spring(response: 0.35, dampingFraction: 0.75)
    }
    /// 进度条跟随：平滑阻尼
    static var progress: Animation {
        .spring(response: 0.45, dampingFraction: 0.85)
    }
}

// MARK: - 入场（淡入 + 上浮，支持 stagger）

private struct EntranceModifier: ViewModifier {
    let delay: Double
    let distance: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : distance)
            // 缩放带一点弹性，比纯位移更"活"
            .scaleEffect(appeared ? 1 : 0.97)
            .onAppear {
                guard !appeared else { return }
                if reduceMotion {
                    appeared = true
                } else {
                    withAnimation(Motion.entrance.delay(delay)) {
                        appeared = true
                    }
                }
            }
    }
}

extension View {
    /// 卡片/分区入场动画。delay 传 index * 0.05 做 stagger。
    func entrance(delay: Double = 0, distance: CGFloat = 14) -> some View {
        modifier(EntranceModifier(delay: delay, distance: distance))
    }
}

// MARK: - Hover 浮起（macOS 指针设备的"可交互"暗示）

private struct HoverLiftModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.015 : 1.0)
            .brightness(hovering && !reduceMotion ? 0.03 : 0)
            .animation(Motion.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 卡片 hover 时轻微浮起。只在指针设备上生效，触控无影响。
    func hoverLift() -> some View {
        modifier(HoverLiftModifier())
    }
}

// MARK: - 呼吸（进行中状态的"活着"暗示）

private struct BreatheModifier: ViewModifier {
    let range: ClosedRange<Double>
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .opacity(phase ? range.upperBound : range.lowerBound)
            .onAppear {
                if reduceMotion {
                    // 终态 = 完全可见：不能停在呼吸下限（永久半透明）
                    phase = true
                    return
                }
                withAnimation(
                    .easeInOut(duration: duration).repeatForever(autoreverses: true)
                ) {
                    phase = true
                }
            }
    }
}

extension View {
    /// 呼吸透明度动画（扫描中/任务进行中）。reduceMotion 下静止。
    func breathe(range: ClosedRange<Double> = 0.55...1.0,
                 duration: Double = 1.2) -> some View {
        modifier(BreatheModifier(range: range, duration: duration))
    }
}

// MARK: - 微光扫过（骨架屏/不确定进度）

/// 不确定进度的微光条：渐变块左右扫过。
struct ShimmerBar: View {
    let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: height)
                LinearGradient(
                    colors: [.clear, Color.accentColor.opacity(0.55), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: w * 0.35, height: height)
                .clipShape(Capsule())
                .offset(x: phase * w)
            }
        }
        .frame(height: height)
        .onAppear {
            // 终态 = 素条：高光块停在屏外（停在中间像渲染残影）
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.1
            }
        }
    }
}
