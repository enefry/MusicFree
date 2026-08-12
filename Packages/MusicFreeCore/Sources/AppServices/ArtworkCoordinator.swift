import MediaSourceAPI
import MusicDomain

/// Application-owned artwork lookup. The source remains responsible for
/// storage and resource lifetime; AppServices only routes the request.
internal actor ArtworkCoordinator: ArtworkServing {
    private let sourceResolver: any MediaSourceResolving

    init(sourceResolver: any MediaSourceResolving) {
        self.sourceResolver = sourceResolver
    }

    func artwork(
        for artworkID: ArtworkID,
        sourceID: MediaSourceID
    ) async throws -> ArtworkResource? {
        let source = try await sourceResolver.source(for: sourceID)
        return try await source.artwork(for: artworkID)
    }
}
