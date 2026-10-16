import Foundation
import AVFAudio
import Testing
import SettingsAPI
import MusicDomain
import MediaSourceAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
@testable import MusicFreePluginHostBridge

private let migrationLyricsID = PluginID(rawValue: "builtin.lyrics.lrclib")
private struct MigrationLyrics: LyricsPlugin {
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        [.init(id: "lyrics", track: query, rawText: "[00:01.00]Example")]
    }
}
private func migrationService() -> PluginHostService {
    .init(runtime: PluginRuntime(registry: PluginRegistry([
        .init(descriptor: .init(id: migrationLyricsID, name: "LRCLIB", kinds: [.lyrics], permissions: [.network],
            policyVersion: "1.2.0", dataProviderID: "lrclib"), lyrics: { _ in MigrationLyrics() }),
        PluginHostService.equalizerRegistration
    ])))
}
@Test func migrationPreservesProviderIdentityIntentAndIndependentAppConsent() async throws {
    let service = migrationService()
    let imports = ImportPreferences.defaults.settingLyricsProvider(.lrclib, enabled: true)
        .settingPrivacyPreferences(.init(providerConsents: [.init(providerID: "lrclib", policyVersion: "1.2.0")]))
    let old = AppSettings(importPreferences: imports)
    let migrated = try await service.adaptingSettings(old, previous: nil)
    let preference = try #require(migrated.pluginPreferences.first { $0.pluginID == migrationLyricsID })
    #expect(preference.isEnabled && preference.isLoadAllowed)
    #expect(preference.grantedPermissions == [.network])
    #expect(!migrated.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
    #expect(service.lyricsProviders.first?.provider == .lrclib)
    #expect(try await service.adaptingSettings(migrated, previous: nil) == migrated)
    await service.apply(migrated)
    #expect(await service.snapshots().first { $0.id == migrationLyricsID }?.state == .permissionRequired)
    let accepted = AppSettings(importPreferences: migrated.importPreferences.settingPrivacyPreferences(
        .init(privacyPolicyVersion: "1.2.0", providerConsents: imports.privacyPreferences.providerConsents)),
        playbackPreferences: migrated.playbackPreferences, pluginPreferences: migrated.pluginPreferences)
    await service.apply(accepted)
    #expect(try await service.lyricsProviders.first?.fetchLyrics(for: .init(itemID: .init(sourceID: .local, externalID: "test"), title: "Song", artistName: "Artist"))?.timedLines.count == 1)
}
@Test func migrationDoesNotRestoreRevokedPluginsAndLegacyEditsRemainUsable() async throws {
    let service = migrationService()
    let original = AppSettings(importPreferences: .defaults.settingLyricsProvider(.lrclib, enabled: true)
        .settingPrivacyPreferences(.init(privacyPolicyVersion: "1.2.0", providerConsents: [.init(providerID: "lrclib", policyVersion: "1.2.0")])) )
    let migrated = try await service.adaptingSettings(original, previous: nil)
    var preferences = migrated.pluginPreferences
    let index = try #require(preferences.firstIndex { $0.pluginID == migrationLyricsID })
    preferences[index].isEnabled = false; preferences[index].grantedPermissions = []; preferences[index].acceptedPolicyVersion = nil
    let revoked = migrated.settingPluginPreferences(preferences)
    let reloaded = try await service.adaptingSettings(revoked, previous: nil)
    #expect(!reloaded.importPreferences.isLyricsProviderEnabled(.lrclib))
    #expect(try await service.adaptingSettings(reloaded, previous: nil) == reloaded)
    #expect(reloaded.pluginPreferences[index].grantedPermissions.isEmpty)
    // A deliberate old-editor toggle updates enablement, without restoring a revoked grant.
    let edited = AppSettings(importPreferences: reloaded.importPreferences.settingLyricsProvider(.lrclib, enabled: true),
        playbackPreferences: reloaded.playbackPreferences, pluginPreferences: reloaded.pluginPreferences)
    let updated = try await service.adaptingSettings(edited, previous: reloaded)
    #expect(updated.pluginPreferences.first { $0.pluginID == migrationLyricsID }?.isEnabled == true)
    #expect(updated.pluginPreferences.first { $0.pluginID == migrationLyricsID }?.grantedPermissions.isEmpty == true)
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(updated)) == updated)
}
#if DEBUG
@Test @MainActor func equalizerMigrationSupportsChainAndLiveParameters() async throws {
    let references = ReferencePluginRegistrationProvider(mediaURL: URL(fileURLWithPath: "/unused")).registrations
    let runtime = PluginRuntime(registry: PluginRegistry(references + [PluginHostService.equalizerRegistration]))
    let id = PluginHostService.equalizerRegistration.descriptor.id
    var nodes: [AVAudioNode] = []; var mounts = 0
    let controller = PluginAudioHostController(runtime: runtime, factories: PluginHostService.audioFactories, installChain: { nodes = $0; mounts += 1 })
    defer { controller.unload() }
    let service = PluginHostService(runtime: runtime, audio: [controller])
    let gain = PluginPreference(pluginID: ReferencePluginRegistrationProvider.dspID, isEnabled: true, isLoadAllowed: true,
        configuration: ["gain": .number(0.5)])
    let old = AppSettings(playbackPreferences: .init(equalizer: try .init(isEnabled: true, preamp: .init(decibels: -3),
        bands: [.init(frequencyHz: 500, gain: .init(decibels: 6))])), pluginPreferences: [gain])
    let migrated = try await service.adaptingSettings(old, previous: nil)
    #expect(migrated.pluginPreferences.first { $0.pluginID == id }?.configuration["500"] == .number(6))
    await service.apply(migrated)
    #expect(nodes.count == 2)
    let node = try #require(nodes.first as? AVAudioUnitEQ)
    #expect(node.bands.count == 10); #expect(node.globalGain == -3); #expect(mounts == 1)
    var next = migrated.pluginPreferences
    let index = try #require(next.firstIndex { $0.pluginID == id }); next[index].configuration["500"] = .number(-6)
    let updated = try await service.adaptingSettings(migrated.settingPluginPreferences(next), previous: migrated)
    #expect(updated.playbackPreferences.equalizer.bands.first { $0.frequencyHz == 500 }?.gain.decibels == -6)
    await service.apply(updated)
    #expect(nodes.first === node); #expect(node.bands[4].gain == -6); #expect(mounts == 1); #expect(!node.bypass)
    next[index].dspPlacement = .perTrack
    await service.apply(migrated.settingPluginPreferences(next))
    #expect(node.bypass); #expect(nodes.count == 1)
}
#endif

private actor NativeCalls {
    var creations = 0; var browse: SourceBrowseRequest?; var code: String?
    func created() { creations += 1 }
    func record(_ request: SourceBrowseRequest) { browse = request }
    func authenticate(_ value: String) { code = value }
}
private struct NativeFixtureFactory: OnlineSourceFactory {
    let calls: NativeCalls
    func makeSource(for configuration: OnlineSourceConfiguration) throws -> (any OnlineSource)? {
        Task { await calls.created() }
        return NativeFixture(configuration: configuration, calls: calls)
    }
}
private struct NativeFixture: SearchableDownloadSource, PlaybackSource, OneTimeCodeAuthenticatingOnlineSource {
    let configuration: OnlineSourceConfiguration; let calls: NativeCalls
    var descriptor: MediaSourceDescriptor { .init(sourceID: configuration.sourceID, kind: .remote, displayName: configuration.displayName, isReadOnly: true) }
    var capabilities: MediaSourceCapabilities { [] }
    var providerKind: OnlineProviderKind { configuration.providerKind }
    var onlineCapabilities: OnlineSourceCapabilities { [.browsing, .searching, .downloading, .onlinePlayback] }
    func resolve(_ id: MediaItemID) async throws -> PlaybackResource { throw PluginError.unavailable }
    func artwork(for id: ArtworkID) async throws -> ArtworkResource? { nil }
    func authenticate(oneTimeCode: String) async throws { await calls.authenticate(oneTimeCode) }
    func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
        await calls.record(request)
        return .init(items: [.init(id: .init(sourceID: configuration.sourceID, externalID: "song"), kind: .audioFile,
            displayName: "File.flac", title: "Song", artist: "Artist", album: "Album", isPlayable: true)], nextPageToken: .init(rawValue: "next"))
    }
    func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage { try await browse(.init(pageToken: request.pageToken)) }
    func download(_ id: SourceObjectID, options: DownloadOptions) async throws -> DownloadReceipt {
        options.progress?(.init(receivedBytes: 12, totalBytes: 12))
        return .init(sourceID: configuration.sourceID, itemID: id, fileURL: URL(fileURLWithPath: "/fixture.flac"), contentRevision: "etag", byteCount: 12)
    }
    func playbackAccess(for id: SourceObjectID, purpose: PlaybackPurpose) async throws -> PlaybackAccess { .downloadRequired }
}
@Test func nativeSourcesLoadLazilyPreserveRichResultsAndRevokePerAccount() async throws {
    let calls = NativeCalls(), factory = NativeFixtureFactory(calls: NativeCalls())
    let nativeFactory = NativeFixtureFactory(calls: calls)
    let registrations = NativeOnlineSourceRegistrationProvider(factory: nativeFactory).registrations
    let runtime = PluginRuntime(registry: PluginRegistry(registrations))
    let service = PluginHostService(runtime: runtime)
    let a = try OnlineSourceConfiguration(sourceID: .init(rawValue: "a"), providerKind: .dsAudio, displayName: "A", endpoint: URL(string: "https://example.invalid"), credentialRecordID: "existing-account", privacyPolicyVersion: "1.2.0", isEnabled: true)
    let b = try OnlineSourceConfiguration(sourceID: .init(rawValue: "b"), providerKind: .dsAudio, displayName: "B", endpoint: a.endpoint, privacyPolicyVersion: "1.2.0", isEnabled: true)
    let old = AppSettings(importPreferences: .defaults.settingPrivacyPreferences(.init(privacyPolicyVersion: "1.2.0"))
        .settingOnlineSourcePreferences(.init(isEnabled: true, sources: [a, b])))
    let migrated = try await service.adaptingSettings(old, previous: nil)
    #expect(migrated.importPreferences.onlineSourcePreferences.sources == [a, b])
    await service.apply(migrated)
    let composite = CompositeOnlineSourceFactory(legacy: factory, runtime: runtime, downloadRoot: URL(fileURLWithPath: "/unused"))
    let sourceA = try #require(try composite.makeSource(for: a) as? any SearchableDownloadSource)
    let sourceB = try #require(try composite.makeSource(for: b) as? any CatalogBrowsingSource)
    #expect(await calls.creations == 0)
    let request = SourceBrowseRequest(mode: .allMusic, pageSize: 37, pageToken: .init(rawValue: "cursor"))
    let page = try await sourceA.browse(request)
    #expect(await calls.browse == request); #expect(page.items.first?.album == "Album"); #expect(page.nextPageToken?.rawValue == "next")
    let receipt = try await sourceA.download(.init(sourceID: a.sourceID, externalID: "song"), options: .init())
    #expect(receipt.contentRevision == "etag"); #expect(receipt.byteCount == 12)
    let authenticating = try #require(sourceA as? any OneTimeCodeAuthenticatingOnlineSource)
    try await authenticating.authenticate(oneTimeCode: "123456")
    #expect(await calls.code == "123456")
    let revokedA = try OnlineSourceConfiguration(sourceID: a.sourceID, providerKind: a.providerKind, displayName: a.displayName, endpoint: a.endpoint, isEnabled: false)
    let revoked = AppSettings(importPreferences: migrated.importPreferences.settingOnlineSourcePreferences(.init(isEnabled: true, sources: [revokedA, b])),
        playbackPreferences: migrated.playbackPreferences, pluginPreferences: migrated.pluginPreferences)
    await service.apply(try await service.adaptingSettings(revoked, previous: migrated))
    await #expect(throws: PluginError.permissionRequired) { try await sourceA.browse(request) }
    #expect(try await sourceB.browse(request).items.count == 1)
    await service.apply(AppSettings(importPreferences: migrated.importPreferences.settingPrivacyPreferences(.defaults), pluginPreferences: migrated.pluginPreferences))
    await #expect(throws: PluginError.permissionRequired) { try await sourceB.browse(request) }
}

@Test func invalidEqualizerPluginConfigurationDoesNotBreakSettingsLoad() async throws {
    let service = migrationService(), id = PluginHostService.equalizerRegistration.descriptor.id
    let invalid = PluginPreference(pluginID: id, isEnabled: true, isLoadAllowed: true, configuration: ["500": .number(99)])
    let settings = AppSettings(pluginPreferences: [invalid])
    let restored = try await service.adaptingSettings(settings, previous: nil)
    #expect(restored.pluginPreferences.first { $0.pluginID == id } == invalid)
    await service.apply(restored)
    #expect(await service.snapshots().first { $0.id == id }?.state == .failed)
}

@Test func builtinDefaultsMatchLegacyIntentWithoutAcceptingPrivacy() throws {
    let metadata = ImportPreferences.defaultMetadataProviders.map { preference in
        PluginDescriptor(id: .init(rawValue: "builtin.metadata." + preference.provider.rawValue),
            name: preference.provider.rawValue, kinds: [.metadata], permissions: [.network], dataProviderID: preference.provider.rawValue)
    }
    let lyrics = ImportPreferences.defaultLyricsProviders.map { preference in
        PluginDescriptor(id: .init(rawValue: "builtin.lyrics." + preference.provider.rawValue),
            name: preference.provider.rawValue, kinds: [.lyrics], permissions: [.network], dataProviderID: preference.provider.rawValue)
    }
    let descriptors = metadata + lyrics + [PluginHostService.equalizerRegistration.descriptor]
    let migrated = try BuiltinPluginSettingsAdapter.adapt(.defaults, previous: nil, descriptors: descriptors)
    #expect(migrated.pluginPreferences.count == descriptors.count)
    #expect(migrated.pluginPreferences.allSatisfy { !$0.isEnabled && $0.isLoadAllowed })
    #expect(migrated.pluginPreferences.allSatisfy { $0.grantedPermissions.isEmpty && $0.acceptedPolicyVersion == nil })
    #expect(!migrated.importPreferences.privacyPreferences.isPrivacyPolicyAccepted)
    #expect(!migrated.importPreferences.onlineSourcePreferences.isEnabled)
    let legacy = AppSettings(importPreferences: .defaults.settingMetadataProvider(.musicBrainz, enabled: true))
    let enabled = try BuiltinPluginSettingsAdapter.adapt(legacy, previous: nil, descriptors: descriptors)
    #expect(enabled.pluginPreferences.first { $0.pluginID.rawValue == "builtin.metadata.musicBrainz" }?.isEnabled == true)
    #expect(enabled.pluginPreferences.first { $0.pluginID.rawValue == "builtin.metadata.musicBrainz" }?.grantedPermissions.isEmpty == true)
    var revoked = enabled.pluginPreferences
    let index = try #require(revoked.firstIndex { $0.pluginID.rawValue == "builtin.metadata.musicBrainz" })
    revoked[index].isEnabled = false
    let restored = try BuiltinPluginSettingsAdapter.adapt(legacy.settingPluginPreferences(revoked), previous: nil, descriptors: descriptors)
    #expect(!restored.importPreferences.isMetadataProviderEnabled(.musicBrainz))
}
