import Testing
import UIKit
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
@testable import BuiltinPluginSettings

@Suite(.serialized) @MainActor
struct StereoBalanceSettingsTests {
    private let id = PluginID(rawValue: "builtin.dsp.stereoBalance")
    private func descriptor() -> PluginDescriptor {
        .init(id: id, name: "声道均衡", kinds: [.dsp], configuration: .init(fields: [
            .init(id: "strengthPercent", title: "Strength", kind: .number, minimumNumber: 0, maximumNumber: 100),
            .init(id: "automatic", title: "Automatic", kind: .flag)
        ]))
    }
    @Test func defaultsSaveZeroAndRestoreOnlyParameters() async throws {
        var preference = PluginPreference(pluginID: id, isVisible: false, isEnabled: false, isLoadAllowed: false)
        let context = PluginSettingsContext(descriptor: descriptor(), readPreference: { preference },
            saveConfiguration: { values, _ in preference.configuration = values }, saveCredential: { _ in throw PluginError.unsupportedCapability },
            deleteCredential: { _ in Issue.record("Unexpected credential deletion") }, setConsent: { _ in Issue.record("Unexpected permission mutation") })
        let controller = StereoBalancePluginSettingsViewController(context: context)
        controller.loadViewIfNeeded()
        for _ in 0..<200 where !controller.canEdit { await Task.yield() }
        #expect(controller.canEdit)
        controller.render()
        let row = try #require(controller.rows["plugins.builtin.dsp.stereoBalance.strength"])
        guard case .slider(let value, let range, let step, _, let save) = row.control else { Issue.record("Missing slider"); return }
        #expect(value == 20 && range == 0...100 && step == 1)
        save(0)
        for _ in 0..<200 where controller.model.saving { await Task.yield() }
        #expect(preference.configuration["strengthPercent"] == .number(0))
        let reloaded = StereoBalanceSettingsModel(context: context)
        await reloaded.load()
        #expect(reloaded.strengthPercent == 0)
        controller.model.resetParameters()
        for _ in 0..<200 where controller.model.saving { await Task.yield() }
        #expect(preference.configuration == ["strengthPercent": .number(20), "automatic": .flag(true)])
        #expect(!preference.isVisible && !preference.isEnabled && !preference.isLoadAllowed)
    }

    @Test func rapidEditsAndFailedSaveKeepLatestDraft() async throws {
        var preference = PluginPreference(pluginID: id)
        var blocked: CheckedContinuation<Void, Never>?
        var attempts = 0
        var shouldFail = false
        let context = PluginSettingsContext(descriptor: descriptor(), readPreference: { preference },
            saveConfiguration: { values, _ in
                attempts += 1
                if attempts == 1 { await withCheckedContinuation { blocked = $0 } }
                if shouldFail { throw PluginError.unavailable }
                preference.configuration = values
            }, saveCredential: { _ in throw PluginError.unsupportedCapability }, deleteCredential: { _ in }, setConsent: { _ in })
        let model = StereoBalanceSettingsModel(context: context)
        await model.load()
        model.setStrength(30)
        for _ in 0..<200 where blocked == nil { await Task.yield() }
        let continuation = try #require(blocked)
        model.setStrength(50); model.setAutomatic(false)
        continuation.resume()
        for _ in 0..<400 where model.saving { await Task.yield() }
        #expect(preference.configuration == ["strengthPercent": .number(50), "automatic": .flag(false)])
        shouldFail = true
        model.setStrength(20)
        for _ in 0..<200 where model.saving { await Task.yield() }
        #expect(model.failure != nil && model.strengthPercent == 20 && model.canEdit)
        #expect(preference.configuration["strengthPercent"] == .number(50))
        shouldFail = false; model.retrySave()
        for _ in 0..<200 where model.saving { await Task.yield() }
        #expect(model.failure == nil && preference.configuration["strengthPercent"] == .number(20))
    }
}
