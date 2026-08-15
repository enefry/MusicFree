import AppServices
import LibraryAPI
import MusicDomain

enum LibraryGenreNameLoader {
    static func load(
        genreIDs: Set<GenreID>,
        sourceID: MediaSourceID,
        from library: any LibraryServing
    ) async throws -> [GenreID: String] {
        guard !genreIDs.isEmpty else { return [:] }

        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var names: [GenreID: String] = [:]
        var seenCursors = Set<LibraryCursor>()

        while names.count < genreIDs.count {
            try Task.checkCancellation()
            let page = try await library.browseGenres(
                matching: GenreQuery(sourceID: sourceID),
                page: request
            )
            try Task.checkCancellation()

            for genre in page.elements where genreIDs.contains(genre.id) {
                names[genre.id] = genre.name
            }

            guard names.count < genreIDs.count,
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
