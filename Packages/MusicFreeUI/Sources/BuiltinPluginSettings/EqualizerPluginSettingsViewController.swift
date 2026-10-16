import DesignSystem
import PlaybackAPI
import SettingsAPI
import SettingsFeature
import UIKit

@MainActor
public final class EqualizerPluginSettingsViewController: PluginSettingsFormViewController {
    private let context: EqualizerSettingsContext
    private var loadTask: Task<Void, Never>?
    let equalizerBank = SettingsEqualizerBankView()
    let equalizerPresets = SettingsChoiceGridView()

    public init(context: EqualizerSettingsContext) {
        self.context = context
        super.init()
        title = L("均衡器")
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { loadTask?.cancel() }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "settings.playback.equalizer.form"
        loadTask = Task { [weak self] in await self?.context.load() }
    }
    public override var canEdit: Bool { context.canEditPlayback }
    public override func makeSections() -> [Section] {
        let enabled = context.isEnabled && context.canEditPlayback
        var result = [Section(id: "equalizer", title: "", rows: [
            toggle("settings.playback.equalizer", L("均衡器"), value: enabled) { [weak self] in self?.context.setEqualizerEnabled($0) }
        ])]
        let descriptor = context.equalizerDescriptor
        let minimum = max(Double(descriptor?.minimumPreampDecibels ?? Float(EqualizerGain.minimumDecibels)), EqualizerGain.minimumDecibels)
        let maximum = min(Double(descriptor?.maximumPreampDecibels ?? Float(EqualizerGain.maximumDecibels)), EqualizerGain.maximumDecibels)
        let gainText: (Double) -> String = { String(format: "%+.1f dB", $0) }
        if minimum <= maximum {
            result.append(.init(id: "equalizerPreamp", title: "", rows: [
                slider("settings.playback.equalizer.preamp", L("前级增益"), value: context.displayedEqualizerPreamp, range: minimum...maximum, step: 0.5,
                    valueText: gainText(context.displayedEqualizerPreamp), enabled: enabled, format: gainText) { [weak self] in self?.context.setEqualizerPreamp($0) }
            ]))
        }
        equalizerBank.configure(bands: context.equalizerBands, enabled: enabled,
            gain: { context.equalizerGain(for: $0) }, save: { [weak self] gain, band in self?.context.setEqualizerGain(gain, for: band) })
        result.append(.init(id: "equalizerBands", title: L("频段"), footer: L("上下拖动调节，松手保存。双击频段恢复为 0 dB。"), rows: [
            .init(id: "settings.playback.equalizer.bands", title: "", control: .custom(equalizerBank))
        ]))
        if !context.equalizerPresets.isEmpty {
            let presets = context.equalizerPresets
            let selectedID = context.selectedEqualizerPresetID
            let currentTitle = presets.first { $0.id == selectedID }.map { presetTitle($0.name) } ?? L("自定义")
            let options = presets.map { preset in
                UIAction(title: presetTitle(preset.name), state: preset.id == selectedID ? .on : .off) { [weak self] _ in
                    self?.context.applyEqualizerPreset(id: preset.id)
                }
            }
            var selection = menu("settings.playback.equalizer.preset", L("声音风格"), value: currentTitle, options: options)
            selection.enabled = enabled
            equalizerPresets.configure(choices: presets.map { preset in
                .init(id: "settings.playback.equalizer.preset.\(preset.id)", title: presetTitle(preset.name), selected: preset.id == context.selectedEqualizerPresetID,
                    action: { [weak self] in self?.context.applyEqualizerPreset(id: preset.id) })
            }, enabled: enabled)
            result.append(.init(id: "equalizerPresets", title: L("预设"), rows: [
                selection,
                .init(id: "settings.playback.equalizer.quickPresets", title: "", control: .custom(equalizerPresets))
            ]))
        }
        var reset = action("settings.playback.equalizer.reset", L("恢复平直"), symbol: "arrow.counterclockwise") { [weak self] in self?.context.resetEqualizer() }
        reset.enabled = enabled
        result.append(.init(id: "equalizerReset", title: "", rows: [reset]))
        if !context.supportsEqualizer { result.append(.init(id: "equalizerUnavailable", title: "", rows: [text("equalizerNote", L("当前播放引擎未启用均衡器，保存的均衡器设置会在支持后生效。"))])) }
        if let failure = context.failure {
            var recovery = [text("settings.equalizer.failure", failure)]
            if context.loadFailed {
                recovery.append(action("settings.equalizer.retryLoad", L("重试")) { [weak self] in
                    self?.loadTask = Task { [weak self] in await self?.context.retryLoad() }
                })
            } else if context.canRetryFailedSave {
                recovery.append(action("settings.equalizer.retrySave", L("重试保存")) { [weak self] in self?.context.retryFailedSave() })
            }
            result.append(.init(id: "failure", title: "", rows: recovery))
        }
        return result
    }

    func presetTitle(_ name: String) -> String {
        let names = ["flat": "平直", "bass boost": "低音增强", "treble boost": "高音增强", "vocal": "人声", "classical": "古典", "club": "俱乐部", "dance": "舞曲", "full bass": "重低音", "full bass and treble": "重低音与高音", "full treble": "高音", "headphones": "耳机", "large hall": "大型厅堂", "live": "现场", "party": "派对", "pop": "流行", "reggae": "雷鬼", "rock": "摇滚", "ska": "斯卡", "soft": "柔和", "soft rock": "柔和摇滚", "techno": "电子"]
        return names[name.lowercased()].map { L($0) } ?? name
    }

}
