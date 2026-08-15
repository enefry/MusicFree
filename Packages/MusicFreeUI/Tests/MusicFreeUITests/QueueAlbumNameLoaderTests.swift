import AppServices
import LibraryAPI
import MusicDomain
@testable import PlayerFeature
import Testing

@MainActor
@Test("Queue album names traverse every library page")
func queueAlbumNamesTraverseEveryPage() async throws {
  let requiredID = AlbumID("required")
  let library = QueueAlbumTestLibrary(
    pages: [
      LibraryPage(
        elements: [Album(id: AlbumID("other"), title: "Other")],
        nextCursor: LibraryCursor("page-2")
      ),
      LibraryPage(elements: [Album(id: requiredID, title: "Required")])
    ]
  )

  let names = try await QueueAlbumNameLoader.load(
    albumIDs: [requiredID],
    sourceID: MediaSourceID(rawValue: "remote"),
    from: library
  )

  #expect(names == [requiredID: "Required"])
  #expect(library.requests.map(\.cursor) == [nil, LibraryCursor("page-2")])
  #expect(library.requests.allSatisfy { $0.limit == LibraryPageRequest.maximumLimit })
  #expect(library.sourceIDs == [
    MediaSourceID(rawValue: "remote"),
    MediaSourceID(rawValue: "remote")
  ])
}

@MainActor
private final class QueueAlbumTestLibrary: LibraryServing {
  var pages: [LibraryPage<Album>]
  var requests: [LibraryPageRequest] = []
  var sourceIDs: [MediaSourceID] = []

  init(pages: [LibraryPage<Album>]) {
    self.pages = pages
  }

  func track(id: MediaItemID) async throws -> Track? { nil }

  func browseTracks(
    matching query: TrackQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: [])
  }

  func browseAlbums(
    matching query: AlbumQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Album> {
    requests.append(page)
    if let sourceID = query.sourceID {
      sourceIDs.append(sourceID)
    }
    guard !pages.isEmpty else {
      return LibraryPage(elements: [])
    }
    return pages.removeFirst()
  }

  func browseArtists(
    matching query: ArtistQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    LibraryPage(elements: [])
  }

  func searchTracks(
    text: String,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: [])
  }

  func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
    throw LibraryError.query(.unsupportedSort)
  }

  func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
    throw LibraryError.query(.unsupportedSort)
  }

  func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
    throw LibraryError.query(.unsupportedSort)
  }

  func makeChangeStream() async -> AsyncStream<LibraryChange> {
    AsyncStream { $0.finish() }
  }
}
