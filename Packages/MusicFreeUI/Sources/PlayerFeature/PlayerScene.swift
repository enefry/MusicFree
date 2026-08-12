import AppServices
import SwiftUI

@MainActor
public struct PlayerScene: View {
  @StateObject private var viewModel: PlayerViewModel
  @State private var isQueuePresented = false
  private let artworkServing: (any ArtworkServing)?
  private let library: (any LibraryServing)?

  public init() {
    self.init(serving: PlayerStore())
  }

  init(
    viewModel: PlayerViewModel,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    self.artworkServing = artworkServing
    self.library = library
  }

  public init(
    serving: any PlaybackServing,
    audioServing: (any PlayerAudioServing)? = nil,
    artworkServing: (any ArtworkServing)? = nil,
    library: (any LibraryServing)? = nil
  ) {
    self.init(
      viewModel: PlayerViewModel(serving: serving, audioServing: audioServing),
      artworkServing: artworkServing,
      library: library
    )
  }

  public var body: some View {
    NowPlayingView(
      viewModel: viewModel,
      onShowQueue: { isQueuePresented = true },
      artworkServing: artworkServing,
      library: library
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
