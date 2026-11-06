import SwiftUI

// MARK: - 设计系统（macOS 27 Golden Gate 语法）
//
// Golden Gate 精修 Liquid Glass：圆角收紧（12→10，不再夸张）、
// 顶部高光（specular highlight）+ 底部加深（darker edge）营造玻璃纵深、
// 投影更柔更散（拒绝反复描边解释层级）。

enum Theme {
    // 品牌色与渐变统一由 MockTheme 提供（baseline-ui 审计：旧蓝青渐变已退役，
    // 全应用唯一强调色 = MockTheme.accent 紫）

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
                .foregroundStyle(MockTheme.accent)
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

// MARK: - 迁移阶段节点（计划评审/执行视图共用的「固定阶段」可视化原语）

/// 阶段节点的视觉状态。图标 + 文字双通道：颜色只做辅助，语义靠符号与文案。
enum MigrationStageVisualState: Equatable {
    /// 尚未开始
    case pending
    /// 正在进行
    case active
    /// 已完成
    case done
    /// 终止且非成功（已取消 / 已失败）
    case stopped
}

/// 单个迁移阶段的节点：圆环符号 + 阶段名。
/// 评审 sheet 里四个固定阶段全部以 `.pending` 呈现；
/// 执行视图（Task 3）按 `MigrationExecutionPhase` 推进同一组件。
struct MigrationStageNode: View {
    let title: String
    let state: MigrationStageVisualState

    private var systemImage: String {
        switch state {
        case .pending: return "circle"
        case .active: return "arrowtriangle.right.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .pending: return .secondary
        case .active: return MockTheme.accent
        case .done: return MockTheme.healthGreen
        case .stopped: return MockTheme.statOrange
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(color)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(state == .pending ? .secondary : color)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(accessibilityState)")
    }

    private var accessibilityState: String {
        switch state {
        case .pending: return l10n("未开始")
        case .active: return l10n("进行中")
        case .done: return l10n("已完成")
        case .stopped: return l10n("已停止")
        }
    }
}

// MARK: - 迁移入口统一控件（Task 5：冷静控制台层级）

/// 唯一主操作按钮：实色 `MockTheme.accent` 胶囊。
/// 冷静控制台规范（Task 5 Step 3）：主操作只用单一低饱和强调色，
/// 不再使用蓝→紫渐变；按压缩放复用 pressScale（内部自带 reduceMotion 闸）。
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(enabled ? MockTheme.accent : Color.primary.opacity(0.2)))
            .shadow(color: enabled ? MockTheme.accent.opacity(0.25) : .clear,
                    radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .pressScale()
    }
}

/// 次级命令样式：文字 + 发丝描边胶囊，视觉权重一律低于 `PrimaryActionButton`。
/// 「迁移历史 / 全部回迁 / 一键腾空间 / 盘要退休」等降级命令的统一外观；
/// `tint` 默认中性灰，仅在命令本身携带既有警告语义时传入（如盘要退休的橙）。
private struct SecondaryCommandModifier: ViewModifier {
    var tint: Color = .secondary

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
    }
}

extension View {
    /// 次级命令：文字/描边控件，弱于唯一主操作
    func secondaryCommand(tint: Color = .secondary) -> some View {
        modifier(SecondaryCommandModifier(tint: tint))
    }
}
