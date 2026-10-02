import SwiftUI

struct DiskBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// mountPoint → 链路体检结果（协议/格式/结论）
    @State private var linkInfo: [String: LinkInfo] = [:]
    /// mountPoint → 实测速度文案（手动触发，不随扫描自动跑——测速要写几百 MB）
    @State private var speedText: [String: String] = [:]
    @State private var speedRunning: [String: Bool] = [:]

    var body: some View {
        HStack(spacing: 12) {
            if let builtin = appState.builtinDrive {
                driveCard(drive: builtin, label: "内置硬盘",
                          icon: "internaldrive.fill", color: .blue)
                    .task(id: builtin.mountPoint) { probeLink(mount: builtin.mountPoint) }
            }

            if let external = appState.externalDrive {
                driveCard(drive: external, label: "外置硬盘",
                          icon: "externaldrive.fill", color: .green)
                    .task(id: external.mountPoint) { probeLink(mount: external.mountPoint) }
            } else {
                offlineCard
            }

            GlobalTaskCapsule()   // v3.1 附录 A2：任何面板都能看到在跑的任务
        }
        // 换线缆/换盒子后重插同一路径：旧链路结论必须作废重探
        .onChange(of: appState.externalDrive?.mountPoint) { _, new in
            guard let new, !new.isEmpty else { return }
            probeLink(mount: new)
            speedText[new] = nil   // 可能换了设备，旧速度数字作废
        }
    }

    /// 探测并覆盖缓存（diskutil 阻塞子进程走 OffPool；重插/换设备时重探）
    private func probeLink(mount: String) {
        guard !mount.isEmpty else { return }
        Task {
            let info = await OffPool.run { DiskLinkProbe.probe(mountPoint: mount) }
            if let info { linkInfo[mount] = info }
            // 自审发现：updateMetadata 此前全项目零调用——linkTier 永远 unknown，
            // 健康分 USB2 扣分与腾空间引擎的链路系数实际从未生效。现在把探测结果
            // 喂给 VolumeStore。诚实映射：diskutil 的 Protocol 分不出 USB2/USB3，
            // USB 一律 unknown（保守）；USB2 档只能由实测速度降档判定（runSpeedTest）
            let p = info?.protocolKind.lowercased() ?? ""
            let tier: LinkTier = (p.contains("pci") || p.contains("thunderbolt")
                                  || p.contains("fabric")) ? .thunderbolt : .unknown
            await MainActor.run {
                if let uuid = appState.volumeStore.volumes
                    .first(where: { $0.info.mountPoint == mount })?.id {
                    appState.volumeStore.updateMetadata(uuid: uuid, tier: tier)
                }
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
                        // 空间变化时用量条平滑伸缩（拔盘迁移后立即可感知）
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.4),
                                   value: drive.freeSize)
                }
            }
            .frame(height: 6)

            // 链路体检行：卷格式 · 连接协议 · 体感结论（exFAT 高亮警告）
            if let link = linkInfo[drive.mountPoint] {
                let v = link.verdict
                let summary = link.protocolKind.isEmpty
                    ? link.filesystemDisplay
                    : "\(link.filesystemDisplay) · \(link.protocolKind)"
                HStack(spacing: 4) {
                    Image(systemName: v.positive
                          ? "checkmark.circle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("\(summary) · \(v.text)")
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                .foregroundColor(v.positive ? .secondary : .orange)
                .help(v.text)   // 行宽不够截断时，悬停看全文
            }

            // 实测速度行（仅外置盘）：协议不等于体感，数字才有依据
            if drive.isExternal {
                speedRow(mount: drive.mountPoint)
            }
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

    // MARK: - 实测盘速（v2.12.0）

    @ViewBuilder
    private func speedRow(mount: String) -> some View {
        HStack(spacing: 5) {
            if let text = speedText[mount] {
                Image(systemName: "speedometer")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(text)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                    .help(text)
            }
            Spacer()
            if speedRunning[mount] == true {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Button("测速") { runSpeedTest(mount: mount) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .help("写 256MB 临时文件并读回实测，测完即删；点一次磨一次盘，按需点")
            }
        }
    }

    /// dd 是阻塞子进程：OffPool 跑（铁律），回主线程只做赋值
    private func runSpeedTest(mount: String) {
        guard speedRunning[mount] != true else { return }
        speedRunning[mount] = true
        speedText[mount] = nil
        Task {
            let result = await OffPool.run { DiskSpeedTest.run(mountPoint: mount) }
            speedRunning[mount] = false
            speedText[mount] = result.map {
                "写入 \(Int($0.writeMBps)) · 读取 \(Int($0.readMBps)) MB/s"
            } ?? "测速失败（盘可能只读或已满）"
            // 实测数据喂 VolumeStore：速度是链路档位的唯一诚实证据——
            // 写入 <50MB/s 判 USB2 档（健康分/推荐引擎才会如实降权）；USB 且达标升 usb3
            await MainActor.run {
                if let uuid = appState.volumeStore.volumes
                    .first(where: { $0.info.mountPoint == mount })?.id {
                    if let result {
                        appState.volumeStore.updateMetadata(uuid: uuid, mbps: result.writeMBps)
                        // 只在有证据时动档位：<50MB/s 判 USB2；USB 且达标升 USB3。
                        // 其余情况（如雷电盘）保留探测已给出的档位，别把已知降成未知
                        let isUSB = (linkInfo[mount]?.protocolKind.lowercased() ?? "").contains("usb")
                        if result.writeMBps < 50 {
                            appState.volumeStore.updateMetadata(uuid: uuid, tier: .usb2)
                        } else if isUSB {
                            appState.volumeStore.updateMetadata(uuid: uuid, tier: .usb3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 外置盘未连接

    private var offlineCard: some View {
        HStack(spacing: 8) {
            DriveIconBox(systemImage: "externaldrive.badge.xmark", color: .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("外置硬盘")
                    .font(.system(size: 12, weight: .semibold))
                Text(VolumeOfflineBanner.message(for: nil))
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
