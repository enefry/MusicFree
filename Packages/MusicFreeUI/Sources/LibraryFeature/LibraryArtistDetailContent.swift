import MusicDomain

/// Pure relationship rules used by the artist detail screen.
///
/// Artist metadata is not guaranteed to be identical on every related record:
/// a track can carry the artist relationship while its album does not, and an
/// older library can retain a track pointing at an album record that has since
/// disappeared. Keep those cases visible instead of relying on one query's
/// relationship projection.
enum LibraryArtistDetailContent {
    struct AlbumGroup: Hashable, Sendable {
        let album: Album
        let albumIDs: [AlbumID]
    }

    static func tracks(
        for artistID: ArtistID,
        from allTracks: [Track],
        albums: [Album]
    ) -> [Track] {
        let albumsByID = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        return allTracks.filter { track in
            track.artistIDs.contains(artistID)
                || track.albumID.flatMap { albumsByID[$0]?.artistIDs.contains(artistID) } == true
        }
    }

    static func albums(
        for artistID: ArtistID,
        tracks: [Track],
        from allAlbums: [Album]
    ) -> [Album] {
        albumGroups(for: artistID, tracks: tracks, from: allAlbums).map(\.album)
    }

    static func albumGroups(
        for artistID: ArtistID,
        tracks: [Track],
        from allAlbums: [Album]
    ) -> [AlbumGroup] {
        let trackAlbumIDs = Set(tracks.compactMap(\.albumID))
        var groups: [AlbumGroup] = []
        var groupIndexByKey: [AlbumKey: Int] = [:]

        for album in allAlbums where trackAlbumIDs.contains(album.id) || album.artistIDs.contains(artistID) {
            let key = AlbumKey(album: album)
            if let index = groupIndexByKey[key] {
                let existing = groups[index]
                guard !existing.albumIDs.contains(album.id) else { continue }
                groups[index] = AlbumGroup(
                    album: mergedAlbum(existing.album, with: album),
                    albumIDs: existing.albumIDs + [album.id]
                )
            } else {
                groupIndexByKey[key] = groups.count
                groups.append(AlbumGroup(album: album, albumIDs: [album.id]))
            }
        }
        return groups
    }

    static func noAlbumTracks(
        from tracks: [Track],
        knownAlbums: [Album]
    ) -> [Track] {
        noAlbumTracks(from: tracks, knownAlbumIDs: Set(knownAlbums.map(\.id)))
    }

    static func noAlbumTracks(
        from tracks: [Track],
        knownAlbumIDs: Set<AlbumID>
    ) -> [Track] {
        return tracks.filter { track in
            guard let albumID = track.albumID else { return true }
            return !knownAlbumIDs.contains(albumID)
        }
    }

    private struct AlbumKey: Hashable {
        let title: String
        let releaseYear: Int?
        let albumType: AlbumType?

        init(album: Album) {
            title = album.title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        
            releaseYear = album.releaseYear
            albumType = album.albumType
        }
    }

    private static func mergedAlbum(_ lhs: Album, with rhs: Album) -> Album {
        var artistIDs = lhs.artistIDs
        for artistID in rhs.artistIDs where !artistIDs.contains(artistID) {
            artistIDs.append(artistID)
        }
        return Album(
            id: lhs.id,
            title: lhs.title,
            sortTitle: lhs.sortTitle ?? rhs.sortTitle,
            artistIDs: artistIDs,
            artwork: lhs.artwork ?? rhs.artwork,
            releaseYear: lhs.releaseYear ?? rhs.releaseYear,
            trackCount: [lhs.trackCount, rhs.trackCount].compactMap { $0 }.max(),
            albumType: lhs.albumType ?? rhs.albumType
        )
    }
}
