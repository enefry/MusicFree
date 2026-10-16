import DesignSystem
import SettingsAPI
import UIKit

@MainActor
extension SettingsViewController {
    static let accentPresets: [(String, String)] = [
        ("默认", MusicFreeAccentColorStore.defaultHex), ("蓝色", "007AFF"),
        ("绿色", "34C759"), ("紫色", "AF52DE"), ("黄色", "FF9500")
    ]

    var accentColorTitle: String {
        Self.accentPresets.first { $0.1 == MusicFreeAccentColorStore.hexValue }.map { L($0.0) } ?? L("自定义")
    }

    func accentColorSections() -> [Section] {
        let selected = MusicFreeAccentColorStore.hexValue
        let options = Self.accentPresets.enumerated().map { index, preset in
            var row = action("settings.accentColor.preset.\(index)", L(preset.0)) { [weak self] in
                self?.setAccentColor(MusicFreeAccentColorStore.uiColor(forHex: preset.1))
                self?.reloadLocalizedContent()
            }
            row.image = colorImage(MusicFreeAccentColorStore.uiColor(forHex: preset.1))
            row.isSelected = preset.1 == selected
            return row
        }
        var custom = action("settings.accentColor.custom", L("选择颜色"), disclosure: true) { [weak self] in
            guard let self else { return }
            let picker = UIColorPickerViewController()
            picker.selectedColor = MusicFreeAccentColorStore.uiColor(forHex:
                UserDefaults.standard.string(forKey: "musicfree.customAccentColor") ?? selected)
            picker.supportsAlpha = false
            picker.delegate = self
            self.pendingAccentColor = nil
            self.present(picker, animated: true)
        }
        custom.swatchColor = MusicFreeAccentColorStore.uiColor(forHex: selected)
        custom.isSelected = !Self.accentPresets.contains { $0.1 == selected }
        custom.trailingValue = custom.isSelected ? "#\(selected)" : ""
        return [.init(id: "accentDefault", title: L("默认"), rows: [options[0]]),
                .init(id: "accentPresets", title: L("预设"), rows: Array(options.dropFirst())),
                .init(id: "accentCustom", title: L("自定义"), rows: [custom])]
    }

    private func colorImage(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 28, height: 28)).image { context in
            color.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: 26, height: 26))
        }.withRenderingMode(.alwaysOriginal)
    }

    var transitionSummary: String {
        let transition = viewModel.settings.playbackPreferences.transition
        var parts: [String] = []
        if transition.fadeInDuration > .zero || transition.fadeOutDuration > .zero { parts.append(L("淡入淡出")) }
        if transition.isCrossfadeEnabled { parts.append(L(transition.smartCrossfadeEnabled ? "智能交叉渐变" : "交叉淡化")) }
        else if transition.gaplessPlaybackEnabled { parts.append(L("无缝播放")) }
        if transition.skipBoundarySilence { parts.append(L("跳过首尾静音")) }
        return parts.isEmpty ? L("已关闭") : parts.joined(separator: " · ")
    }

    func transitionSections() -> [Section] {
        let transition = viewModel.settings.playbackPreferences.transition
        var result: [Section] = []
        if viewModel.supportsFade {
            result.append(.init(id: "transitionFades", title: L("淡入淡出"), footer: L("0 秒为关闭，最长 3 秒。"), rows: [
                menu("settings.playback.fade.preset", L("同时设置淡入和淡出"), value: L("快速设置"), options: [0.0, 0.5, 1, 2, 3].map { seconds in
                    UIAction(title: seconds == 0 ? L("已关闭") : String(format: "%g s", seconds)) { [weak self] _ in
                        guard let self else { return }
                        let old = self.viewModel.settings.playbackPreferences.transition
                        self.viewModel.setSongTransition(gaplessEnabled: old.gaplessPlaybackEnabled, crossfadeDuration: old.crossfadeDuration,
                            fadeIn: .seconds(seconds), fadeOut: .seconds(seconds))
                    }
                }),
                durationRow("fadeIn", L("淡入"), transition.fadeInDuration) { [weak self] in self?.viewModel.setFadeDuration($0, isFadeIn: true) },
                durationRow("fadeOut", L("淡出"), transition.fadeOutDuration) { [weak self] in self?.viewModel.setFadeDuration($0, isFadeIn: false) }
            ]))
        }
        if viewModel.supportsBoundarySilenceSkipping {
            let automaticallySkips = transition.isCrossfadeEnabled && transition.smartCrossfadeEnabled
            var silence = toggle("settings.playback.skipBoundarySilence", L("跳过首尾静音"), value: transition.skipBoundarySilence || automaticallySkips) { [weak self] value in
                guard let self else { return }
                let old = self.viewModel.settings.playbackPreferences.transition
                self.viewModel.setSongTransition(gaplessEnabled: old.gaplessPlaybackEnabled,
                    crossfadeDuration: old.crossfadeDuration, skipBoundarySilence: value)
            }
            silence.enabled = !automaticallySkips && viewModel.canEditPlayback
            result.append(.init(id: "boundarySilence", title: L("静音跳过"),
                footer: L(automaticallySkips ? "智能模式会自动跳过首尾静音。" : "跳过本地歌曲首尾的连续静音，保留曲中的停顿。"), rows: [silence]))
        }
        guard viewModel.supportsGapless || viewModel.supportsCrossfade else { return result }
        let enabled = transition.gaplessPlaybackEnabled || transition.isCrossfadeEnabled
        if transition.isCrossfadeEnabled { rememberedCrossfadeDuration = transition.crossfadeDuration; preferredCrossfade = true }
        else if transition.gaplessPlaybackEnabled { preferredCrossfade = false }
        result.append(.init(id: "transitionEnabled", title: L("自动切歌"), rows: [
            toggle("settings.playback.transitions.enabled", L("歌曲过渡"), value: enabled) { [weak self] value in
                guard let self else { return }
                let crossfade = value && (self.preferredCrossfade || !self.viewModel.supportsGapless)
                self.viewModel.setSongTransition(gaplessEnabled: value && !crossfade,
                    crossfadeDuration: crossfade ? self.rememberedCrossfadeDuration : .zero)
            }
        ]))
        var styles: [SettingsNativeRow] = []
        if viewModel.supportsGapless {
            var gapless = action("settings.playback.gapless", L("无缝播放"), detail: L("直接衔接上一首的结尾与下一首的开头。"), symbol: "link") { [weak self] in
                self?.preferredCrossfade = false
                self?.viewModel.setSongTransition(gaplessEnabled: true, crossfadeDuration: .zero)
            }
            gapless.isSelected = !preferredCrossfade
            gapless.enabled = enabled
            styles.append(gapless)
        }
        if viewModel.supportsCrossfade {
            var crossfade = action("settings.playback.crossfade", L("交叉淡化"), detail: L("将上一首的结尾与下一首的开头混合过渡。"), symbol: "shuffle") { [weak self] in
                guard let self else { return }; self.preferredCrossfade = true
                self.viewModel.setSongTransition(gaplessEnabled: false, crossfadeDuration: self.rememberedCrossfadeDuration)
            }
            crossfade.isSelected = preferredCrossfade
            crossfade.enabled = enabled
            let duration = transition.crossfadeDuration.components
            crossfade.trailingValue = transition.isCrossfadeEnabled
                ? String(format: L(transition.smartCrossfadeEnabled ? "自动 · 最长 %.1f s" : "%.1f s"), Double(duration.seconds) + Double(duration.attoseconds) / 1e18) : L("已关闭")
            styles.append(crossfade)
        }
        result.append(.init(id: "transitionStyle", title: L("过渡风格"), rows: styles))
        if viewModel.supportsSmartCrossfade {
            var smart = toggle("settings.playback.smartCrossfade", L("智能交叉渐变"), value: transition.smartCrossfadeEnabled) { [weak self] value in
                guard let self else { return }
                self.viewModel.setSongTransition(gaplessEnabled: false,
                    crossfadeDuration: self.rememberedCrossfadeDuration, smartCrossfadeEnabled: value)
            }
            smart.enabled = enabled && preferredCrossfade && viewModel.canEditPlayback
            result.append(.init(id: "smartTransition", title: L("智能交叉渐变"),
                footer: L("分析首尾静音、响度和节拍；拍速接近时自动对拍，过渡后平滑恢复原速。"), rows: [smart]))
        }
        if viewModel.supportsCrossfade {
            let seconds = Double(rememberedCrossfadeDuration.components.seconds) + Double(rememberedCrossfadeDuration.components.attoseconds) / 1e18
            let format: (Double) -> String = { String(format: "%.1f s", $0) }
            result.append(.init(id: "transitionDuration", title: L(transition.smartCrossfadeEnabled ? "最长过渡时长" : "交叉淡化时长"),
                footer: L(transition.smartCrossfadeEnabled ? "自动过渡不超过此时长；节拍不可靠时按响度选择，分析失败时使用固定渐变。" : "两首歌曲重叠播放的时间，最长 12 秒；选择交叉淡化后可调整。"), rows: [
                slider("settings.playback.crossfadeDuration", L(transition.smartCrossfadeEnabled ? "最长过渡时长" : "交叉淡化时长"), value: seconds, range: 0.1...12, step: 0.1,
                    valueText: format(seconds), enabled: enabled && preferredCrossfade, format: format) { [weak self] value in
                    self?.rememberedCrossfadeDuration = .seconds(value)
                    self?.viewModel.setSongTransition(gaplessEnabled: false, crossfadeDuration: .seconds(value))
                }
            ]))
        }
        result.append(.init(id: "transitionNote", title: "", rows: [text("settings.playback.transitions.note", L("本地单声道和双声道曲目在 1 倍速下支持歌曲过渡和首尾静音跳过；网络播放、CUE 分段等不支持的组合使用普通切歌。"))]))
        return result
    }
}
