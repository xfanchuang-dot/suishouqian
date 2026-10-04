import SwiftUI

/// 通用空状态：渐变插画 + 标题 + 说明 + 可选操作按钮。
///
/// 插画纯代码绘制（SF Symbol + 渐变 + 光晕），零图片资源，深色模式自适应。
/// reduceMotion 由调用方传入（各页面已有 @Environment），静止时保持合法构图，
/// 不做假装静止（此前动效批次修过 6 处同类语义破洞）。
struct EmptyStateView: View {
    let symbol: String
    /// 环绕主图标的小装饰符号（0~3 个）
    let accentSymbols: [String]
    let gradient: [Color]
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var reduceMotion: Bool = false

    @State private var floating = false

    var body: some View {
        VStack(spacing: 18) {
            illustration

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .entrance()
    }

    // MARK: - 插画

    /// 空数组兜底：通用组件不能假设调用方一定传了颜色（裸 gradient[0] 会崩）
    private var palette: [Color] {
        gradient.isEmpty ? [.blue, .cyan] : gradient
    }
    private var primary: Color { palette[0] }
    private var secondary: Color { palette.count > 1 ? palette[1] : palette[0] }

    private struct AccentItem: Identifiable {
        let id: Int
        let name: String
        let x: CGFloat
        let y: CGFloat
        let delay: Double
    }

    private var accents: [AccentItem] {
        let positions: [(CGFloat, CGFloat)] = [(-72, -52), (74, -38), (62, 58)]
        return accentSymbols.prefix(3).enumerated().map { i, name in
            AccentItem(id: i, name: name,
                       x: positions[i].0, y: positions[i].1,
                       delay: Double(i) * 0.45)
        }
    }

    private var illustration: some View {
        ZStack {
            // 环境光晕
            Circle()
                .fill(primary.opacity(0.16))
                .frame(width: 200, height: 200)
                .blur(radius: 36)
            Circle()
                .fill(secondary.opacity(0.12))
                .frame(width: 150, height: 150)
                .blur(radius: 28)
                .offset(x: 36, y: -24)

            // 主图标圆
            Circle()
                .fill(
                    LinearGradient(
                        colors: palette,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 104, height: 104)
                .shadow(color: primary.opacity(0.38), radius: 18, y: 10)

            // 顶部高光（macOS 27 Golden Gate 式）
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0)],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: 104, height: 104)

            Image(systemName: symbol)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.white)
                .shadow(radius: 2)

            // 环绕小装饰，呼吸浮动
            ForEach(accents) { a in
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    .overlay(
                        Image(systemName: a.name)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(primary)
                    )
                    .offset(x: a.x, y: a.y + (floating ? -7 : 7))
                    .animation(
                        reduceMotion ? nil
                            : .easeInOut(duration: 2.2).repeatForever(autoreverses: true).delay(a.delay),
                        value: floating
                    )
            }
        }
        .frame(width: 220, height: 190)
        .onAppear {
            if !reduceMotion {
                // 下一 runloop 再启动，避免与 entrance 同时抢动画
                DispatchQueue.main.async {
                    floating = true
                }
            }
        }
    }
}
