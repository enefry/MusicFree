import AppServices
import DesignSystem
import Foundation
import MusicDomain
import UIKit

/// Uses a custom cover first, then the first playable entry with readable artwork.
/// The request identity and cancellation guard prevent reused cells showing old covers.
@MainActor
final class PlaylistCoverBinding {
    private struct Request: Equatable {
        let playlist: Playlist
        let trackIDs: [MediaItemID]?
        let dimension: Int
        let revision: UInt64
    }

    private weak var view: MusicFreeUIKitArtworkView?
    private var request: Request?
    private var task: Task<Void, Never>?
    private var generation = 0

    init(view: MusicFreeUIKitArtworkView) { self.view = view }
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
        playlist: Playlist,
        trackIDs: [MediaItemID]? = nil,
        dimension: Int,
        revision: UInt64,
        store: any PlaylistFeatureStore,
        library: (any LibraryServing)?,
        artwork: (any ArtworkServing)?
    ) {
        let next = Request(playlist: playlist, trackIDs: trackIDs, dimension: dimension, revision: revision)
        guard request != next else { return }
        let samePlaylist = request?.playlist.id == playlist.id
        generation += 1
        let version = generation
        task?.cancel()
        request = next
        if !samePlaylist { view?.image = nil }
        guard let artwork else {
            view?.image = nil
            view?.isLoading = false
            return
        }
        view?.isLoading = view?.image == nil
        task = Task { @MainActor [weak self] in
            var image: UIImage?
            if let id = playlist.artworkID {
                image = await PlaylistArtworkImagePipeline.shared.image(
                    artworkID: id, sourceID: .local, maximumPixelDimension: dimension, serving: artwork
                )
            }
            if image == nil, let library, !Task.isCancelled {
                let ids: [MediaItemID]
                if let trackIDs {
                    ids = trackIDs
                } else {
                    ids = (try? await store.loadEntries(in: playlist.id))?
                        .sorted { $0.position < $1.position }.map(\.trackID) ?? []
                }
                var tried = Set<ArtworkID>()
                for id in ids {
                    guard !Task.isCancelled else { return }
                    guard let track = try? await library.track(id: id),
                          let artworkID = track.artworkID,
                          tried.insert(artworkID).inserted else { continue }
                    image = await PlaylistArtworkImagePipeline.shared.image(
                        artworkID: artworkID, sourceID: track.id.sourceID,
                        maximumPixelDimension: dimension, serving: artwork
                    )
                    if image != nil { break }
                }
            }
            guard let self, !Task.isCancelled, generation == version else { return }
            view?.image = image
            view?.isLoading = false
            task = nil
        }
    }
}
