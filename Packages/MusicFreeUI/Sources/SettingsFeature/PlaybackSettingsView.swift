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
            transitionControls

            capabilityNote(
                isSupported: viewModel.supportsEqualizer,
                message: L("当前播放引擎未启用均衡器，保存的均衡器设置会在支持后生效。")
            )
        }
    }

    private var transitionControls: some View {
        Group {
            if viewModel.supportsFade {
            durationControl(L("淡入"), value: viewModel.settings.playbackPreferences.transition.fadeInDuration) {
                viewModel.setFadeDuration($0, isFadeIn: true)
            }
            durationControl(L("淡出"), value: viewModel.settings.playbackPreferences.transition.fadeOutDuration) {
                viewModel.setFadeDuration($0, isFadeIn: false)
            }
            }
            if viewModel.supportsGapless {
            Toggle(L("无缝播放"), isOn: Binding(
                get: { viewModel.settings.playbackPreferences.transition.gaplessPlaybackEnabled },
                set: { viewModel.setGaplessPlaybackEnabled($0) }
            ))
            }
            if viewModel.supportsCrossfade {
            Toggle(L("交叉淡化"), isOn: Binding(
                get: { viewModel.settings.playbackPreferences.transition.isCrossfadeEnabled },
                set: { viewModel.setCrossfadeDuration($0 ? .seconds(1) : .zero) }
            ))
            durationControl(L("交叉淡化时长"), value: viewModel.settings.playbackPreferences.transition.crossfadeDuration) {
                viewModel.setCrossfadeDuration($0)
            }
            }
            Text(L("0 秒为关闭，最长 3 秒。本地单声道和双声道曲目在 1 倍速下支持无缝播放与交叉淡化，可衔接不同采样率和编码格式。文件自带静音会保留；网络播放、CUE 分段等不支持的组合使用普通切歌。"))
                .font(MusicFreeTypographyTokens.caption)
                .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
        }
        .disabled(viewModel.isSaving)
    }

    private func durationControl(_ title: String, value: Duration, set: @escaping (Duration) -> Void) -> some View {
        PlaybackTransitionDurationControl(title: title, duration: value, isSaving: viewModel.isSaving, save: set)
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

/// Keep dragging local; saving every sample disables the form mid-gesture.
private struct PlaybackTransitionDurationControl: View {
    let title: String
    let duration: Duration
    let isSaving: Bool
    let save: (Duration) -> Void
    @State private var seconds: Double = 0
    @State private var isEditing = false

    private var savedSeconds: Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f s", seconds)).monospacedDigit() }
            Slider(value: $seconds, in: 0...3, step: 0.01) { editing in
                isEditing = editing
                if !editing { save(.seconds(seconds)) }
            }
            .accessibilityLabel(Text(title))
        }
        .onAppear { seconds = savedSeconds }
        .onChange(of: duration) { _, _ in if !isEditing { seconds = savedSeconds } }
        .onChange(of: isSaving) { _, saving in if !saving, !isEditing { seconds = savedSeconds } }
    }
}
