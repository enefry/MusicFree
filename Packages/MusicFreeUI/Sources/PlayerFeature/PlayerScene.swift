import AppServices
import SwiftUI

@MainActor
public struct PlayerScene: View {
  @StateObject private var viewModel: PlayerViewModel
  @State private var isQueuePresented = false
  @State private var isMoreActionsPresented = false
  private let artworkServing: (any ArtworkServing)?
  private let library: (any LibraryServing)?
  private let lyricsServing: (any LyricsServing)?
  private let rendersBackdrop: Bool

  public init() {
    self.init(serving: PlayerStore())
  }

  init(
    viewModel: PlayerViewModel,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil,
    lyricsServing: (any LyricsServing)? = nil,
    rendersBackdrop: Bool = true
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.artworkServing = artworkServing
    self.library = library
    self.lyricsServing = lyricsServing
    self.rendersBackdrop = rendersBackdrop
  }

  public init(
    serving: any PlaybackServing,
    audioServing: (any PlayerAudioServing)? = nil,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil,
    lyricsServing: (any LyricsServing)? = nil,
    rendersBackdrop: Bool = true
  ) {
    self.init(
      viewModel: PlayerViewModel(serving: serving, audioServing: audioServing),
      artworkServing: artworkServing,
      library: library,
      lyricsServing: lyricsServing,
      rendersBackdrop: rendersBackdrop
    )
  }

  public var body: some View {
    NowPlayingView(
      viewModel: viewModel,
      onShowQueue: { isQueuePresented = true },
      isMoreActionsPresented: $isMoreActionsPresented,
      artworkServing: artworkServing,
      library: library,
      lyricsServing: lyricsServing,
      rendersBackdrop: rendersBackdrop
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
