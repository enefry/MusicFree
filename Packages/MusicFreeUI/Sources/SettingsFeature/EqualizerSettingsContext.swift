import PlaybackAPI
import SettingsAPI

/// Compatibility adapter for the built-in DSP's playback preferences. Only EQ
/// operations are exposed; the companion cannot edit other playback settings.
@MainActor
public struct EqualizerSettingsContext {
    private let model: SettingsSceneModel
    public init(model: SettingsSceneModel) { self.model = model }
    public func load() async { await model.loadIfNeeded() }
    public var canEditPlayback: Bool { model.viewModel.canEditPlayback }
    public var isEnabled: Bool { model.viewModel.settings.playbackPreferences.equalizer.isEnabled }
    public var equalizerDescriptor: EqualizerDescriptor? { model.viewModel.equalizerDescriptor }
    public var equalizerBands: [EqualizerBandDescriptor] { model.viewModel.equalizerBands }
    public var equalizerPresets: [EqualizerPresetDescriptor] { model.viewModel.equalizerPresets }
    public var selectedEqualizerPresetID: UInt32? { model.viewModel.selectedEqualizerPresetID }
    public var displayedEqualizerPreamp: Double { model.viewModel.displayedEqualizerPreamp }
    public var supportsEqualizer: Bool { model.viewModel.supportsEqualizer }
    public var failure: String? { model.viewModel.lastFailure?.message ?? model.viewModel.loadState.failure?.message }
    public var loadFailed: Bool { model.viewModel.loadState.failure != nil }
    public var canRetryFailedSave: Bool { model.viewModel.canRetryFailedSave }
    public func retryLoad() async { await model.viewModel.retry() }
    public func retryFailedSave() { model.viewModel.retryFailedSave() }
    public func setEqualizerEnabled(_ value: Bool) { model.viewModel.setEqualizerEnabled(value) }
    public func setEqualizerPreamp(_ value: Double) { model.viewModel.setEqualizerPreamp(value) }
    public func equalizerGain(for band: EqualizerBandDescriptor) -> Double { model.viewModel.equalizerGain(for: band) }
    public func setEqualizerGain(_ value: Double, for band: EqualizerBandDescriptor) { model.viewModel.setEqualizerGain(value, for: band) }
    public func applyEqualizerPreset(id: UInt32) { model.viewModel.applyEqualizerPreset(id: id) }
    public func resetEqualizer() { model.viewModel.resetEqualizer() }
}
