import Foundation
import Testing
import AppServices
import MusicDomain
import MusicTestSupport
import LibraryAPI
import SettingsAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime
import MusicFreePluginHostBridge

@Test func builtinDataRegistrationsRemainDisabledWithoutMigration() async {
    let provider = BuiltinDataPluginRegistrationProvider(bundle: Bundle(for: BundleAnchor.self),
        includeLyrics: false, includeMetadataServer: false)
    let registry = PluginRegistry(provider.registrations, compiledOut: provider.unavailable)
    #expect(registry.descriptors.count == 10)
    #expect(registry.registrations.keys.contains(.init(rawValue: "builtin.metadata.netEase")))
    #expect(registry.registrations.keys.contains(.init(rawValue: "builtin.metadata.qqMusic")))
    #expect(registry.unavailable[.init(rawValue: "builtin.lyrics.netEase")] == .compiledOut)
    #expect(registry.unavailable[.init(rawValue: "builtin.lyrics.qqMusic")] == .compiledOut)
    #expect(registry.unavailable.values.allSatisfy { $0 == .compiledOut })
    let runtime = PluginRuntime(registry: registry)
    let snapshots = await runtime.snapshots()
    #expect(snapshots.allSatisfy { !$0.preference.isEnabled && !$0.preference.isLoadAllowed })
    #expect(snapshots.first { $0.id.rawValue == "builtin.metadata.musicKit" }?.state == .disabled)
}
private final class BundleAnchor: NSObject {}

#if !DEBUG
@Test @MainActor func releaseAudioFactoriesContainOnlyProductionEffects() {
    #expect(Set(PluginHostService.audioFactories.keys) == [PluginHostService.equalizerRegistration.descriptor.id])
}
#endif

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
    #expect(result.first?.artistName == "Example Artist")
    #expect(result.first?.albumName == "Catalog Album")
}

private actor DeferredArtworkFixture: MetadataPlugin {
    let error: PluginDataError?
    let byteCount: Int
    private(set) var artworkRequests: [String] = []

    init(error: PluginDataError? = nil, byteCount: Int = 4) {
        self.error = error
        self.byteCount = byteCount
    }

    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        [.init(id: "catalog", track: query, patch: .init(numbers: [.year: 2024]), artworkReference: "cover")]
    }

    func artwork(reference: String, context: PluginOperationContext) async throws -> Data? {
        artworkRequests.append(reference)
        if let error { throw error }
        return Data(repeating: 1, count: byteCount)
    }
}

@Test func metadataArtworkFailureIsDeferredUntilAfterSearch() async throws {
    let fixture = DeferredArtworkFixture(error: .requestFailed(code: "artwork_http_404", httpStatus: 404))
    let (runtime, id) = await metadataRuntime(plugin: fixture)
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let candidate = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "song"), title: "Song", artistName: "Artist",
        missingFields: [.year, .artwork])).first)
    #expect(candidate.year == 2024)
    #expect(candidate.artworkData == nil)
    #expect(await fixture.artworkRequests.isEmpty)
    await #expect(throws: MetadataEnrichmentError.requestFailed(code: "artwork_http_404", httpStatus: 404)) {
        try await adapter.artworkData(for: candidate)
    }
    #expect(await fixture.artworkRequests == ["cover"])
}

@Test(arguments: [4, 20 * 1024 * 1024, 20 * 1024 * 1024 + 1])
func metadataDeferredArtworkKeepsPayloadBound(byteCount: Int) async throws {
    let fixture = DeferredArtworkFixture(byteCount: byteCount)
    let (runtime, id) = await metadataRuntime(plugin: fixture)
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let candidate = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "song"), title: "Song", missingFields: [.artwork])).first)
    if byteCount <= 20 * 1024 * 1024 {
        #expect(try await adapter.artworkData(for: candidate)?.count == byteCount)
    } else {
        await #expect(throws: MetadataEnrichmentError.requestFailed(code: "plugin_invalid_response", httpStatus: nil)) {
            try await adapter.artworkData(for: candidate)
        }
    }
}

@Test func metadataDeferredArtworkRechecksRuntimePermissionAndCancellation() async throws {
    let fixture = DeferredArtworkFixture()
    let (runtime, id) = await metadataRuntime(plugin: fixture)
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let candidate = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "song"), title: "Song", missingFields: [.artwork])).first)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        for await _ in stream {}
        return try await adapter.artworkData(for: candidate)
    }
    task.cancel()
    continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    await runtime.apply(preferences: [], applicationPrivacyAccepted: true)
    await #expect(throws: MetadataEnrichmentError.unavailable) { try await adapter.artworkData(for: candidate) }
    #expect(await fixture.artworkRequests.isEmpty)
}

@Test func metadataRequestedFieldsWithoutPatchRemainUnchanged() async throws {
    let (runtime, id) = await metadataRuntime(plugin: DeferredArtworkFixture())
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let candidate = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "song"), title: "Song", artistName: "Artist", albumName: "Album",
        missingFields: [.artist, .album, .year])).first)
    #expect(candidate.artistName == nil)
    #expect(candidate.albumName == nil)
    #expect(candidate.year == 2024)
    #expect(try await adapter.artworkData(for: candidate) == nil)
}

private struct ArtworkReferenceFixture: MetadataPlugin {
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        [.init(id: "shared-id", track: query, patch: .init(), artworkReference: query.title)]
    }
    func artwork(reference: String, context: PluginOperationContext) async throws -> Data? { Data(reference.utf8) }
}

@Test func metadataDeferredArtworkKeepsReferencesForOverlappingSearches() async throws {
    let (runtime, id) = await metadataRuntime(plugin: ArtworkReferenceFixture())
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let first = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "first"), title: "First Song", missingFields: [.artwork])).first)
    let second = try #require(try await adapter.search(.init(
        itemID: .init(sourceID: .local, externalID: "second"), title: "Second Song", missingFields: [.artwork])).first)
    #expect(try await adapter.artworkData(for: first) == Data("First Song".utf8))
    #expect(try await adapter.artworkData(for: second) == Data("Second Song".utf8))
}

private actor EnrichmentRecordsFixture: MetadataEnrichmentRecordRepository {
    private var values: [MediaItemID: MetadataEnrichmentRecord] = [:]
    func record(for itemID: MediaItemID) async throws -> MetadataEnrichmentRecord? { values[itemID] }
    func records() async throws -> [MetadataEnrichmentRecord] { Array(values.values) }
    func save(_ record: MetadataEnrichmentRecord) async throws { values[record.itemID] = record }
    func remove(itemID: MediaItemID) async throws { values[itemID] = nil }
}

@MainActor
private func enrich(
    itemID: MediaItemID,
    repository: InMemoryLibraryRepository,
    adapter: PluginMetadataProviderAdapter
) async throws -> MetadataEnrichmentRecord {
    let records = EnrichmentRecordsFixture()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository, metadataEnrichmentProvider: adapter, metadataEnrichmentRecordRepository: records))
    await container.metadataEnrichmentServing.setPrivacyPreferences(
        .defaults.acceptingPrivacyPolicy().acceptingProviderPolicy(adapter.provider.rawValue))
    await container.metadataEnrichmentServing.setProviderPreferences([.init(provider: adapter.provider, isEnabled: true)])
    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)
    var completed: MetadataEnrichmentRecord?
    for _ in 0..<200 {
        if let record = try await records.record(for: itemID), record.status == .matched {
            completed = record
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    await container.metadataEnrichmentServing.setEnabled(false)
    return try #require(completed)
}

@Test @MainActor func metadataArtworkFailureStillCommitsYearThroughCoordinator() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "artwork-failure")
    let repository = InMemoryLibraryRepository(tracks: [Track(id: itemID, title: "Song")])
    let fixture = DeferredArtworkFixture(error: .requestFailed(code: "artwork_http_404", httpStatus: 404))
    let (runtime, id) = await metadataRuntime(plugin: fixture)
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let record = try await enrich(itemID: itemID, repository: repository, adapter: adapter)
    let updated = try #require(try await repository.track(id: itemID))
    #expect(updated.year == 2024)
    #expect(updated.artwork == nil)
    #expect(record.updatedFields == [.year])
    #expect(record.lastErrorCode == "artwork_http_404")
    #expect(await fixture.artworkRequests == ["cover"])
}

private struct TransliteratedCatalogFixture: MetadataPlugin {
    func candidates(for query: PluginTrackQuery, fields: Set<PluginMetadataField>, context: PluginOperationContext) async throws -> [PluginMetadataCandidate] {
        [.init(id: "transliterated", track: .init(title: "ni hao", artist: "Artist", album: "Catalog Album"),
            patch: .init(text: [.artist: "Unrequested Artist", .album: "Unrequested Album", .genre: "Rock"], numbers: [.year: 2024]))]
    }
}

@Test @MainActor func metadataMatchingEvidenceSurvivesCoordinatorAndPreservesExistingTags() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "transliterated")
    let artistID = ArtistID("artist"), albumID = AlbumID("album"), genreID = GenreID("genre")
    let repository = InMemoryLibraryRepository(
        tracks: [Track(id: itemID, title: "你好", albumID: albumID, artistIDs: [artistID], genreIDs: [genreID])],
        albums: [Album(id: albumID, title: "Local Album", artistIDs: [artistID], trackCount: 1)],
        artists: [Artist(id: artistID, name: "Artist")], genres: [Genre(id: genreID, name: "Jazz")])
    let (runtime, id) = await metadataRuntime(plugin: TransliteratedCatalogFixture())
    let adapter = PluginMetadataProviderAdapter(pluginID: id, runtime: runtime)
    let query = MetadataEnrichmentQuery(itemID: itemID, title: "你好", artistName: "Artist", albumName: "Local Album", missingFields: [.year])
    let candidates = try await adapter.search(query)
    let candidate = try #require(candidates.first)
    #expect(candidate.artistName == "Artist")
    #expect(candidate.albumName == "Catalog Album")
    #expect(candidate.genreName == nil)
    #expect(MetadataEnrichmentMatcher.match(query: query, candidates: candidates) == .matched(candidate))
    let record = try await enrich(itemID: itemID, repository: repository, adapter: adapter)
    let updated = try #require(try await repository.track(id: itemID))
    #expect(updated.year == 2024)
    #expect(updated.title == "你好")
    #expect(updated.artistIDs == [artistID])
    #expect(updated.albumID == albumID)
    #expect(updated.genreIDs == [genreID])
    #expect(record.updatedFields == [.year])
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
