import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain

enum LibraryCollectionQueueTarget: Hashable, Sendable {
    case album(AlbumID)
    case albums([AlbumID])
    case noAlbum
    case artist(ArtistID)
    case genre(GenreID)
    case folder(String)

    fileprivate var query: TrackQuery {
        switch self {
        case .album(let albumID):
            return TrackQuery(sourceID: .local, albumID: albumID)
        case .albums, .noAlbum, .folder:
            return TrackQuery(sourceID: .local)
        case .artist(let artistID):
            return TrackQuery(sourceID: .local, artistID: artistID)
        case .genre(let genreID):
            return TrackQuery(sourceID: .local, genreID: genreID)
        }
    }

    fileprivate func includes(_ track: Track) -> Bool {
        switch self {
        case .folder(let path):
            return track.folderPath == path
        case .noAlbum:
            return track.albumID == nil
        case .albums(let albumIDs):
            return track.albumID.map(albumIDs.contains) == true
        case .album, .artist, .genre:
            return true
        }
    }

    fileprivate func ordered(_ tracks: [Track]) -> [Track] {
        switch self {
        case .album, .albums:
            return LibraryAlbumTrackOrdering.ordered(tracks)
        case .noAlbum, .artist, .genre, .folder:
            return tracks
        }
    }

    fileprivate var accessibilityValue: String {
        switch self {
        case .album(let albumID): return "album.\(albumID.rawValue)"
        case .albums(let albumIDs): return "albums.\(albumIDs.map(\.rawValue).joined(separator: ","))"
        case .noAlbum: return "noAlbum"
        case .artist(let artistID): return "artist.\(artistID.rawValue)"
        case .genre(let genreID): return "genre.\(genreID.rawValue)"
        case .folder(let path): return "folder.\(path)"
        }
    }
}

enum LibraryCollectionQueuePlacement: Equatable, Sendable {
    case next
    case end
}

enum LibraryCollectionTrackLoader {
    static func tracks(
        for target: LibraryCollectionQueueTarget,
        from library: any LibraryServing
    ) async throws -> [Track] {
        let tracks: [Track]
        if case .noAlbum = target {
            tracks = try await noAlbumContent(from: library).tracks
        } else {
            tracks = try await loadTracks(matching: target.query, from: library)
                .filter(target.includes)
        }

        var seenIDs = Set<MediaItemID>()
        return target.ordered(tracks).filter { track in
            seenIDs.insert(track.id).inserted
        }
    }

    static func noAlbumContent(
        from library: any LibraryServing
    ) async throws -> (tracks: [Track], knownAlbumIDs: Set<AlbumID>) {
        async let allTracks = loadAllTracks(from: library)
        async let allAlbums = loadAllAlbums(from: library)
        let (tracks, albums) = try await (allTracks, allAlbums)
        let knownAlbumIDs = Set(albums.map(\.id))
        let noAlbumTracks = tracks.filter { track in
            guard let albumID = track.albumID else { return true }
            return !knownAlbumIDs.contains(albumID)
        }
        return (noAlbumTracks, knownAlbumIDs)
    }

    private static func loadTracks(
        matching query: TrackQuery,
        from library: any LibraryServing
    ) async throws -> [Track] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var seenCursors = Set<LibraryCursor>()
        var tracks: [Track] = []

        while true {
            try Task.checkCancellation()
            let page = try await library.browseTracks(matching: query, page: request)
            try Task.checkCancellation()
            tracks.append(contentsOf: page.elements)

            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                break
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryCollectionQueueLoadError.repeatedCursor
            }
            request = nextRequest
        }
        return tracks
    }

    private static func loadAllTracks(from library: any LibraryServing) async throws -> [Track] {
        try await loadTracks(matching: TrackQuery(sourceID: .local), from: library)
    }

    private static func loadAllAlbums(from library: any LibraryServing) async throws -> [Album] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var seenCursors = Set<LibraryCursor>()
        var albums: [Album] = []

        while true {
            try Task.checkCancellation()
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: .local),
                page: request
            )
            try Task.checkCancellation()
            albums.append(contentsOf: page.elements)

            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                break
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryCollectionQueueLoadError.repeatedCursor
            }
            request = nextRequest
        }
        return albums
    }

    static func itemIDs(
        for target: LibraryCollectionQueueTarget,
        from library: any LibraryServing
    ) async throws -> [MediaItemID] {
        try await tracks(for: target, from: library).map(\.id)
    }

    static func itemIDs(
        for targets: Set<LibraryCollectionQueueTarget>,
        from library: any LibraryServing
    ) async throws -> Set<MediaItemID> {
        var collectedIDs = Set<MediaItemID>()
        for target in targets {
            collectedIDs.formUnion(try await Self.itemIDs(for: target, from: library))
        }
        return collectedIDs
    }
}

private enum LibraryCollectionQueueLoadError: LocalizedError {
    case repeatedCursor

    var errorDescription: String? {
        L("集合歌曲分页状态无效，请刷新资料库后重试。")
    }
}
