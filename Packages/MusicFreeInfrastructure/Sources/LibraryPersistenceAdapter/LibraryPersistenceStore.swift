import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SwiftData

private struct StoredTrack {
    var value: Track
    let dateAddedAt: Date
}

private struct StoredAlbum {
    var value: Album
    let dateAddedAt: Date
}

private struct StoredArtist {
    var value: Artist
    let dateAddedAt: Date
}

private struct StoredGenre {
    var value: Genre
    let dateAddedAt: Date
}

private struct LibrarySnapshot {
    var tracks: [MediaItemID: StoredTrack]
    var albums: [AlbumID: StoredAlbum]
    var artists: [ArtistID: StoredArtist]
    var genres: [GenreID: StoredGenre]
    var artwork: [ArtworkID: ArtworkReference]
}

private enum PageKind: String, Codable {
    case tracks
    case albums
    case artists
    case genres
    case folders
    case playlists
    case history
}

private struct PageCursorPayload: Codable {
    let schema: Int
    let kind: PageKind
    let revision: UInt64
    let fingerprint: String
    let offset: Int
}

private final class LibraryChangeHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]
    private var isFinished = false

    func makeStream() -> AsyncStream<LibraryChange> {
        let streamID = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.remove(streamID)
            }

            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
            } else {
                continuations[streamID] = continuation
                lock.unlock()
            }
        }
    }

    func publish(_ change: LibraryChange) {
        lock.lock()
        let current = Array(continuations.values)
        lock.unlock()
        for continuation in current {
            continuation.yield(change)
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let current = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in current {
            continuation.finish()
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func remove(_ streamID: UUID) {
        lock.lock()
        continuations.removeValue(forKey: streamID)
        lock.unlock()
    }
}

/// The shared serialized SwiftData lifecycle for all library repositories.
public actor LibraryPersistenceStore {
    public static let currentSchemaVersion = 1

    public let configuration: LibraryPersistenceConfiguration
    public let schemaVersion: Int

    private let container: ModelContainer
    private let context: ModelContext
    private var metadata: StoreMetadataRecord
    private var appliedTransactionKeys: Set<String>
    private var queueVersion: Int64
    private var closed = false
    private var browseRecordFetchCount: Int?
    private nonisolated let changeHub = LibraryChangeHub()

    public init(
        configuration: LibraryPersistenceConfiguration = .inMemory
    ) throws {
        self.configuration = configuration
        self.schemaVersion = Self.currentSchemaVersion

        do {
            let schema = Schema(versionedSchema: MusicFreeSchema.self)
            let modelConfiguration: ModelConfiguration
            switch configuration.location {
            case .inMemory:
                modelConfiguration = ModelConfiguration(
                    "MusicFreeLibrary",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            case .file(let url):
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true
                )
                modelConfiguration = ModelConfiguration(
                    "MusicFreeLibrary",
                    schema: schema,
                    url: url
                )
            }

            let container = try ModelContainer(
                for: schema,
                configurations: [modelConfiguration]
            )
            let context = ModelContext(container)
            let metadataRecords = try context.fetch(FetchDescriptor<StoreMetadataRecord>())
            if let existingMetadata = metadataRecords.first {
                guard existingMetadata.revision >= 0 else {
                    throw LibraryPersistenceError.corruptedStore
                }
                self.metadata = existingMetadata
            } else {
                let newMetadata = StoreMetadataRecord(
                    storageKey: "state",
                    revision: 0,
                    appliedTransactionKeys: try PersistenceCodec.encode(Set<String>())
                )
                context.insert(newMetadata)
                try context.save()
                self.metadata = newMetadata
            }
            self.appliedTransactionKeys = try PersistenceCodec.decode(
                Set<String>.self,
                from: self.metadata.appliedTransactionKeys
            )
            let queueRecords = try context.fetch(FetchDescriptor<PlaybackQueueRecord>())
            self.queueVersion = queueRecords.first?.version ?? 0
            self.container = container
            self.context = context
        } catch let error as LibraryPersistenceError {
            throw error
        } catch {
            throw LibraryPersistenceError.openFailed
        }
    }

    /// Returns the current optimistic-concurrency revision.
    public func currentRevision() throws -> LibraryRevision {
        try ensureOpen()
        return try revisionValue()
    }

    /// Finishes change streams and rejects future repository operations.
    public func close() {
        guard !closed else { return }
        closed = true
        changeHub.finish()
    }

    internal nonisolated func makeChangeStream() -> AsyncStream<LibraryChange> {
        changeHub.makeStream()
    }

    internal nonisolated var changeSubscriberCount: Int {
        changeHub.subscriberCount
    }

    internal func lastBrowseRecordFetchCount() -> Int? {
        browseRecordFetchCount
    }

    internal func track(id: MediaItemID) throws -> Track? {
        try ensureOpen()
        let storageKey = PersistenceKey.item(id)
        let descriptor = FetchDescriptor<TrackRecord>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        guard let record = try fetchFirst(descriptor) else {
            return nil
        }
        return try LibraryRecordMapper.track(from: record)
    }

    internal func album(id: AlbumID) throws -> Album? {
        try ensureOpen()
        let storageKey = id.rawValue
        let descriptor = FetchDescriptor<AlbumRecord>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        guard let record = try fetchFirst(descriptor) else {
            return nil
        }
        return try LibraryRecordMapper.album(from: record)
    }

    internal func artist(id: ArtistID) throws -> Artist? {
        try ensureOpen()
        let storageKey = id.rawValue
        let descriptor = FetchDescriptor<ArtistRecord>(
            predicate: #Predicate { $0.storageKey == storageKey }
        )
        guard let record = try fetchFirst(descriptor) else {
            return nil
        }
        return try LibraryRecordMapper.artist(from: record)
    }

    internal func tracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) throws -> LibraryPage<Track> {
        try ensureOpen()
        browseRecordFetchCount = nil
        if query.searchText == nil,
           query.sourceID == nil,
           query.albumID == nil,
           query.artistID == nil,
           query.genreID == nil,
           query.favorite == .any
        {
            let sortOrder = sortOrder(for: query.sort.direction)
            switch query.sort.key {
            case .dateAdded:
                return try boundedPage(
                    model: TrackRecord.self,
                    sortBy: [
                        SortDescriptor(\TrackRecord.dateAddedAt, order: sortOrder),
                        SortDescriptor(\TrackRecord.sourceID, order: .forward),
                        SortDescriptor(\TrackRecord.externalID, order: .forward),
                    ],
                    page: page,
                    kind: .tracks,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.track(from: $0) }
                )
            case .lastPlayed:
                return try boundedPage(
                    model: TrackRecord.self,
                    sortBy: [
                        SortDescriptor(\TrackRecord.lastPlayedAt, order: sortOrder),
                        SortDescriptor(\TrackRecord.sourceID, order: .forward),
                        SortDescriptor(\TrackRecord.externalID, order: .forward),
                    ],
                    page: page,
                    kind: .tracks,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.track(from: $0) }
                )
            case .playCount:
                return try boundedPage(
                    model: TrackRecord.self,
                    sortBy: [
                        SortDescriptor(\TrackRecord.playCount, order: sortOrder),
                        SortDescriptor(\TrackRecord.sourceID, order: .forward),
                        SortDescriptor(\TrackRecord.externalID, order: .forward),
                    ],
                    page: page,
                    kind: .tracks,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.track(from: $0) }
                )
            case .title, .albumTitle, .artistName, .duration:
                break
            }
        }
        let snapshot = try loadLibrarySnapshot()
        let artists = snapshot.artists
        let albums = snapshot.albums
        let genres = snapshot.genres
        let values = snapshot.tracks.values.filter { stored in
            let track = stored.value
            guard query.sourceID == nil || track.id.sourceID == query.sourceID else {
                return false
            }
            switch query.favorite {
            case .any:
                break
            case .favorite where !track.isFavorite:
                return false
            case .notFavorite where track.isFavorite:
                return false
            default:
                break
            }
            guard query.albumID == nil || track.albumID == query.albumID else {
                return false
            }
            guard query.artistID == nil || track.artistIDs.contains(query.artistID!) else {
                return false
            }
            guard query.genreID == nil || track.genreIDs.contains(query.genreID!) else {
                return false
            }
            guard let searchText = query.searchText else { return true }
            let albumText = track.albumID.flatMap { albums[$0]?.value.title } ?? ""
            let artistText = track.artistIDs.compactMap { artists[$0]?.value.name }.joined(separator: " ")
            let genreText = track.genreIDs.compactMap { genres[$0]?.value.name }.joined(separator: " ")
            let candidate: String
            switch query.searchScope {
            case .title:
                candidate = track.title
            case .album:
                candidate = albumText
            case .artist:
                candidate = artistText
            case .genre:
                candidate = genreText
            case .all:
                candidate = [track.title, albumText, artistText, genreText].joined(separator: " ")
            }
            return normalizedSearch(candidate).contains(normalizedSearch(searchText))
        }

        let sorted = Array(values).sorted { lhs, rhs in
            let result: Int
            switch query.sort.key {
            case .title:
                result = compare(normalizedSort(lhs.value.sortTitle ?? lhs.value.title),
                                 normalizedSort(rhs.value.sortTitle ?? rhs.value.title))
            case .albumTitle:
                result = compare(
                    normalizedSort(lhs.value.albumID.flatMap { albums[$0]?.value.sortTitle ?? albums[$0]?.value.title } ?? ""),
                    normalizedSort(rhs.value.albumID.flatMap { albums[$0]?.value.sortTitle ?? albums[$0]?.value.title } ?? "")
                )
            case .artistName:
                result = compare(
                    normalizedSort(firstArtistName(lhs.value, artists: artists)),
                    normalizedSort(firstArtistName(rhs.value, artists: artists))
                )
            case .dateAdded:
                result = compare(lhs.dateAddedAt, rhs.dateAddedAt)
            case .duration:
                result = compareOptional(lhs.value.duration, rhs.value.duration)
            case .lastPlayed:
                result = compareOptional(lhs.value.statistics.lastPlayedAt, rhs.value.statistics.lastPlayedAt)
            case .playCount:
                result = compare(lhs.value.statistics.playCount, rhs.value.statistics.playCount)
            }
            let directed = query.sort.direction == .ascending ? result : -result
            return directed == 0 ? lhs.value.id < rhs.value.id : directed < 0
        }.map(\.value)

        return try paginate(
            elements: sorted,
            page: page,
            kind: .tracks,
            fingerprint: try fingerprint(query)
        )
    }

    internal func albums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) throws -> LibraryPage<Album> {
        try ensureOpen()
        browseRecordFetchCount = nil
        if query.searchText == nil, query.sourceID == nil, query.artistID == nil {
            let sortOrder = sortOrder(for: query.sort.direction)
            switch query.sort.key {
            case .dateAdded:
                return try boundedPage(
                    model: AlbumRecord.self,
                    sortBy: [
                        SortDescriptor(\AlbumRecord.dateAddedAt, order: sortOrder),
                        SortDescriptor(\AlbumRecord.rawID, order: .forward),
                    ],
                    page: page,
                    kind: .albums,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.album(from: $0) }
                )
            case .year:
                return try boundedPage(
                    model: AlbumRecord.self,
                    sortBy: [
                        SortDescriptor(\AlbumRecord.releaseYear, order: sortOrder),
                        SortDescriptor(\AlbumRecord.rawID, order: .forward),
                    ],
                    page: page,
                    kind: .albums,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.album(from: $0) }
                )
            case .trackCount:
                return try boundedPage(
                    model: AlbumRecord.self,
                    sortBy: [
                        SortDescriptor(\AlbumRecord.trackCount, order: sortOrder),
                        SortDescriptor(\AlbumRecord.rawID, order: .forward),
                    ],
                    page: page,
                    kind: .albums,
                    fingerprint: try fingerprint(query),
                    map: { try LibraryRecordMapper.album(from: $0) }
                )
            case .title, .artistName:
                break
            }
        }
        let snapshot = try loadLibrarySnapshot()
        let sourceIDsByAlbum = sourceIDsByAlbum(snapshot.tracks.values)
        let artistNames = snapshot.artists
        let values = snapshot.albums.values.filter { stored in
            let album = stored.value
            guard query.sourceID == nil || sourceIDsByAlbum[album.id]?.contains(query.sourceID!) == true else {
                return false
            }
            guard query.artistID == nil || album.artistIDs.contains(query.artistID!) else {
                return false
            }
            guard let searchText = query.searchText else { return true }
            let artistText = album.artistIDs.compactMap { artistNames[$0]?.value.name }.joined(separator: " ")
            let candidate: String
            switch query.searchScope {
            case .artist:
                candidate = artistText
            case .all, .title, .album:
                candidate = [album.title, artistText].joined(separator: " ")
            case .genre:
                candidate = ""
            }
            return normalizedSearch(candidate).contains(normalizedSearch(searchText))
        }

        let sorted = Array(values).sorted { lhs, rhs in
            let result: Int
            switch query.sort.key {
            case .title:
                result = compare(normalizedSort(lhs.value.sortTitle ?? lhs.value.title),
                                 normalizedSort(rhs.value.sortTitle ?? rhs.value.title))
            case .artistName:
                result = compare(
                    normalizedSort(firstArtistName(lhs.value.artistIDs, artists: artistNames)),
                    normalizedSort(firstArtistName(rhs.value.artistIDs, artists: artistNames))
                )
            case .dateAdded:
                result = compare(lhs.dateAddedAt, rhs.dateAddedAt)
            case .year:
                result = compareOptional(lhs.value.releaseYear, rhs.value.releaseYear)
            case .trackCount:
                result = compareOptional(lhs.value.trackCount, rhs.value.trackCount)
            }
            let directed = query.sort.direction == .ascending ? result : -result
            return directed == 0 ? lhs.value.id < rhs.value.id : directed < 0
        }.map(\.value)

        return try paginate(
            elements: sorted,
            page: page,
            kind: .albums,
            fingerprint: try fingerprint(query)
        )
    }

    internal func artists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) throws -> LibraryPage<Artist> {
        try ensureOpen()
        browseRecordFetchCount = nil
        if query.searchText == nil, query.sourceID == nil, query.sort.key == .dateAdded {
            return try boundedPage(
                model: ArtistRecord.self,
                sortBy: [
                    SortDescriptor(
                        \ArtistRecord.dateAddedAt,
                        order: sortOrder(for: query.sort.direction)
                    ),
                    SortDescriptor(\ArtistRecord.rawID, order: .forward),
                ],
                page: page,
                kind: .artists,
                fingerprint: try fingerprint(query),
                map: { try LibraryRecordMapper.artist(from: $0) }
            )
        }
        let snapshot = try loadLibrarySnapshot()
        let sourceIDsByArtist = sourceIDsByArtist(snapshot.tracks.values)
        let values = snapshot.artists.values.filter { stored in
            let artist = stored.value
            guard query.sourceID == nil || sourceIDsByArtist[artist.id]?.contains(query.sourceID!) == true else {
                return false
            }
            guard let searchText = query.searchText else { return true }
            return normalizedSearch(artist.name).contains(normalizedSearch(searchText))
        }

        let sorted = Array(values).sorted { lhs, rhs in
            let result: Int
            switch query.sort.key {
            case .name:
                result = compare(normalizedSort(lhs.value.sortName ?? lhs.value.name),
                                 normalizedSort(rhs.value.sortName ?? rhs.value.name))
            case .dateAdded:
                result = compare(lhs.dateAddedAt, rhs.dateAddedAt)
            case .albumCount:
                result = compare(
                    albumCount(for: lhs.value.id, in: snapshot),
                    albumCount(for: rhs.value.id, in: snapshot)
                )
            case .trackCount:
                result = compare(
                    trackCount(for: lhs.value.id, in: snapshot),
                    trackCount(for: rhs.value.id, in: snapshot)
                )
            }
            let directed = query.sort.direction == .ascending ? result : -result
            return directed == 0 ? lhs.value.id < rhs.value.id : directed < 0
        }.map(\.value)

        return try paginate(
            elements: sorted,
            page: page,
            kind: .artists,
            fingerprint: try fingerprint(query)
        )
    }

    internal func genres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) throws -> LibraryPage<Genre> {
        try ensureOpen()
        let snapshot = try loadLibrarySnapshot()
        let sourceIDsByGenre = sourceIDsByGenre(snapshot.tracks.values)
        let values = snapshot.genres.values.filter { stored in
            let genre = stored.value
            guard query.sourceID == nil || sourceIDsByGenre[genre.id]?.contains(query.sourceID!) == true else {
                return false
            }
            guard let searchText = query.searchText else { return true }
            return normalizedSearch(genre.name).contains(normalizedSearch(searchText))
        }
        let sorted = Array<StoredGenre>(values).sorted(by: { lhs, rhs in
            let result: Int
            switch query.sort.key {
            case .name:
                result = compare(
                    normalizedSort(lhs.value.sortName ?? lhs.value.name),
                    normalizedSort(rhs.value.sortName ?? rhs.value.name)
                )
            case .trackCount:
                result = compare(
                    genreTrackCount(for: lhs.value.id, in: snapshot),
                    genreTrackCount(for: rhs.value.id, in: snapshot)
                )
            }
            let directed = query.sort.direction == .ascending ? result : -result
            return directed == 0 ? lhs.value.id < rhs.value.id : directed < 0
        }).map(\.value)
        return try paginate(
            elements: sorted,
            page: page,
            kind: .genres,
            fingerprint: try fingerprint(query)
        )
    }

    internal func folders(page: LibraryPageRequest) throws -> LibraryPage<LibraryFolder> {
        try ensureOpen()
        let snapshot = try loadLibrarySnapshot()
        var counts: [String: Int] = [:]
        for track in snapshot.tracks.values {
            guard let path = track.value.folderPath else { continue }
            counts[path, default: 0] += 1
        }
        let folders = counts
            .map { LibraryFolder(path: $0.key, trackCount: $0.value) }
            .sorted { lhs, rhs in
                let leftName = LibrarySortSupport.normalizedSortValue(
                    LibrarySortSupport.leafName(of: lhs.path)
                )
                let rightName = LibrarySortSupport.normalizedSortValue(
                    LibrarySortSupport.leafName(of: rhs.path)
                )
                if leftName != rightName { return leftName < rightName }
                let pathComparison = lhs.path.localizedStandardCompare(rhs.path)
                if pathComparison != .orderedSame {
                    return pathComparison == .orderedAscending
                }
                return lhs.path < rhs.path
            }
        return try paginate(
            elements: folders,
            page: page,
            kind: .folders,
            fingerprint: "folders"
        )
    }

    internal func playlists(page: LibraryPageRequest) throws -> LibraryPage<Playlist> {
        try ensureOpen()
        let records = try fetch(PlaylistRecord.self)
        let playlists = try records.map { try LibraryRecordMapper.playlist(from: $0) }
        let sorted = playlists.sorted {
            let lhsKey = normalizedSort($0.sortName ?? $0.name)
            let rhsKey = normalizedSort($1.sortName ?? $1.name)
            let result = compare(lhsKey, rhsKey)
            return result == 0 ? $0.id < $1.id : result < 0
        }
        return try paginate(elements: sorted, page: page, kind: .playlists, fingerprint: "playlists")
    }

    internal func entries(in playlistID: PlaylistID) throws -> [PlaylistEntry] {
        try ensureOpen()
        let records = try fetch(PlaylistEntryRecord.self).filter { $0.playlistID == playlistID.rawValue }
        return try records.map { try LibraryRecordMapper.entry(from: $0) }.sorted()
    }

    internal func recentHistory(page: LibraryPageRequest) throws -> LibraryPage<PlaybackHistoryRecord> {
        try ensureOpen()
        browseRecordFetchCount = nil
        return try boundedPage(
            model: PlaybackHistoryRecordModel.self,
            sortBy: [
                SortDescriptor(\PlaybackHistoryRecordModel.lastEventAt, order: .reverse),
                SortDescriptor(\PlaybackHistoryRecordModel.storageKey, order: .forward),
            ],
            page: page,
            kind: .history,
            fingerprint: "history",
            map: { try PlaybackRecordMapper.history(from: $0) }
        )
    }

    internal func clearHistory() throws {
        try ensureOpen()
        let records = try fetch(PlaybackHistoryRecordModel.self)
        guard !records.isEmpty else { return }

        let itemIDs = Set(records.map {
            MediaItemID(
                sourceID: MediaSourceID($0.sourceID),
                externalID: $0.externalID
            )
        })
        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys

        do {
            records.forEach(context.delete)
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playbackHistory],
                affectedIDs: LibraryAffectedIDs(trackIDs: itemIDs)
            ))
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func loadQueue() throws -> PlaybackQueueSnapshot {
        try ensureOpen()
        guard let record = try fetch(PlaybackQueueRecord.self).first else {
            return .empty
        }
        return try PlaybackRecordMapper.queue(from: record)
    }

    internal func apply(_ transaction: LibraryTransaction) throws {
        try ensureOpen()
        if appliedTransactionKeys.contains(transaction.idempotencyKey) {
            throw LibraryError.conflict(.transactionAlreadyApplied)
        }
        try checkExpectedRevision(transaction.expectedRevision)

        let before = try loadLibrarySnapshot()
        var after = before
        var trackIDs = Set<MediaItemID>()
        var albumIDs = Set<AlbumID>()
        var artistIDs = Set<ArtistID>()
        var genreIDs = Set<GenreID>()
        var artworkIDs = Set<ArtworkID>()
        var categories = Set<LibraryChangeCategory>()
        var upsertKeys = Set<String>()
        var relationKeys = Set<String>()
        var statisticsKeys = Set<MediaItemID>()

        // Apply value upserts first so a transaction can refer to another
        // value that is introduced by the same request.
        for mutation in transaction.mutations {
            guard case .upsert(let upsert) = mutation else { continue }
            switch upsert {
            case .track(let value):
                guard upsertKeys.insert("track:\(PersistenceKey.item(value.id))").inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                after.tracks[value.id] = StoredTrack(
                    value: value,
                    dateAddedAt: before.tracks[value.id]?.dateAddedAt ?? Date()
                )
                trackIDs.insert(value.id)
                categories.insert(.tracks)
            case .album(let value):
                guard upsertKeys.insert("album:\(value.id.rawValue)").inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                after.albums[value.id] = StoredAlbum(
                    value: value,
                    dateAddedAt: before.albums[value.id]?.dateAddedAt ?? Date()
                )
                albumIDs.insert(value.id)
                categories.insert(.albums)
            case .artist(let value):
                guard upsertKeys.insert("artist:\(value.id.rawValue)").inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                after.artists[value.id] = StoredArtist(
                    value: value,
                    dateAddedAt: before.artists[value.id]?.dateAddedAt ?? Date()
                )
                artistIDs.insert(value.id)
                categories.insert(.artists)
            case .genre(let value):
                guard upsertKeys.insert("genre:\(value.id.rawValue)").inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                after.genres[value.id] = StoredGenre(
                    value: value,
                    dateAddedAt: before.genres[value.id]?.dateAddedAt ?? Date()
                )
                genreIDs.insert(value.id)
                categories.insert(.genres)
            case .artwork(let value):
                guard upsertKeys.insert("artwork:\(value.id.rawValue)").inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                after.artwork[value.id] = value
                artworkIDs.insert(value.id)
                categories.insert(.artwork)
            }
        }

        for mutation in transaction.mutations {
            switch mutation {
            case .upsert:
                continue
            case .relation(let relation):
                switch relation {
                case .setAlbum(let trackID, let albumID):
                    guard relationKeys.insert("album:\(PersistenceKey.item(trackID))").inserted else {
                        throw LibraryError.constraint(.duplicateMutation)
                    }
                    guard var track = after.tracks[trackID] else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    if let albumID, after.albums[albumID] == nil {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    track.value = replacing(track.value, albumID: albumID)
                    after.tracks[trackID] = track
                    trackIDs.insert(trackID)
                    albumIDs.formUnion([albumID].compactMap { $0 })
                    categories.insert(.tracks)
                case .setArtists(let trackID, let values):
                    guard relationKeys.insert("artists:\(PersistenceKey.item(trackID))").inserted else {
                        throw LibraryError.constraint(.duplicateMutation)
                    }
                    guard var track = after.tracks[trackID],
                          Set(values).count == values.count,
                          values.allSatisfy({ after.artists[$0] != nil })
                    else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    track.value = replacing(track.value, artistIDs: values)
                    after.tracks[trackID] = track
                    trackIDs.insert(trackID)
                    artistIDs.formUnion(values)
                    categories.insert(.tracks)
                case .setGenres(let trackID, let values):
                    guard relationKeys.insert("genres:\(PersistenceKey.item(trackID))").inserted else {
                        throw LibraryError.constraint(.duplicateMutation)
                    }
                    guard var track = after.tracks[trackID],
                          Set(values).count == values.count,
                          values.allSatisfy({ after.genres[$0] != nil })
                    else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    track.value = replacing(track.value, genreIDs: values)
                    after.tracks[trackID] = track
                    trackIDs.insert(trackID)
                    genreIDs.formUnion(values)
                    categories.insert(.tracks)
                case .setArtwork(let trackID, let artworkID):
                    guard relationKeys.insert("artwork:\(PersistenceKey.item(trackID))").inserted else {
                        throw LibraryError.constraint(.duplicateMutation)
                    }
                    guard var track = after.tracks[trackID] else {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    if let artworkID, after.artwork[artworkID] == nil {
                        throw LibraryError.constraint(.danglingReference)
                    }
                    track.value = replacing(track.value, artwork: artworkID.map { after.artwork[$0]! })
                    after.tracks[trackID] = track
                    trackIDs.insert(trackID)
                    artworkIDs.formUnion([artworkID].compactMap { $0 })
                    categories.insert(.tracks)
                }
            case .statistics(let statistics):
                let trackID: MediaItemID
                switch statistics {
                case .replace(let value, _), .increment(let value, _):
                    trackID = value
                }
                guard statisticsKeys.insert(trackID).inserted else {
                    throw LibraryError.constraint(.duplicateMutation)
                }
                guard var track = after.tracks[trackID] else {
                    throw LibraryError.constraint(.danglingReference)
                }
                switch statistics {
                case .replace(_, let value):
                    track.value = replacing(track.value, statistics: value)
                case .increment(_, let delta):
                    guard delta.isNonNegative else {
                        throw LibraryError.constraint(.invalidStatisticsDelta)
                    }
                    track.value = replacing(track.value, statistics: increment(
                        track.value.statistics,
                        by: delta
                    ))
                }
                after.tracks[trackID] = track
                trackIDs.insert(trackID)
                categories.insert(.playbackStatistics)
            }
        }

        try validateReferences(in: after)

        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            for trackID in trackIDs {
                guard let value = after.tracks[trackID] else { continue }
                try persistTrack(value, existing: before.tracks[trackID])
            }
            for albumID in albumIDs {
                guard let value = after.albums[albumID] else { continue }
                try persistAlbum(value, existing: before.albums[albumID])
            }
            for artistID in artistIDs {
                guard let value = after.artists[artistID] else { continue }
                try persistArtist(value, existing: before.artists[artistID])
            }
            for genreID in genreIDs {
                guard let value = after.genres[genreID] else { continue }
                try persistGenre(value, existing: before.genres[genreID])
            }
            for artworkID in artworkIDs {
                guard let value = after.artwork[artworkID] else { continue }
                try persistArtwork(value, existing: before.artwork[artworkID])
            }

            let revision = try advanceRevision(idempotencyKey: transaction.idempotencyKey)
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: categories,
                affectedIDs: LibraryAffectedIDs(
                    trackIDs: trackIDs,
                    albumIDs: albumIDs,
                    artistIDs: artistIDs,
                    genreIDs: genreIDs,
                    artworkIDs: artworkIDs
                )
            ))
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func remove(_ itemIDs: Set<MediaItemID>) throws {
        try ensureOpen()
        guard !itemIDs.isEmpty else { return }

        let existingTrackRecords = try fetch(TrackRecord.self).filter {
            itemIDs.contains(MediaItemID(sourceID: MediaSourceID($0.sourceID), externalID: $0.externalID))
        }
        guard !existingTrackRecords.isEmpty else { return }

        var playlistIDs = Set<PlaylistID>()
        let entryRecords = try fetch(PlaylistEntryRecord.self).filter { record in
            let itemID = MediaItemID(sourceID: MediaSourceID(record.sourceID), externalID: record.externalID)
            guard itemIDs.contains(itemID) else { return false }
            playlistIDs.insert(PlaylistID(record.playlistID))
            return true
        }
        let historyRecords = try fetch(PlaybackHistoryRecordModel.self).filter { record in
            itemIDs.contains(MediaItemID(sourceID: MediaSourceID(record.sourceID), externalID: record.externalID))
        }

        do {
            for record in existingTrackRecords {
                context.delete(record)
            }
            for record in entryRecords {
                context.delete(record)
            }
            for record in historyRecords {
                context.delete(record)
            }

            if let queueRecord = try fetch(PlaybackQueueRecord.self).first {
                let snapshot = try PlaybackRecordMapper.queue(from: queueRecord)
                let remainingEntries = snapshot.entries.filter { !itemIDs.contains($0.itemID) }
                if remainingEntries.count != snapshot.entries.count {
                    let remainingIDs = Set(remainingEntries.map(\.id))
                    let currentEntryID = snapshot.currentEntryID.flatMap { remainingIDs.contains($0) ? $0 : nil }
                    let shuffleOrder = snapshot.shuffleOrder.filter { remainingIDs.contains($0) }
                    let pruned = PlaybackQueueSnapshot(
                        entries: remainingEntries,
                        currentEntryID: currentEntryID,
                        repeatMode: snapshot.repeatMode,
                        shuffleMode: snapshot.shuffleMode,
                        shuffleSeed: snapshot.shuffleSeed,
                        shuffleOrder: shuffleOrder,
                        resumePosition: currentEntryID == nil ? nil : snapshot.resumePosition
                    )
                    queueVersion = max(queueVersion + 1, queueRecord.version + 1)
                    try PlaybackRecordMapper.update(queueRecord, from: pruned, version: queueVersion)
                }
            }

            let oldRevision = metadata.revision
            let oldAppliedData = metadata.appliedTransactionKeys
            let oldAppliedKeys = appliedTransactionKeys
            do {
                let revision = try advanceRevision()
                try saveContext()
                var categories: Set<LibraryChangeCategory> = [.tracks, .deletions]
                if !entryRecords.isEmpty { categories.insert(.playlistEntries) }
                if !historyRecords.isEmpty { categories.insert(.playbackHistory) }
                publish(LibraryChange(
                    revision: revision,
                    categories: categories,
                    affectedIDs: LibraryAffectedIDs(
                        trackIDs: Set(existingTrackRecords.map {
                            MediaItemID(sourceID: MediaSourceID($0.sourceID), externalID: $0.externalID)
                        }),
                        playlistIDs: playlistIDs
                    )
                ))
            } catch {
                context.rollback()
                metadata.revision = oldRevision
                metadata.appliedTransactionKeys = oldAppliedData
                appliedTransactionKeys = oldAppliedKeys
                throw error
            }
        } catch {
            context.rollback()
            throw error
        }
    }

    internal func createPlaylist(_ draft: PlaylistDraft) throws -> Playlist {
        try ensureOpen()
        try checkExpectedRevision(nil)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.constraint(.invalidPlaylistName) }
        if let artworkID = draft.artworkID,
           try loadLibrarySnapshot().artwork[artworkID] == nil {
            throw LibraryError.constraint(.danglingReference)
        }
        let now = Date()
        let value = Playlist(
            id: PlaylistID(UUID().uuidString.lowercased()),
            name: name,
            sortName: normalizedOptionalText(draft.sortName),
            artwork: draft.artworkID.map { ArtworkReference(id: $0) },
            createdAt: now,
            updatedAt: now
        )
        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            context.insert(try LibraryRecordMapper.makePlaylist(value))
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playlists],
                affectedIDs: LibraryAffectedIDs(playlistIDs: [value.id])
            ))
            return value
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func updatePlaylist(_ mutation: PlaylistMutation) throws -> Playlist {
        try ensureOpen()
        try checkExpectedRevision(mutation.expectedRevision)
        guard let record = try fetch(PlaylistRecord.self).first(where: {
            $0.storageKey == PersistenceKey.playlist(mutation.playlistID)
        }) else {
            throw LibraryError.constraint(.danglingReference)
        }
        var value = try LibraryRecordMapper.playlist(from: record)
        let snapshot = try loadLibrarySnapshot()
        let newName: String
        let newSortName: String?
        let newArtworkID: ArtworkID?
        switch mutation.change {
        case .rename(let name):
            newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            newSortName = value.sortName
            newArtworkID = value.artworkID
        case .setSortName(let sortName):
            newName = value.name
            newSortName = normalizedOptionalText(sortName)
            newArtworkID = value.artworkID
        case .setArtwork(let artworkID):
            newName = value.name
            newSortName = value.sortName
            newArtworkID = artworkID
        case .replace(let name, let sortName, let artworkID):
            newName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            newSortName = normalizedOptionalText(sortName)
            newArtworkID = artworkID
        }
        guard !newName.isEmpty else { throw LibraryError.constraint(.invalidPlaylistName) }
        if let newArtworkID, snapshot.artwork[newArtworkID] == nil {
            throw LibraryError.constraint(.danglingReference)
        }
        let updatedAt = Date()
        value = Playlist(
            id: value.id,
            name: newName,
            sortName: newSortName,
            artwork: newArtworkID.map { ArtworkReference(id: $0) },
            createdAt: value.createdAt,
            updatedAt: updatedAt
        )

        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            try LibraryRecordMapper.update(record, from: value)
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playlists],
                affectedIDs: LibraryAffectedIDs(playlistIDs: [value.id])
            ))
            return value
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func applyPlaylistEntries(_ mutation: PlaylistEntriesMutation) throws {
        try ensureOpen()
        try checkExpectedRevision(mutation.expectedRevision)
        guard try fetch(PlaylistRecord.self).contains(where: {
            $0.storageKey == PersistenceKey.playlist(mutation.playlistID)
        }) else {
            throw LibraryError.constraint(.danglingReference)
        }
        let snapshot = try loadLibrarySnapshot()
        let current = try entries(in: mutation.playlistID).sorted { $0.position < $1.position }
        var orderedItems = current.map(\.trackID)

        switch mutation.operation {
        case .insert(let insertions):
            for insertion in insertions {
                guard insertion.hasValidPosition, insertion.position <= orderedItems.count else {
                    throw LibraryError.constraint(.invalidPlaylistPosition)
                }
                guard snapshot.tracks[insertion.itemID] != nil else {
                    throw LibraryError.constraint(.danglingReference)
                }
                guard !orderedItems.contains(insertion.itemID) else {
                    throw LibraryError.constraint(.duplicatePlaylistMember)
                }
                orderedItems.insert(insertion.itemID, at: insertion.position)
            }
        case .move(let moves):
            for move in moves {
                guard move.hasValidPosition, move.position < orderedItems.count,
                      let currentIndex = orderedItems.firstIndex(of: move.itemID)
                else {
                    throw LibraryError.constraint(.invalidPlaylistPosition)
                }
                let item = orderedItems.remove(at: currentIndex)
                orderedItems.insert(item, at: move.position)
            }
        case .remove(let itemIDs):
            orderedItems.removeAll { itemIDs.contains($0) }
        case .reorder(let itemIDs):
            guard Set(itemIDs).count == itemIDs.count,
                  Set(itemIDs) == Set(orderedItems)
            else {
                throw LibraryError.constraint(.duplicatePlaylistMember)
            }
            guard itemIDs.allSatisfy({ snapshot.tracks[$0] != nil }) else {
                throw LibraryError.constraint(.danglingReference)
            }
            orderedItems = itemIDs
        }

        let updated = orderedItems.enumerated().map {
            PlaylistEntry(playlistID: mutation.playlistID, trackID: $0.element, position: $0.offset)
        }
        guard updated != current else { return }

        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            let records = try fetch(PlaylistEntryRecord.self).filter {
                $0.playlistID == mutation.playlistID.rawValue
            }
            for record in records {
                context.delete(record)
            }
            for entry in updated {
                context.insert(LibraryRecordMapper.makeEntry(entry))
            }
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playlistEntries],
                affectedIDs: LibraryAffectedIDs(playlistIDs: [mutation.playlistID])
            ))
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func deletePlaylist(_ playlistID: PlaylistID) throws {
        try ensureOpen()
        let playlists = try fetch(PlaylistRecord.self)
        guard let record = playlists.first(where: { $0.storageKey == PersistenceKey.playlist(playlistID) }) else {
            return
        }
        let entries = try fetch(PlaylistEntryRecord.self).filter { $0.playlistID == playlistID.rawValue }
        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            context.delete(record)
            for entry in entries {
                context.delete(entry)
            }
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playlists, .playlistEntries],
                affectedIDs: LibraryAffectedIDs(playlistIDs: [playlistID])
            ))
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func recordHistory(_ event: PlaybackHistoryEvent) throws {
        try ensureOpen()
        let itemID: MediaItemID
        let sessionID: UUID
        switch event {
        case .started(let value):
            itemID = value.itemID
            sessionID = value.sessionID
        case .validPlayback(let value):
            itemID = value.itemID
            sessionID = value.sessionID
            guard value.playedDuration >= .zero else {
                throw LibraryError.constraint(.invalidStatisticsDelta)
            }
        case .completed(let value):
            itemID = value.itemID
            sessionID = value.sessionID
        case .skipped(let value):
            itemID = value.itemID
            sessionID = value.sessionID
            guard value.playedDuration >= .zero else {
                throw LibraryError.constraint(.invalidStatisticsDelta)
            }
        }

        let snapshot = try loadLibrarySnapshot()
        guard var track = snapshot.tracks[itemID] else {
            throw LibraryError.constraint(.danglingReference)
        }
        let historyRecords = try fetch(PlaybackHistoryRecordModel.self)
        let existingRecord = historyRecords.first(where: { $0.storageKey == PersistenceKey.history(sessionID) })
        let existingHistory = try existingRecord.map { try PlaybackRecordMapper.history(from: $0) }
        let nowHistory: PlaybackHistoryRecord
        let newStatistics: PlaybackStatistics

        switch event {
        case .started(let value):
            nowHistory = PlaybackHistoryRecord(
                sessionID: sessionID,
                itemID: itemID,
                lastStartedAt: existingHistory?.lastStartedAt ?? value.startedAt,
                lastEventAt: max(existingHistory?.lastEventAt ?? value.startedAt, value.startedAt),
                totalPlayedDuration: existingHistory?.totalPlayedDuration ?? .zero,
                lastPosition: existingHistory?.lastPosition,
                lastCompletionReason: existingHistory?.lastCompletionReason
            )
            newStatistics = existingHistory == nil
                ? replacing(track.value.statistics, playCount: track.value.statistics.playCount + 1, lastPlayedAt: value.startedAt)
                : track.value.statistics
        case .validPlayback(let value):
            let total = (existingHistory?.totalPlayedDuration ?? .zero) + value.playedDuration
            nowHistory = PlaybackHistoryRecord(
                sessionID: sessionID,
                itemID: itemID,
                lastStartedAt: existingHistory?.lastStartedAt ?? value.occurredAt,
                lastEventAt: max(existingHistory?.lastEventAt ?? value.occurredAt, value.occurredAt),
                totalPlayedDuration: total,
                lastPosition: total,
                lastCompletionReason: existingHistory?.lastCompletionReason
            )
            newStatistics = increment(
                track.value.statistics,
                by: PlaybackStatisticsDelta(
                    totalListeningDuration: value.playedDuration,
                    lastPlayedAt: value.occurredAt
                )
            )
        case .completed(let value):
            nowHistory = PlaybackHistoryRecord(
                sessionID: sessionID,
                itemID: itemID,
                lastStartedAt: existingHistory?.lastStartedAt ?? value.occurredAt,
                lastEventAt: max(existingHistory?.lastEventAt ?? value.occurredAt, value.occurredAt),
                totalPlayedDuration: existingHistory?.totalPlayedDuration ?? .zero,
                lastPosition: existingHistory?.lastPosition,
                lastCompletionReason: value.reason
            )
            newStatistics = replacing(
                track.value.statistics,
                completionCount: track.value.statistics.completionCount + 1,
                lastPlayedAt: value.occurredAt,
                lastCompletionReason: value.reason
            )
        case .skipped(let value):
            let total = (existingHistory?.totalPlayedDuration ?? .zero) + value.playedDuration
            nowHistory = PlaybackHistoryRecord(
                sessionID: sessionID,
                itemID: itemID,
                lastStartedAt: existingHistory?.lastStartedAt ?? value.occurredAt,
                lastEventAt: max(existingHistory?.lastEventAt ?? value.occurredAt, value.occurredAt),
                totalPlayedDuration: total,
                lastPosition: total,
                lastCompletionReason: .skipped
            )
            newStatistics = increment(
                track.value.statistics,
                by: PlaybackStatisticsDelta(
                    skipCount: 1,
                    totalListeningDuration: value.playedDuration,
                    lastPlayedAt: value.occurredAt
                )
            )
        }
        track.value = replacing(track.value, statistics: newStatistics)

        let oldRevision = metadata.revision
        let oldAppliedData = metadata.appliedTransactionKeys
        let oldAppliedKeys = appliedTransactionKeys
        do {
            try persistTrack(track, existing: snapshot.tracks[itemID])
            if let existingRecord {
                try PlaybackRecordMapper.update(existingRecord, from: nowHistory)
            } else {
                context.insert(try PlaybackRecordMapper.makeHistory(nowHistory))
            }
            let revision = try advanceRevision()
            try saveContext()
            publish(LibraryChange(
                revision: revision,
                categories: [.playbackHistory, .playbackStatistics],
                affectedIDs: LibraryAffectedIDs(trackIDs: [itemID])
            ))
        } catch {
            context.rollback()
            metadata.revision = oldRevision
            metadata.appliedTransactionKeys = oldAppliedData
            appliedTransactionKeys = oldAppliedKeys
            throw error
        }
    }

    internal func saveQueue(_ snapshot: PlaybackQueueSnapshot) throws {
        try ensureOpen()
        guard let existingRecord = try fetch(PlaybackQueueRecord.self).first else {
            let oldVersion = queueVersion
            do {
                queueVersion = max(queueVersion + 1, 1)
                context.insert(try PlaybackRecordMapper.makeQueue(snapshot, version: queueVersion))
                try saveContext()
            } catch {
                context.rollback()
                queueVersion = oldVersion
                throw error
            }
            return
        }
        let oldVersion = queueVersion
        let oldPayload = existingRecord.payload
        guard try PlaybackRecordMapper.queue(from: existingRecord) != snapshot else { return }
        do {
            queueVersion = max(queueVersion + 1, existingRecord.version + 1)
            try PlaybackRecordMapper.update(existingRecord, from: snapshot, version: queueVersion)
            try saveContext()
        } catch {
            context.rollback()
            queueVersion = oldVersion
            existingRecord.payload = oldPayload
            throw error
        }
    }

    private func ensureOpen() throws {
        guard !closed else { throw LibraryPersistenceError.closed }
    }

    private func revisionValue() throws -> LibraryRevision {
        guard metadata.revision >= 0 else { throw LibraryPersistenceError.corruptedStore }
        return LibraryRevision(UInt64(metadata.revision))
    }

    private func fetch<Model: PersistentModel>(_ type: Model.Type) throws -> [Model] {
        do {
            return try context.fetch(FetchDescriptor<Model>())
        } catch {
            throw LibraryPersistenceError.corruptedStore
        }
    }

    private func fetchFirst<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>
    ) throws -> Model? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            throw LibraryPersistenceError.corruptedStore
        }
    }

    private func boundedPage<Model: PersistentModel, Element: Sendable>(
        model _: Model.Type,
        sortBy: [SortDescriptor<Model>],
        page: LibraryPageRequest,
        kind: PageKind,
        fingerprint: String,
        map: (Model) throws -> Element
    ) throws -> LibraryPage<Element> {
        let totalCount: Int
        do {
            totalCount = try context.fetchCount(FetchDescriptor<Model>())
        } catch {
            throw LibraryPersistenceError.corruptedStore
        }
        let revision = try revisionValue()
        let offset = try pageOffset(
            for: page,
            kind: kind,
            fingerprint: fingerprint,
            revision: revision,
            totalCount: totalCount
        )
        var descriptor = FetchDescriptor<Model>(sortBy: sortBy)
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = page.limit + 1

        let records: [Model]
        do {
            records = try context.fetch(descriptor)
        } catch {
            throw LibraryPersistenceError.corruptedStore
        }
        browseRecordFetchCount = records.count
        let visibleRecords = records.prefix(page.limit)
        let elements = try visibleRecords.map(map)
        let hasNextPage = records.count > page.limit
        let nextCursor = try hasNextPage
            ? makeCursor(
                kind: kind,
                revision: revision,
                fingerprint: fingerprint,
                offset: offset + elements.count
            )
            : nil
        return LibraryPage(elements: elements, nextCursor: nextCursor)
    }

    private func loadLibrarySnapshot() throws -> LibrarySnapshot {
        var snapshot = LibrarySnapshot(tracks: [:], albums: [:], artists: [:], genres: [:], artwork: [:])
        for record in try fetch(TrackRecord.self) {
            let value = try LibraryRecordMapper.track(from: record)
            guard snapshot.tracks[value.id] == nil else { throw LibraryPersistenceError.corruptedStore }
            snapshot.tracks[value.id] = StoredTrack(value: value, dateAddedAt: record.dateAddedAt)
        }
        for record in try fetch(AlbumRecord.self) {
            let value = try LibraryRecordMapper.album(from: record)
            guard snapshot.albums[value.id] == nil else { throw LibraryPersistenceError.corruptedStore }
            snapshot.albums[value.id] = StoredAlbum(value: value, dateAddedAt: record.dateAddedAt)
        }
        for record in try fetch(ArtistRecord.self) {
            let value = try LibraryRecordMapper.artist(from: record)
            guard snapshot.artists[value.id] == nil else { throw LibraryPersistenceError.corruptedStore }
            snapshot.artists[value.id] = StoredArtist(value: value, dateAddedAt: record.dateAddedAt)
        }
        for record in try fetch(GenreRecord.self) {
            let value = try LibraryRecordMapper.genre(from: record)
            guard snapshot.genres[value.id] == nil else { throw LibraryPersistenceError.corruptedStore }
            snapshot.genres[value.id] = StoredGenre(value: value, dateAddedAt: record.dateAddedAt)
        }
        for record in try fetch(ArtworkRecord.self) {
            let value = try LibraryRecordMapper.artwork(from: record)
            guard snapshot.artwork[value.id] == nil else { throw LibraryPersistenceError.corruptedStore }
            snapshot.artwork[value.id] = value
        }
        return snapshot
    }

    private func paginate<Element: Sendable>(
        elements: [Element],
        page: LibraryPageRequest,
        kind: PageKind,
        fingerprint: String
    ) throws -> LibraryPage<Element> {
        let revision = try revisionValue()
        let offset = try pageOffset(
            for: page,
            kind: kind,
            fingerprint: fingerprint,
            revision: revision,
            totalCount: elements.count
        )
        let end = min(offset + page.limit, elements.count)
        let nextCursor: LibraryCursor?
        if end < elements.count {
            nextCursor = try makeCursor(
                kind: kind,
                revision: revision,
                fingerprint: fingerprint,
                offset: end
            )
        } else {
            nextCursor = nil
        }
        return LibraryPage(elements: Array(elements[offset..<end]), nextCursor: nextCursor)
    }

    private func pageOffset(
        for page: LibraryPageRequest,
        kind: PageKind,
        fingerprint: String,
        revision: LibraryRevision,
        totalCount: Int
    ) throws -> Int {
        guard let cursor = page.cursor else { return 0 }
        let payload = try decodeCursor(cursor)
        guard payload.schema == Self.currentSchemaVersion,
              payload.kind == kind,
              payload.revision == revision.rawValue,
              payload.fingerprint == fingerprint,
              payload.offset >= 0,
              payload.offset <= totalCount
        else {
            throw LibraryError.query(.expiredCursor)
        }
        return payload.offset
    }

    private func makeCursor(
        kind: PageKind,
        revision: LibraryRevision,
        fingerprint: String,
        offset: Int
    ) throws -> LibraryCursor {
        let payload = PageCursorPayload(
            schema: Self.currentSchemaVersion,
            kind: kind,
            revision: revision.rawValue,
            fingerprint: fingerprint,
            offset: offset
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            throw LibraryPersistenceError.encodingFailed
        }
        return LibraryCursor(rawValue: data.base64EncodedString())
    }

    private func decodeCursor(_ cursor: LibraryCursor) throws -> PageCursorPayload {
        guard let data = Data(base64Encoded: cursor.rawValue) else {
            throw LibraryError.query(.invalidCursor)
        }
        do {
            return try JSONDecoder().decode(PageCursorPayload.self, from: data)
        } catch {
            throw LibraryError.query(.invalidCursor)
        }
    }

    private func fingerprint<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            throw LibraryPersistenceError.encodingFailed
        }
        return data.base64EncodedString()
    }

    private func normalizedSearch(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func normalizedSort(_ value: String) -> String {
        LibrarySortSupport.normalizedSortValue(value)
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case (let lhs?, let rhs?): return compare(lhs, rhs)
        }
    }

    private func sortOrder(for direction: LibrarySortDirection) -> SortOrder {
        direction == .ascending ? .forward : .reverse
    }

    private func firstArtistName(
        _ track: Track,
        artists: [ArtistID: StoredArtist]
    ) -> String {
        firstArtistName(track.artistIDs, artists: artists)
    }

    private func firstArtistName(
        _ artistIDs: [ArtistID],
        artists: [ArtistID: StoredArtist]
    ) -> String {
        artistIDs.compactMap { artists[$0]?.value.sortName ?? artists[$0]?.value.name }.first ?? ""
    }

    private func sourceIDsByAlbum(_ tracks: Dictionary<MediaItemID, StoredTrack>.Values) -> [AlbumID: Set<MediaSourceID>] {
        var result: [AlbumID: Set<MediaSourceID>] = [:]
        for track in tracks {
            if let albumID = track.value.albumID {
                result[albumID, default: []].insert(track.value.id.sourceID)
            }
        }
        return result
    }

    private func sourceIDsByArtist(_ tracks: Dictionary<MediaItemID, StoredTrack>.Values) -> [ArtistID: Set<MediaSourceID>] {
        var result: [ArtistID: Set<MediaSourceID>] = [:]
        for track in tracks {
            for artistID in track.value.artistIDs {
                result[artistID, default: []].insert(track.value.id.sourceID)
            }
        }
        return result
    }

    private func sourceIDsByGenre(_ tracks: Dictionary<MediaItemID, StoredTrack>.Values) -> [GenreID: Set<MediaSourceID>] {
        var result: [GenreID: Set<MediaSourceID>] = [:]
        for track in tracks {
            for genreID in track.value.genreIDs {
                result[genreID, default: []].insert(track.value.id.sourceID)
            }
        }
        return result
    }

    private func albumCount(for artistID: ArtistID, in snapshot: LibrarySnapshot) -> Int {
        snapshot.albums.values.filter { $0.value.artistIDs.contains(artistID) }.count
    }

    private func trackCount(for artistID: ArtistID, in snapshot: LibrarySnapshot) -> Int {
        snapshot.tracks.values.filter { $0.value.artistIDs.contains(artistID) }.count
    }

    private func genreTrackCount(for genreID: GenreID, in snapshot: LibrarySnapshot) -> Int {
        snapshot.tracks.values.filter { $0.value.genreIDs.contains(genreID) }.count
    }

    private func checkExpectedRevision(_ expected: LibraryRevision?) throws {
        guard let expected else { return }
        let actual = try revisionValue()
        guard actual == expected else {
            throw LibraryError.conflict(.revisionMismatch(expected: expected, actual: actual))
        }
    }

    private func advanceRevision(idempotencyKey: String? = nil) throws -> LibraryRevision {
        guard metadata.revision < Int64.max else {
            throw LibraryError.capacity(.resultTooLarge)
        }
        var keys = appliedTransactionKeys
        if let idempotencyKey {
            keys.insert(idempotencyKey)
        }
        let encodedKeys = try PersistenceCodec.encode(keys)
        metadata.revision += 1
        metadata.appliedTransactionKeys = encodedKeys
        appliedTransactionKeys = keys
        return LibraryRevision(UInt64(metadata.revision))
    }

    private func saveContext() throws {
        do {
            try context.save()
        } catch {
            throw LibraryError.capacity(.storageUnavailable)
        }
    }

    private func publish(_ change: LibraryChange) {
        changeHub.publish(change)
    }

    private func validateReferences(in snapshot: LibrarySnapshot) throws {
        for stored in snapshot.tracks.values {
            let track = stored.value
            if let albumID = track.albumID, snapshot.albums[albumID] == nil {
                throw LibraryError.constraint(.danglingReference)
            }
            guard track.artistIDs.allSatisfy({ snapshot.artists[$0] != nil }),
                  track.genreIDs.allSatisfy({ snapshot.genres[$0] != nil })
            else {
                throw LibraryError.constraint(.danglingReference)
            }
            if let artworkID = track.artworkID, snapshot.artwork[artworkID] == nil {
                throw LibraryError.constraint(.danglingReference)
            }
        }
        for stored in snapshot.albums.values {
            guard stored.value.artistIDs.allSatisfy({ snapshot.artists[$0] != nil }) else {
                throw LibraryError.constraint(.danglingReference)
            }
            if let artworkID = stored.value.artworkID, snapshot.artwork[artworkID] == nil {
                throw LibraryError.constraint(.danglingReference)
            }
        }
        for stored in snapshot.artists.values {
            if let artworkID = stored.value.artworkID, snapshot.artwork[artworkID] == nil {
                throw LibraryError.constraint(.danglingReference)
            }
        }
    }

    private func replacing(_ value: Track, albumID: AlbumID?) -> Track {
        Track(
            id: value.id,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: albumID,
            artistIDs: value.artistIDs,
            genreIDs: value.genreIDs,
            folderPath: value.folderPath,
            duration: value.duration,
            technicalInfo: value.technicalInfo,
            artwork: value.artwork,
            isFavorite: value.isFavorite,
            statistics: value.statistics
        )
    }

    private func replacing(_ value: Track, artistIDs: [ArtistID]) -> Track {
        Track(
            id: value.id,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: value.albumID,
            artistIDs: artistIDs,
            genreIDs: value.genreIDs,
            folderPath: value.folderPath,
            duration: value.duration,
            technicalInfo: value.technicalInfo,
            artwork: value.artwork,
            isFavorite: value.isFavorite,
            statistics: value.statistics
        )
    }

    private func replacing(_ value: Track, genreIDs: [GenreID]) -> Track {
        Track(
            id: value.id,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: value.albumID,
            artistIDs: value.artistIDs,
            genreIDs: genreIDs,
            folderPath: value.folderPath,
            duration: value.duration,
            technicalInfo: value.technicalInfo,
            artwork: value.artwork,
            isFavorite: value.isFavorite,
            statistics: value.statistics
        )
    }

    private func replacing(_ value: Track, artwork: ArtworkReference?) -> Track {
        Track(
            id: value.id,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: value.albumID,
            artistIDs: value.artistIDs,
            genreIDs: value.genreIDs,
            folderPath: value.folderPath,
            duration: value.duration,
            technicalInfo: value.technicalInfo,
            artwork: artwork,
            isFavorite: value.isFavorite,
            statistics: value.statistics
        )
    }

    private func replacing(_ value: Track, statistics: PlaybackStatistics) -> Track {
        Track(
            id: value.id,
            title: value.title,
            sortTitle: value.sortTitle,
            albumID: value.albumID,
            artistIDs: value.artistIDs,
            genreIDs: value.genreIDs,
            folderPath: value.folderPath,
            duration: value.duration,
            technicalInfo: value.technicalInfo,
            artwork: value.artwork,
            isFavorite: value.isFavorite,
            statistics: statistics
        )
    }

    private func replacing(
        _ value: PlaybackStatistics,
        playCount: Int,
        lastPlayedAt: Date
    ) -> PlaybackStatistics {
        PlaybackStatistics(
            playCount: playCount,
            completionCount: value.completionCount,
            skipCount: value.skipCount,
            lastPlayedAt: lastPlayedAt,
            lastCompletionReason: value.lastCompletionReason,
            totalListeningDuration: value.totalListeningDuration
        )
    }

    private func replacing(
        _ value: PlaybackStatistics,
        completionCount: Int,
        lastPlayedAt: Date,
        lastCompletionReason: PlaybackCompletionReason
    ) -> PlaybackStatistics {
        PlaybackStatistics(
            playCount: value.playCount,
            completionCount: completionCount,
            skipCount: value.skipCount,
            lastPlayedAt: lastPlayedAt,
            lastCompletionReason: lastCompletionReason,
            totalListeningDuration: value.totalListeningDuration
        )
    }

    private func increment(
        _ value: PlaybackStatistics,
        by delta: PlaybackStatisticsDelta
    ) -> PlaybackStatistics {
        PlaybackStatistics(
            playCount: value.playCount + delta.playCount,
            completionCount: value.completionCount + delta.completionCount,
            skipCount: value.skipCount + delta.skipCount,
            lastPlayedAt: latest(value.lastPlayedAt, delta.lastPlayedAt),
            lastCompletionReason: value.lastCompletionReason,
            totalListeningDuration: value.totalListeningDuration + delta.totalListeningDuration
        )
    }

    private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return value
        case (let lhs?, let rhs?): return max(lhs, rhs)
        }
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func persistTrack(_ value: StoredTrack, existing: StoredTrack?) throws {
        let key = PersistenceKey.item(value.value.id)
        if let record = try fetch(TrackRecord.self).first(where: { $0.storageKey == key }) {
            try LibraryRecordMapper.update(record, from: value.value)
        } else {
            context.insert(try LibraryRecordMapper.makeTrack(value.value, dateAddedAt: existing?.dateAddedAt ?? value.dateAddedAt))
        }
    }

    private func persistAlbum(_ value: StoredAlbum, existing: StoredAlbum?) throws {
        let key = value.value.id.rawValue
        if let record = try fetch(AlbumRecord.self).first(where: { $0.storageKey == key }) {
            try LibraryRecordMapper.update(record, from: value.value)
        } else {
            context.insert(try LibraryRecordMapper.makeAlbum(value.value, dateAddedAt: existing?.dateAddedAt ?? value.dateAddedAt))
        }
    }

    private func persistArtist(_ value: StoredArtist, existing: StoredArtist?) throws {
        let key = value.value.id.rawValue
        if let record = try fetch(ArtistRecord.self).first(where: { $0.storageKey == key }) {
            try LibraryRecordMapper.update(record, from: value.value)
        } else {
            context.insert(try LibraryRecordMapper.makeArtist(value.value, dateAddedAt: existing?.dateAddedAt ?? value.dateAddedAt))
        }
    }

    private func persistGenre(_ value: StoredGenre, existing: StoredGenre?) throws {
        let key = value.value.id.rawValue
        if let record = try fetch(GenreRecord.self).first(where: { $0.storageKey == key }) {
            try LibraryRecordMapper.update(record, from: value.value)
        } else {
            context.insert(try LibraryRecordMapper.makeGenre(value.value, dateAddedAt: existing?.dateAddedAt ?? value.dateAddedAt))
        }
    }

    private func persistArtwork(_ value: ArtworkReference, existing: ArtworkReference?) throws {
        let key = PersistenceKey.artwork(value.id)
        if let record = try fetch(ArtworkRecord.self).first(where: { $0.storageKey == key }) {
            try LibraryRecordMapper.update(record, from: value)
        } else {
            context.insert(try LibraryRecordMapper.makeArtwork(value))
        }
    }
}
