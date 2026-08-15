import AppServices
import LibraryAPI
import MusicDomain

enum QueueArtistNameLoader {
  static func subtitle(
    for track: Track?,
    artistNames: [ArtistID: String]
  ) -> String? {
    guard let track else { return nil }
    let names = track.artistIDs.compactMap { artistNames[$0] }
    return names.isEmpty ? nil : names.joined(separator: "、")
  }

  static func load(
    artistIDs: Set<ArtistID>,
    sourceID: MediaSourceID,
    from library: any LibraryServing
  ) async throws -> [ArtistID: String] {
    guard !artistIDs.isEmpty else {
      return [:]
    }

    var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
    var names: [ArtistID: String] = [:]
    var seenCursors = Set<LibraryCursor>()

    while names.count < artistIDs.count {
      try Task.checkCancellation()
      let page = try await library.browseArtists(
        matching: ArtistQuery(sourceID: sourceID),
        page: request
      )
      try Task.checkCancellation()

      for artist in page.elements where artistIDs.contains(artist.id) {
        names[artist.id] = artist.name
      }

      guard names.count < artistIDs.count,
            let nextRequest = try page.nextPage(limit: request.limit)
      else {
        break
      }
      guard let nextCursor = nextRequest.cursor,
            seenCursors.insert(nextCursor).inserted
      else {
        throw LibraryError.query(.invalidCursor)
      }
      request = nextRequest
    }

    return names
  }

  static func load(
    for tracks: [Track],
    from library: any LibraryServing
  ) async throws -> [ArtistID: String] {
    let tracksBySource = Dictionary(grouping: tracks, by: { $0.id.sourceID })
    var names: [ArtistID: String] = [:]
    for sourceID in tracksBySource.keys.sorted() {
      let artistIDs = Set(tracksBySource[sourceID, default: []].flatMap(\.artistIDs))
      names.merge(
        try await load(artistIDs: artistIDs, sourceID: sourceID, from: library),
        uniquingKeysWith: { _, new in new }
      )
    }
    return names
  }
}
