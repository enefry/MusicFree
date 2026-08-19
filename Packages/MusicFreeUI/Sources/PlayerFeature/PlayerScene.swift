import AppServices
import SwiftUI

@MainActor
public struct PlayerScene: View {
  @StateObject private var viewModel: PlayerViewModel
  @State private var isQueuePresented = false
  private let artworkServing: (any ArtworkServing)?
  private let library: (any LibraryServing)?
  private let lyricsServing: (any LyricsServing)?

  public init() {
    self.init(serving: PlayerStore())
  }

  init(
    viewModel: PlayerViewModel,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil,
    lyricsServing: (any LyricsServing)? = nil
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.artworkServing = artworkServing
    self.library = library
    self.lyricsServing = lyricsServing
  }

  public init(
    serving: any PlaybackServing,
    audioServing: (any PlayerAudioServing)? = nil,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil,
    lyricsServing: (any LyricsServing)? = nil
  ) {
    self.init(
      viewModel: PlayerViewModel(serving: serving, audioServing: audioServing),
      artworkServing: artworkServing,
      library: library,
      lyricsServing: lyricsServing
    )
  }

  public var body: some View {
    NowPlayingView(
      viewModel: viewModel,
      onShowQueue: { isQueuePresented = true },
      artworkServing: artworkServing,
      library: library,
      lyricsServing: lyricsServing
    )
    .sheet(isPresented: $isQueuePresented) {
      NavigationStack {
        QueueView(
          viewModel: viewModel,
          artworkServing: artworkServing,
          library: library
        )
      }
    }
  }
}
