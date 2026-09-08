import Foundation
import MusicDomain

/// An explicit user-directed merge, committed together with the destination's edits.
public struct LibraryAlbumMerge: Codable, Equatable, Sendable {
    public let sourceAlbumIDs: Set<AlbumID>
    public let destinationAlbumID: AlbumID

    public init(sourceAlbumIDs: Set<AlbumID>, destinationAlbumID: AlbumID) {
        self.sourceAlbumIDs = sourceAlbumIDs
        self.destinationAlbumID = destinationAlbumID
    }

    public static func normalizedTitle(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.replacingOccurrences(of: #"\s*([·•・:：-])\s*"#, with: "$1", options: .regularExpression)
    }
}

/// Shared value-only relationship plan for the durable and in-memory repositories.
/// Media identities and source snapshots are deliberately left untouched.
public struct LibraryAlbumMergePlan: Sendable {
    public let album: Album
    public let release: AlbumRelease
    public let movedTrackIDs: Set<MediaItemID>
    public let logicalTracks: [LogicalTrack]
    public let discs: [Disc]
    public let members: [LibraryCollectionMember]
    public let removedReleaseIDs: Set<AlbumReleaseID>
    public let removedDiscIDs: Set<DiscID>

    public init(
        merge: LibraryAlbumMerge,
        albums: [AlbumID: Album],
        tracks: [Track],
        logicalTracks: [LogicalTrackID: LogicalTrack],
        variants: [TrackVariant],
        releases: [AlbumReleaseID: AlbumRelease],
        discs: [DiscID: Disc],
        members: [LibraryCollectionMember]
    ) throws {
        guard !merge.sourceAlbumIDs.isEmpty,
              !merge.sourceAlbumIDs.contains(merge.destinationAlbumID),
              let destination = albums[merge.destinationAlbumID],
              merge.sourceAlbumIDs.allSatisfy({ albums[$0] != nil })
        else { throw LibraryError.constraint(.danglingReference) }
        guard merge.sourceAlbumIDs.allSatisfy({
            LibraryAlbumMerge.normalizedTitle(albums[$0]!.title) == LibraryAlbumMerge.normalizedTitle(destination.title)
        }) else { throw LibraryError.constraint(.danglingReference) }

        let destinationReleaseID = AlbumReleaseID(legacyAlbumID: destination.id)
        let sourceReleaseIDs = Set(merge.sourceAlbumIDs.map(AlbumReleaseID.init(legacyAlbumID:)))
            .union(releases.values.filter {
                $0.legacyAlbumID.map(merge.sourceAlbumIDs.contains) == true
            }.map(\.id))
        let mergedAlbumIDs = merge.sourceAlbumIDs.union([destination.id])
        let mergedReleaseIDs = sourceReleaseIDs.union([destinationReleaseID])
        let albumTracks = tracks.filter { $0.albumID.map(mergedAlbumIDs.contains) == true }
        var logicalValues = logicalTracks
        for track in albumTracks where logicalValues[track.logicalTrackID] == nil {
            logicalValues[track.logicalTrackID] = track.logicalTrackProjection
        }
        let albumLogicalIDs = Set(logicalValues.values.filter {
            $0.releaseID.map(mergedReleaseIDs.contains) == true
        }.map(\.id)).union(albumTracks.map(\.logicalTrackID))
        let albumVariants = variants.filter { albumLogicalIDs.contains($0.logicalTrackID) }
        guard albumTracks.allSatisfy({ $0.id.sourceID == .local }),
              albumVariants.allSatisfy({ $0.id.sourceID == .local })
        else { throw LibraryError.constraint(.danglingReference) }

        let movedTracks = albumTracks.filter { $0.albumID.map(merge.sourceAlbumIDs.contains) == true }
        let movedLogicalIDs = Set(movedTracks.map(\.logicalTrackID)).union(logicalValues.values.filter {
            $0.releaseID.map(sourceReleaseIDs.contains) == true
        }.map(\.id))
        self.movedTrackIDs = Set(movedTracks.map(\.id)).union(albumVariants.filter {
            movedLogicalIDs.contains($0.logicalTrackID)
        }.map(\.id))
        self.logicalTracks = logicalValues.values.filter { movedLogicalIDs.contains($0.id) }.map { value in
            let number = value.discNumber ?? value.discID.flatMap { discs[$0]?.number } ?? 1
            return LogicalTrack(
                id: value.id,
                releaseID: destinationReleaseID,
                discID: DiscID(releaseID: destinationReleaseID, number: number),
                title: value.title,
                artistIDs: value.artistIDs,
                genreIDs: value.genreIDs,
                trackNumber: value.trackNumber,
                trackTotal: value.trackTotal,
                discNumber: value.discNumber,
                discTotal: value.discTotal,
                duration: value.duration,
                artwork: value.artwork,
                isFavorite: value.isFavorite,
                statistics: value.statistics
            )
        }
        self.album = Album(
            id: destination.id,
            title: destination.title,
            sortTitle: destination.sortTitle,
            artistIDs: destination.artistIDs,
            artwork: destination.artwork,
            releaseYear: destination.releaseYear,
            trackCount: Set(albumTracks.map(\.id)).union(albumVariants.map(\.id)).count,
            albumType: destination.albumType
        )
        let previousRelease = releases[destinationReleaseID]
        self.release = AlbumRelease(
            id: destinationReleaseID,
            legacyAlbumID: destination.id,
            groupID: previousRelease?.groupID,
            title: destination.title,
            artistIDs: destination.artistIDs,
            releaseYear: destination.releaseYear,
            editionTitle: previousRelease?.editionTitle,
            albumType: destination.albumType,
            artwork: destination.artwork
        )

        var mergedDiscs: [Int: Disc] = [:]
        for disc in discs.values.sorted(by: { $0.id < $1.id }) where mergedReleaseIDs.contains(disc.releaseID) {
            if mergedDiscs[disc.number] == nil || disc.releaseID == destinationReleaseID {
                mergedDiscs[disc.number] = disc
            }
        }
        var logicalCounts: [Int: Int] = [:]
        for logicalID in albumLogicalIDs {
            guard let logical = logicalValues[logicalID] else { continue }
            let number = logical.discNumber ?? logical.discID.flatMap { discs[$0]?.number } ?? 1
            logicalCounts[number, default: 0] += 1
        }
        self.discs = Set(mergedDiscs.keys).union(logicalCounts.keys).sorted().map { number in
            Disc(
                id: DiscID(releaseID: destinationReleaseID, number: number),
                releaseID: destinationReleaseID,
                number: number,
                title: mergedDiscs[number]?.title,
                trackCount: logicalCounts[number] ?? 0
            )
        }
        let affectedCollections = Set(members.filter { sourceReleaseIDs.contains($0.releaseID) }.map(\.collectionID))
        var positions: [LibraryCollectionID: Int] = [:]
        for member in members where affectedCollections.contains(member.collectionID)
            && mergedReleaseIDs.contains(member.releaseID) {
            positions[member.collectionID] = min(positions[member.collectionID] ?? member.position, member.position)
        }
        self.members = positions.map { collectionID, position in
            LibraryCollectionMember(collectionID: collectionID, releaseID: destinationReleaseID, position: position)
        }
        self.removedReleaseIDs = sourceReleaseIDs
        self.removedDiscIDs = Set(discs.values.filter { sourceReleaseIDs.contains($0.releaseID) }.map(\.id))
    }
}
