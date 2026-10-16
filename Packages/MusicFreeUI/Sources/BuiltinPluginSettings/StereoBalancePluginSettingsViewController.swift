import DesignSystem
import MusicFreePluginSettingsUIKitAPI
import SettingsFeature
import UIKit

@MainActor
public final class StereoBalancePluginSettingsViewController: PluginSettingsFormViewController {
    let model: StereoBalanceSettingsModel
    private var loadTask: Task<Void, Never>?
    private let prefix = "plugins.builtin.dsp.stereoBalance"

    public init(context: PluginSettingsContext) {
        model = StereoBalanceSettingsModel(context: context)
        super.init()
        title = L("声道均衡")
    }
    @available(*, unavailable) required public init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { loadTask?.cancel() }
    public override var canEdit: Bool { model.canEdit }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = prefix + ".form"
        loadTask = Task { [weak self] in await self?.model.load() }
    }
    public override func makeSections() -> [Section] {
        let format: (Double) -> String = { String(format: "%.0f%%", $0) }
        var result = [Section(id: "mode", title: "", footer: model.automatic
            ? L("仅在左右声道差异明显时调整，强度不会超过设置值。")
            : L("持续混合左右声道，数值越大，声场越集中。100% 为单声道。"), rows: [
                toggle(prefix + ".automatic", L("自动调整"), value: model.automatic) { [weak self] in self?.model.setAutomatic($0) }
            ])]
        let options = [20.0, 30, 50].map { strength in
            UIAction(title: format(strength), state: model.strengthPercent == strength ? .on : .off) { [weak self] _ in
                self?.model.setStrength(strength)
            }
        }
        result.append(.init(id: "strength", title: "", footer: model.automatic
            ? L("0% 保留原声；100% 允许最大调整到单声道，并非始终输出单声道。")
            : L("0% 保留原声，100% 为单声道。"), rows: [
                slider(prefix + ".strength", model.automatic ? L("最大均衡强度") : L("均衡强度"),
                       value: model.strengthPercent, range: 0...100, step: 1, valueText: format(model.strengthPercent), format: format) { [weak self] in
                    self?.model.setStrength($0)
                },
                menu(prefix + ".presets", L("快捷强度"), value: format(model.strengthPercent), options: options)
            ]))
        var reset = action(prefix + ".reset", L("恢复默认参数"), symbol: "arrow.counterclockwise") { [weak self] in self?.model.resetParameters() }
        reset.enabled = canEdit
        result.append(.init(id: "apply", title: "", footer: L("播放中修改后，请暂停再继续播放，使新设置生效。"), rows: [reset]))
        if model.loading || model.saving {
            result.append(.init(id: "status", title: "", rows: [text(prefix + ".status", model.loading ? L("加载中") : L("保存中"))]))
        }
        if let failure = model.failure {
            result.append(.init(id: "failure", title: "", rows: [
                text(prefix + ".failure", failure),
                action(prefix + ".retry", L("重试")) { [weak self] in
                    guard let self else { return }
                    if model.loadFailed { loadTask = Task { [weak self] in await self?.model.load() } }
                    else { model.retrySave() }
                }
            ]))
        }
        return result
    }
}
