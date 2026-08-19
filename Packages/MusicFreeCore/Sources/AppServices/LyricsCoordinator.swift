import Foundation
import LibraryAPI
import MusicDomain
import OSLog

/// Coordinates the ordered lyrics provider chain and keeps successful results
/// in the library. A local result always wins unless the caller explicitly
/// asks for a refresh.
internal actor LyricsCoordinator: LyricsServing {
    private let providers: [any LyricsProviding]
    private let library: any LibraryServing
    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "lyrics-preload"
    )

    private var preload = LyricsPreloadSnapshot()
    private var preloadContinuations: [UUID: AsyncStream<LyricsPreloadSnapshot>.Continuation] = [:]
    private var preloadTask: Task<Void, Never>?

    init(
        providers: [any LyricsProviding],
        library: any LibraryServing
    ) {
        self.providers = providers
        self.library = library
    }

    func fetchLyrics(
        for query: LyricsQuery,
        forceRefresh: Bool
    ) async throws -> TrackLyrics? {
        guard !providers.isEmpty else { return nil }
        guard let currentTrack = try await library.track(id: query.itemID) else {
            return nil
        }
        if !forceRefresh, let localLyrics = currentTrack.lyrics {
            return localLyrics
        }

        var lastError: Error?
        for provider in providers {
            try Task.checkCancellation()
            do {
                guard let lyrics = try await provider.fetchLyrics(for: query),
                      !lyrics.isEmpty
                else {
                    continue
                }
                let updated = try await library.supplementMetadata(
                    TrackMetadataSupplement(
                        itemID: query.itemID,
                        lyrics: lyrics
                    )
                )
                return updated.lyrics ?? lyrics
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        return nil
    }

    func preloadSnapshot() async -> LyricsPreloadSnapshot {
        preload
    }

    func makePreloadSnapshotStream() async -> AsyncStream<LyricsPreloadSnapshot> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<LyricsPreloadSnapshot>.makeStream()
        preloadContinuations[subscriptionID] = continuation
        continuation.yield(preload)
        Self.logger.debug(
            "preload snapshot subscriber connected id=\(subscriptionID.uuidString, privacy: .public) subscribers=\(self.preloadContinuations.count, privacy: .public)"
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removePreloadSubscription(subscriptionID) }
        }
        return stream
    }

    func startPreload() async {
        guard preloadTask == nil else {
            Self.logger.debug("preload request ignored reason=already_running")
            return
        }

        preload = LyricsPreloadSnapshot(status: .downloading)
        publishPreload()
        Self.logger.info("preload requested")

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performPreload()
        }
        preloadTask = task
    }

    /// Waits for the current preload operation without changing its lifecycle.
    /// This is intentionally internal so tests can synchronize with the
    /// unstructured task while the public service remains fire-and-observe.
    func waitForPreload() async {
        await preloadTask?.value
    }

    func cancelPreload() async {
        guard let task = preloadTask else {
            Self.logger.debug(
                "preload cancel ignored status=\(self.preload.status.rawValue, privacy: .public)"
            )
            return
        }

        task.cancel()
        if preload.status == .downloading {
            preload = LyricsPreloadSnapshot(
                status: .cancelled,
                total: preload.total,
                processed: preload.processed,
                downloaded: preload.downloaded,
                cached: preload.cached,
                noLyrics: preload.noLyrics,
                failed: preload.failed
            )
            publishPreload()
        }
        await task.value
        Self.logger.info(
            "preload cancel completed status=\(self.preload.status.rawValue, privacy: .public) processed=\(self.preload.processed, privacy: .public)/\(self.preload.total, privacy: .public)"
        )
    }

    private func performPreload() async {
        let startedAt = Date()
        do {
            let tracks = try await loadLocalTracks()
            preload = LyricsPreloadSnapshot(
                status: .downloading,
                total: tracks.count
            )
            publishPreload()
            Self.logger.info("preload library loaded tracks=\(tracks.count, privacy: .public)")

            guard tracks.contains(where: { $0.lyrics == nil }) else {
                preload = LyricsPreloadSnapshot(
                    status: .completed,
                    total: tracks.count,
                    processed: tracks.count,
                    cached: tracks.count
                )
                return finishPreload(startedAt: startedAt)
            }

            let artistNames = try await loadArtistNames()
            let albumNames = try await loadAlbumNames()
            var downloaded = 0
            var cached = 0
            var noLyrics = 0
            var failed = 0

            for track in tracks {
                try Task.checkCancellation()
                preload = LyricsPreloadSnapshot(
                    status: .downloading,
                    total: tracks.count,
                    processed: preload.processed,
                    downloaded: downloaded,
                    cached: cached,
                    noLyrics: noLyrics,
                    failed: failed,
                    currentTitle: track.title
                )
                publishPreload()

                if track.lyrics != nil {
                    cached += 1
                } else {
                    do {
                        let result = try await fetchLyrics(
                            for: makeQuery(
                                for: track,
                                artistNames: artistNames,
                                albumNames: albumNames
                            ),
                            forceRefresh: false
                        )
                        if result == nil {
                            noLyrics += 1
                        } else {
                            downloaded += 1
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failed += 1
                        Self.logger.error(
                            "preload track failed item=\(track.id.externalID, privacy: .public) code=\(Self.errorCode(error), privacy: .public)"
                        )
                    }
                }

                preload = LyricsPreloadSnapshot(
                    status: .downloading,
                    total: tracks.count,
                    processed: preload.processed + 1,
                    downloaded: downloaded,
                    cached: cached,
                    noLyrics: noLyrics,
                    failed: failed
                )
                publishPreload()
            }

            preload = LyricsPreloadSnapshot(
                status: .completed,
                total: tracks.count,
                processed: preload.processed,
                downloaded: downloaded,
                cached: cached,
                noLyrics: noLyrics,
                failed: failed
            )
            finishPreload(startedAt: startedAt)
        } catch is CancellationError {
            preload = LyricsPreloadSnapshot(
                status: .cancelled,
                total: preload.total,
                processed: preload.processed,
                downloaded: preload.downloaded,
                cached: preload.cached,
                noLyrics: preload.noLyrics,
                failed: preload.failed
            )
            finishPreload(startedAt: startedAt)
        } catch {
            preload = LyricsPreloadSnapshot(
                status: .failed,
                total: preload.total,
                processed: preload.processed,
                downloaded: preload.downloaded,
                cached: preload.cached,
                noLyrics: preload.noLyrics,
                failed: preload.failed,
                errorCode: Self.errorCode(error)
            )
            finishPreload(startedAt: startedAt)
        }
    }

    private func finishPreload(startedAt: Date) {
        preloadTask = nil
        publishPreload()
        Self.logger.info(
            "preload finished status=\(self.preload.status.rawValue, privacy: .public) processed=\(self.preload.processed, privacy: .public)/\(self.preload.total, privacy: .public) downloaded=\(self.preload.downloaded, privacy: .public) cached=\(self.preload.cached, privacy: .public) noLyrics=\(self.preload.noLyrics, privacy: .public) failed=\(self.preload.failed, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)"
        )
    }

    private func loadLocalTracks() async throws -> [Track] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var tracks: [Track] = []

        while true {
            try Task.checkCancellation()
            let page = try await library.browseTracks(
                matching: TrackQuery(sourceID: .local),
                page: request
            )
            tracks.append(contentsOf: page.elements)
            guard let nextPage = try page.nextPage(
                limit: LibraryPageRequest.maximumLimit
            ) else {
                return tracks
            }
            request = nextPage
        }
    }

    private func loadArtistNames() async throws -> [ArtistID: String] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var names: [ArtistID: String] = [:]

        while true {
            try Task.checkCancellation()
            let page = try await library.browseArtists(
                matching: ArtistQuery(sourceID: .local),
                page: request
            )
            for artist in page.elements {
                names[artist.id] = artist.name
            }
            guard let nextPage = try page.nextPage(
                limit: LibraryPageRequest.maximumLimit
            ) else {
                return names
            }
            request = nextPage
        }
    }

    private func loadAlbumNames() async throws -> [AlbumID: String] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var names: [AlbumID: String] = [:]

        while true {
            try Task.checkCancellation()
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: .local),
                page: request
            )
            for album in page.elements {
                names[album.id] = album.title
            }
            guard let nextPage = try page.nextPage(
                limit: LibraryPageRequest.maximumLimit
            ) else {
                return names
            }
            request = nextPage
        }
    }

    private func makeQuery(
        for track: Track,
        artistNames: [ArtistID: String],
        albumNames: [AlbumID: String]
    ) -> LyricsQuery {
        let durationSeconds: TimeInterval?
        if let duration = track.duration {
            let components = duration.components
            durationSeconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
        } else {
            durationSeconds = nil
        }
        let artistName = track.artistIDs
            .compactMap { artistNames[$0] }
            .joined(separator: ", ")
        let albumName = track.albumID.flatMap { albumNames[$0] }
        return LyricsQuery(
            itemID: track.id,
            title: track.title,
            artistName: artistName,
            albumName: albumName,
            durationSeconds: durationSeconds
        )
    }

    private func publishPreload() {
        let value = preload
        for continuation in preloadContinuations.values {
            continuation.yield(value)
        }
    }

    private func removePreloadSubscription(_ id: UUID) {
        preloadContinuations.removeValue(forKey: id)
        Self.logger.debug(
            "preload snapshot subscriber disconnected id=\(id.uuidString, privacy: .public) subscribers=\(self.preloadContinuations.count, privacy: .public)"
        )
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? LyricsProviderError {
            switch error {
            case .unavailable: return "provider_unavailable"
            case .noMatch: return "no_match"
            case .network: return "network"
            case let .requestFailed(code, _): return code
            case .invalidResponse: return "invalid_response"
            case .payloadTooLarge: return "payload_too_large"
            }
        }
        return "lyrics_preload_failed"
    }
}
