@testable import AppServices
import LibraryAPI
import MusicDomain
import MusicTestSupport
import SettingsAPI
import Testing

private func acceptedPrivacy(
    for providers: [LyricsProviderID]
) -> PrivacyPreferences {
    providers.reduce(PrivacyPreferences.defaults.acceptingPrivacyPolicy()) { privacy, provider in
        privacy.acceptingProviderPolicy(provider.rawValue)
    }
}

@Suite(.serialized)
struct LyricsCoordinatorTests {
    @Test("Lyrics coordinator persists lyrics without replacing existing metadata")
    func persistsLyricsWithoutReplacingMetadata() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "lyrics-persistence")
        let artistID = ArtistID(rawValue: "existing-artist")
        let albumID = AlbumID(rawValue: "existing-album")
        let genreID = GenreID(rawValue: "existing-genre")
        let track = Track(
            id: itemID,
            title: "Existing Title",
            albumID: albumID,
            artistIDs: [artistID],
            genreIDs: [genreID],
            trackNumber: 2,
            discNumber: 1,
            fileName: "existing.mp3",
            duration: .seconds(180),
            year: 2020,
            comment: "Existing comment"
        )
        let repository = InMemoryLibraryRepository(
            tracks: [track],
            albums: [Album(
                id: albumID,
                title: "Existing Album",
                artistIDs: [artistID],
                releaseYear: 2020
            )],
            artists: [Artist(id: artistID, name: "Existing Artist")],
            genres: [Genre(id: genreID, name: "Existing Genre")]
        )
        let lyrics = TrackLyrics(rawText: "[00:01.00]Online line")
        let provider = TestLyricsProvider(
            provider: .lrclib,
            result: lyrics
        )
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(
            providers: [provider],
            library: library
        )
        await coordinator.setPrivacyPreferences(acceptedPrivacy(for: [.lrclib]))
        await coordinator.setProviderPreferences([
            LyricsProviderPreference(provider: .lrclib, isEnabled: true)
        ])

        let result = try await coordinator.fetchLyrics(
            for: LyricsQuery(
                itemID: itemID,
                title: track.title,
                artistName: "Existing Artist",
                albumName: "Existing Album",
                durationSeconds: 180
            ),
            forceRefresh: false
        )
        let updated = try #require(result)
        let persisted = try #require(try await repository.track(id: itemID))

        #expect(updated == lyrics)
        #expect(persisted.lyrics == lyrics)
        #expect(persisted.title == "Existing Title")
        #expect(persisted.trackNumber == 2)
        #expect(persisted.discNumber == 1)
        #expect(persisted.year == 2020)
        #expect(persisted.comment == "Existing comment")
        let persistedAlbumID = try #require(persisted.albumID)
        let persistedAlbum = try #require(
            try await repository.album(id: persistedAlbumID)
        )
        #expect(persistedAlbum.title == "Existing Album")
        let persistedArtistID = try #require(persisted.artistIDs.first)
        let persistedArtist = try #require(
            try await repository.artist(id: persistedArtistID)
        )
        #expect(persistedArtist.name == "Existing Artist")
        let persistedGenreID = try #require(persisted.genreIDs.first)
        let persistedGenre = try #require(
            try await repository.genre(id: persistedGenreID)
        )
        #expect(persistedGenre.name == "Existing Genre")
        #expect(await provider.callCount == 1)
    }

    @Test("Lyrics coordinator uses local lyrics before contacting providers")
    func usesLocalLyricsBeforeProviders() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "lyrics-local-first")
        let localLyrics = TrackLyrics(rawText: "Local line")
        let track = Track(
            id: itemID,
            title: "Song",
            lyrics: localLyrics
        )
        let repository = InMemoryLibraryRepository(tracks: [track])
        let provider = TestLyricsProvider(
            provider: .lrclib,
            result: TrackLyrics(rawText: "Remote line")
        )
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(providers: [provider], library: library)

        let result = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song", artistName: "Artist"),
            forceRefresh: false
        )

        #expect(result == localLyrics)
        #expect(await provider.callCount == 0)
    }

    @Test("Lyrics coordinator tries providers in order until one returns lyrics")
    func triesProvidersInOrder() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "lyrics-provider-order")
        let repository = InMemoryLibraryRepository(tracks: [Track(id: itemID, title: "Song")])
        let first = TestLyricsProvider(
            provider: LyricsProviderID(rawValue: "first"),
            result: nil
        )
        let secondLyrics = TrackLyrics(rawText: "Second provider line")
        let second = TestLyricsProvider(
            provider: LyricsProviderID(rawValue: "second"),
            result: secondLyrics
        )
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(
            providers: [first, second],
            library: library
        )
        await coordinator.setPrivacyPreferences(
            acceptedPrivacy(for: [
                LyricsProviderID(rawValue: "first"),
                LyricsProviderID(rawValue: "second")
            ])
        )
        await coordinator.setProviderPreferences([
            LyricsProviderPreference(
                provider: LyricsProviderID(rawValue: "first"),
                isEnabled: true
            ),
            LyricsProviderPreference(
                provider: LyricsProviderID(rawValue: "second"),
                isEnabled: true
            )
        ])

        let result = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song", artistName: "Artist"),
            forceRefresh: true
        )

        #expect(result == secondLyrics)
        #expect(await first.callCount == 1)
        #expect(await second.callCount == 1)
        #expect(try await repository.track(id: itemID)?.lyrics == secondLyrics)
    }

    @Test("Lyrics coordinator skips disabled providers")
    func skipsDisabledProviders() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "lyrics-provider-disabled")
        let repository = InMemoryLibraryRepository(tracks: [Track(id: itemID, title: "Song")])
        let firstProviderID = LyricsProviderID(rawValue: "first-disabled")
        let first = TestLyricsProvider(
            provider: firstProviderID,
            result: TrackLyrics(rawText: "First provider line")
        )
        let secondLyrics = TrackLyrics(rawText: "Second provider line")
        let secondProviderID = LyricsProviderID(rawValue: "second-enabled")
        let second = TestLyricsProvider(
            provider: secondProviderID,
            result: secondLyrics
        )
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(
            providers: [first, second],
            library: library
        )

        await coordinator.setPrivacyPreferences(
            acceptedPrivacy(for: [firstProviderID, secondProviderID])
        )
        await coordinator.setProviderPreferences([
            LyricsProviderPreference(provider: firstProviderID, isEnabled: false),
            LyricsProviderPreference(provider: secondProviderID, isEnabled: true)
        ])
        let result = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song"),
            forceRefresh: true
        )

        #expect(result == secondLyrics)
        #expect(await first.callCount == 0)
        #expect(await second.callCount == 1)
    }

    @Test("Lyrics coordinator disables provider queries and preload")
    func disablesProviderQueriesAndPreload() async throws {
        let itemID = MediaItemID(sourceID: .local, externalID: "lyrics-disabled")
        let localLyrics = TrackLyrics(rawText: "Local line")
        let repository = InMemoryLibraryRepository(
            tracks: [Track(id: itemID, title: "Song", lyrics: localLyrics)]
        )
        let lyrics = TrackLyrics(rawText: "Online line")
        let provider = TestLyricsProvider(provider: .lrclib, result: lyrics)
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(providers: [provider], library: library)

        await coordinator.setPrivacyPreferences(acceptedPrivacy(for: [.lrclib]))
        #expect(await coordinator.registeredLyricsProviderIDs() == [.lrclib])
        await coordinator.setEnabled(false)
        let localResult = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song"),
            forceRefresh: false
        )
        let disabledResult = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song"),
            forceRefresh: true
        )
        await coordinator.startPreload()

        #expect(localResult == localLyrics)
        #expect(disabledResult == nil)
        #expect(await provider.callCount == 0)
        #expect((await coordinator.preloadSnapshot()).status == .idle)

        await coordinator.setEnabled(true)
        let enabledResult = try await coordinator.fetchLyrics(
            for: LyricsQuery(itemID: itemID, title: "Song"),
            forceRefresh: true
        )

        #expect(enabledResult == lyrics)
        #expect(await provider.callCount == 1)
    }

    @Test("Lyrics preload skips cached tracks and persists missing lyrics")
    func preloadsMissingLyrics() async throws {
        let cachedID = MediaItemID(sourceID: .local, externalID: "lyrics-preload-cached")
        let missingID = MediaItemID(sourceID: .local, externalID: "lyrics-preload-missing")
        let artistID = ArtistID(rawValue: "preload-artist")
        let albumID = AlbumID(rawValue: "preload-album")
        let cachedLyrics = TrackLyrics(rawText: "Cached line")
        let downloadedLyrics = TrackLyrics(rawText: "Downloaded line")
        let repository = InMemoryLibraryRepository(
            tracks: [
                Track(
                    id: cachedID,
                    title: "Cached Song",
                    albumID: albumID,
                    artistIDs: [artistID],
                    lyrics: cachedLyrics
                ),
                Track(
                    id: missingID,
                    title: "Missing Song",
                    albumID: albumID,
                    artistIDs: [artistID]
                ),
            ],
            albums: [Album(id: albumID, title: "Preload Album", artistIDs: [artistID])],
            artists: [Artist(id: artistID, name: "Preload Artist")]
        )
        let provider = TestLyricsProvider(
            provider: .lrclib,
            result: downloadedLyrics
        )
        let library = LibraryCoordinator(
            repository: repository,
            remover: nil,
            queueRepository: nil,
            historyRepository: nil
        )
        let coordinator = LyricsCoordinator(providers: [provider], library: library)
        await coordinator.setPrivacyPreferences(acceptedPrivacy(for: [.lrclib]))
        await coordinator.setProviderPreferences([
            LyricsProviderPreference(provider: .lrclib, isEnabled: true)
        ])

        await coordinator.startPreload()
        let starting = await coordinator.preloadSnapshot()
        #expect(starting.status == .downloading)
        await coordinator.waitForPreload()
        let final = await coordinator.preloadSnapshot()

        #expect(final.status == .completed)
        #expect(final.total == 2)
        #expect(final.processed == 2)
        #expect(final.cached == 1)
        #expect(final.downloaded == 1)
        #expect(final.noLyrics == 0)
        #expect(final.failed == 0)
        #expect(await provider.callCount == 1)
        #expect(try await repository.track(id: cachedID)?.lyrics == cachedLyrics)
        #expect(try await repository.track(id: missingID)?.lyrics == downloadedLyrics)
    }
}

private actor TestLyricsProvider: LyricsProviding {
    let provider: LyricsProviderID
    let result: TrackLyrics?
    private(set) var callCount = 0

    init(provider: LyricsProviderID, result: TrackLyrics?) {
        self.provider = provider
        self.result = result
    }

    func fetchLyrics(for _: LyricsQuery) async throws -> TrackLyrics? {
        callCount += 1
        return result
    }
}
