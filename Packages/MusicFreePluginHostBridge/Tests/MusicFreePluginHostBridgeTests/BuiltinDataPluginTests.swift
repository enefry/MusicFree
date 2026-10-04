import Foundation
import Testing
import MusicDomain
import LibraryAPI
import SettingsAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge

@Test func builtinDataRegistrationsRemainDisabledWithoutMigration() async {
    let provider = BuiltinDataPluginRegistrationProvider(bundle: Bundle(for: BundleAnchor.self),
        includeLyrics: false, includeMetadataServer: false)
    let registry = PluginRegistry(provider.registrations, compiledOut: provider.unavailable)
    #expect(registry.descriptors.count == 6)
    #expect(registry.unavailable.values.allSatisfy { $0 == .compiledOut })
    let runtime = PluginRuntime(registry: registry)
    let snapshots = await runtime.snapshots()
    #expect(snapshots.allSatisfy { !$0.preference.isEnabled && !$0.preference.isLoadAllowed })
    #expect(snapshots.first { $0.id.rawValue == "builtin.metadata.musicKit" }?.state == .disabled)
}
private final class BundleAnchor: NSObject {}

private actor AuthorizationFixture: MetadataPlugin {
    private var authorization = PluginMetadataAuthorizationStatus.notDetermined
    func authorizationStatus() async -> PluginMetadataAuthorizationStatus { authorization }
    func requestAuthorization() async -> PluginMetadataAuthorizationStatus { authorization = .authorized; return authorization }
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] { [] }
}
private func metadataRuntime(plugin: any MetadataPlugin) async -> (PluginRuntime, PluginID) {
    let id = PluginID(rawValue: "test.metadata")
    let runtime = PluginRuntime(registry: PluginRegistry([
        .init(descriptor: .init(id: id, name: "Fixture", kinds: [.metadata], permissions: [.network]), metadata: { _ in plugin })
    ]))
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true,
        grantedPermissions: [.network], acceptedPolicyVersion: "1")], applicationPrivacyAccepted: true)
    return (runtime, id)
}
@Test func metadataSystemAuthorizationIsForwardedAndRevocationBlocksIt() async {
    let (runtime, id) = await metadataRuntime(plugin: AuthorizationFixture())
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    #expect(await adapter.authorizationStatus() == .notDetermined)
    #expect(await adapter.requestAuthorization() == .authorized)
    #expect(await adapter.authorizationStatus() == .authorized)
    await runtime.apply(preferences: [], applicationPrivacyAccepted: true)
    #expect(await adapter.requestAuthorization() == .unavailable)
}

private struct CatalogFixture: MetadataPlugin {
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        [.init(id: "good", track: .init(title: "Example Song (Remastered)", artist: "Example Artist", album: "Catalog Album", durationSeconds: 180),
               patch: .init(text: [.album: "Catalog Album", .genre: "Rock"], numbers: [.year: 2024])),
         .init(id: "wrong", track: .init(title: "Example Song", artist: "Unrelated Performer", durationSeconds: 180), patch: .init(numbers: [.year: 2000]))]
    }
}
@Test func catalogMatchingPreservesLegacyVariantsAndFiltersPatches() async throws {
    let (runtime, id) = await metadataRuntime(plugin: CatalogFixture())
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let result = try await adapter.search(.init(itemID: .init(sourceID: .local, externalID: "song"),
        title: "Example Song", artistName: "Example Artist", albumName: "Local Album", durationSeconds: 180.4, missingFields: [.year]))
    #expect(result.count == 1)
    #expect(result.first?.catalogID == "good")
    #expect(result.first?.year == 2024)
    #expect(result.first?.genreName == nil)
    #expect(result.first?.albumName == nil)
}

private struct FailureFixture: LyricsPlugin, MetadataPlugin {
    let error: PluginDataError
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] { throw error }
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] { throw error }
}
@Test func dataFailureCodesAndRetryInformationSurviveTheBridge() async throws {
    let (runtime, id) = await metadataRuntime(plugin: FailureFixture(error: .rateLimited(retryAfterSeconds: 7, httpStatus: 429)))
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    await #expect(throws: MetadataEnrichmentError.rateLimited(retryAfterSeconds: 7, httpStatus: 429)) {
        try await adapter.search(.init(itemID: .init(sourceID: .local, externalID: "song"), title: "Song", artistName: "Artist"))
    }
    // A recoverable service failure must not permanently remove the provider
    // from the coordinator's retry chain.
    #expect(await adapter.authorizationStatus() == .authorized)
    let lyricsID = PluginID(rawValue: "test.lyrics")
    let lyricsRuntime = PluginRuntime(registry: PluginRegistry([
        .init(descriptor: .init(id: lyricsID, name: "Lyrics", kinds: [.lyrics]), lyrics: { _ in FailureFixture(error: .requestFailed(code: "lrclib_http_503", httpStatus: 503)) })
    ]))
    await lyricsRuntime.apply(preferences: [.init(pluginID: lyricsID, isEnabled: true, isLoadAllowed: true)], applicationPrivacyAccepted: false)
    let lyrics = PluginLyricsProviderAdapter(pluginID: lyricsID, runtime: lyricsRuntime)
    await #expect(throws: LyricsProviderError.requestFailed(code: "lrclib_http_503", httpStatus: 503)) {
        try await lyrics.fetchLyrics(for: .init(itemID: .init(sourceID: .local, externalID: "song"), title: "Song", artistName: "Artist"))
    }
}

private struct RawLRCFixture: LyricsPlugin {
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        [.init(id: "raw-lrc", track: query, rawText: "[offset:-100]\n[00:01.25]中文歌词")]
    }
}
@Test func rawServiceLyricsKeepTimingAndDeclaredOffsetInHost() async throws {
    let id = PluginID(rawValue: "raw.lyrics")
    let runtime = PluginRuntime(registry: PluginRegistry([
        .init(descriptor: .init(id: id, name: "Raw LRC", kinds: [.lyrics]), lyrics: { _ in RawLRCFixture() })
    ]))
    await runtime.apply(preferences: [.init(pluginID: id, isEnabled: true, isLoadAllowed: true)], applicationPrivacyAccepted: false)
    let adapter = PluginLyricsProviderAdapter(pluginID: id, runtime: runtime)
    let result = try #require(try await adapter.fetchLyrics(for: .init(itemID: .init(sourceID: .local, externalID: "raw"), title: "Song", artistName: "Artist")))
    #expect(result.timedLines.first?.timestampMilliseconds == 1250)
    #expect(result.timedLines.first?.text == "中文歌词")
    #expect(result.declaredOffsetMilliseconds == -100)
}

private actor AuthorizationLoadCounter {
    var count = 0
    func loaded() { count += 1 }
}
@Test func disabledMetadataCanAuthorizeWithoutLoadingOrRunningCandidates() async throws {
    let id = PluginID(rawValue: "builtin.metadata.fixture"), plugin = AuthorizationFixture(), loads = AuthorizationLoadCounter()
    let runtime = PluginRuntime(registry: PluginRegistry([
        .init(descriptor: .init(id: id, name: "Metadata", kinds: [.metadata], permissions: [.network], dataProviderID: "musicKit"),
            metadata: { _ in await loads.loaded(); return plugin },
            metadataAuthorization: .init(status: { await plugin.authorizationStatus() }, request: { await plugin.requestAuthorization() }))
    ]))
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let preference = PluginPreference(pluginID: id, isEnabled: false, isLoadAllowed: true,
        grantedPermissions: [.network], acceptedPolicyVersion: "1")
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: true)
    #expect(await adapter.authorizationStatus() == .notDetermined)
    #expect(await adapter.requestAuthorization() == .authorized)
    #expect(await adapter.authorizationStatus() == .authorized)
    #expect(await loads.count == 0)
    #expect(await runtime.snapshots().first?.state == .disabled)
    await #expect(throws: PluginError.disabled) { try await runtime.perform(pluginID: id, kind: .metadata) { _, _ in 1 } }
    var revoked = preference; revoked.grantedPermissions = []; revoked.acceptedPolicyVersion = nil
    await runtime.apply(preferences: [revoked], applicationPrivacyAccepted: true)
    #expect(await adapter.requestAuthorization() == .unavailable)
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(await adapter.requestAuthorization() == .unavailable)
    var blocked = preference; blocked.isLoadAllowed = false
    await runtime.apply(preferences: [blocked], applicationPrivacyAccepted: true)
    #expect(await adapter.requestAuthorization() == .unavailable)
    #expect(await loads.count == 0)
}
