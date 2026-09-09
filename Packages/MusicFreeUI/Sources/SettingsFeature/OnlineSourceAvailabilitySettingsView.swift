import DesignSystem
import MediaSourceAPI
import SwiftUI

struct OnlineSourceAvailabilitySettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        List {
            Section {
                Toggle(
                    L("启用在线源服务"),
                    isOn: Binding(
                        get: {
                            viewModel.isPrivacyPolicyAccepted
                                && viewModel.isOnlineSourcesEnabled
                        },
                        set: { viewModel.setOnlineSourcesEnabled($0) }
                    )
                )
                .disabled(viewModel.isSaving || !viewModel.isPrivacyPolicyAccepted)
                .accessibilityValue(onlineSourcesAvailabilityStatus)
                .accessibilityIdentifier("settings.import.onlineSources.toggle")

                if !viewModel.isPrivacyPolicyAccepted {
                    Text(L("请先同意应用隐私政策，在线源服务会保持关闭。"))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                }

                if viewModel.onlineSourceConfigurations.isEmpty {
                    Text(L("还没有配置在线源。请从在线源 Tab 添加来源。"))
                        .font(MusicFreeTypographyTokens.secondary)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                } else {
                    ForEach(viewModel.onlineSourceConfigurations, id: \.sourceID) { configuration in
                        Toggle(
                            isOn: Binding(
                                get: {
                                    viewModel.onlineSourceConfigurations
                                        .first(where: { $0.sourceID == configuration.sourceID })?
                                        .isEnabled == true
                                },
                                set: {
                                    viewModel.setOnlineSourceEnabled(
                                        configuration.sourceID,
                                        $0
                                    )
                                }
                            )
                        ) {
                            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                                Text(configuration.displayName)
                                Text(onlineSourceProviderTitle(configuration.providerKind))
                                    .font(MusicFreeTypographyTokens.caption)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                                Text(sourceAvailabilityStatus(configuration))
                                    .font(MusicFreeTypographyTokens.caption)
                                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                            }
                        }
                        .disabled(
                            viewModel.isSaving
                                || !viewModel.isPrivacyPolicyAccepted
                                || !isOnlineSourcePrivacyAccepted(configuration)
                        )
                        .accessibilityIdentifier(
                            "settings.import.onlineSource.\(configuration.sourceID.rawValue).enabled"
                        )
                    }
                }
            } header: {
                Text(L("在线源服务"))
            } footer: {
                Text(L("总开关控制在线源服务；每个来源还可以独立启用或关闭。已经导入本地的媒体不受影响。"))
            }
        }
        .navigationTitle(L("在线源可用性"))
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .accessibilityIdentifier("settings.import.onlineSourceAvailability")
    }

    private var onlineSourcesAvailabilityStatus: String {
        guard viewModel.isPrivacyPolicyAccepted else {
            return L("需要先同意应用隐私政策")
        }
        return viewModel.isOnlineSourcesEnabled ? L("已开启") : L("已关闭")
    }

    private func sourceAvailabilityStatus(
        _ configuration: OnlineSourceConfiguration
    ) -> String {
        guard viewModel.isPrivacyPolicyAccepted else {
            return L("需要先同意应用隐私政策")
        }
        guard isOnlineSourcePrivacyAccepted(configuration) else {
            return L("需要先同意来源隐私协议")
        }
        if configuration.isEnabled {
            return viewModel.isOnlineSourcesEnabled ? L("已启用") : L("已启用，但总开关已关闭")
        }
        return L("已关闭")
    }
}
