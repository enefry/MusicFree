import DesignSystem
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

            NavigationLink {
                MetadataEnrichmentSettingsView(viewModel: viewModel)
            } label: {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Label(L("元数据填充"), systemImage: "wand.and.stars")
                    Spacer(minLength: MusicFreeSpacingTokens.small)
                    Text(metadataEntryStatus)
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityIdentifier("settings.import.metadataEnrichment.entry")
        }
    }

    private var metadataEntryStatus: String {
        let preferences = viewModel.settings.importPreferences.metadataProviders
        let enabledCount = preferences.filter(\.isEnabled).count
        guard enabledCount > 0 else { return L("未开启") }
        let enabledProviders = preferences.filter(\.isEnabled).map(\.provider)

        let availableCount = viewModel.metadataEnrichmentSnapshot.providerStatuses.filter {
            enabledProviders.contains($0.provider)
                && $0.isRegistered
                && $0.authorization == .authorized
        }.count
        guard availableCount > 0 else { return L("暂无可用来源") }
        return L("%d 个来源可用", availableCount)
    }
}
