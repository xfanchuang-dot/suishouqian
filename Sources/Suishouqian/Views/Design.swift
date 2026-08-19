import SwiftUI

// MARK: - 设计系统（macOS Tahoe 风格：主题渐变 / 卡片 / 状态胶囊）

enum Theme {
    /// 品牌渐变：蓝 → 青
    static let accent = LinearGradient(
        colors: [.blue, .teal],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let accentColor = Color.blue
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

/// 卡片背景：圆角 + 细描边 + 轻投影
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
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
            RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.13))
            )
    }
}
