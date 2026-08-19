import SwiftUI

struct DiskBarView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        HStack(spacing: 24) {
            // 内置硬盘
            if let builtin = appState.builtinDrive {
                driveCard(drive: builtin, label: "内置硬盘")
            }
            
            // 外置硬盘
            if let external = appState.externalDrive {
                driveCard(drive: external, label: "外置硬盘")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("外置硬盘")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive.badge.xmark")
                            .foregroundColor(.secondary)
                        Text("未连接")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    func driveCard(drive: DriveInfo, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: drive.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            
            // 空间条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(usageColor(drive.usageRatio))
                        .frame(width: geo.size.width * drive.usageRatio, height: 8)
                }
            }
            .frame(height: 8)
            
            HStack {
                Text("可用 \(drive.freeFormatted)")
                    .font(.system(size: 11, weight: .medium))
                Text("/ \(drive.totalFormatted)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    func usageColor(_ ratio: Double) -> Color {
        switch ratio {
        case ..<0.5: return .green
        case ..<0.8: return .orange
        default: return .red
        }
    }
}
