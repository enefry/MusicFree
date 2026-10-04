import Foundation
import Testing
import SettingsAPI
import SystemIntegrationAPI
import MusicFreePluginAPI
@testable import AppServices

private actor MigrationSettingsRepository: SettingsRepository {
    var value = AppSettings.defaults
    var writes: [AppSettings] = []
    func load() async throws -> AppSettings { value }
    func save(_ settings: AppSettings) async throws { value = settings; writes.append(settings) }
    func reset() async throws { value = .defaults }
    nonisolated func changes() -> AsyncStream<AppSettings> { AsyncStream { $0.finish() } }
}
private actor MigrationSettingsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var waiting: Bool { continuation != nil }
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private struct MigrationSettingsPlugins: PluginServing {
    let gate: MigrationSettingsGate
    func adaptingSettings(_ settings: AppSettings, previous: AppSettings?) async throws -> AppSettings {
        if previous == nil { await gate.wait() }
        return settings.settingPluginPreferences([.init(pluginID: .init(rawValue: "migrated.plugin"), isLoadAllowed: true,
            configuration: ["rate": .number(settings.playbackPreferences.rate.value)])])
    }
    func apply(_ settings: AppSettings) async {}
    func snapshots() async -> [PluginSnapshot] { [] }
    func stop() async {}
}
@Test func pluginSettingsMigrationSerializesStartupSaveAndReset() async throws {
    let repository = MigrationSettingsRepository(), gate = MigrationSettingsGate()
    let coordinator = SettingsCoordinator(repository: repository, plugins: MigrationSettingsPlugins(gate: gate),
        playbackCapabilities: [], equalizerDescriptor: nil, systemCapabilities: .init())
    let loading = Task { try await coordinator.load() }
    defer { Task { await gate.release() }; loading.cancel() }
    for _ in 0..<100 where !(await gate.waiting) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await gate.waiting)
    let changed = AppSettings(playbackPreferences: .init(rate: try .init(value: 1.5)))
    let updating = Task { try await coordinator.update(changed) }
    defer { updating.cancel() }
    await gate.release()
    let initial = try await loading.value
    try await updating.value
    #expect(initial.pluginPreferences.first?.configuration["rate"] == .number(1))
    #expect(await repository.value.playbackPreferences.rate.value == 1.5)
    #expect(await repository.value.pluginPreferences.first?.configuration["rate"] == .number(1.5))
    #expect(await repository.writes.count == 2)
    try await coordinator.reset()
    let restored = try await coordinator.load()
    #expect(restored.playbackPreferences.rate == .normal)
    #expect(restored.pluginPreferences.first?.configuration["rate"] == .number(1))
}
