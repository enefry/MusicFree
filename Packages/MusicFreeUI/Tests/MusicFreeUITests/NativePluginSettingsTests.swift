@testable import SettingsFeature
import Foundation
import MusicFreePluginAPI
import MusicFreePluginSettingsUIKitAPI
import Testing
import UIKit
import AppServices
import PlaybackAPI
import MediaSourceAPI
import MusicDomain
import SettingsAPI

@Suite(.serialized)
@MainActor
struct NativePluginConfigurationTests {
    @Test("DSP priority edits persist, survive refresh, reset to default, and expose an advanced row")
    func dspPrioritySettingsPersistence() async throws {
        let service = PluginPresentationTestService()
        let host = PluginSettingsPageHost(registry: .init(), plugins: service, settings: service)
        host.start(); await host.model.waitForPendingWork()
        let id = await service.descriptor.id
        #expect(host.model.snapshots.first?.effectiveDSPPriority == 500)
        host.model.mutate(id) { $0.dspPriority = 75 }
        await host.model.waitForPendingWork()
        #expect(try await service.load().pluginPreferences.first?.dspPriority == 75)
        host.model.refresh(); await host.model.waitForPendingWork()
        #expect(host.model.snapshots.first?.effectiveDSPPriority == 75)
        let root = PluginSettingsViewController(plugins: service, settings: service, pageHost: host)
        let navigation = UINavigationController(rootViewController: root)
        root.loadViewIfNeeded()
        root.tableView(root.tableView, didSelectRowAt: .init(row: 0, section: 1))
        let detail = try #require(navigation.topViewController as? PluginSettingsViewController)
        detail.loadViewIfNeeded()
        let datasource = try #require(detail.tableView.dataSource as? UITableViewDiffableDataSource<String, String>)
        #expect(datasource.snapshot().itemIdentifiers.contains("plugins.test.dsp.priority"))
        await service.failNextSave()
        host.model.mutate(id) { $0.dspPriority = 10 }
        await host.model.waitForPendingWork()
        #expect(host.model.failure != nil)
        #expect(host.model.snapshots.first?.effectiveDSPPriority == 75)
        host.model.mutate(id) { $0.dspPriority = nil }
        await host.model.waitForPendingWork()
        #expect(try await service.load().pluginPreferences.first?.dspPriority == nil)
        #expect(host.model.snapshots.first?.effectiveDSPPriority == 500)
        #expect(try await service.load().pluginPreferences.first?.isEnabled == true)
    }

    @Test("Plugin overview is compact and detail saves preserve controls, scroll and rapid edits")
    func groupedPluginNavigationAndStableSave() async throws {
        let service = PluginPresentationTestService()
        let controller = PluginSettingsViewController(plugins: service, settings: service)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let navigation = UINavigationController(rootViewController: controller)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<200 where (controller.tableView.dataSource as? UITableViewDiffableDataSource<String, String>)?.snapshot().itemIdentifiers.contains("plugins.test.dsp.entry") != true { await Task.yield() }
        let table = controller.tableView!
        #expect(table.numberOfSections == 3) // Management, one DSP summary, explanation.
        #expect(table.numberOfRows(inSection: 1) == 1)
        #expect(await service.analysisSubscriptions == 0)
        controller.tableView(table, didSelectRowAt: .init(row: 0, section: 1))
        let detail = try #require(navigation.topViewController as? PluginSettingsViewController)
        #expect(detail !== controller)
        guard detail !== controller else { return }
        navigation.setViewControllers([controller, detail], animated: false)
        detail.loadViewIfNeeded()
        detail.viewWillAppear(false)
        navigation.view.layoutIfNeeded()
        detail.view.frame = navigation.view.bounds
        detail.view.layoutIfNeeded()
        let detailTable = detail.tableView!
        detailTable.layoutIfNeeded()
        let path = IndexPath(row: 2, section: 0)
        let cell = try #require(detailTable.cellForRow(at: path))
        let toggle = try #require(cell.accessoryView as? UISwitch)
        let offset = detailTable.contentOffset
        await service.suspendNextSave()
        toggle.isOn = false
        performActions(toggle)
        for _ in 0..<100 where await !service.isSaving { await Task.yield() }
        #expect(cell.contentView.alpha == 1)
        #expect(toggle.isEnabled)
        #expect(!toggle.isOn)
        #expect(detailTable.cellForRow(at: path) === cell)
        #expect(detailTable.contentOffset == offset)
        // A second edit must queue behind the first instead of being discarded.
        toggle.isOn = true
        performActions(toggle)
        await service.resumeSave()
        for _ in 0..<200 where await service.saveCount < 2 { await Task.yield() }
        #expect(await service.saveCount == 2)
        #expect(try await service.load().pluginPreferences.first?.isEnabled == true)
        #expect(detailTable.cellForRow(at: path) === cell)
        #expect(cell.accessoryView === toggle)
        #expect(cell.contentView.alpha == 1)
        #expect(detailTable.contentOffset == offset)
        detail.beginAppearanceTransition(false, animated: false)
        detail.endAppearanceTransition()
        for _ in 0..<100 where await service.activeAnalysisSubscriptions != 0 { await Task.yield() }
        #expect(await service.activeAnalysisSubscriptions == 0)
    }

    @Test("Companion entries validate stable IDs, order consistently, and create pages only on navigation")
    func companionRegistryAndLazyFactories() throws {
        let id = PluginID(rawValue: "test.dsp")
        var created = 0
        var registry = PluginSettingsPageRegistry()
        func registration(_ suffix: String, order: Int = 0) -> PluginSettingsPageRegistration {
            .init(entry: .init(id: id.rawValue + "." + suffix, pluginID: id, title: suffix,
                systemImage: "slider.vertical.3", placement: .playback, order: order)) { _ in
                created += 1; return UIViewController()
            }
        }
        try registry.register(registration("z", order: 1))
        try registry.register(registration("b"))
        try registry.register(registration("a"))
        #expect(created == 0)
        #expect(registry.entries(placement: .playback).map(\.id) == ["test.dsp.a", "test.dsp.b", "test.dsp.z"])
        #expect(registry.entries(placement: .importing).isEmpty)
        #expect(throws: PluginSettingsRegistrationError.duplicateEntry("test.dsp.a")) {
            try registry.register(registration("a"))
        }
        #expect(throws: PluginSettingsRegistrationError.invalidEntry("foreign.page")) {
            try registry.register(.init(entry: .init(id: "foreign.page", pluginID: id, title: "Page", systemImage: "gear")) { _ in UIViewController() })
        }
        #expect(throws: PluginSettingsRegistrationError.duplicateNavigationIdentifier("test.dsp.a")) {
            try registry.register(.init(entry: .init(id: "test.dsp.alias", pluginID: id, title: "Alias", systemImage: "gear",
                navigationIdentifier: "test.dsp.a")) { _ in UIViewController() })
        }
        let service = PluginPresentationTestService()
        let host = PluginSettingsPageHost(registry: registry, plugins: service, settings: service)
        let context = host.context(for: .init(id: id, name: "DSP", kinds: [.dsp]))
        #expect(registry.makeViewController(entryID: "test.dsp.a", context: context) != nil)
        #expect(created == 1)
        let foreign = host.context(for: .init(id: .init(rawValue: "other"), name: "Other", kinds: [.metadata]))
        #expect(registry.makeViewController(entryID: "test.dsp.a", context: foreign) == nil)
        #expect(created == 1)
    }

    @Test("A complete companion replaces its form while an auxiliary page keeps the fallback")
    func companionFallbackRoles() async throws {
        for role in [PluginSettingsPageRole.configuration, .supplement] {
            let service = PluginPresentationTestService()
            let descriptor = await service.descriptor
            var registry = PluginSettingsPageRegistry()
            try registry.register(.init(entry: .init(id: "test.dsp.configuration", pluginID: descriptor.id,
                title: "Custom", systemImage: "gear", role: role)) { _ in UIViewController() })
            let host = PluginSettingsPageHost(registry: registry, plugins: service, settings: service)
            host.start(); await host.model.waitForPendingWork()
            let root = PluginSettingsViewController(plugins: service, settings: service, pageHost: host)
            let navigation = UINavigationController(rootViewController: root)
            root.loadViewIfNeeded()
            root.tableView(root.tableView, didSelectRowAt: .init(row: 0, section: 1))
            let detail = try #require(navigation.topViewController as? PluginSettingsViewController)
            detail.loadViewIfNeeded()
            let datasource = try #require(detail.tableView.dataSource as? UITableViewDiffableDataSource<String, String>)
            let identifiers = datasource.snapshot().itemIdentifiers
            #expect(identifiers.contains("plugins.pages.test.dsp.configuration"))
            #expect(identifiers.contains("plugins.test.dsp.configuration") == (role == .supplement))
        }
    }

    @Test("Custom pages persist only their plugin's configuration and use the runtime credential scope")
    func scopedCompanionPersistence() async throws {
        let service = PluginPresentationTestService()
        let descriptor = await service.descriptor
        let other = PluginPreference(pluginID: .init(rawValue: "other.plugin"), configuration: ["text": .text("keep")])
        let initial = AppSettings.defaults.settingPluginPreferences([.init(pluginID: descriptor.id), other])
        await service.publishExternal(initial)
        let host = PluginSettingsPageHost(registry: .init(), plugins: service, settings: service)
        let context = host.context(for: descriptor)
        let reference = try await context.saveCredential(Data("opaque secret".utf8))
        try await context.saveConfiguration(["gain": .number(2)], reference)
        let saved = try await service.load()
        #expect(saved.playbackPreferences == initial.playbackPreferences)
        #expect(saved.importPreferences == initial.importPreferences)
        #expect(saved.pluginPreferences.last == other)
        #expect(saved.pluginPreferences.first?.credentialRecordID == reference)
        #expect(saved.pluginPreferences.first?.configuration == ["gain": .number(2)])
        #expect(await service.credentialScope?.0 == descriptor.id)
        #expect(await service.credentialScope?.1 == "default")
        await #expect(throws: PluginError.invalidConfiguration) {
            try await context.saveConfiguration(["gain": .number(20)], reference)
        }
        #expect(try await context.readPreference().configuration == ["gain": .number(2)])
        try await context.deleteCredential(reference)
        #expect(await service.deletedCredential == reference)
    }

    @Test("Custom account pages manage independent instances and cannot edit another plugin's source")
    func scopedSourceInstances() async throws {
        let service = PluginPresentationTestService()
        let descriptor = PluginDescriptor(id: .init(rawValue: "test.source"), name: "Source", kinds: [.onlineSource],
            sourceConfiguration: .init(fields: [.init(id: "collection", title: "Collection", kind: .text, required: true)]),
            onlineProviderID: "test.source")
        let foreign = try OnlineSourceConfiguration(sourceID: .init(rawValue: "foreign.account"),
            providerKind: .init(rawValue: "foreign.provider"), displayName: "Other account")
        let initial = AppSettings.defaults.settingPluginPreferences([.init(pluginID: descriptor.id)])
        let settings = AppSettings(importPreferences: initial.importPreferences.settingOnlineSourcePreferences(.init(sources: [foreign])),
            pluginPreferences: initial.pluginPreferences)
        await service.publishExternal(settings)
        let host = PluginSettingsPageHost(registry: .init(), plugins: service, settings: service)
        let sources = try #require(host.context(for: descriptor).sources)
        let credential = try await sources.saveCredential(Data("account token".utf8), "account.a")
        #expect(await service.credentialScope?.1 == "account.a")
        let instance = PluginInstanceConfiguration(instanceID: "account.a", values: ["collection": .text("Music")], credentialRecordID: credential,
            acceptedPolicyVersion: descriptor.policyVersion)
        try await sources.saveSource(.init(id: "account.a", displayName: "My account", isEnabled: true, configuration: instance))
        #expect(try await sources.readSources().map(\.id) == ["account.a"])
        #expect(try await service.load().pluginPreferences.first?.instances.first?.values == ["collection": .text("Music")])
        let beforeRefusal = try await service.load()
        await #expect(throws: PluginError.unavailable) { try await sources.removeSource("foreign.account") }
        #expect(try await service.load() == beforeRefusal)
        await #expect(throws: PluginError.unavailable) {
            try await sources.saveSource(.init(id: "foreign.account", displayName: "Overwrite", isEnabled: true,
                configuration: .init(instanceID: "foreign.account", values: ["collection": .text("Music")])))
        }
        #expect(try await service.load() == beforeRefusal)
        try await sources.removeSource("account.a")
        #expect(await service.deletedCredential == credential)
        #expect(try await sources.readSources().isEmpty)
        #expect(try await service.load().importPreferences.onlineSourcePreferences.sources == [foreign])
        #expect(try await service.load().pluginPreferences.first?.instances.isEmpty == true)
        #expect(try await service.load().importPreferences.privacyPreferences.isPrivacyPolicyAccepted == false)
    }

    @Test("A disabled plugin retains its settings page and hidden entries leave category navigation")
    func companionVisibilityAndDisabledConfiguration() async throws {
        let service = PluginPresentationTestService()
        let descriptor = await service.descriptor
        var registry = PluginSettingsPageRegistry()
        try registry.register(.init(entry: .init(id: "test.dsp.page", pluginID: descriptor.id,
            title: "Page", systemImage: "gear", placement: .playback)) { _ in UIViewController() })
        let host = PluginSettingsPageHost(registry: registry, plugins: service, settings: service)
        host.start(); await host.model.waitForPendingWork()
        host.model.mutate(descriptor.id) { $0.isEnabled = false; $0.isLoadAllowed = false }
        await host.model.waitForPendingWork()
        #expect(host.entries(placement: .playback).count == 1)
        #expect(host.makePage(entryID: "test.dsp.page") != nil)
        host.model.mutate(descriptor.id) { $0.isVisible = false }
        await host.model.waitForPendingWork()
        #expect(host.entries(placement: .playback).isEmpty)
        #expect(host.makePage(entryID: "test.dsp.page") != nil) // Explicit management remains available.
    }

    private func performActions(_ control: UIControl) {
        for target in control.allTargets {
            for action in control.actions(forTarget: target, forControlEvent: .valueChanged) ?? [] {
                (target as? NSObject)?.perform(NSSelectorFromString(action), with: control)
            }
        }
    }

    @Test("Pending plugin choices survive refreshes and consent/configuration queue behind switches")
    func unifiedMutationQueue() async throws {
        let service = PluginPresentationTestService()
        let model = PluginSettingsModel(plugins: service, settings: service)
        model.start(); model.refresh()
        await model.waitForPendingWork()
        let descriptor = await service.descriptor
        await service.suspendNextSave()
        model.mutate(descriptor.id) { $0.isEnabled = false }
        for _ in 0..<100 where await !service.isSaving { await Task.yield() }
        #expect(await service.isSaving)
        model.mutate(descriptor.id) { $0.isEnabled = true }
        model.setConsent(descriptor, granting: true)
        model.refresh()
        for _ in 0..<100 { await Task.yield() }
        #expect(model.snapshots.first?.preference.isEnabled == true)
        #expect(model.snapshots.first?.preference.acceptedPolicyVersion == descriptor.policyVersion)
        let configuration = Task { await model.saveConfiguration(descriptor, values: ["gain": .number(2)]) }
        await Task.yield()
        await service.resumeSave()
        #expect(await configuration.value)
        await model.waitForPendingWork()
        let saved = try await service.load()
        #expect(await service.saveCount == 4)
        #expect(saved.pluginPreferences.first?.isEnabled == true)
        #expect(saved.pluginPreferences.first?.grantedPermissions == [.network])
        #expect(saved.pluginPreferences.first?.configuration == ["gain": .number(2)])
        #expect(!saved.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
    }

    @Test("Plugin failures roll back only the failed edit and subsequent saves remain available")
    func failedEditThenQueuedSave() async throws {
        let service = PluginPresentationTestService()
        let model = PluginSettingsModel(plugins: service, settings: service)
        model.refresh(); await model.waitForPendingWork()
        let id = await service.descriptor.id
        await service.failNextSave()
        model.mutate(id) { $0.isEnabled = false }
        await model.waitForPendingWork()
        #expect(model.snapshots.first?.preference.isEnabled == true)
        #expect(model.failure != nil)
        await service.suspendNextSave(); await service.failNextSave()
        model.mutate(id) { $0.isEnabled = false }
        for _ in 0..<100 where await !service.isSaving { await Task.yield() }
        model.mutate(id) { $0.isVisible = false }
        await service.resumeSave(); await model.waitForPendingWork()
        let preference = try #require(await service.load().pluginPreferences.first)
        #expect(preference.isEnabled)
        #expect(!preference.isVisible)
        #expect(model.failure == nil)
    }

    @Test("External plugin changes and normalized settings reach the shared model and runtime")
    func externalUpdatesAndNormalization() async throws {
        let service = PluginPresentationTestService()
        let model = PluginSettingsModel(plugins: service, settings: service)
        model.start(); model.refresh(); await model.waitForPendingWork()
        let descriptor = await service.descriptor
        await service.normalizeSaves()
        #expect(await model.saveConfiguration(descriptor, values: ["gain": .number(2)]))
        await model.waitForPendingWork()
        #expect(model.snapshots.first?.preference.configuration == ["gain": .number(3)])
        #expect(await service.lastApplied?.pluginPreferences.first?.configuration == ["gain": .number(3)])
        let external = AppSettings.defaults.settingPluginPreferences([.init(pluginID: descriptor.id, isEnabled: false)])
        await service.publishExternal(external)
        for _ in 0..<200 where model.snapshots.first?.preference.isEnabled != false { await Task.yield() }
        #expect(model.snapshots.first?.preference.isEnabled == false)
    }

    @Test("A plugin read failure can be retried without recreating the page")
    func retryLoad() async {
        let service = PluginPresentationTestService()
        let model = PluginSettingsModel(plugins: service, settings: service)
        await service.failNextLoad()
        model.refresh(); await model.waitForPendingWork()
        #expect(model.failure != nil)
        #expect(!model.isLoading)
        model.refresh(); await model.waitForPendingWork()
        #expect(model.failure == nil)
        #expect(model.snapshots.count == 1)
    }

    @Test("Rapid source save taps create only one source and retain independent application consent")
    func sourceSaveDoesNotDuplicate() async throws {
        let service = PluginPresentationTestService()
        var completions = 0
        let descriptor = PluginDescriptor(id: .init(rawValue: "test.source"), name: "Source", kinds: [.onlineSource])
        let controller = PluginSourceEditorViewController(descriptor: descriptor, configuration: nil, settings: service, plugins: service) {
            completions += 1
        }
        controller.loadViewIfNeeded()
        let path = IndexPath(row: 0, section: 1)
        for _ in 0..<100 where !controller.tableView(controller.tableView, cellForRowAt: path).isUserInteractionEnabled { await Task.yield() }
        await service.suspendNextSave()
        // Both taps arrive before the first asynchronous task starts.
        controller.tableView(controller.tableView, didSelectRowAt: path)
        controller.tableView(controller.tableView, didSelectRowAt: path)
        for _ in 0..<100 where await !service.isSaving { await Task.yield() }
        #expect(await service.isSaving)
        await service.resumeSave()
        for _ in 0..<100 where completions == 0 { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(await service.saveCount == 1)
        #expect(completions == 1)
        let current = try await service.load()
        #expect(current.importPreferences.onlineSourcePreferences.sources.count == 1)
        #expect(!current.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
    }

    @Test("Native configuration preserves a credential reference and stays editable after a failed save")
    func failedSavePreservesDraftAndCredential() async throws {
        let descriptor = PluginDescriptor(id: .init(rawValue: "native.configuration"), name: "Configuration", kinds: [.metadata], configuration: .init(fields: [
            .init(id: "token", title: "Token", kind: .secret, required: true),
            .init(id: "limit", title: "Limit", kind: .number, required: true, minimumNumber: 1, maximumNumber: 10)
        ]))
        var saved: [String: PluginConfigurationValue]?
        var succeeds = false
        let controller = PluginConfigurationViewController(descriptor: descriptor, initial: ["limit": .number(2)], credentialRecordID: "existing-keychain-reference") { values in
            saved = values
            return succeeds
        }
        let navigation = UINavigationController(rootViewController: controller)
        controller.loadViewIfNeeded()
        let table = controller.tableView!
        #expect(controller.tableView(table, numberOfRowsInSection: 0) == 1)
        let cell = controller.tableView(table, cellForRowAt: .init(row: 0, section: 0))
        let input = try #require(cell.contentView.subviews.compactMap { $0 as? UITextField }.first)
        input.text = "6"
        let button = try #require(controller.navigationItem.rightBarButtonItem)
        let selector = try #require(button.action)
        controller.perform(selector)
        for _ in 0..<100 where saved == nil { await Task.yield() }
        #expect(saved == ["limit": .number(6)])
        #expect(navigation.topViewController === controller)
        #expect(input.text == "6")
        #expect(controller.tableView(table, titleForFooterInSection: 0) != nil)
        #expect(button.isEnabled)
        succeeds = true
        navigation.setViewControllers([UIViewController(), controller], animated: false)
        controller.perform(selector)
        for _ in 0..<100 where navigation.topViewController === controller { await Task.yield() }
        #expect(navigation.topViewController !== controller)
    }

    @Test("Invalid numeric configuration remains on screen without calling persistence")
    func invalidNumberDoesNotSave() throws {
        let descriptor = PluginDescriptor(id: .init(rawValue: "native.number"), name: "Number", kinds: [.metadata], configuration: .init(fields: [
            .init(id: "limit", title: "Limit", kind: .number, required: true, minimumNumber: 1, maximumNumber: 10)
        ]))
        var saves = 0
        let controller = PluginConfigurationViewController(descriptor: descriptor, initial: ["limit": .number(2)], credentialRecordID: nil) { _ in saves += 1; return true }
        controller.loadViewIfNeeded()
        let table = controller.tableView!
        let cell = controller.tableView(table, cellForRowAt: .init(row: 0, section: 0))
        let input = try #require(cell.contentView.subviews.compactMap { $0 as? UITextField }.first)
        let selector = try #require(controller.navigationItem.rightBarButtonItem?.action)
        for text in ["abc", "NaN", "99"] {
            input.text = text
            controller.perform(selector)
            #expect(saves == 0)
            #expect(controller.tableView(table, titleForFooterInSection: 0) != nil)
            #expect(input.text == text)
        }
    }
}

private actor PluginPresentationTestService: PluginServing, SettingsServing {
    let descriptor = PluginDescriptor(id: .init(rawValue: "test.dsp"), name: "DSP", kinds: [.dsp], permissions: [.network], configuration: .init(fields: [
        .init(id: "gain", title: "Gain", kind: .number, minimumNumber: 0, maximumNumber: 4)
    ]))
    private var current = AppSettings.defaults.settingPluginPreferences([.init(pluginID: .init(rawValue: "test.dsp"), isEnabled: true, isLoadAllowed: true)])
    private var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var saveCount = 0
    private(set) var analysisSubscriptions = 0
    private var changes: [AsyncStream<AppSettings>.Continuation] = []
    private var fails = false
    private var loadFails = false
    private var normalizes = false
    private var analysisContinuations: [UUID: AsyncStream<PluginPCMAnalysisSnapshot>.Continuation] = [:]
    var activeAnalysisSubscriptions: Int { analysisContinuations.count }
    private(set) var lastApplied: AppSettings?
    private(set) var credentialScope: (PluginID, String)?
    private(set) var deletedCredential: String?
    func saveCredential(_ data: Data, pluginID: PluginID, instanceID: String) -> String {
        credentialScope = (pluginID, instanceID)
        return "scoped-reference"
    }
    func deleteCredential(recordID: String, pluginID: PluginID, instanceID: String) {
        credentialScope = (pluginID, instanceID)
        deletedCredential = recordID
    }
    var isSaving: Bool { continuation != nil }
    func suspendNextSave() { suspend = true }
    func resumeSave() { continuation?.resume(); continuation = nil }
    func failNextSave() { fails = true }
    func failNextLoad() { loadFails = true }
    func normalizeSaves() { normalizes = true }
    func publishExternal(_ value: AppSettings) { current = value; changes.forEach { $0.yield(value) } }
    func load() throws -> AppSettings {
        if loadFails { loadFails = false; throw PluginError.unavailable }
        return current
    }
    func update(_ settings: AppSettings) async throws {
        if suspend { suspend = false; await withCheckedContinuation { continuation = $0 } }
        if fails { fails = false; throw PluginError.unavailable }
        current = settings; saveCount += 1
        if normalizes {
            var preferences = current.pluginPreferences
            preferences[0].configuration["gain"] = .number(3)
            current = current.settingPluginPreferences(preferences)
        }
        changes.forEach { $0.yield(current) }
    }
    func reset() { current = .defaults }
    func effective() -> EffectivePlaybackSettings { .init(settings: current, effects: .neutral, playbackCapabilities: [], systemCapabilities: .init()) }
    func makeChangeStream() -> AsyncStream<AppSettings> {
        let (stream, continuation) = AsyncStream<AppSettings>.makeStream()
        changes.append(continuation)
        return stream
    }
    func apply(_ settings: AppSettings) { lastApplied = settings; current = settings }
    func snapshots() -> [PluginSnapshot] {
        let preference = current.pluginPreferences.first ?? .init(pluginID: descriptor.id)
        return [.init(descriptor: descriptor, preference: preference, state: preference.isEnabled ? .registered : .disabled)]
    }
    func stop() {}
    func audioAnalysis() -> AsyncStream<PluginPCMAnalysisSnapshot> {
        analysisSubscriptions += 1
        let id = UUID()
        let (stream, continuation) = AsyncStream<PluginPCMAnalysisSnapshot>.makeStream()
        analysisContinuations[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeAnalysisSubscription(id) } }
        return stream
    }
    private func removeAnalysisSubscription(_ id: UUID) { analysisContinuations[id] = nil }
}
