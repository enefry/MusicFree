import AppServices
import LibraryAPI
import MusicDomain

enum LibraryArtistNameLoader {
    static func load(
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
                matching: ArtistQuery(sourceID: .local),
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
