import SwiftUI

struct DiskBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            if let builtin = appState.builtinDrive {
                driveCard(drive: builtin, label: "内置硬盘",
                          icon: "internaldrive.fill", color: .blue)
            }

            if let external = appState.externalDrive {
                driveCard(drive: external, label: "外置硬盘",
                          icon: "externaldrive.fill", color: .green)
            } else {
                offlineCard
            }
        }
    }

    // MARK: - 在线磁盘卡片

    private func driveCard(drive: DriveInfo, label: String,
                           icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DriveIconBox(systemImage: icon, color: color)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                    Text("可用 \(drive.freeFormatted) / 共 \(drive.totalFormatted)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !drive.isExternal && drive.freeSize < 40 * 1_073_741_824 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .help("内置盘剩余空间低于 40GB 警戒线")
                }
                Text("\(Int(drive.usageRatio * 100))%")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(usageColor(drive.usageRatio))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 6)

                    Capsule()
                        .fill(barGradient(usageColor(drive.usageRatio)))
                        .frame(width: max(6, geo.size.width * drive.usageRatio),
                               height: 6)
                }
            }
            .frame(height: 6)
        }
        .padding(12)
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

    // MARK: - 外置盘未连接

    private var offlineCard: some View {
        HStack(spacing: 8) {
            DriveIconBox(systemImage: "externaldrive.badge.xmark", color: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("外置硬盘")
                    .font(.system(size: 12, weight: .semibold))
                Text("未连接 · 插入后将自动识别")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18))
        )
    }

    // MARK: -

    private func barGradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.65), color],
                       startPoint: .leading, endPoint: .trailing)
    }

    private func usageColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.5: return .green
        case ..<0.8: return .orange
        default: return .red
        }
    }
}
