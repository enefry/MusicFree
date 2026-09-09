import DesignSystem
import SwiftUI

struct ImportSettingsView: View {
    let viewModel: SettingsViewModel
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool
    let onNavigate: ((SettingsDestination) -> Void)?

    init(
        viewModel: SettingsViewModel,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true,
        onNavigate: ((SettingsDestination) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
        self.onNavigate = onNavigate
    }

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

            NavigationLink {
                MetadataEnrichmentSettingsView(
                    viewModel: viewModel,
                    metadataServerEnabled: metadataServerEnabled,
                    lyricsEnabled: lyricsEnabled
                )
                .onAppear { onNavigate?(.importing) }
            } label: {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Label(L("元数据填充"), systemImage: "wand.and.stars")
                    Spacer(minLength: MusicFreeSpacingTokens.small)
                    Text(metadataEntryStatus)
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.import.metadataEnrichment.entry")
            }

            NavigationLink {
                OnlineSourceAvailabilitySettingsView(viewModel: viewModel)
                .onAppear { onNavigate?(.importing) }
            } label: {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Label(L("在线源可用性"), systemImage: "externaldrive.connected.to.line.below")
                    Spacer(minLength: MusicFreeSpacingTokens.small)
                    Text(onlineSourceAvailabilityEntryStatus)
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings.import.onlineSourceAvailability.entry")
            }
        }
    }

    private var metadataEntryStatus: String {
        let preferences = viewModel.settings.importPreferences.runtimeMetadataProviders
        let enabledProviders = preferences.filter {
            $0.isEnabled && (metadataServerEnabled || $0.provider != .metadataServer)
        }
        let enabledCount = enabledProviders.count
        guard enabledCount > 0 else { return L("未开启") }
        let enabledProviderIDs = enabledProviders.map(\.provider)

        let availableCount = viewModel.metadataEnrichmentSnapshot.providerStatuses.filter {
            enabledProviderIDs.contains($0.provider)
                && $0.isRegistered
                && $0.authorization == .authorized
        }.count
        guard availableCount > 0 else { return L("暂无可用来源") }
        return L("%d 个来源可用", availableCount)
    }

    private var onlineSourceAvailabilityEntryStatus: String {
        guard viewModel.isPrivacyPolicyAccepted else {
            return L("需要先同意隐私政策")
        }
        guard viewModel.isOnlineSourcesEnabled else { return L("未开启") }

        let availableCount = viewModel.onlineSourceConfigurations.filter {
            $0.isEnabled && isOnlineSourcePrivacyAccepted($0)
        }.count
        guard availableCount > 0 else { return L("暂无可用来源") }
        return L("%d 个来源可用", availableCount)
    }
}
