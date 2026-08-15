import AppServices
import LibraryAPI
import MusicDomain

enum LibraryAlbumLoader {
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
