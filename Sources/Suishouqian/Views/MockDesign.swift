import SwiftUI

// MARK: - 效果图设计系统（五页统一皮肤）
//
// 来源：数据/迁移/概览/设置/应用 五张效果图。视觉语言：
//   灰窗底 + 内容区一张大白圆角卡（r=18，柔和投影）；
//   卡片白底 r=16 + 发丝描边 + 柔影；主紫 #7060EC（与侧栏选中同源）；
//   主按钮蓝→紫渐变胶囊；健康横幅浅绿渐变；用量条蓝→紫（内置）/绿（外置）。

enum MockTheme {
    /// 主紫（与侧栏选中色一致）
    static let accent = Color(red: 0.44, green: 0.36, blue: 0.93)
    /// 主按钮渐变：蓝 → 紫
    static let primaryGradient = LinearGradient(
        colors: [Color(red: 0.23, green: 0.51, blue: 0.96),
                 Color(red: 0.55, green: 0.36, blue: 0.93)],
        startPoint: .leading, endPoint: .trailing)
    /// 用量条：内置盘 蓝→紫
    static let builtinBar = LinearGradient(
        colors: [Color(red: 0.23, green: 0.51, blue: 0.96),
                 Color(red: 0.55, green: 0.36, blue: 0.93)],
        startPoint: .leading, endPoint: .trailing)
    /// 用量条：外置盘 绿
    static let externalBar = LinearGradient(
        colors: [Color(red: 0.20, green: 0.78, blue: 0.55),
                 Color(red: 0.13, green: 0.70, blue: 0.47)],
        startPoint: .leading, endPoint: .trailing)
    /// 健康横幅：浅绿渐变底
    static let healthBanner = LinearGradient(
        colors: [Color(red: 0.90, green: 0.98, blue: 0.94),
                 Color(red: 0.85, green: 0.96, blue: 0.90)],
        startPoint: .leading, endPoint: .trailing)
    static let healthGreen = Color(red: 0.13, green: 0.70, blue: 0.45)
    static let statOrange = Color(red: 0.96, green: 0.62, blue: 0.20)

    enum Corner {
        static let page: CGFloat = 18     // 内容大白卡
        static let card: CGFloat = 16     // 页内卡片
        static let iconSquare: CGFloat = 10
        static let bar: CGFloat = 5
    }
}

// MARK: - 页面大白卡（内容区统一容器）

private struct MockPageModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: MockTheme.Corner.page, style: .continuous)
                    // 深色模式自适应：浅色白 / 深色深灰（写死 Color.white 深色下瞎眼）
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 20, y: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MockTheme.Corner.page, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.04))
            )
            .padding(14)
    }
}

// MARK: - 页内白卡

private struct MockCardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: MockTheme.Corner.card, style: .continuous)
                    // 深色模式自适应
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MockTheme.Corner.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05))
            )
    }
}

extension View {
    /// 整页大白卡（ContentView 对每个页面套用）
    func mockPage() -> some View { modifier(MockPageModifier()) }
    /// 页内白卡（概览统计卡、迁移任务卡、备份记录行…）
    func mockCard(padding: CGFloat = 16) -> some View { modifier(MockCardModifier(padding: padding)) }
    /// 悬停浮起：复用 Motion.swift 的 hoverLift（动效批已定义——重复声明会撞
    /// ambiguous use 编译错，本文件不再定义）
    /// 按压缩放（主按钮用）：按下时缩到 0.97，松开回弹
    func pressScale() -> some View { modifier(PressScaleModifier()) }
}

// MARK: - 微交互

/// 按压缩放：给主按钮加的触感反馈
private struct PressScaleModifier: ViewModifier {
    @State private var pressing = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(pressing ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressing)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressing = true }
                    .onEnded { _ in pressing = false }
            )
    }
}

// MARK: - 大标题（效果图：28pt 粗体左对齐）

struct MockPageTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 彩色图标方块（统计卡 / 备份记录行）

struct MockIconSquare: View {
    let systemImage: String
    var color: Color = MockTheme.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: MockTheme.Corner.iconSquare, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

// MARK: - 用量条（渐变填充 + 灰底，胶囊圆角）

struct MockUsageBar: View {
    let ratio: Double
    var gradient: LinearGradient = MockTheme.builtinBar
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.primary.opacity(0.07))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(gradient)
                        .frame(width: max(height, geo.size.width * min(max(ratio, 0), 1)))
                }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

// MARK: - 三色分段用量条（数据页「数据存储概览」）

struct MockSegment: Identifiable {
    let id = UUID()
    let label: String
    let bytes: Int64
    let color: Color
    var formatted: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct MockSegmentedBar: View {
    let segments: [MockSegment]
    var height: CGFloat = 14

    var body: some View {
        let total = max(segments.reduce(Int64(0)) { $0 + $1.bytes }, 1)
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(segments) { seg in
                    let w = geo.size.width * CGFloat(seg.bytes) / CGFloat(total)
                    if w > 0.5 {
                        Rectangle().fill(seg.color).frame(width: max(w, 2))
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - 主按钮：蓝→紫渐变胶囊（效果图「一键迁移全部」「重新扫描」）

struct MockGradientButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 13)
            .background(
                Capsule().fill(enabled ? MockTheme.primaryGradient
                                       : LinearGradient(colors: [Color.primary.opacity(0.2),
                                                                 Color.primary.opacity(0.2)],
                                                        startPoint: .leading, endPoint: .trailing))
            )
            .shadow(color: MockTheme.accent.opacity(enabled ? 0.35 : 0), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pressScale()
    }
}

// MARK: - 底部统计条（效果图各页底栏：纯灰文本 · 分隔）

struct MockBottomBar: View {
    let items: [String]
    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Text("·") }
                Text(item)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .padding(.vertical, 10)
    }
}

// MARK: - 胶囊页签（设置页「通用 / 备份 / 外置盘守护」）

struct MockCapsuleTabs<T: Hashable>: View {
    let tabs: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tabs, id: \.value) { tab in
                let selected = selection == tab.value
                Button { selection = tab.value } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? MockTheme.accent : .primary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(selected
                                ? MockTheme.accent.opacity(0.13)
                                : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                selected ? MockTheme.accent.opacity(0.35) : Color.clear,
                                lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}
