import Foundation
import AppServices
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import SettingsAPI
import Testing

private actor TestMetadataProvider: MetadataEnrichmentProviding {
    let provider: MetadataEnrichmentProvider
    private(set) var searchCount = 0
    var authorization: MetadataEnrichmentAuthorizationStatus = .authorized
    private var searchResults: [[MetadataEnrichmentCandidate]]

    init(
        provider: MetadataEnrichmentProvider = .musicKit,
        candidate: MetadataEnrichmentCandidate
    ) {
        self.provider = provider
        self.searchResults = [[candidate]]
    }

    init(
        provider: MetadataEnrichmentProvider = .musicKit,
        searchResults: [[MetadataEnrichmentCandidate]]
    ) {
        self.provider = provider
        self.searchResults = searchResults
    }

    func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
        authorization
    }

    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        authorization
    }

    func setAuthorization(_ status: MetadataEnrichmentAuthorizationStatus) {
        authorization = status
    }

    func search(
        _: MetadataEnrichmentQuery
    ) async throws -> [MetadataEnrichmentCandidate] {
        let index = min(searchCount, max(0, searchResults.count - 1))
        searchCount += 1
        return searchResults.isEmpty ? [] : searchResults[index]
    }

    func artworkData(
        for candidate: MetadataEnrichmentCandidate
    ) async throws -> Data? {
        candidate.artworkData
    }
}

private actor TestMetadataRecordRepository: MetadataEnrichmentRecordRepository {
    private struct Key: Hashable {
        let itemID: MediaItemID
        let provider: MetadataProviderID
    }

    private var values: [Key: MetadataEnrichmentRecord] = [:]

    func record(for itemID: MediaItemID) async throws -> MetadataEnrichmentRecord? {
        values.values
            .filter { $0.itemID == itemID }
            .sorted { $0.provider < $1.provider }
            .first
    }

    func record(
        for itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws -> MetadataEnrichmentRecord? {
        values[Key(itemID: itemID, provider: provider)]
    }

    func records() async throws -> [MetadataEnrichmentRecord] {
        values.values.sorted {
            if $0.itemID != $1.itemID { return $0.itemID < $1.itemID }
            return $0.provider < $1.provider
        }
    }

    func records(for provider: MetadataProviderID) async throws -> [MetadataEnrichmentRecord] {
        values.values.filter { $0.provider == provider }
    }

    func save(_ record: MetadataEnrichmentRecord) async throws {
        values[Key(itemID: record.itemID, provider: record.provider)] = record
    }

    func remove(itemID: MediaItemID) async throws {
        values = values.filter { $0.value.itemID != itemID }
    }

    func remove(
        itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws {
        values.removeValue(forKey: Key(itemID: itemID, provider: provider))
    }
}

private actor TestArtworkWriter {
    private(set) var values: [Data] = []

    func write(_ data: Data) {
        values.append(data)
    }
}

@MainActor
@Test("App dependencies reject duplicate metadata provider IDs")
func appDependenciesRejectDuplicateMetadataProviders() {
    let first = TestMetadataProvider(candidate: MetadataEnrichmentCandidate(
        catalogID: "first",
        title: "Song"
    ))
    let second = TestMetadataProvider(candidate: MetadataEnrichmentCandidate(
        catalogID: "second",
        title: "Song"
    ))

    #expect(throws: AppServiceError.self) {
        try AppDependencies(metadataEnrichmentProviders: [first, second])
    }
}

@Test("Filename fallback can match a title-only catalog result")
func metadataEnrichmentFilenameFallbackMatchesTitleOnly() {
    let itemID = MediaItemID(sourceID: .local, externalID: "filename-match")
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: "01 - Artist - Song",
        fileName: "01 - Artist - Song.mp3",
        isFilenameFallback: true
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "song-1",
        title: "Song"
    )

    #expect(query.searchTerm == "Artist Song")
    #expect(query.filenameTitle == "Song")
    #expect(query.filenameArtist == "Artist")
    #expect(MetadataEnrichmentMatcher.match(query: query, candidates: [candidate]) == .matched(candidate))
}

@Test("Metadata search terms are ordered from specific to tolerant")
func metadataEnrichmentSearchTermsAreOrdered() {
    let query = MetadataEnrichmentQuery(
        itemID: MediaItemID(sourceID: .local, externalID: "search-terms"),
        title: "千古一爱(电视剧《康熙大帝》片尾曲)",
        artistName: "毛阿敏",
        albumName: "康熙大帝 电视剧原声带"
    )

    #expect(query.searchTerms == [
        "千古一爱(电视剧《康熙大帝》片尾曲) 毛阿敏",
        "千古一爱 毛阿敏",
        "千古一爱(电视剧《康熙大帝》片尾曲) 康熙大帝 电视剧原声带",
        "千古一爱(电视剧《康熙大帝》片尾曲)",
        "千古一爱"
    ])
}

@Test("Filename terms do not override an explicit local title")
func metadataEnrichmentDoesNotUseFilenameForExplicitTitles() {
    let itemID = MediaItemID(sourceID: .local, externalID: "explicit-title")
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: "User Edited Title",
        fileName: "Other Artist - Song.mp3",
        isFilenameFallback: false
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "filename-only-match",
        title: "Song"
    )

    #expect(MetadataEnrichmentMatcher.match(query: query, candidates: [candidate]) == .noMatch)
}

@Test("Filename fallback rejects a same-title candidate from another artist")
func metadataEnrichmentFilenameFallbackChecksFilenameArtist() {
    let itemID = MediaItemID(sourceID: .local, externalID: "filename-artist-mismatch")
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: "01 - Artist - Song",
        fileName: "01 - Artist - Song.mp3",
        isFilenameFallback: true
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "wrong-artist-song",
        title: "Song",
        artistName: "Different Singer"
    )

    #expect(MetadataEnrichmentMatcher.match(query: query, candidates: [candidate]) == .noMatch)
}

@Test("Metadata matching tolerates catalog title suffixes and artist transliteration")
func metadataEnrichmentMatchesCatalogVersionWithTransliteratedArtist() {
    let itemID = MediaItemID(sourceID: .local, externalID: "catalog-version")
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: "爱恨情仇命里去",
        artistName: "赵季平",
        albumName: "杨佩佩精装大戏主题曲II",
        durationSeconds: 345.907,
        missingFields: [.albumArtist, .genre, .trackNumber, .discNumber]
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "1478866053",
        title: "爱恨情仇命里去 (From \"倚天屠龍記\") [Instrumental Version]",
        artistName: "Zhao Jiping",
        albumArtistName: "Zhao Jiping",
        albumName: "Compilation of Yang Pei Pei's TV Series Soundtracks II",
        trackNumber: 13,
        discNumber: 1,
        year: 1994,
        durationSeconds: 345.834
    )

    #expect(
        MetadataEnrichmentMatcher.match(query: query, candidates: [candidate])
            == .matched(candidate)
    )
}

@Test("Metadata matching tolerates a transliterated catalog title")
func metadataEnrichmentMatchesTransliteratedTitleAndArtist() {
    let itemID = MediaItemID(sourceID: .local, externalID: "transliterated-title")
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: "梦驼铃",
        artistName: "费玉清",
        durationSeconds: 182,
        missingFields: [.albumArtist, .genre]
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "transliterated-song",
        title: "Meng Tuo Ling",
        artistName: "Fei Yuqing",
        durationSeconds: 181.8
    )

    #expect(
        MetadataEnrichmentMatcher.match(query: query, candidates: [candidate])
            == .matched(candidate)
    )
}

@MainActor
@Test("Metadata enrichment supplements imported metadata without replacing existing values")
func metadataEnrichmentSupplementsImportedMetadata() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "enrichment-track")
    let track = Track(
        id: itemID,
        title: "01 - Artist - Song",
        fileName: "01 - Artist - Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let provider = TestMetadataProvider(candidate: MetadataEnrichmentCandidate(
        catalogID: "catalog-song",
        title: "Song",
        artistName: "Artist",
        albumArtistName: "Artist",
        albumName: "Album",
        genreName: "Pop",
        trackNumber: 2,
        discNumber: 1,
        year: 2024
    ))
    let records = TestMetadataRecordRepository()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProvider: provider,
        metadataEnrichmentRecordRepository: records
    ))

    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)

    var updated: Track?
    for _ in 0..<50 {
        updated = try await repository.track(id: itemID)
        if updated?.title == "Song" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let finalTrack = try #require(updated)
    #expect(await provider.searchCount == 1)
    #expect(finalTrack.title == "Song")
    #expect(finalTrack.artistIDs.count == 1)
    #expect(finalTrack.albumID != nil)
    #expect(finalTrack.genreIDs.count == 1)
    #expect(finalTrack.trackNumber == 2)
    #expect(finalTrack.year == 2024)

    await container.metadataEnrichmentServing.setEnabled(false)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await provider.searchCount == 1)
}

@MainActor
@Test("Metadata enrichment persists a downloaded cover on the track and album")
func metadataEnrichmentPersistsArtwork() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "enrichment-artwork")
    let artworkData = Data([0x01, 0x02, 0x03, 0x04])
    let track = Track(
        id: itemID,
        title: "Artwork Song",
        fileName: "Artwork Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let provider = TestMetadataProvider(candidate: MetadataEnrichmentCandidate(
        catalogID: "catalog-artwork-song",
        title: "Artwork Song",
        artistName: "Artist",
        albumArtistName: "Artist",
        albumName: "Artwork Album",
        artworkData: artworkData
    ))
    let records = TestMetadataRecordRepository()
    let artworkWriter = TestArtworkWriter()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        artworkWriter: { data, _ in
            await artworkWriter.write(data)
            return ArtworkWriteReceipt(wasCreated: true)
        },
        libraryRepository: repository,
        metadataEnrichmentProvider: provider,
        metadataEnrichmentRecordRepository: records
    ))

    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.startScan()

    var updated: Track?
    for _ in 0..<50 {
        updated = try await repository.track(id: itemID)
        if updated?.artwork != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    let finalTrack = try #require(updated)
    let albumID = try #require(finalTrack.albumID)
    let finalAlbum = try #require(try await repository.album(id: albumID))
    let artworkID = ArtworkID(
        rawValue: "sha256-\(MusicContentIdentity.sha256Hex(artworkData))"
    )
    #expect(finalTrack.artwork?.id == artworkID)
    #expect(finalAlbum.artwork?.id == artworkID)
    #expect(await artworkWriter.values == [artworkData])

    let record = try #require(try await records.record(for: itemID))
    #expect(record.candidateCount == 1)
    #expect(record.updatedFields.contains(.artwork))
    #expect(record.lastErrorCode == nil)
}

@MainActor
@Test("A manual scan retries a previous no-match after matcher changes")
func metadataEnrichmentManualScanRetriesNoMatch() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "retry-no-match")
    let track = Track(
        id: itemID,
        title: "Retry Song",
        fileName: "Retry Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "retry-catalog-song",
        title: "Retry Song",
        artistName: "Artist",
        albumArtistName: "Artist",
        albumName: "Album"
    )
    let provider = TestMetadataProvider(searchResults: [[], [candidate]])
    let records = TestMetadataRecordRepository()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProvider: provider,
        metadataEnrichmentRecordRepository: records
    ))

    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.startScan()
    for _ in 0..<50 {
        if (await container.metadataEnrichmentServing.snapshot()).scan.status == .completed {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((try await records.record(for: itemID))?.status == .noMatch)

    await container.metadataEnrichmentServing.startScan()
    for _ in 0..<50 {
        if (await container.metadataEnrichmentServing.snapshot()).scan.status == .completed {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await provider.searchCount == 2)
    #expect((try await repository.track(id: itemID))?.artistIDs.count == 1)
    #expect((try await records.record(for: itemID))?.status == .matched)
}

@MainActor
@Test("A manual scan retries a previously exhausted provider failure")
func metadataEnrichmentManualScanRetriesExhaustedFailure() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "retry-failed")
    let track = Track(
        id: itemID,
        title: "Retry Failed Song",
        fileName: "Retry Failed Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "retry-failed-catalog-song",
        title: "Retry Failed Song",
        artistName: "Artist",
        albumArtistName: "Artist",
        albumName: "Album"
    )
    let provider = TestMetadataProvider(candidate: candidate)
    let records = TestMetadataRecordRepository()
    let query = MetadataEnrichmentQuery(
        itemID: itemID,
        title: track.title,
        fileName: track.fileName,
        durationSeconds: 180,
        missingFields: Set(MetadataEnrichmentField.allCases),
        isFilenameFallback: true
    )
    try await records.save(
        MetadataEnrichmentRecord(
            itemID: itemID,
            queryFingerprint: query.fingerprint,
            status: .failed,
            attemptCount: 3,
            nextRetryAt: Date().addingTimeInterval(3_600),
            lastErrorCode: "metadata_track_http_503",
            lastHTTPStatus: 503
        )
    )
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProvider: provider,
        metadataEnrichmentRecordRepository: records
    ))

    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.startScan()
    for _ in 0..<50 {
        if (await container.metadataEnrichmentServing.snapshot()).scan.status == .completed {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await provider.searchCount == 1)
    let record = try #require(try await records.record(for: itemID))
    #expect(record.status == .matched)
    #expect(record.attemptCount == 1)
}

@MainActor
@Test("Metadata enrichment falls back through enabled providers in order")
func metadataEnrichmentFallsBackThroughProviderOrder() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "provider-fallback")
    let track = Track(
        id: itemID,
        title: "Fallback Song",
        fileName: "Fallback Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let first = TestMetadataProvider(
        provider: .musicKit,
        searchResults: [[]]
    )
    let candidate = MetadataEnrichmentCandidate(
        catalogID: "server-fallback-song",
        title: "Fallback Song",
        artistName: "Fallback Artist",
        albumName: "Fallback Album"
    )
    let second = TestMetadataProvider(
        provider: .metadataServer,
        candidate: candidate
    )
    let records = TestMetadataRecordRepository()
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProviders: [first, second],
        metadataEnrichmentRecordRepository: records
    ))

    await container.metadataEnrichmentServing.setProviderPreferences([
        MetadataProviderPreference(provider: .musicKit, isEnabled: true),
        MetadataProviderPreference(provider: .metadataServer, isEnabled: true)
    ])
    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)

    for _ in 0..<50 {
        if (try await repository.track(id: itemID))?.artistIDs.count == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await first.searchCount == 1)
    #expect(await second.searchCount == 1)
    #expect((try await records.record(
        for: itemID,
        provider: .musicKit
    ))?.status == .noMatch)
    #expect((try await records.record(
        for: itemID,
        provider: .metadataServer
    ))?.status == .matched)
}

@MainActor
@Test("Metadata enrichment stops after the first provider matches")
func metadataEnrichmentStopsAfterProviderMatch() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "provider-stop")
    let track = Track(
        id: itemID,
        title: "Primary Song",
        fileName: "Primary Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let first = TestMetadataProvider(
        provider: .musicKit,
        candidate: MetadataEnrichmentCandidate(
            catalogID: "primary-song",
            title: "Primary Song",
            artistName: "Primary Artist"
        )
    )
    let second = TestMetadataProvider(
        provider: .metadataServer,
        candidate: MetadataEnrichmentCandidate(
            catalogID: "secondary-song",
            title: "Primary Song",
            artistName: "Secondary Artist"
        )
    )
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProviders: [first, second]
    ))

    await container.metadataEnrichmentServing.setProviderPreferences([
        MetadataProviderPreference(provider: .musicKit, isEnabled: true),
        MetadataProviderPreference(provider: .metadataServer, isEnabled: true)
    ])
    await container.metadataEnrichmentServing.setEnabled(true)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)

    for _ in 0..<50 {
        if await first.searchCount == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await first.searchCount == 1)
    #expect(await second.searchCount == 0)
}

@MainActor
@Test("An unregistered enabled provider does not block a registered provider")
func metadataEnrichmentIgnoresUnregisteredProvider() async throws {
    let itemID = MediaItemID(sourceID: .local, externalID: "provider-unregistered")
    let track = Track(
        id: itemID,
        title: "Registered Song",
        fileName: "Registered Song.mp3",
        duration: .seconds(180)
    )
    let repository = InMemoryLibraryRepository(tracks: [track])
    let provider = TestMetadataProvider(candidate: MetadataEnrichmentCandidate(
        catalogID: "registered-song",
        title: "Registered Song",
        artistName: "Artist"
    ))
    let container = try AppServiceContainer(dependencies: AppDependencies(
        libraryRepository: repository,
        metadataEnrichmentProvider: provider
    ))

    await container.metadataEnrichmentServing.setProviderPreferences([
        MetadataProviderPreference(provider: .metadataServer, isEnabled: true),
        MetadataProviderPreference(provider: .musicKit, isEnabled: true)
    ])
    await container.metadataEnrichmentServing.setEnabled(true)
    let snapshot = await container.metadataEnrichmentServing.snapshot()
    #expect(snapshot.isEnabled)
    #expect(snapshot.status(for: .metadataServer)?.isRegistered == false)
    await container.metadataEnrichmentServing.enqueue(itemID: itemID)

    for _ in 0..<50 {
        if (try await repository.track(id: itemID))?.artistIDs.count == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await provider.searchCount == 1)
}

@MainActor
@Test("Authorizing one provider does not hide another active provider")
func metadataEnrichmentKeepsActiveAuthorizationWhenAnotherProviderIsDenied() async throws {
    let primary = TestMetadataProvider(
        provider: .musicKit,
        candidate: MetadataEnrichmentCandidate(catalogID: "primary", title: "Song")
    )
    let secondary = TestMetadataProvider(
        provider: .metadataServer,
        candidate: MetadataEnrichmentCandidate(catalogID: "secondary", title: "Song")
    )
    await secondary.setAuthorization(.denied)
    let container = try AppServiceContainer(dependencies: AppDependencies(
        metadataEnrichmentProviders: [primary, secondary]
    ))

    await container.metadataEnrichmentServing.setProviderPreferences([
        MetadataProviderPreference(provider: .musicKit, isEnabled: true),
        MetadataProviderPreference(provider: .metadataServer, isEnabled: true)
    ])
    await container.metadataEnrichmentServing.setEnabled(true)

    let requested = await container.metadataEnrichmentServing.requestAuthorization(
        for: .metadataServer
    )
    let snapshot = await container.metadataEnrichmentServing.snapshot()

    #expect(requested == .denied)
    #expect(snapshot.activeProvider == .musicKit)
    #expect(snapshot.authorization == .authorized)
    #expect(snapshot.isEnabled)
}
