import AppServices
import Combine
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain

enum NowPlayingHistoryLoadState: Equatable {
  case idle
  case loading
  case loaded
  case empty
  case failed
}

@MainActor
final class NowPlayingHistoryLoader: ObservableObject {
  @Published private(set) var state: NowPlayingHistoryLoadState = .idle
  @Published private(set) var items: [PlaybackHistoryItem] = []
  @Published private(set) var artistNames: [ArtistID: String] = [:]
  @Published private(set) var isClearing = false
  @Published private(set) var failureMessage: String?

  private let library: (any LibraryServing)?
  private var operationGeneration: UInt64 = 0

  init(library: (any LibraryServing)?) {
    self.library = library
  }

  func load() async {
    operationGeneration &+= 1
    let expectedGeneration = operationGeneration
    let previousState = state
    let previousItems = items
    let previousArtistNames = artistNames
    guard let library else {
      items = []
      artistNames = [:]
      state = .empty
      return
    }

    if state == .idle || state == .failed {
      state = .loading
    }
    failureMessage = nil
    do {
      let request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
      let page = try await library.recentHistory(page: request)
      try Task.checkCancellation()
      let names = try await loadArtistNames(
        for: page.elements,
        library: library
      )
      try Task.checkCancellation()
      guard operationGeneration == expectedGeneration else { return }
      items = page.elements
      artistNames = names
      state = items.isEmpty ? .empty : .loaded
    } catch is CancellationError {
      return
    } catch {
      guard operationGeneration == expectedGeneration else { return }
      if previousState == .loaded || previousState == .empty {
        items = previousItems
        artistNames = previousArtistNames
        state = previousState
      } else {
        items = []
        artistNames = [:]
        state = .failed
      }
      failureMessage = L("无法载入播放历史，请稍后重试。")
    }
  }

  func clear() async {
    guard let library, !items.isEmpty, !isClearing else { return }
    operationGeneration &+= 1
    let expectedGeneration = operationGeneration
    isClearing = true
    failureMessage = nil
    defer { isClearing = false }

    do {
      try await library.clearPlaybackHistory()
      try Task.checkCancellation()
      guard operationGeneration == expectedGeneration else { return }
      items = []
      artistNames = [:]
      state = .empty
    } catch is CancellationError {
      return
    } catch {
      guard operationGeneration == expectedGeneration else { return }
      failureMessage = L("无法清除播放历史，请稍后重试。")
    }
  }

  func observeChanges() async {
    guard let library else { return }
    let changes = await library.makeChangeStream()
    for await change in changes {
      guard !Task.isCancelled else { return }
      guard change.categories.contains(.playbackHistory) else { continue }
      await load()
    }
  }

  func dismissFailure() {
    failureMessage = nil
  }

  private func loadArtistNames(
    for items: [PlaybackHistoryItem],
    library: any LibraryServing
  ) async throws -> [ArtistID: String] {
    try await QueueArtistNameLoader.load(
      for: items.map(\.track),
      from: library
    )
  }
}

enum NowPlayingHistoryPresentation {
  static func visibleItems(
    from items: [PlaybackHistoryItem],
    currentItemID: MediaItemID?
  ) -> [PlaybackHistoryItem] {
    // REGRESSION GUARD: only the active playback session is represented by
    // the current row. Filtering by item ID hides every unfinished replay of
    // the same song and makes a large history appear truncated. History
    // records carry a session ID, so select the latest unfinished session
    // explicitly and leave older sessions available to scroll.
    let currentSessionID = items
      .filter {
        $0.track.id == currentItemID && $0.lastCompletionReason == nil
      }
      .max { lhs, rhs in
        lhs.lastEventAt < rhs.lastEventAt
      }?
      .sessionID

    return items.filter { $0.sessionID != currentSessionID }
  }

  static func nowPlayingItems(
    from items: [PlaybackHistoryItem],
    currentItemID: MediaItemID?
  ) -> [PlaybackHistoryItem] {
    visibleItems(from: items, currentItemID: currentItemID)
  }
}
