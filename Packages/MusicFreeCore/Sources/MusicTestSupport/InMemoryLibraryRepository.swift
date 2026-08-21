import Foundation
import LibraryAPI
import MusicDomain

private struct LibraryCollectionMemberKey: Hashable, Sendable {
    let collectionID: LibraryCollectionID
    let releaseID: AlbumReleaseID

    init(_ value: LibraryCollectionMember) {
        collectionID = value.collectionID
        releaseID = value.releaseID
    }
}

@available(macOS 13.0, iOS 16.0, *)
private extension Track {
    func automaticLogicalTrackProjection(includeLegacyRelease: Bool) -> LogicalTrack {
        guard !includeLegacyRelease else { return logicalTrackProjection }
        let projection = logicalTrackProjection
        return LogicalTrack(
            id: projection.id,
            title: projection.title,
            artistIDs: projection.artistIDs,
            genreIDs: projection.genreIDs,
            trackNumber: projection.trackNumber,
            trackTotal: projection.trackTotal,
            discNumber: projection.discNumber,
            discTotal: projection.discTotal,
            duration: projection.duration,
            artwork: projection.artwork,
            isFavorite: projection.isFavorite,
            statistics: projection.statistics
        )
    }
}

@available(macOS 13.0, iOS 16.0, *)
public struct InMemoryLibraryFailureScript: Sendable {
    public var readError: LibraryError?
    public var writeError: LibraryError?
    public var removeError: LibraryError?
    public var historyError: LibraryError?

    public init(
        readError: LibraryError? = nil,
        writeError: LibraryError? = nil,
        removeError: LibraryError? = nil,
        historyError: LibraryError? = nil
    ) {
        self.readError = readError
        self.writeError = writeError
        self.removeError = removeError
        self.historyError = historyError
    }

    public init(failsWrites: Bool) {
        self.init(
            writeError: failsWrites ? .capacity(.storageUnavailable) : nil
        )
    }
}

/// An actor-isolated library and playback-history repository with atomic
/// transaction application, deterministic paging, and committed change
/// notifications.
@available(macOS 13.0, iOS 16.0, *)
public actor InMemoryLibraryRepository: LibraryRepository, PlaybackHistoryRepository {
    private var trackStore: [MediaItemID: Track]
    private var albumStore: [AlbumID: Album]
    private var artistStore: [ArtistID: Artist]
    private var genreStore: [GenreID: Genre]
    private var artworkStore: [ArtworkID: ArtworkReference]
    private var logicalTrackStore: [LogicalTrackID: LogicalTrack]
    private var trackVariantStore: [MediaItemID: TrackVariant]
    private var mediaAssetStore: [MediaAssetID: MediaAsset]
    private var albumGroupStore: [AlbumGroupID: AlbumGroup]
    private var albumReleaseStore: [AlbumReleaseID: AlbumRelease]
    private var discStore: [DiscID: Disc]
    private var collectionStore: [LibraryCollectionID: LibraryCollection]
    private var collectionMemberStore: [LibraryCollectionMemberKey: LibraryCollectionMember]
    private var historyStore: [UUID: PlaybackHistoryRecord]
    private var currentRevision = LibraryRevision.initial
    private var appliedIdempotencyKeys: Set<String> = []
    private var failureScript: InMemoryLibraryFailureScript

    private let changeHub: TestAsyncStreamHub<LibraryChange>

    public private(set) var appliedTransactions: [LibraryTransaction] = []
    public private(set) var removeCalls: [Set<MediaItemID>] = []
    public private(set) var historyEvents: [PlaybackHistoryEvent] = []
    public private(set) var emittedChanges: [LibraryChange] = []

    public init(
        tracks: [Track] = [],
        albums: [Album] = [],
        artists: [Artist] = [],
        genres: [Genre] = [],
        history: [PlaybackHistoryRecord] = [],
        failureScript: InMemoryLibraryFailureScript = .init()
    ) {
        let knownAlbumIDs = Set(albums.map(\.id))
        trackStore = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        albumStore = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        artistStore = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        genreStore = Dictionary(genres.map { ($0.id, $0) }, uniquingKeysWith: { _, later in later })
        artworkStore = Dictionary(
            (tracks.compactMap(\.artwork)
                + albums.compactMap(\.artwork)
                + artists.compactMap(\.artwork))
                .map { ($0.id, $0) },
            uniquingKeysWith: { _, later in later }
        )
        logicalTrackStore = Dictionary(tracks.map { track in
            let hasKnownAlbum = track.albumID.map(knownAlbumIDs.contains) ?? false
            return (
                track.logicalTrackID,
                track.automaticLogicalTrackProjection(includeLegacyRelease: hasKnownAlbum)
            )
        }, uniquingKeysWith: { _, later in later })
        trackVariantStore = Dictionary(tracks.map {
            ($0.id, $0.trackVariantProjection)
        }, uniquingKeysWith: { _, later in later })
        mediaAssetStore = Dictionary(tracks.map {
            ($0.assetID, $0.mediaAssetProjection)
        }, uniquingKeysWith: { _, later in later })
        albumGroupStore = [:]
        albumReleaseStore = Dictionary(albums.map {
            let release = $0.releaseProjection
            return (release.id, release)
        }, uniquingKeysWith: { _, later in later })
        discStore = Dictionary(tracks.compactMap { track in
            guard track.albumID.map(knownAlbumIDs.contains) == true else { return nil }
            return track.discProjection.map { ($0.id, $0) }
        }, uniquingKeysWith: { _, later in later })
        collectionStore = [:]
        collectionMemberStore = [:]
        historyStore = Dictionary(history.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, later in later })
        self.failureScript = failureScript
        changeHub = TestAsyncStreamHub()
    }

    public func track(id: MediaItemID) async throws -> Track? {
        try checkReadFailure()
        return trackStore[id]
    }

    public func album(id: AlbumID) async throws -> Album? {
        try checkReadFailure()
        return albumStore[id]
    }

    public func artist(id: ArtistID) async throws -> Artist? {
        try checkReadFailure()
        return artistStore[id]
    }

    public func genre(id: GenreID) async throws -> Genre? {
        try checkReadFailure()
        return genreStore[id]
    }

    public func artwork(id: ArtworkID) async throws -> ArtworkReference? {
        try checkReadFailure()
        return artworkStore[id]
    }

    public func logicalTrack(id: LogicalTrackID) async throws -> LogicalTrack? {
        try checkReadFailure()
        return logicalTrackStore[id]
    }

    public func trackVariant(id: MediaItemID) async throws -> TrackVariant? {
        try checkReadFailure()
        return trackVariantStore[id]
    }

    public func variants(for logicalTrackID: LogicalTrackID) async throws -> [TrackVariant] {
        try checkReadFailure()
        return trackVariantStore.values
            .filter { $0.logicalTrackID == logicalTrackID }
            .sorted { $0.id < $1.id }
    }

    public func mediaAsset(id: MediaAssetID) async throws -> MediaAsset? {
        try checkReadFailure()
        return mediaAssetStore[id]
    }

    public func release(id: AlbumReleaseID) async throws -> AlbumRelease? {
        try checkReadFailure()
        return albumReleaseStore[id]
    }

    public func discs(for releaseID: AlbumReleaseID) async throws -> [Disc] {
        try checkReadFailure()
        return discStore.values
            .filter { $0.releaseID == releaseID }
            .sorted { $0.number < $1.number }
    }

    public func collections() async throws -> [LibraryCollection] {
        try checkReadFailure()
        return collectionStore.values.sorted { lhs, rhs in
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    public func members(in collectionID: LibraryCollectionID) async throws -> [LibraryCollectionMember] {
        try checkReadFailure()
        return collectionMemberStore.values
            .filter { $0.collectionID == collectionID }
            .sorted { lhs, rhs in
                lhs.position == rhs.position ? lhs.releaseID < rhs.releaseID : lhs.position < rhs.position
            }
    }

    public func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
        try checkReadFailure()
        return trackStore.values.contains { $0.artworkID == artworkID }
            || albumStore.values.contains { $0.artworkID == artworkID }
            || artistStore.values.contains { $0.artworkID == artworkID }
            || logicalTrackStore.values.contains { $0.artwork?.id == artworkID }
            || albumReleaseStore.values.contains { $0.artwork?.id == artworkID }
            || collectionStore.values.contains { $0.artwork?.id == artworkID }
    }

    public func isMediaAssetReferenced(
        _ assetID: MediaAssetID,
        excluding itemIDs: Set<MediaItemID>
    ) async throws -> Bool {
        try checkReadFailure()
        return trackVariantStore.values.contains {
            $0.assetID == assetID && !itemIDs.contains($0.id)
        }
    }

    public func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        try checkReadFailure()
        let values = trackStore.values.filter { matches($0, query: query) }
        let sorted = values.sorted { compare($0, $1, using: query.sort) }
        return try makePage(sorted, request: page)
    }

    public func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        try checkReadFailure()
        let values = albumStore.values.filter { album in
            if let sourceID = query.sourceID,
               !trackStore.values.contains(where: { $0.albumID == album.id && $0.id.sourceID == sourceID }) {
                return false
            }
            if let artistID = query.artistID, !album.artistIDs.contains(artistID) {
                return false
            }
            guard let searchText = query.searchText?.lowercased() else { return true }
            switch query.searchScope {
            case .all, .title, .album:
                return album.title.lowercased().contains(searchText)
            case .artist:
                return album.artistIDs.contains { artistStore[$0]?.name.lowercased().contains(searchText) == true }
            case .genre:
                return false
            }
        }
        let sorted = values.sorted { compare($0, $1, using: query.sort) }
        return try makePage(sorted, request: page)
    }

    public func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        try checkReadFailure()
        let values = artistStore.values.filter { artist in
            if let sourceID = query.sourceID,
               !trackStore.values.contains(where: { track in
                   guard track.id.sourceID == sourceID else { return false }
                   if track.artistIDs.contains(artist.id) { return true }
                   return track.albumID.flatMap { albumStore[$0]?.artistIDs.contains(artist.id) } == true
               }) {
                return false
            }
            guard let searchText = query.searchText?.lowercased() else { return true }
            return artist.name.lowercased().contains(searchText)
        }
        let sorted = values.sorted { compare($0, $1, using: query.sort) }
        return try makePage(sorted, request: page)
    }

    public func genres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        try checkReadFailure()
        let values = genreStore.values.filter { genre in
            if let sourceID = query.sourceID,
               !trackStore.values.contains(where: { $0.genreIDs.contains(genre.id) && $0.id.sourceID == sourceID }) {
                return false
            }
            guard let searchText = query.searchText?.lowercased() else { return true }
            return genre.name.lowercased().contains(searchText)
        }
        let sorted = values.sorted { lhs, rhs in
            let left: SortValue
            let right: SortValue
            switch query.sort.key {
            case .name:
                left = .text(lhs.sortName ?? lhs.name)
                right = .text(rhs.sortName ?? rhs.name)
            case .trackCount:
                left = .number(Double(trackStore.values.filter { $0.genreIDs.contains(lhs.id) }.count))
                right = .number(Double(trackStore.values.filter { $0.genreIDs.contains(rhs.id) }.count))
            }
            if left != right {
                return query.sort.direction == .ascending ? left < right : right < left
            }
            return lhs.id < rhs.id
        }
        return try makePage(sorted, request: page)
    }

    public func folders(page: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        try checkReadFailure()
        var counts: [String: Int] = [:]
        for track in trackStore.values {
            if let folderPath = track.folderPath {
                counts[folderPath, default: 0] += 1
            }
        }
        let values = counts.map { LibraryFolder(path: $0.key, trackCount: $0.value) }
            .sorted { lhs, rhs in
                let leftName = LibrarySortSupport.normalizedSortValue(
                    LibrarySortSupport.leafName(of: lhs.path)
                )
                let rightName = LibrarySortSupport.normalizedSortValue(
                    LibrarySortSupport.leafName(of: rhs.path)
                )
                if leftName != rightName { return leftName < rightName }
                return lhs.path < rhs.path
            }
        return try makePage(values, request: page)
    }

    public func apply(_ transaction: LibraryTransaction) async throws {
        try checkWriteFailure()
        guard transaction.expectedRevision == nil || transaction.expectedRevision == currentRevision else {
            throw LibraryError.conflict(
                .revisionMismatch(expected: transaction.expectedRevision, actual: currentRevision)
            )
        }
        guard !appliedIdempotencyKeys.contains(transaction.idempotencyKey) else {
            throw LibraryError.conflict(.transactionAlreadyApplied)
        }

        var nextTracks = trackStore
        var nextAlbums = albumStore
        var nextArtists = artistStore
        var nextGenres = genreStore
        var nextArtwork = artworkStore
        var nextLogicalTracks = logicalTrackStore
        var nextTrackVariants = trackVariantStore
        var nextMediaAssets = mediaAssetStore
        var nextAlbumGroups = albumGroupStore
        var nextAlbumReleases = albumReleaseStore
        var nextDiscs = discStore
        var nextCollections = collectionStore
        var nextCollectionMembers = collectionMemberStore
        let previousLogicalTracks = logicalTrackStore
        let previousTrackVariants = trackVariantStore
        let previousAlbumReleases = albumReleaseStore
        let explicitLogicalTrackIDs = Set(transaction.mutations.compactMap { mutation -> LogicalTrackID? in
            guard case .upsert(.logicalTrack(let value)) = mutation else { return nil }
            return value.id
        })
        let explicitVariantIDs = Set(transaction.mutations.compactMap { mutation -> MediaItemID? in
            guard case .upsert(.trackVariant(let value)) = mutation else { return nil }
            return value.id
        })
        let explicitAssetIDs = Set(transaction.mutations.compactMap { mutation -> MediaAssetID? in
            guard case .upsert(.mediaAsset(let value)) = mutation else { return nil }
            return value.id
        })
        let explicitReleaseIDs = Set(transaction.mutations.compactMap { mutation -> AlbumReleaseID? in
            guard case .upsert(.albumRelease(let value)) = mutation else { return nil }
            return value.id
        })
        let explicitDiscIDs = Set(transaction.mutations.compactMap { mutation -> DiscID? in
            guard case .upsert(.disc(let value)) = mutation else { return nil }
            return value.id
        })
        let availableLegacyAlbumIDs = Set(nextAlbums.keys).union(
            transaction.mutations.compactMap { mutation -> AlbumID? in
                guard case .upsert(.album(let value)) = mutation else { return nil }
                return value.id
            }
        )
        var categories = Set<LibraryChangeCategory>()
        var trackIDs = Set<MediaItemID>()
        var albumIDs = Set<AlbumID>()
        var artistIDs = Set<ArtistID>()
        var genreIDs = Set<GenreID>()
        var artworkIDs = Set<ArtworkID>()

        for mutation in transaction.mutations {
            switch mutation {
            case .upsert(let upsert):
                switch upsert {
                case .track(let value):
                    nextTracks[value.id] = value
                    if let artwork = value.artwork {
                        nextArtwork[artwork.id] = artwork
                    }
                    let hasKnownAlbum = value.albumID.map(availableLegacyAlbumIDs.contains) ?? false
                    if !explicitLogicalTrackIDs.contains(value.logicalTrackID) {
                        nextLogicalTracks[value.logicalTrackID] = value.automaticLogicalTrackProjection(
                            includeLegacyRelease: hasKnownAlbum
                        )
                    }
                    if !explicitVariantIDs.contains(value.id) {
                        nextTrackVariants[value.id] = value.trackVariantProjection
                    }
                    if !explicitAssetIDs.contains(value.assetID) {
                        nextMediaAssets[value.assetID] = value.mediaAssetProjection
                    }
                    if hasKnownAlbum,
                       let disc = value.discProjection,
                       !explicitDiscIDs.contains(disc.id)
                    {
                        nextDiscs[disc.id] = disc
                    }
                    trackIDs.insert(value.id)
                    categories.insert(.tracks)
                case .album(let value):
                    nextAlbums[value.id] = value
                    if let artwork = value.artwork {
                        nextArtwork[artwork.id] = artwork
                    }
                    let release = value.releaseProjection
                    if !explicitReleaseIDs.contains(release.id) {
                        nextAlbumReleases[release.id] = release
                    }
                    albumIDs.insert(value.id)
                    categories.insert(.albums)
                case .artist(let value):
                    nextArtists[value.id] = value
                    if let artwork = value.artwork {
                        nextArtwork[artwork.id] = artwork
                    }
                    artistIDs.insert(value.id)
                    categories.insert(.artists)
                case .genre(let value):
                    nextGenres[value.id] = value
                    genreIDs.insert(value.id)
                    categories.insert(.genres)
                case .artwork(let value):
                    nextArtwork[value.id] = value
                    artworkIDs.insert(value.id)
                    categories.insert(.artwork)
                case .logicalTrack(let value):
                    nextLogicalTracks[value.id] = value
                    categories.insert(.tracks)
                case .trackVariant(let value):
                    nextTrackVariants[value.id] = value
                    categories.insert(.tracks)
                case .mediaAsset(let value):
                    nextMediaAssets[value.id] = value
                    categories.insert(.tracks)
                case .albumGroup(let value):
                    nextAlbumGroups[value.id] = value
                    categories.insert(.albums)
                case .albumRelease(let value):
                    nextAlbumReleases[value.id] = value
                    categories.insert(.albums)
                case .disc(let value):
                    nextDiscs[value.id] = value
                    categories.insert(.albums)
                case .collection(let value):
                    nextCollections[value.id] = value
                    categories.insert(.albums)
                case .collectionMember(let value):
                    nextCollectionMembers[LibraryCollectionMemberKey(value)] = value
                    categories.insert(.albums)
                }

            case .relation(let relation):
                let itemID: MediaItemID
                switch relation {
                case .setAlbum(let trackID, let albumID):
                    itemID = trackID
                    if let albumID, nextAlbums[albumID] == nil {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    guard let track = nextTracks[trackID] else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    nextTracks[trackID] = replacing(track, albumID: albumID)
                case .setArtists(let trackID, let relatedArtistIDs):
                    itemID = trackID
                    guard Set(relatedArtistIDs).count == relatedArtistIDs.count,
                          relatedArtistIDs.allSatisfy({ nextArtists[$0] != nil }),
                          let track = nextTracks[trackID]
                    else { throw LibraryError.constraint(.danglingReference) }
                    nextTracks[trackID] = replacing(track, artistIDs: relatedArtistIDs)
                case .setGenres(let trackID, let relatedGenreIDs):
                    itemID = trackID
                    guard Set(relatedGenreIDs).count == relatedGenreIDs.count,
                          relatedGenreIDs.allSatisfy({ nextGenres[$0] != nil }),
                          let track = nextTracks[trackID]
                    else { throw LibraryError.constraint(.danglingReference) }
                    nextTracks[trackID] = replacing(track, genreIDs: relatedGenreIDs)
                case .setArtwork(let trackID, let artworkID):
                    itemID = trackID
                    if let artworkID, nextArtwork[artworkID] == nil {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    guard let track = nextTracks[trackID] else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    nextTracks[trackID] = replacing(track, artworkID: artworkID)
                }
                trackIDs.insert(itemID)
                categories.insert(.tracks)

            case .statistics(let statistics):
                let itemID: MediaItemID
                switch statistics {
                case .replace(let trackID, let value):
                    guard let track = nextTracks[trackID] else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    nextTracks[trackID] = replacing(track, statistics: value)
                    itemID = trackID
                case .increment(let trackID, let delta):
                    guard delta.isNonNegative, let track = nextTracks[trackID] else {
                        throw LibraryError.constraint(.invalidStatisticsDelta)
                    }
                    nextTracks[trackID] = replacing(
                        track,
                        statistics: try increment(track.statistics, by: delta)
                    )
                    itemID = trackID
                }
                trackIDs.insert(itemID)
                categories.insert(.playbackStatistics)
            }
        }

        guard nextTracks.values.allSatisfy({ value in
            (value.albumID == nil || nextAlbums[value.albumID!] != nil)
                && value.artistIDs.allSatisfy { nextArtists[$0] != nil }
                && value.genreIDs.allSatisfy { nextGenres[$0] != nil }
                && (value.artwork == nil || nextArtwork[value.artwork!.id] != nil)
        }), nextAlbums.values.allSatisfy({ value in
            value.artistIDs.allSatisfy { nextArtists[$0] != nil }
                && (value.artwork == nil || nextArtwork[value.artwork!.id] != nil)
        }), nextArtists.values.allSatisfy({ value in
            value.artwork == nil || nextArtwork[value.artwork!.id] != nil
        }), nextTrackVariants.values.allSatisfy({
            nextLogicalTracks[$0.logicalTrackID] != nil && nextMediaAssets[$0.assetID] != nil
        }), nextLogicalTracks.values.allSatisfy({ value in
            guard value.artistIDs.allSatisfy({ nextArtists[$0] != nil }),
                  value.genreIDs.allSatisfy({ nextGenres[$0] != nil }),
                  value.artwork == nil || nextArtwork[value.artwork!.id] != nil,
                  value.releaseID == nil || nextAlbumReleases[value.releaseID!] != nil
            else { return false }
            guard let discID = value.discID else { return true }
            guard let releaseID = value.releaseID,
                  let disc = nextDiscs[discID],
                  disc.releaseID == releaseID,
                  value.discNumber == nil || value.discNumber == disc.number
            else { return false }
            return true
        }), nextDiscs.values.allSatisfy({
            nextAlbumReleases[$0.releaseID] != nil
                && $0.id == DiscID(releaseID: $0.releaseID, number: $0.number)
        }),
        nextAlbumGroups.values.allSatisfy({ value in
            value.artistIDs.allSatisfy { nextArtists[$0] != nil }
        }), nextAlbumReleases.values.allSatisfy({ value in
            value.artistIDs.allSatisfy { nextArtists[$0] != nil }
                && (value.groupID == nil || nextAlbumGroups[value.groupID!] != nil)
                && (value.legacyAlbumID == nil || nextAlbums[value.legacyAlbumID!] != nil)
                && (value.artwork == nil || nextArtwork[value.artwork!.id] != nil)
        }), nextCollectionMembers.values.allSatisfy({
            nextCollections[$0.collectionID] != nil && nextAlbumReleases[$0.releaseID] != nil
        }), nextCollections.values.allSatisfy({
            $0.artwork == nil || nextArtwork[$0.artwork!.id] != nil
        }) else {
            throw LibraryError.constraint(.danglingReference)
        }

        var staleLogicalTrackIDs = Set<LogicalTrackID>()
        var staleAssetIDs = Set<MediaAssetID>()
        var staleReleaseIDs = Set<AlbumReleaseID>()
        var staleDiscIDs = Set<DiscID>()
        var staleGroupIDs = Set<AlbumGroupID>()

        for (itemID, previous) in previousTrackVariants {
            guard let current = nextTrackVariants[itemID] else { continue }
            if previous.logicalTrackID != current.logicalTrackID {
                staleLogicalTrackIDs.insert(previous.logicalTrackID)
            }
            if previous.assetID != current.assetID {
                staleAssetIDs.insert(previous.assetID)
            }
        }

        for itemID in trackIDs {
            guard let previous = trackStore[itemID],
                  let current = nextTracks[itemID]
            else { continue }
            if previous.logicalTrackID != current.logicalTrackID {
                staleLogicalTrackIDs.insert(previous.logicalTrackID)
            }
            if previous.assetID != current.assetID {
                staleAssetIDs.insert(previous.assetID)
            }
            guard previous.logicalTrackID == current.logicalTrackID else { continue }
            let previousLogical = previousLogicalTracks[previous.logicalTrackID]
                ?? previous.logicalTrackProjection
            let currentLogical = current.automaticLogicalTrackProjection(
                includeLegacyRelease: current.albumID.map(nextAlbums.keys.contains) ?? false
            )
            if previousLogical.releaseID != currentLogical.releaseID {
                staleReleaseIDs.formUnion([previousLogical.releaseID].compactMap { $0 })
            }
            if previousLogical.discID != currentLogical.discID {
                staleDiscIDs.formUnion([previousLogical.discID].compactMap { $0 })
            }
        }

        for (logicalID, value) in transaction.mutations.compactMap({ mutation -> (LogicalTrackID, LogicalTrack)? in
            guard case .upsert(.logicalTrack(let value)) = mutation else { return nil }
            return (value.id, value)
        }) {
            guard let previous = previousLogicalTracks[logicalID] else { continue }
            if previous.releaseID != value.releaseID {
                staleReleaseIDs.formUnion([previous.releaseID].compactMap { $0 })
            }
            if previous.discID != value.discID {
                staleDiscIDs.formUnion([previous.discID].compactMap { $0 })
            }
        }

        for (releaseID, value) in transaction.mutations.compactMap({ mutation -> (AlbumReleaseID, AlbumRelease)? in
            guard case .upsert(.albumRelease(let value)) = mutation else { return nil }
            return (value.id, value)
        }) {
            guard let previous = previousAlbumReleases[releaseID],
                  previous.groupID != value.groupID
            else { continue }
            staleGroupIDs.formUnion([previous.groupID].compactMap { $0 })
        }

        pruneReplacedLocalMediaGraph(
            logicalTrackIDs: staleLogicalTrackIDs,
            assetIDs: staleAssetIDs,
            releaseIDs: staleReleaseIDs,
            discIDs: staleDiscIDs,
            groupIDs: staleGroupIDs,
            protectedLogicalTrackIDs: explicitLogicalTrackIDs,
            protectedAssetIDs: explicitAssetIDs,
            protectedReleaseIDs: explicitReleaseIDs,
            protectedDiscIDs: explicitDiscIDs,
            protectedGroupIDs: Set(transaction.mutations.compactMap { mutation -> AlbumGroupID? in
                guard case .upsert(.albumGroup(let value)) = mutation else { return nil }
                return value.id
            }),
            retainedLegacyReleaseIDs: Set(nextAlbums.keys.map {
                AlbumReleaseID(legacyAlbumID: $0)
            }),
            logicalTracks: &nextLogicalTracks,
            variants: nextTrackVariants,
            assets: &nextMediaAssets,
            releases: &nextAlbumReleases,
            discs: &nextDiscs,
            groups: &nextAlbumGroups,
            collections: &nextCollections,
            collectionMembers: &nextCollectionMembers
        )

        trackStore = nextTracks
        albumStore = nextAlbums
        artistStore = nextArtists
        genreStore = nextGenres
        artworkStore = nextArtwork
        logicalTrackStore = nextLogicalTracks
        trackVariantStore = nextTrackVariants
        mediaAssetStore = nextMediaAssets
        albumGroupStore = nextAlbumGroups
        albumReleaseStore = nextAlbumReleases
        discStore = nextDiscs
        collectionStore = nextCollections
        collectionMemberStore = nextCollectionMembers
        currentRevision = LibraryRevision(currentRevision.rawValue + 1)
        appliedIdempotencyKeys.insert(transaction.idempotencyKey)
        appliedTransactions.append(transaction)

        let change = LibraryChange(
            revision: currentRevision,
            categories: categories,
            affectedIDs: LibraryAffectedIDs(
                trackIDs: trackIDs,
                albumIDs: albumIDs,
                artistIDs: artistIDs,
                genreIDs: genreIDs,
                artworkIDs: artworkIDs
            )
        )
        emittedChanges.append(change)
        changeHub.yield(change)
    }

    public func remove(_ itemIDs: Set<MediaItemID>) async throws {
        try checkRemoveFailure()
        guard !itemIDs.isEmpty else { return }
        removeCalls.append(itemIDs)
        let removedTracks = itemIDs.reduce(into: [MediaItemID: Track]()) { result, itemID in
            if let track = trackStore[itemID] { result[itemID] = track }
        }
        var removed = Set<MediaItemID>()
        for itemID in itemIDs {
            if trackStore.removeValue(forKey: itemID) != nil
                || trackVariantStore[itemID] != nil
            {
                removed.insert(itemID)
            }
        }
        guard !removed.isEmpty else { return }
        let removedVariants = removed.compactMap { itemID -> TrackVariant? in
            if let variant = trackVariantStore.removeValue(forKey: itemID) {
                return variant
            }
            return removedTracks[itemID]?.trackVariantProjection
        }
        let removedLogicalIDs = Set(removedVariants.map(\.logicalTrackID))
        let removedLogicalValues = removedLogicalIDs.compactMap { logicalTrackStore[$0] }
        let retainedLogicalIDs = Set(trackVariantStore.values.map(\.logicalTrackID))
        let retainedAssetIDs = Set(trackVariantStore.values.map(\.assetID))
        for logicalTrackID in removedLogicalIDs
            where !retainedLogicalIDs.contains(logicalTrackID)
        {
            logicalTrackStore[logicalTrackID] = nil
        }
        for assetID in Set(removedVariants.map(\.assetID)) where !retainedAssetIDs.contains(assetID) {
            mediaAssetStore[assetID] = nil
        }

        let retainedReleaseIDs = Set(logicalTrackStore.values.compactMap(\.releaseID))
        let retainedDiscIDs = Set(logicalTrackStore.values.compactMap(\.discID))
        let removedReleaseIDs = Set(removedLogicalValues.compactMap(\.releaseID))
            .subtracting(retainedReleaseIDs)
        let removedDiscIDs = Set(removedLogicalValues.compactMap(\.discID))
            .subtracting(retainedDiscIDs)
        let removedGroupIDs = Set(removedReleaseIDs.compactMap { albumReleaseStore[$0]?.groupID })
        for releaseID in removedReleaseIDs {
            albumReleaseStore[releaseID] = nil
        }
        for discID in removedDiscIDs {
            discStore[discID] = nil
        }
        var affectedCollectionIDs = Set<LibraryCollectionID>()
        let removedMemberKeys = collectionMemberStore.compactMap { key, member in
            removedReleaseIDs.contains(member.releaseID) ? key : nil
        }
        for key in removedMemberKeys {
            if let member = collectionMemberStore[key] {
                affectedCollectionIDs.insert(member.collectionID)
            }
            collectionMemberStore[key] = nil
        }
        let retainedCollectionIDs = Set(collectionMemberStore.values.map(\.collectionID))
        for collectionID in affectedCollectionIDs {
            guard !retainedCollectionIDs.contains(collectionID),
                  let collection = collectionStore[collectionID],
                  collection.kind == .boxSet || collection.kind == .importedFolder
            else { continue }
            collectionStore[collectionID] = nil
        }
        let retainedGroupIDs = Set(albumReleaseStore.values.compactMap(\.groupID))
        for groupID in removedGroupIDs where !retainedGroupIDs.contains(groupID) {
            albumGroupStore[groupID] = nil
        }
        currentRevision = LibraryRevision(currentRevision.rawValue + 1)
        let change = LibraryChange(
            revision: currentRevision,
            categories: [.deletions],
            affectedIDs: LibraryAffectedIDs(trackIDs: removed)
        )
        emittedChanges.append(change)
        changeHub.yield(change)
    }

    nonisolated public func changes() -> AsyncStream<LibraryChange> {
        changeHub.makeStream()
    }

    public func close() {
        changeHub.finish()
    }

    public func revision() -> LibraryRevision {
        currentRevision
    }

    public func setFailureScript(_ script: InMemoryLibraryFailureScript) {
        failureScript = script
    }

    public func recordPlaybackStarted(_ event: PlaybackStart) async throws {
        try checkHistoryFailure()
        historyEvents.append(.started(event))
        historyStore[event.sessionID] = PlaybackHistoryRecord(
            sessionID: event.sessionID,
            itemID: event.itemID,
            lastStartedAt: event.startedAt,
            lastEventAt: event.startedAt,
            totalPlayedDuration: .zero
        )
    }

    public func recordValidPlayback(_ event: ValidPlayback) async throws {
        try checkHistoryFailure()
        guard event.playedDuration >= .zero else {
            throw LibraryError.constraint(.invalidStatisticsDelta)
        }
        historyEvents.append(.validPlayback(event))
        let existing = historyStore[event.sessionID]
        historyStore[event.sessionID] = PlaybackHistoryRecord(
            sessionID: event.sessionID,
            itemID: event.itemID,
            lastStartedAt: existing?.lastStartedAt ?? event.occurredAt,
            lastEventAt: event.occurredAt,
            totalPlayedDuration: (existing?.totalPlayedDuration ?? .zero) + event.playedDuration,
            lastPosition: event.playedDuration,
            lastCompletionReason: existing?.lastCompletionReason
        )
    }

    public func recordCompleted(_ event: PlaybackCompletion) async throws {
        try checkHistoryFailure()
        historyEvents.append(.completed(event))
        let existing = historyStore[event.sessionID]
        historyStore[event.sessionID] = PlaybackHistoryRecord(
            sessionID: event.sessionID,
            itemID: event.itemID,
            lastStartedAt: existing?.lastStartedAt ?? event.occurredAt,
            lastEventAt: event.occurredAt,
            totalPlayedDuration: existing?.totalPlayedDuration ?? .zero,
            lastPosition: existing?.lastPosition,
            lastCompletionReason: event.reason
        )
    }

    public func recordSkipped(_ event: PlaybackSkip) async throws {
        try checkHistoryFailure()
        guard event.playedDuration >= .zero else {
            throw LibraryError.constraint(.invalidStatisticsDelta)
        }
        historyEvents.append(.skipped(event))
        let existing = historyStore[event.sessionID]
        historyStore[event.sessionID] = PlaybackHistoryRecord(
            sessionID: event.sessionID,
            itemID: event.itemID,
            lastStartedAt: existing?.lastStartedAt ?? event.occurredAt,
            lastEventAt: event.occurredAt,
            totalPlayedDuration: (existing?.totalPlayedDuration ?? .zero) + event.playedDuration,
            lastPosition: event.playedDuration,
            lastCompletionReason: .skipped
        )
    }

    public func recentHistory(page: LibraryPageRequest) async throws
        -> LibraryPage<PlaybackHistoryRecord>
    {
        try checkHistoryFailure()
        let values = historyStore.values.sorted {
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.sessionID.uuidString < $1.sessionID.uuidString
        }
        return try makePage(values, request: page)
    }

    public func clearHistory() async throws {
        try checkHistoryFailure()
        guard !historyStore.isEmpty else { return }
        let itemIDs = Set(historyStore.values.map(\.itemID))
        historyStore.removeAll(keepingCapacity: true)
        currentRevision = LibraryRevision(currentRevision.rawValue + 1)
        let change = LibraryChange(
            revision: currentRevision,
            categories: [.playbackHistory],
            affectedIDs: LibraryAffectedIDs(trackIDs: itemIDs)
        )
        emittedChanges.append(change)
        changeHub.yield(change)
    }

    private func checkReadFailure() throws {
        if let error = failureScript.readError { throw error }
    }

    private func checkWriteFailure() throws {
        if let error = failureScript.writeError { throw error }
    }

    private func checkRemoveFailure() throws {
        if let error = failureScript.removeError { throw error }
    }

    private func checkHistoryFailure() throws {
        if let error = failureScript.historyError { throw error }
    }

    private func matches(_ track: Track, query: TrackQuery) -> Bool {
        if let sourceID = query.sourceID, track.id.sourceID != sourceID { return false }
        if let albumID = query.albumID, track.albumID != albumID { return false }
        if let artistID = query.artistID, !track.artistIDs.contains(artistID) { return false }
        if let genreID = query.genreID, !track.genreIDs.contains(genreID) { return false }
        switch query.favorite {
        case .any:
            break
        case .favorite where !track.isFavorite, .notFavorite where track.isFavorite:
            return false
        default:
            break
        }
        guard let searchText = query.searchText?.lowercased() else { return true }
        let fields: [String]
        switch query.searchScope {
        case .all:
            fields = [
                track.title,
                track.albumID.flatMap { albumStore[$0]?.title } ?? "",
                track.artistIDs.compactMap { artistStore[$0]?.name }.joined(separator: " "),
                track.genreIDs.compactMap { genreStore[$0]?.name }.joined(separator: " ")
            ]
        case .title:
            fields = [track.title]
        case .album:
            fields = [track.albumID.flatMap { albumStore[$0]?.title } ?? ""]
        case .artist:
            fields = track.artistIDs.compactMap { artistStore[$0]?.name }
        case .genre:
            fields = track.genreIDs.compactMap { genreStore[$0]?.name }
        }
        return fields.contains { $0.lowercased().contains(searchText) }
    }

    private func compare(
        _ lhs: Track,
        _ rhs: Track,
        using descriptor: TrackSortDescriptor
    ) -> Bool {
        let left: SortValue
        let right: SortValue
        switch descriptor.key {
        case .title:
            left = .text(lhs.sortTitle ?? lhs.title)
            right = .text(rhs.sortTitle ?? rhs.title)
        case .albumTitle:
            left = .text(lhs.albumID.flatMap { albumStore[$0]?.sortTitle ?? albumStore[$0]?.title } ?? "")
            right = .text(rhs.albumID.flatMap { albumStore[$0]?.sortTitle ?? albumStore[$0]?.title } ?? "")
        case .artistName:
            left = .text(lhs.artistIDs.compactMap { artistStore[$0]?.sortName ?? artistStore[$0]?.name }.first ?? "")
            right = .text(rhs.artistIDs.compactMap { artistStore[$0]?.sortName ?? artistStore[$0]?.name }.first ?? "")
        case .dateAdded:
            left = .text(lhs.id.externalID)
            right = .text(rhs.id.externalID)
        case .duration:
            left = .number(lhs.duration.map(durationSeconds) ?? -1)
            right = .number(rhs.duration.map(durationSeconds) ?? -1)
        case .lastPlayed:
            left = .date(lhs.statistics.lastPlayedAt ?? Date.distantPast)
            right = .date(rhs.statistics.lastPlayedAt ?? Date.distantPast)
        case .playCount:
            left = .number(Double(lhs.statistics.playCount))
            right = .number(Double(rhs.statistics.playCount))
        }
        if left != right {
            return descriptor.direction == .ascending ? left < right : right < left
        }
        return lhs.id < rhs.id
    }

    private func compare(
        _ lhs: Album,
        _ rhs: Album,
        using descriptor: AlbumSortDescriptor
    ) -> Bool {
        let left: SortValue
        let right: SortValue
        switch descriptor.key {
        case .title:
            left = .text(lhs.sortTitle ?? lhs.title)
            right = .text(rhs.sortTitle ?? rhs.title)
        case .artistName:
            left = .text(lhs.artistIDs.compactMap { artistStore[$0]?.sortName ?? artistStore[$0]?.name }.first ?? "")
            right = .text(rhs.artistIDs.compactMap { artistStore[$0]?.sortName ?? artistStore[$0]?.name }.first ?? "")
        case .dateAdded:
            left = .text(lhs.id.rawValue)
            right = .text(rhs.id.rawValue)
        case .year:
            left = .number(Double(lhs.releaseYear ?? -1))
            right = .number(Double(rhs.releaseYear ?? -1))
        case .trackCount:
            left = .number(Double(lhs.trackCount ?? -1))
            right = .number(Double(rhs.trackCount ?? -1))
        }
        if left != right {
            return descriptor.direction == .ascending ? left < right : right < left
        }
        return lhs.id < rhs.id
    }

    private func compare(
        _ lhs: Artist,
        _ rhs: Artist,
        using descriptor: ArtistSortDescriptor
    ) -> Bool {
        let left: SortValue
        let right: SortValue
        switch descriptor.key {
        case .name:
            left = .text(lhs.sortName ?? lhs.name)
            right = .text(rhs.sortName ?? rhs.name)
        case .dateAdded:
            left = .text(lhs.id.rawValue)
            right = .text(rhs.id.rawValue)
        case .albumCount:
            left = .number(Double(Set(trackStore.values.compactMap { $0.albumID }).count))
            right = left
        case .trackCount:
            left = .number(Double(trackStore.values.filter { $0.artistIDs.contains(lhs.id) }.count))
            right = .number(Double(trackStore.values.filter { $0.artistIDs.contains(rhs.id) }.count))
        }
        if left != right {
            return descriptor.direction == .ascending ? left < right : right < left
        }
        return lhs.id < rhs.id
    }

    private func pruneReplacedLocalMediaGraph(
        logicalTrackIDs: Set<LogicalTrackID>,
        assetIDs: Set<MediaAssetID>,
        releaseIDs: Set<AlbumReleaseID>,
        discIDs: Set<DiscID>,
        groupIDs: Set<AlbumGroupID>,
        protectedLogicalTrackIDs: Set<LogicalTrackID>,
        protectedAssetIDs: Set<MediaAssetID>,
        protectedReleaseIDs: Set<AlbumReleaseID>,
        protectedDiscIDs: Set<DiscID>,
        protectedGroupIDs: Set<AlbumGroupID>,
        retainedLegacyReleaseIDs: Set<AlbumReleaseID>,
        logicalTracks: inout [LogicalTrackID: LogicalTrack],
        variants: [MediaItemID: TrackVariant],
        assets: inout [MediaAssetID: MediaAsset],
        releases: inout [AlbumReleaseID: AlbumRelease],
        discs: inout [DiscID: Disc],
        groups: inout [AlbumGroupID: AlbumGroup],
        collections: inout [LibraryCollectionID: LibraryCollection],
        collectionMembers: inout [LibraryCollectionMemberKey: LibraryCollectionMember]
    ) {
        guard !logicalTrackIDs.isEmpty
                || !assetIDs.isEmpty
                || !releaseIDs.isEmpty
                || !discIDs.isEmpty
                || !groupIDs.isEmpty
        else { return }

        let retainedLogicalIDs = Set(variants.values.map(\.logicalTrackID))
        let retainedAssetIDs = Set(variants.values.map(\.assetID))
        var releaseIDsToConsider = releaseIDs
        var discIDsToConsider = discIDs

        for logicalID in logicalTrackIDs
            where !retainedLogicalIDs.contains(logicalID)
                && !protectedLogicalTrackIDs.contains(logicalID)
        {
            guard let logical = logicalTracks.removeValue(forKey: logicalID) else { continue }
            if let releaseID = logical.releaseID { releaseIDsToConsider.insert(releaseID) }
            if let discID = logical.discID { discIDsToConsider.insert(discID) }
        }

        for assetID in assetIDs
            where !retainedAssetIDs.contains(assetID)
                && !protectedAssetIDs.contains(assetID)
        {
            assets.removeValue(forKey: assetID)
        }

        let retainedReleaseIDs = Set(logicalTracks.values.compactMap(\.releaseID))
            .union(retainedLegacyReleaseIDs)
        var deletedReleaseIDs = Set<AlbumReleaseID>()
        var deletedGroupIDs = groupIDs
        for releaseID in releaseIDsToConsider
            where !protectedReleaseIDs.contains(releaseID)
                && !retainedReleaseIDs.contains(releaseID)
        {
            guard let release = releases.removeValue(forKey: releaseID) else { continue }
            deletedReleaseIDs.insert(releaseID)
            if let groupID = release.groupID { deletedGroupIDs.insert(groupID) }
        }

        let retainedDiscIDs = Set(logicalTracks.values.compactMap(\.discID))
        for discID in discIDsToConsider
            where !retainedDiscIDs.contains(discID)
                && !protectedDiscIDs.contains(discID)
        {
            guard let disc = discs[discID],
                  discIDsToConsider.contains(discID)
                    || deletedReleaseIDs.contains(disc.releaseID)
            else { continue }
            discs.removeValue(forKey: discID)
        }

        var affectedCollectionIDs = Set<LibraryCollectionID>()
        collectionMembers = collectionMembers.filter { _, member in
            guard deletedReleaseIDs.contains(member.releaseID) else { return true }
            affectedCollectionIDs.insert(member.collectionID)
            return false
        }
        let retainedCollectionIDs = Set(collectionMembers.values.map(\.collectionID))
        for collectionID in affectedCollectionIDs
            where !retainedCollectionIDs.contains(collectionID)
        {
            guard let collection = collections[collectionID],
                  collection.kind == .boxSet || collection.kind == .importedFolder
            else { continue }
            collections.removeValue(forKey: collectionID)
        }

        let retainedGroupIDs = Set(releases.values.compactMap(\.groupID))
        deletedGroupIDs.formUnion(
            deletedReleaseIDs.compactMap { releaseID in
                releases[releaseID]?.groupID
            }
        )
        for groupID in deletedGroupIDs
            where !protectedGroupIDs.contains(groupID)
                && !retainedGroupIDs.contains(groupID)
        {
            groups.removeValue(forKey: groupID)
        }
    }

    private func replacing(_ track: Track, albumID: AlbumID?) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: track.artwork,
            isFavorite: track.isFavorite,
            statistics: track.statistics
        )
    }

    private func replacing(_ track: Track, artistIDs: [ArtistID]) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: track.artwork,
            isFavorite: track.isFavorite,
            statistics: track.statistics
        )
    }

    private func replacing(_ track: Track, genreIDs: [GenreID]) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: track.artwork,
            isFavorite: track.isFavorite,
            statistics: track.statistics
        )
    }

    private func replacing(_ track: Track, artworkID: ArtworkID?) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: artworkID.map { ArtworkReference(id: $0) },
            isFavorite: track.isFavorite,
            statistics: track.statistics
        )
    }

    private func replacing(_ track: Track, statistics: PlaybackStatistics) -> Track {
        Track(
            id: track.id,
            logicalTrackID: track.logicalTrackID,
            assetID: track.assetID,
            playbackSelection: track.playbackSelection,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            trackTotal: track.trackTotal,
            discNumber: track.discNumber,
            discTotal: track.discTotal,
            fileName: track.fileName,
            folderPath: track.folderPath,
            duration: track.duration,
            technicalInfo: track.technicalInfo,
            year: track.year,
            comment: track.comment,
            lyrics: track.lyrics,
            artwork: track.artwork,
            isFavorite: track.isFavorite,
            statistics: statistics
        )
    }

    private func increment(
        _ statistics: PlaybackStatistics,
        by delta: PlaybackStatisticsDelta
    ) throws -> PlaybackStatistics {
        guard delta.isNonNegative,
              statistics.playCount <= Int.max - delta.playCount,
              statistics.completionCount <= Int.max - delta.completionCount,
              statistics.skipCount <= Int.max - delta.skipCount
        else { throw LibraryError.constraint(.invalidStatisticsDelta) }
        return PlaybackStatistics(
            playCount: statistics.playCount + delta.playCount,
            completionCount: statistics.completionCount + delta.completionCount,
            skipCount: statistics.skipCount + delta.skipCount,
            lastPlayedAt: delta.lastPlayedAt ?? statistics.lastPlayedAt,
            lastCompletionReason: statistics.lastCompletionReason,
            totalListeningDuration: statistics.totalListeningDuration + delta.totalListeningDuration
        )
    }

    private func makePage<Element: Sendable>(
        _ values: [Element],
        request: LibraryPageRequest
    ) throws -> LibraryPage<Element> {
        let offset = try pageOffset(request.cursor)
        guard offset <= values.count else {
            throw LibraryError.query(.expiredCursor)
        }
        let end = min(offset + request.limit, values.count)
        let next = end < values.count ? LibraryCursor("offset:\(end)") : nil
        return LibraryPage(elements: Array(values[offset..<end]), nextCursor: next)
    }

    private func pageOffset(_ cursor: LibraryCursor?) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.rawValue.hasPrefix("offset:"),
              let value = Int(cursor.rawValue.dropFirst("offset:".count)),
              value >= 0
        else { throw LibraryError.query(.invalidCursor) }
        return value
    }

    private func durationSeconds(_ value: Duration) -> Double {
        let components = value.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private enum SortValue: Comparable {
        case text(String)
        case number(Double)
        case date(Date)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.text(let left), .text(let right)):
                return LibrarySortSupport.normalizedSortValue(left)
                    == LibrarySortSupport.normalizedSortValue(right)
            case (.number(let left), .number(let right)):
                return left == right
            case (.date(let left), .date(let right)):
                return left == right
            default:
                return false
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.text(let left), .text(let right)):
                return LibrarySortSupport.normalizedSortValue(left)
                    < LibrarySortSupport.normalizedSortValue(right)
            case (.number(let left), .number(let right)):
                return left < right
            case (.date(let left), .date(let right)):
                return left < right
            case (.text, .number), (.text, .date):
                return true
            case (.number, .text), (.date, .text):
                return false
            case (.number, .date):
                return true
            case (.date, .number):
                return false
            }
        }
    }
}
