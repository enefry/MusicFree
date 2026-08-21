import Foundation
import MusicDomain

/// Repository contract for paged library reads and atomic library writes.
public protocol LibraryRepository: Sendable {
    func track(id: MediaItemID) async throws -> Track?
    func album(id: AlbumID) async throws -> Album?
    func artist(id: ArtistID) async throws -> Artist?
    func genre(id: GenreID) async throws -> Genre?
    func artwork(id: ArtworkID) async throws -> ArtworkReference?
    func logicalTrack(id: LogicalTrackID) async throws -> LogicalTrack?
    func trackVariant(id: MediaItemID) async throws -> TrackVariant?
    func variants(for logicalTrackID: LogicalTrackID) async throws -> [TrackVariant]
    func mediaAsset(id: MediaAssetID) async throws -> MediaAsset?
    func release(id: AlbumReleaseID) async throws -> AlbumRelease?
    func discs(for releaseID: AlbumReleaseID) async throws -> [Disc]
    func collections() async throws -> [LibraryCollection]
    func members(in collectionID: LibraryCollectionID) async throws -> [LibraryCollectionMember]
    /// Returns whether any durable library object still points at the artwork.
    /// This is intentionally distinct from `artwork(id:)`: a record may remain
    /// after a failed migration or a custom repository may retain unreferenced
    /// metadata while the managed file is eligible for cleanup.
    func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool
    /// Returns whether a media asset is still referenced by a variant outside
    /// the item IDs being removed.
    func isMediaAssetReferenced(
        _ assetID: MediaAssetID,
        excluding itemIDs: Set<MediaItemID>
    ) async throws -> Bool

    func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track>

    func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album>

    func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist>

    func genres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre>

    /// Returns logical source folders. Absolute filesystem paths are never
    /// exposed by this contract.
    func folders(page: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder>

    /// The transaction must commit all mutations or make no visible change.
    func apply(_ transaction: LibraryTransaction) async throws

    /// Removes tracks and prunes their relationships, playlist entries, and statistics atomically.
    func remove(_ itemIDs: Set<MediaItemID>) async throws

    /// Emits only committed changes and finishes when the repository is disposed.
    func changes() -> AsyncStream<LibraryChange>
}

public extension LibraryRepository {
    func logicalTrack(id: LogicalTrackID) async throws -> LogicalTrack? {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        while true {
            let page = try await tracks(matching: TrackQuery(), page: request)
            if let track = page.elements.first(where: { $0.logicalTrackID == id }) {
                return track.logicalTrackProjection
            }
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else { return nil }
            request = next
        }
    }

    func trackVariant(id: MediaItemID) async throws -> TrackVariant? {
        try await track(id: id)?.trackVariantProjection
    }

    func variants(for logicalTrackID: LogicalTrackID) async throws -> [TrackVariant] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var result: [TrackVariant] = []
        while true {
            let page = try await tracks(matching: TrackQuery(), page: request)
            result.append(contentsOf: page.elements.filter { $0.logicalTrackID == logicalTrackID }.map(\.trackVariantProjection))
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else { return result.sorted { $0.id < $1.id } }
            request = next
        }
    }

    func mediaAsset(id: MediaAssetID) async throws -> MediaAsset? {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        while true {
            let page = try await tracks(matching: TrackQuery(sourceID: id.sourceID), page: request)
            if let track = page.elements.first(where: { $0.assetID == id }) {
                return track.mediaAssetProjection
            }
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else { return nil }
            request = next
        }
    }

    func release(id: AlbumReleaseID) async throws -> AlbumRelease? {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        while true {
            let page = try await albums(matching: AlbumQuery(), page: request)
            if let album = page.elements.first(where: { AlbumReleaseID(legacyAlbumID: $0.id) == id }) {
                return album.releaseProjection
            }
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else { return nil }
            request = next
        }
    }

    func discs(for releaseID: AlbumReleaseID) async throws -> [Disc] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var discs: [DiscID: Disc] = [:]
        while true {
            let page = try await tracks(matching: TrackQuery(), page: request)
            for track in page.elements where track.albumID.map(AlbumReleaseID.init(legacyAlbumID:)) == releaseID {
                if let disc = track.discProjection { discs[disc.id] = disc }
            }
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else {
                return discs.values.sorted { $0.number < $1.number }
            }
            request = next
        }
    }

    func collections() async throws -> [LibraryCollection] { [] }

    func members(in _: LibraryCollectionID) async throws -> [LibraryCollectionMember] { [] }

    func genre(id: GenreID) async throws -> Genre? {
        let page = try await genres(
            matching: GenreQuery(),
            page: LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        )
        return page.elements.first { $0.id == id }
    }

    func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
        try await artwork(id: artworkID) != nil
    }

    func isMediaAssetReferenced(
        _ assetID: MediaAssetID,
        excluding itemIDs: Set<MediaItemID>
    ) async throws -> Bool {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        while true {
            let page = try await tracks(
                matching: TrackQuery(sourceID: assetID.sourceID),
                page: request
            )
            if page.elements.contains(where: {
                $0.assetID == assetID && !itemIDs.contains($0.id)
            }) {
                return true
            }
            guard let next = try page.nextPage(limit: LibraryPageRequest.maximumLimit) else {
                return false
            }
            request = next
        }
    }

    func genres(
        matching _: GenreQuery,
        page _: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        LibraryPage(elements: [])
    }

    func folders(page _: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        LibraryPage(elements: [])
    }
}
