import AppServices
import DesignSystem
import Foundation
import PlaybackAPI
import SettingsAPI
import SwiftUI

struct PlaybackSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let sleepTimerServing: (any SleepTimerServing)?
    let onNavigate: ((SettingsDestination) -> Void)?
    @State private var isRateSliderExpanded = false

    init(
        viewModel: SettingsViewModel,
        sleepTimerServing: (any SleepTimerServing)?,
        onNavigate: ((SettingsDestination) -> Void)? = nil
    ) {
        _viewModel = Bindable(viewModel)
        self.sleepTimerServing = sleepTimerServing
        self.onNavigate = onNavigate
    }

    var body: some View {
        Section(L("播放偏好")) {
            baseRateControl
            if isRateSliderExpanded {
                HStack {
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
                }.padding(.leading, MusicFreeSpacingTokens.xLarge)
            }
            sleepTimerLink
            equalizerLink

            capabilityNote(
                isSupported: viewModel.supportsEqualizer,
                message: L("当前播放引擎未启用均衡器，保存的均衡器设置会在支持后生效。")
            )
        }
    }

    private var sleepTimerLink: some View {
        NavigationLink {
            SleepTimerSettingsView(
                settingsViewModel: viewModel,
                serving: sleepTimerServing
            )
            .onAppear { onNavigate?(.playback) }
        } label: {
            Label(L("Sleep timer"), systemImage: "moon.zzz")
        }
        .accessibilityIdentifier("settings.playback.sleepTimer.entry")
    }

    private var baseRateControl: some View {
        HStack {
            Text(L("默认播放速度"))
            Spacer(minLength: MusicFreeSpacingTokens.medium)
            Text(rateText)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                .monospacedDigit()
            Button {
                withAnimation {
                    isRateSliderExpanded.toggle()
                }
            } label: {
                Image(systemName: isRateSliderExpanded ? "chevron.up.circle" : "chevron.down.circle")
                    .font(MusicFreeTypographyTokens.body)
            }
            .foregroundStyle(MusicFreeColorTokens.accent)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("settings.playback.rate.collapse")
        }
        .accessibilityLabel(Text(L("默认播放速度")))
        .accessibilityValue(Text(rateText))
        .accessibilityIdentifier("settings.playback.rate.entry")
        .transition(.opacity)
    }

    private var equalizerLink: some View {
        NavigationLink {
            EqualizerSettingsView(viewModel: viewModel)
                .onAppear { onNavigate?(.playback) }
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
