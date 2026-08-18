import Foundation
import AppServices
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import SettingsAPI
import Testing

private actor TestMetadataProvider: MetadataEnrichmentProviding {
    let provider: MetadataEnrichmentProvider = .musicKit
    private(set) var searchCount = 0
    var authorization: MetadataEnrichmentAuthorizationStatus = .authorized
    private var searchResults: [[MetadataEnrichmentCandidate]]

    init(candidate: MetadataEnrichmentCandidate) {
        self.searchResults = [[candidate]]
    }

    init(searchResults: [[MetadataEnrichmentCandidate]]) {
        self.searchResults = searchResults
    }

    func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
        authorization
    }

    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        authorization
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
    private var values: [MediaItemID: MetadataEnrichmentRecord] = [:]

    func record(for itemID: MediaItemID) async throws -> MetadataEnrichmentRecord? {
        values[itemID]
    }

    func records() async throws -> [MetadataEnrichmentRecord] {
        values.values.sorted { $0.itemID < $1.itemID }
    }

    func save(_ record: MetadataEnrichmentRecord) async throws {
        values[record.itemID] = record
    }

    func remove(itemID: MediaItemID) async throws {
        values.removeValue(forKey: itemID)
    }
}

private actor TestArtworkWriter {
    private(set) var values: [Data] = []

    func write(_ data: Data) {
        values.append(data)
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
