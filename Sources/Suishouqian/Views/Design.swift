import SwiftUI

// MARK: - 设计系统（macOS 27 Golden Gate 语法）
//
// Golden Gate 精修 Liquid Glass：圆角收紧（12→10，不再夸张）、
// 顶部高光（specular highlight）+ 底部加深（darker edge）营造玻璃纵深、
// 投影更柔更散（拒绝反复描边解释层级）。

enum Theme {
    /// 品牌渐变：蓝 → 青
    static let accent = LinearGradient(
        colors: [.blue, .teal],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let accentColor = Color.blue

    /// macOS 27 统一圆角：卡片 10，图标容器 8，小徽章 7
    enum Corner {
        static let card: CGFloat = 10
        static let iconBox: CGFloat = 8
        static let badge: CGFloat = 7
    }
}

/// 分区标题：小图标 + 大写小字号副标题
struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
        }
    }
}

/// 状态胶囊：着色背景 + 同色文字与图标
struct StatusPill: View {
    let text: String
    let systemImage: String?
    let color: Color

    init(_ text: String, systemImage: String? = nil, color: Color) {
        self.text = text
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: Capsule())
        .foregroundColor(color)
    }
}

/// 卡片背景：macOS 27 语法——收紧圆角 + 玻璃高光边缘 + 柔化投影。
/// 顶部 0.5pt 高光（浅色模式白/深色模式亦白，低透明度即玻璃边），
/// 底部轻微加深，投影更散（radius 8, y 2）不再用生硬小投影。
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Corner.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.45),
                                .white.opacity(0.08),
                                .black.opacity(0.08)
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
    }
}

extension View {
    func cardStyle() -> some View { modifier(CardStyle()) }
}

/// 应用图标容器：38pt 圆角底 + 居中图标
struct IconContainer: View {
    let icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 38, height: 38)
        .background(
            RoundedRectangle(cornerRadius: Theme.Corner.iconBox, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// 磁盘图标方块：着色浅底 + 居中符号
struct DriveIconBox: View {
    let systemImage: String
    let color: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.Corner.badge, style: .continuous)
                    .fill(color.opacity(0.13))
            )
    }
}
