import AppServices
import DesignSystem
import MediaSourceAPI
import SwiftUI

struct ImportSettingsView: View {
    let viewModel: SettingsViewModel
    let metadataServerEnabled: Bool
    let lyricsEnabled: Bool
    let libraryConversion: (any LibraryConversionServing)?
    let onNavigate: ((SettingsDestination) -> Void)?

    init(
        viewModel: SettingsViewModel,
        metadataServerEnabled: Bool = true,
        lyricsEnabled: Bool = true,
        libraryConversion: (any LibraryConversionServing)? = nil,
        onNavigate: ((SettingsDestination) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.metadataServerEnabled = metadataServerEnabled
        self.lyricsEnabled = lyricsEnabled
        self.libraryConversion = libraryConversion
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
                AudioConversionSettingsView(
                    viewModel: viewModel,
                    libraryConversion: libraryConversion,
                    onNavigate: onNavigate
                )
                .onAppear { onNavigate?(.importing) }
            } label: {
                HStack(spacing: MusicFreeSpacingTokens.small) {
                    Label(L("音频转换"), systemImage: "waveform.badge.plus")
                    Spacer(minLength: MusicFreeSpacingTokens.small)
                    Text(audioConversionEntryStatus)
                        .font(MusicFreeTypographyTokens.caption)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .contain)
            }
            .accessibilityIdentifier("settings.import.audioConversion.entry")

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

    private var audioConversionEntryStatus: String {
        let preferences = viewModel.settings.importPreferences.audioConversion
        guard preferences.automaticallyConvertLosslessImports else { return L("未开启") }
        return preferences.target.displayName
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

private struct AudioConversionSettingsView: View {
    let viewModel: SettingsViewModel
    let libraryConversion: (any LibraryConversionServing)?
    let onNavigate: ((SettingsDestination) -> Void)?

    var body: some View {
        Form {
            Section {
                Toggle(L("启用导入转换"), isOn: automaticConversionBinding)
                    .accessibilityIdentifier("settings.import.audioConversion.enabled")

                Picker(L("转换格式"), selection: conversionTargetBinding) {
                    Text(L("ALAC（无损）"))
                        .tag(AudioConversionTarget.alac)
                    ForEach(AACLCBitRate.allCases, id: \.self) { bitRate in
                        Text("AAC-LC \(bitRate.kilobitsPerSecond) kbps")
                            .tag(AudioConversionTarget.aacLC(bitRate))
                    }
                }
                .accessibilityIdentifier("settings.import.audioConversion.target")

                Picker(L("同时转换"), selection: conversionConcurrencyBinding) {
                    ForEach(MediaConversionConcurrency.allCases, id: \.self) { concurrency in
                        Text("\(concurrency.rawValue)").tag(concurrency)
                    }
                }
                .accessibilityIdentifier("settings.import.audioConversion.concurrency")
            } header: {
                Text(L("导入转换"))
            } footer: {
                Text(L("仅在音乐播放中转码；暂停、停止或缓冲时，转码也会暂停并保留进度，继续播放后自动恢复。播放中，前台按设置并发转码，后台仅运行一个转码任务。"))
                    .accessibilityIdentifier("settings.import.audioConversion.backgroundTip")
            }

            if let libraryConversion {
                Section(L("现有资料库")) {
                    NavigationLink {
                        LibraryAudioConversionView(
                            service: libraryConversion,
                            scope: .allLocalMedia,
                            initialTarget: viewModel.settings.importPreferences
                                .audioConversion.target
                        )
                        .onAppear { onNavigate?(.importing) }
                    } label: {
                        Label(
                            L("转换已有资料库"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .accessibilityIdentifier("settings.import.audioConversion.library")
                }
            }
        }
        .navigationTitle(L("音频转换"))
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
        .accessibilityIdentifier("settings.import.audioConversion.form")
    }

    private var automaticConversionBinding: Binding<Bool> {
        Binding(
            get: {
                viewModel.settings.importPreferences.audioConversion
                    .automaticallyConvertLosslessImports
            },
            set: { viewModel.setAutomaticAudioConversionEnabled($0) }
        )
    }

    private var conversionTargetBinding: Binding<AudioConversionTarget> {
        Binding(
            get: { viewModel.settings.importPreferences.audioConversion.target },
            set: { viewModel.setAudioConversionTarget($0) }
        )
    }

    private var conversionConcurrencyBinding: Binding<MediaConversionConcurrency> {
        Binding(
            get: { viewModel.settings.importPreferences.audioConversion.maximumConcurrency },
            set: { viewModel.setAudioConversionConcurrency($0) }
        )
    }
}

private extension AudioConversionTarget {
    var displayName: String {
        switch self {
        case .alac:
            return L("ALAC（无损）")
        case .aacLC(let bitRate):
            return "AAC-LC \(bitRate.kilobitsPerSecond) kbps"
        }
    }
}
