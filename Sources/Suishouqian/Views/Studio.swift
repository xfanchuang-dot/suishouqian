import SwiftUI

/// 效果图 A 的视觉语言：透气渐变底、大圆角毛玻璃卡、环图和强调色。
/// 深色模式用同一套结构，只换底色和阴影。最低系统 macOS 14。
enum Studio {
    static let radius: CGFloat = 18
    static let blue = Color(red: 0.22, green: 0.48, blue: 0.98)
    static let teal = Color(red: 0.16, green: 0.74, blue: 0.70)
    static let ringBlue = [
        Color(red: 0.36, green: 0.46, blue: 0.98),
        Color(red: 0.45, green: 0.78, blue: 1.0)
    ]
    static let ringTeal = [
        Color(red: 0.28, green: 0.84, blue: 0.74),
        Color(red: 0.16, green: 0.62, blue: 0.72)
    ]

    static func canvas(_ scheme: ColorScheme) -> LinearGradient {
        if scheme == .dark {
            return LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.18),
                    Color(red: 0.07, green: 0.08, blue: 0.11)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.97, blue: 1.0),
                Color(red: 0.86, green: 0.91, blue: 0.97)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var savedGradient: LinearGradient {
        LinearGradient(colors: [blue, teal], startPoint: .leading, endPoint: .trailing)
    }
}

struct StudioCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Studio.radius, style: .continuous)
                    .fill(.thinMaterial)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.08), radius: 18, y: 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Studio.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.14 : 0.06))
            }
    }
}

extension View {
    func studioCard() -> some View { modifier(StudioCard()) }
    func studioCanvas() -> some View {
        modifier(StudioCanvasModifier())
    }
}

private struct StudioCanvasModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background(Studio.canvas(scheme))
    }
}

/// 磁盘占用环。中间放调用方自己的百分比。
struct UsageRing: View {
    var ratio: Double
    var colors: [Color]
    var lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(ratio, 0), 1))
                .stroke(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityLabel(l10n("已用 %lld%%", Int(min(max(ratio, 0), 1) * 100)))
    }
}

/// 侧栏图标：圆角色块。选中时整行变蓝，图标改成白色。
struct SidebarTile: View {
    let systemImage: String
    let tint: Color
    var selected: Bool

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(selected ? Color.white : tint)
            .frame(width: 28, height: 28)
            .background(
                (selected ? Color.white.opacity(0.22) : tint.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}
