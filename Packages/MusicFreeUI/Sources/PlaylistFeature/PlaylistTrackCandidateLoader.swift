import AppServices
import Foundation
import LibraryAPI
import MusicDomain
import Observation

@MainActor
@Observable
final class PlaylistTrackCandidateLoader {
    private static let repeatedCursorMessage = "资料库分页游标重复，无法继续加载歌曲。"

    private let library: (any LibraryServing)?

    private(set) var candidates: [PlaylistTrackCandidate] = []
    private(set) var loadState: PlaylistFeatureLoadState = .idle
    private(set) var isLoading = false

    init(library: (any LibraryServing)?) {
        self.library = library
    }

    func load() async {
        guard let library, !isLoading else {
            return
        }

        isLoading = true
        if candidates.isEmpty {
            loadState = .loading
        }
        defer {
            isLoading = false
        }

        do {
            var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            var loadedTracks: [Track] = []
            var seen = Set<MediaItemID>()
            var seenCursors = Set<LibraryCursor>()

            while true {
                try Task.checkCancellation()
                let page = try await library.browseTracks(
                    matching: TrackQuery(),
                    page: request
                )
                try Task.checkCancellation()

                loadedTracks.append(contentsOf: page.elements.compactMap { track in
                    guard seen.insert(track.id).inserted else {
                        return nil
                    }
                    return track
                })

                guard let nextRequest = try page.nextPage(limit: request.limit) else {
                    break
                }
                guard let nextCursor = nextRequest.cursor,
                      seenCursors.insert(nextCursor).inserted
                else {
                    loadState = .failed(Self.repeatedCursorMessage)
                    return
                }
                request = nextRequest
            }

            var artistNames: [ArtistID: String] = [:]
            do {
                artistNames = try await Self.loadArtistNames(
                    artistIDs: Set(loadedTracks.flatMap(\.artistIDs)),
                    from: library
                )
            } catch let error where playlistFeatureIsCancellation(error) {
                throw error
            } catch {
                // Track availability and playlist mutations must not depend on
                // optional relationship metadata being readable.
            }

            let loadedCandidates = loadedTracks.map {
                Self.candidate(for: $0, artistNames: artistNames)
            }
            candidates = loadedCandidates
            loadState = loadedCandidates.isEmpty ? .empty : .loaded
        } catch let error where playlistFeatureIsCancellation(error) {
            loadState = candidates.isEmpty ? .idle : .loaded
        } catch {
            loadState = .failed(playlistFeatureMessage(for: error))
        }
    }

    private static func candidate(
        for track: Track,
        artistNames: [ArtistID: String]
    ) -> PlaylistTrackCandidate {
        let names = track.artistIDs.compactMap { artistNames[$0] }
        return PlaylistTrackCandidate(
            id: track.id,
            title: track.title,
            subtitle: names.isEmpty ? nil : names.joined(separator: "、")
        )
    }

    private static func loadArtistNames(
        artistIDs: Set<ArtistID>,
        from library: any LibraryServing
    ) async throws -> [ArtistID: String] {
        guard !artistIDs.isEmpty else { return [:] }

        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var names: [ArtistID: String] = [:]
        var seenCursors = Set<LibraryCursor>()

        while names.count < artistIDs.count {
            try Task.checkCancellation()
            let page = try await library.browseArtists(
                matching: ArtistQuery(),
                page: request
            )
            try Task.checkCancellation()

            for artist in page.elements where artistIDs.contains(artist.id) {
                names[artist.id] = artist.name
            }

            guard names.count < artistIDs.count,
                  let nextRequest = try page.nextPage(limit: request.limit)
            else { break }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryError.query(.invalidCursor)
            }
            request = nextRequest
        }

        return names
    }
}
