import AppServices
import LibraryAPI
import MusicDomain

enum LibraryAlbumLoader {
    static func load(
        albumIDs: Set<AlbumID>,
        sourceID: MediaSourceID,
        from library: any LibraryServing
    ) async throws -> [AlbumID: String] {
        guard !albumIDs.isEmpty else { return [:] }

        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var names: [AlbumID: String] = [:]
        var seenCursors = Set<LibraryCursor>()

        while names.count < albumIDs.count {
            try Task.checkCancellation()
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: sourceID),
                page: request
            )
            try Task.checkCancellation()

            for album in page.elements where albumIDs.contains(album.id) {
                names[album.id] = album.title
            }

            guard names.count < albumIDs.count,
                  let nextRequest = try page.nextPage(limit: request.limit)
            else {
                break
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryError.query(.invalidCursor)
            }
            request = nextRequest
        }

        return names
    }

    static func load(
        albumID: AlbumID,
        sourceID: MediaSourceID,
        from library: any LibraryServing
    ) async throws -> Album? {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var seenCursors = Set<LibraryCursor>()

        while true {
            try Task.checkCancellation()
            let page = try await library.browseAlbums(
                matching: AlbumQuery(sourceID: sourceID),
                page: request
            )
            try Task.checkCancellation()

            if let album = page.elements.first(where: { $0.id == albumID }) {
                return album
            }

            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                return nil
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryError.query(.invalidCursor)
            }
            request = nextRequest
        }
    }
}
