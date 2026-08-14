import DesignSystem
import Foundation
import PlaybackAPI
import SettingsAPI
import SwiftUI

struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Section(L("播放偏好")) {
            rateControl
            equalizerLink

            capabilityNote(
                isSupported: viewModel.supportsEqualizer,
                message: L("当前播放引擎未启用均衡器，保存的均衡器设置会在支持后生效。")
            )
        }
    }

    private var rateControl: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            HStack {
                Text(L("默认播放速度"))
                Spacer(minLength: MusicFreeSpacingTokens.medium)
                Text(rateText)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .monospacedDigit()
            }

            Slider(
                value: rateBinding,
                in: PlaybackRate.minimumValue ... PlaybackRate.maximumValue,
                step: 0.25,
                onEditingChanged: handleRateEditingChanged
            )
            .disabled(viewModel.isSaving)
            .accessibilityLabel(Text(L("默认播放速度")))
            .accessibilityValue(Text(rateText))
            .accessibilityIdentifier("settings.playback.rate")

            capabilityNote(
                isSupported: viewModel.supportsVariableRate,
                message: L("当前播放引擎未启用变速播放，保存的速度会在支持后生效。")
            )
        }
    }

    private var equalizerLink: some View {
        NavigationLink {
            EqualizerSettingsView(viewModel: viewModel)
        } label: {
            HStack(spacing: MusicFreeSpacingTokens.small) {
                Label(L("均衡器"), systemImage: "slider.vertical.3")
                Spacer(minLength: MusicFreeSpacingTokens.small)
                Text(viewModel.settings.playbackPreferences.equalizer.isEnabled ? L("已开启") : L("已关闭"))
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            }
        }
        .accessibilityIdentifier("settings.playback.equalizer.entry")
    }

    private var rateBinding: Binding<Double> {
        Binding(
            get: { viewModel.displayedPlaybackRate },
            set: { viewModel.updatePlaybackRateDraft($0) }
        )
    }

    private var rateText: String {
        String(format: "%.2gx", viewModel.displayedPlaybackRate)
    }

    private func handleRateEditingChanged(_ isEditing: Bool) {
        if isEditing {
            viewModel.beginPlaybackRateEditing()
        } else {
            viewModel.endPlaybackRateEditing()
        }
    }

    @ViewBuilder
    private func capabilityNote(isSupported: Bool, message: String) -> some View {
        if !isSupported {
            Text(message)
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
    }


}
