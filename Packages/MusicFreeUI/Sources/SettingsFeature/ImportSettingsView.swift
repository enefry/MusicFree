import DesignSystem
import LibraryAPI
import SettingsAPI
import SwiftUI

struct ImportSettingsView: View {
    let viewModel: SettingsViewModel

    var body: some View {
        Section(L("导入与资料库")) {
            HStack {
                Text(L("重复内容"))
                Spacer()
                Text(L("跳过已有内容"))
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
            .accessibilityIdentifier("settings.import.duplicatePolicy")

            Text(L("当前版本对相同内容统一跳过导入；替换和保留重复副本尚未接入。"))
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            Toggle(
                isOn: Binding(
                    get: { viewModel.settings.importPreferences.useMusicKitMetadataEnrichment },
                    set: { viewModel.setMusicKitMetadataEnrichmentEnabled($0) }
                )
            ) {
                Label(L("使用 MusicKit 补充元数据"), systemImage: "wand.and.stars")
            }
            .disabled(viewModel.metadataEnrichmentSnapshot.authorization == .unavailable)
            .accessibilityIdentifier("settings.import.musicKitEnrichment")

            Text(metadataAvailabilityText)
                .font(MusicFreeTypographyTokens.secondary)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)

            if viewModel.metadataEnrichmentSnapshot.authorization == .denied
                || viewModel.metadataEnrichmentSnapshot.authorization == .restricted
            {
                Button {
                    viewModel.requestMusicKitAuthorization()
                } label: {
                    Label(L("重新请求 Apple Music 权限"), systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("settings.import.musicKitAuthorization")
            }

            let scan = viewModel.metadataEnrichmentSnapshot.scan
            if viewModel.metadataEnrichmentSnapshot.isEnabled,
               viewModel.metadataEnrichmentSnapshot.authorization == .authorized
            {
                if scan.status == .scanning {
                    if scan.total > 0 {
                        ProgressView(
                            value: Double(scan.processed),
                            total: Double(scan.total)
                        )
                    } else {
                        ProgressView()
                    }
                    Text(L("正在扫描 %d/%d", scan.processed, scan.total))
                        .font(MusicFreeTypographyTokens.secondary)
                        .accessibilityIdentifier("settings.import.musicKitProgress")
                    if let currentTitle = scan.currentTitle {
                        Text(currentTitle)
                            .lineLimit(1)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    }
                    Button(role: .cancel) {
                        viewModel.cancelMusicKitMetadataScan()
                    } label: {
                        Label(L("取消扫描"), systemImage: "xmark")
                    }
                    .accessibilityIdentifier("settings.import.musicKitCancel")
                } else {
                    Button {
                        viewModel.startMusicKitMetadataScan()
                    } label: {
                        Label(L("扫描并补充"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(scan.status == .scanning)
                    .accessibilityIdentifier("settings.import.musicKitScan")

                    if scan.status == .completed || scan.status == .cancelled {
                        Text(scanSummary(scan))
                            .font(MusicFreeTypographyTokens.secondary)
                            .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    } else if scan.status == .failed {
                        Text(L("扫描未完成，请稍后重试。"))
                            .font(MusicFreeTypographyTokens.secondary)
                            .foregroundStyle(MusicFreeColorTokens.warning)
                    }
                }
            }
        }
    }

    private var metadataAvailabilityText: String {
        switch viewModel.metadataEnrichmentSnapshot.authorization {
        case .notDetermined:
            return L("开启后需要 Apple Music catalog 权限；只补充元数据和封面。")
        case .authorized:
            return L("Apple Music catalog 可用；本地已有信息不会被覆盖。")
        case .denied:
            return L("Apple Music catalog 权限已拒绝，请在系统设置中允许。")
        case .restricted:
            return L("当前设备限制使用 Apple Music catalog。")
        case .unavailable:
            return L("当前系统不支持 MusicKit 元数据补充。")
        }
    }

    private func scanSummary(_ scan: MetadataEnrichmentScanSnapshot) -> String {
        L(
            "已处理 %d 首，匹配 %d 首，无匹配 %d 首，不确定 %d 首，失败 %d 首。",
            scan.processed,
            scan.matched,
            scan.noMatch,
            scan.ambiguous,
            scan.failed
        )
    }
}
