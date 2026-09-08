import AppServices
import DesignSystem
import MusicDomain
import UIKit

/// Separates artwork lifetime from cell text reconfiguration. A subtitle-only
/// update must preserve both the rendered cover and any in-flight request.
@MainActor
final class LibraryArtworkBinding {
    private struct Request: Equatable {
        let artworkID: ArtworkID
        let sourceID: MediaSourceID
        let maximumPixelDimension: Int
    }

    private weak var view: MusicFreeUIKitArtworkView?
    private let pipeline: LibraryArtworkImagePipeline
    private var request: Request?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(
        view: MusicFreeUIKitArtworkView,
        pipeline: LibraryArtworkImagePipeline = .shared
    ) {
        self.view = view
        self.pipeline = pipeline
    }

    deinit { task?.cancel() }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        view?.image = nil
        view?.isLoading = false
    }

    func configure(
        artworkID: ArtworkID?,
        sourceID: MediaSourceID = .local,
        maximumPixelDimension: Int,
        serving: (any ArtworkServing)?
    ) {
        guard let view else { return }
        guard let artworkID, let serving else {
            reset()
            return
        }
        let next = Request(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: max(1, maximumPixelDimension)
        )
        if request == next, view.image != nil || task != nil { return }

        let sameArtwork = request?.artworkID == artworkID && request?.sourceID == sourceID
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        task = nil
        request = next
        if let image = pipeline.cachedImage(
            artworkID: artworkID,
            sourceID: sourceID,
            maximumPixelDimension: next.maximumPixelDimension
        ) {
            view.image = image
            view.isLoading = false
            return
        }
        // A resize can request a larger thumbnail; retain the existing image
        // while it loads. A different artwork identity must never show it.
        if !sameArtwork { view.image = nil }
        view.isLoading = view.image == nil
        let pipeline = pipeline
        task = Task { @MainActor [weak self] in
            let image = await pipeline.image(
                artworkID: artworkID,
                sourceID: sourceID,
                maximumPixelDimension: next.maximumPixelDimension,
                serving: serving
            )
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.view?.image = image
            self.view?.isLoading = false
            self.task = nil
        }
    }
}
