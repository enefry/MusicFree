import DesignSystem
import Foundation
import PlaybackAPI
import SettingsAPI
import SwiftUI

struct EqualizerSettingsView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(L("均衡器"), isOn: equalizerEnabledBinding)
                    .toggleStyle(MusicFreeSwitchToggleStyle())
                    .disabled(viewModel.isSaving)
                    .accessibilityIdentifier("settings.playback.equalizer")
            }

            if viewModel.settings.playbackPreferences.equalizer.isEnabled {
                presetSection
                adjustmentSection
            }
        }
        .navigationTitle(L("均衡器"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(MusicFreeColorTokens.backgroundGrouped)
    }

    @ViewBuilder
    private var presetSection: some View {
        if !viewModel.equalizerPresets.isEmpty {
            Section(L("预设")) {
                Picker(L("声音风格"), selection: presetBinding) {
                    if viewModel.selectedEqualizerPresetID == nil {
                        Text(L("自定义")).tag(nil as UInt32?)
                    }
                    ForEach(viewModel.equalizerPresets) { preset in
                        Text(presetTitle(preset.name)).tag(Optional(preset.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier("settings.playback.equalizer.preset")
            }
        }
    }

    @ViewBuilder
    private var adjustmentSection: some View {
        Section(L("调节")) {
            equalizerPreampControl

            if viewModel.equalizerBands.isEmpty {
                Text(L("当前播放引擎没有提供可调频段。"))
                    .font(MusicFreeTypographyTokens.caption)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
            } else {
                ForEach(viewModel.equalizerBands, id: \.centerFrequencyHz) { band in
                    equalizerBandControl(band)
                }
            }
        }
    }

    private var equalizerPreampControl: some View {
        VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.small) {
            HStack {
                Text(L("前级增益"))
                Spacer(minLength: MusicFreeSpacingTokens.medium)
                Text(equalizerPreampText)
                    .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                    .monospacedDigit()
            }

            Slider(
                value: equalizerPreampBinding,
                in: preampRange,
                step: 0.5,
                onEditingChanged: handlePreampEditingChanged
            )
            .disabled(viewModel.isSaving)
            .accessibilityLabel(Text(L("均衡器前级增益")))
            .accessibilityValue(Text(equalizerPreampText))
        }
    }

    private var equalizerEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.settings.playbackPreferences.equalizer.isEnabled },
            set: { viewModel.setEqualizerEnabled($0) }
        )
    }

    private var presetBinding: Binding<UInt32?> {
        Binding(
            get: { viewModel.selectedEqualizerPresetID },
            set: { id in
                guard let id else { return }
                viewModel.applyEqualizerPreset(id: id)
            }
        )
    }

    private var equalizerPreampBinding: Binding<Double> {
        Binding(
            get: { viewModel.displayedEqualizerPreamp },
            set: { viewModel.updateEqualizerPreampDraft($0) }
        )
    }

    private var equalizerPreampText: String {
        String(format: "%+.1f dB", viewModel.displayedEqualizerPreamp)
    }

    private func handlePreampEditingChanged(_ isEditing: Bool) {
        if isEditing {
            viewModel.beginEqualizerPreampEditing()
        } else {
            viewModel.endEqualizerPreampEditing()
        }
    }

    private var preampRange: ClosedRange<Double> {
        guard let descriptor = viewModel.equalizerDescriptor else {
            return EqualizerGain.minimumDecibels...EqualizerGain.maximumDecibels
        }
        return max(Double(descriptor.minimumPreampDecibels), EqualizerGain.minimumDecibels) ... min(Double(descriptor.maximumPreampDecibels), EqualizerGain.maximumDecibels)
    }

    @ViewBuilder
    private func equalizerBandControl(_ band: EqualizerBandDescriptor) -> some View {
        let gainText = String(format: "%+.1f dB", viewModel.equalizerGain(for: band))
        let minimumGain = max(Double(band.minimumGainDecibels), EqualizerGain.minimumDecibels)
        let maximumGain = min(Double(band.maximumGainDecibels), EqualizerGain.maximumDecibels)
        if minimumGain <= maximumGain {
            VStack(alignment: .leading, spacing: MusicFreeSpacingTokens.xSmall) {
                HStack {
                    Text(frequencyText(band.centerFrequencyHz))
                    Spacer(minLength: MusicFreeSpacingTokens.medium)
                    Text(gainText)
                        .foregroundStyle(MusicFreeColorTokens.foregroundSecondary)
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { viewModel.equalizerGain(for: band) },
                        set: { viewModel.updateEqualizerGainDraft($0, for: band) }
                    ),
                    in: minimumGain...maximumGain,
                    step: 0.5,
                    onEditingChanged: { isEditing in
                        handleBandEditingChanged(isEditing, band: band)
                    }
                )
                .disabled(viewModel.isSaving)
                .accessibilityLabel(Text(L("%@ band gain", frequencyText(band.centerFrequencyHz))))
                .accessibilityValue(Text(gainText))
                .accessibilityIdentifier("settings.playback.equalizer.band.\(Int(band.centerFrequencyHz.rounded()))")
            }
        }
    }

    private func handleBandEditingChanged(
        _ isEditing: Bool,
        band: EqualizerBandDescriptor
    ) {
        if isEditing {
            viewModel.beginEqualizerGainEditing(for: band)
        } else {
            viewModel.endEqualizerGainEditing(for: band)
        }
    }

    private func frequencyText(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return String(format: "%.1f kHz", frequency / 1_000)
        }
        return String(format: "%.0f Hz", frequency)
    }

    private func presetTitle(_ name: String) -> String {
        switch name.lowercased() {
        case "flat": return L("平直")
        case "classical": return L("古典")
        case "club": return L("俱乐部")
        case "dance": return L("舞曲")
        case "full bass": return L("重低音")
        case "full bass and treble": return L("重低音与高音")
        case "full treble": return L("高音")
        case "headphones": return L("耳机")
        case "large hall": return L("大型厅堂")
        case "live": return L("现场")
        case "party": return L("派对")
        case "pop": return L("流行")
        case "reggae": return L("雷鬼")
        case "rock": return L("摇滚")
        case "ska": return L("斯卡")
        case "soft": return L("柔和")
        case "soft rock": return L("柔和摇滚")
        case "techno": return L("电子")
        default: return name
        }
    }
}
