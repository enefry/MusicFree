import AppServices
import LibraryAPI
import MusicDomain
@testable import PlayerFeature
import Testing

@MainActor
@Test("Queue artist names traverse every library page")
func queueArtistNamesTraverseEveryPage() async throws {
  let requiredID = ArtistID("required")
  let library = QueueArtistTestLibrary(
    pages: [
      LibraryPage(
        elements: [Artist(id: ArtistID("other"), name: "Other")],
        nextCursor: LibraryCursor("page-2")
      ),
      LibraryPage(elements: [Artist(id: requiredID, name: "Required")])
    ]
  )

  let names = try await QueueArtistNameLoader.load(
    artistIDs: [requiredID],
    from: library
  )

  #expect(names == [requiredID: "Required"])
  #expect(library.requests.map(\.cursor) == [nil, LibraryCursor("page-2")])
  #expect(library.requests.allSatisfy { $0.limit == LibraryPageRequest.maximumLimit })
}

@MainActor
@Test("Queue artist names reject a repeated library cursor")
func queueArtistNamesRejectRepeatedCursor() async {
  let repeatedCursor = LibraryCursor("page-2")
  let library = QueueArtistTestLibrary(
    pages: [
      LibraryPage(elements: [], nextCursor: repeatedCursor),
      LibraryPage(elements: [], nextCursor: repeatedCursor)
    ]
  )

  do {
    _ = try await QueueArtistNameLoader.load(
      artistIDs: [ArtistID("missing")],
      from: library
    )
    Issue.record("Expected a repeated cursor error")
  } catch let error as LibraryError {
    #expect(error == .query(.invalidCursor))
  } catch {
    Issue.record("Unexpected error: \(error)")
  }

  #expect(library.requests.count == 2)
}

@Test("Queue subtitles follow track artist relationships in order")
func queueSubtitlesFollowTrackArtistRelationships() {
  let firstArtistID = ArtistID("first")
  let missingArtistID = ArtistID("missing")
  let secondArtistID = ArtistID("second")
  let track = Track(
    id: MediaItemID(sourceID: .local, externalID: "multi-artist-track"),
    title: "Multi Artist Track",
    artistIDs: [secondArtistID, missingArtistID, firstArtistID]
  )

  let subtitle = QueueArtistNameLoader.subtitle(
    for: track,
    artistNames: [
      firstArtistID: "First Artist",
      secondArtistID: "Second Artist",
      ArtistID("unrelated"): "Unrelated Artist"
    ]
  )

  #expect(subtitle == "Second Artist、First Artist")
}

@Test("Queue subtitles stay hidden when track artists are unavailable")
func queueSubtitlesStayHiddenWithoutResolvedArtists() {
  let artistlessTrack = Track(
    id: MediaItemID(sourceID: .local, externalID: "artistless-track"),
    title: "Artistless Track",
    albumID: AlbumID("album-fallback-must-not-be-used"),
    duration: .seconds(185)
  )
  let unresolvedTrack = Track(
    id: MediaItemID(sourceID: .local, externalID: "missing-artist-track"),
    title: "Missing Artist Track",
    albumID: AlbumID("album-fallback-must-not-be-used"),
    artistIDs: [ArtistID("missing")],
    duration: .seconds(185)
  )

  #expect(QueueArtistNameLoader.subtitle(for: artistlessTrack, artistNames: [:]) == nil)
  #expect(QueueArtistNameLoader.subtitle(for: unresolvedTrack, artistNames: [:]) == nil)
  #expect(QueueArtistNameLoader.subtitle(for: nil, artistNames: [:]) == nil)
}

@MainActor
private final class QueueArtistTestLibrary: LibraryServing {
  var pages: [LibraryPage<Artist>]
  var requests: [LibraryPageRequest] = []

  init(pages: [LibraryPage<Artist>]) {
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
    LibraryPage(elements: [])
  }

  func browseArtists(
    matching query: ArtistQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    requests.append(page)
    guard !pages.isEmpty else {
      return LibraryPage(elements: [])
    }
    return pages.removeFirst()
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
