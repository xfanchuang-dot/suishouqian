import SwiftUI

/// 通用空状态：渐变插画 + 标题 + 说明 + 可选操作按钮。
///
/// 插画纯代码绘制（拟物移动硬盘 + 弧形环绕的应用图标瓦片 + 光晕），零图片资源，
/// 深色模式自适应。reduceMotion 由调用方传入（各页面已有 @Environment），
/// 静止时保持合法构图，不做假装静止（此前动效批次修过 6 处同类语义破洞）。
struct EmptyStateView: View {
    let symbol: String
    /// 环绕主插画的装饰符号（0~6 个），呈弧形排布、呼吸浮动
    let accentSymbols: [String]
    let gradient: [Color]
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var reduceMotion: Bool = false
    /// 插画资源名（Assets.xcassets）。为 nil 时用代码绘制的 SF Symbol 兜底，
    /// 所以资源没放进工程也能编译运行，只是没那么漂亮。
    var imageName: String? = nil

    @State private var floating = false

    var body: some View {
        VStack(spacing: 20) {
            illustration

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .entrance()
    }

    // MARK: - 配色

    /// 空数组兜底：通用组件不能假设调用方一定传了颜色（裸 gradient[0] 会崩）
    private var palette: [Color] {
        gradient.isEmpty ? [.blue, .cyan] : gradient
    }
    private var primary: Color { palette[0] }
    private var secondary: Color { palette.count > 1 ? palette[1] : palette[0] }

    // MARK: - 插画

    private struct AccentItem: Identifiable {
        let id: Int
        let name: String
        let x: CGFloat
        let y: CGFloat
        let size: CGFloat
        let delay: Double
    }

    /// 弧形环绕位（效果图方向：图标瓦片绕硬盘上半圈铺开）
    private var accents: [AccentItem] {
        let positions: [(CGFloat, CGFloat, CGFloat)] = [
            (-122, -58, 46), (-64, -94, 52), (36, -100, 48),
            (112, -58, 46), (126, 20, 42), (78, 68, 44),
        ]
        return accentSymbols.prefix(6).enumerated().map { i, name in
            AccentItem(id: i, name: name,
                       x: positions[i].0, y: positions[i].1, size: positions[i].2,
                       delay: Double(i) * 0.45)
        }
    }

    private var illustration: some View {
        Group {
            // 运行时校验资源真的在 catalog 里：Image("缺失名") 会画出空白而不是报错，
            // 只判参数非 nil 不构成兜底（落地审查修正）
            if let imageName, UIImage(named: imageName) != nil {
                // 定制插画资源：有图用图，整体呼吸浮动
                Image(imageName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 215)
                    .shadow(color: .black.opacity(0.1), radius: 18, y: 10)
                    .offset(y: floating ? -8 : 8)
                    .animation(
                        reduceMotion ? nil
                            : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                        value: floating
                    )
            } else {
                codeDrawnIllustration
            }
        }
        .frame(width: 230, height: 200)
        .onAppear {
            if !reduceMotion {
                // 下一 runloop 再启动，避免与 entrance 同时抢动画
                DispatchQueue.main.async {
                    floating = true
                }
            }
        }
    }

    /// 代码绘制兜底：SF Symbol + 渐变 + 光晕（资源缺失时不至于一片空白）
    private var codeDrawnIllustration: some View {
        ZStack {
            // 环境光晕
            Circle()
                .fill(primary.opacity(0.15))
                .frame(width: 260, height: 260)
                .blur(radius: 44)
            Circle()
                .fill(secondary.opacity(0.11))
                .frame(width: 190, height: 190)
                .blur(radius: 34)
                .offset(x: 48, y: -30)

            deviceIllustration

            // 环绕应用图标瓦片，呼吸浮动
            ForEach(accents) { a in
                accentTile(a)
            }
        }
        .frame(width: 320, height: 240)
        .onAppear {
            if !reduceMotion {
                // 下一 runloop 再启动，避免与 entrance 同时抢动画
                DispatchQueue.main.async {
                    floating = true
                }
            }
        }
    }

    /// 拟物移动硬盘：圆角机身 + 顶部高光 + 内盘圆 + USB 口（正视图，微倾 3°）
    private var deviceIllustration: some View {
        ZStack {
            // USB 口（先画，机身压住上半截）
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [.gray.opacity(0.75), .gray.opacity(0.4)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 22, height: 14)
                .offset(x: -58, y: 52)

            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: palette,
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 158, height: 100)
                .shadow(color: primary.opacity(0.4), radius: 22, y: 12)

            // 顶部高光（macOS 27 Golden Gate 式）
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0)],
                                     startPoint: .top, endPoint: .center))
                .frame(width: 158, height: 100)

            // 内盘圆
            Circle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 56, height: 56)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                .offset(y: -2)
        }
        .rotationEffect(.degrees(-3))
    }

    /// 应用图标风格的圆角瓦片
    private func accentTile(_ a: AccentItem) -> some View {
        let color = a.id.isMultiple(of: 2) ? primary : secondary
        return RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.95), secondary.opacity(0.7)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: a.size, height: a.size)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0)],
                                         startPoint: .top, endPoint: .center))
            )
            .overlay(
                Image(systemName: a.name)
                    .font(.system(size: a.size * 0.38, weight: .medium))
                    .foregroundStyle(.white)
            )
            .shadow(color: color.opacity(0.32), radius: 7, y: 4)
            .offset(x: a.x, y: a.y + (floating ? -6 : 6))
            .animation(
                reduceMotion ? nil
                    : .easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(a.delay),
                value: floating
            )
    }
}
