import Foundation
import LibraryAPI
import MusicDomain

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
        trackStore = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        albumStore = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) })
        artistStore = Dictionary(uniqueKeysWithValues: artists.map { ($0.id, $0) })
        genreStore = Dictionary(uniqueKeysWithValues: genres.map { ($0.id, $0) })
        artworkStore = [:]
        historyStore = Dictionary(uniqueKeysWithValues: history.map { ($0.sessionID, $0) })
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

    public func isArtworkReferenced(_ artworkID: ArtworkID) async throws -> Bool {
        try checkReadFailure()
        return trackStore.values.contains { $0.artworkID == artworkID }
            || albumStore.values.contains { $0.artworkID == artworkID }
            || artistStore.values.contains { $0.artworkID == artworkID }
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
                    trackIDs.insert(value.id)
                    categories.insert(.tracks)
                case .album(let value):
                    nextAlbums[value.id] = value
                    albumIDs.insert(value.id)
                    categories.insert(.albums)
                case .artist(let value):
                    nextArtists[value.id] = value
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

        trackStore = nextTracks
        albumStore = nextAlbums
        artistStore = nextArtists
        genreStore = nextGenres
        artworkStore = nextArtwork
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
        var removed = Set<MediaItemID>()
        for itemID in itemIDs where trackStore.removeValue(forKey: itemID) != nil {
            removed.insert(itemID)
        }
        guard !removed.isEmpty else { return }
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

    private func replacing(_ track: Track, albumID: AlbumID?) -> Track {
        Track(
            id: track.id,
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
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
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
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
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: genreIDs,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
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
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
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
            title: track.title,
            sortTitle: track.sortTitle,
            albumID: track.albumID,
            artistIDs: track.artistIDs,
            genreIDs: track.genreIDs,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
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
