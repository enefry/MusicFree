import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import OSLog
import PlaybackAPI

private actor LibraryMutationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isActive = false
    private var waiters: [Waiter] = []

    func enter() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !isActive {
            isActive = true
            return true
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    func leave() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        } else {
            isActive = false
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

internal actor LibraryCoordinator: LibraryServing {
    private let repository: (any LibraryRepository)?
    private let remover: (any ManagedMediaRemoving)?
    private let artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)?
    private let artworkPruner: (@Sendable () async throws -> Void)?
    private let queueRepository: (any PlaybackQueueRepository)?
    private let historyRepository: (any PlaybackHistoryRepository)?
    private let deletionHandler: (@Sendable (Set<MediaItemID>) async throws -> Void)?
    private let libraryMutationGate = LibraryMutationGate()
    private var artworkPruneTask: Task<Void, Never>?
    private var artworkPruneNeedsRerun = false

    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "artwork-maintenance"
    )

    init(
        repository: (any LibraryRepository)?,
        remover: (any ManagedMediaRemoving)?,
        artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)? = nil,
        artworkPruner: (@Sendable () async throws -> Void)? = nil,
        queueRepository: (any PlaybackQueueRepository)?,
        historyRepository: (any PlaybackHistoryRepository)?,
        deletionHandler: (@Sendable (Set<MediaItemID>) async throws -> Void)? = nil
    ) {
        self.repository = repository
        self.remover = remover
        self.artworkWriter = artworkWriter
        self.artworkPruner = artworkPruner
        self.queueRepository = queueRepository
        self.historyRepository = historyRepository
        self.deletionHandler = deletionHandler
    }

    func track(id: MediaItemID) async throws -> Track? {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.track(id: id)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.track")
        }
    }

    func browseTracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.tracks(matching: query, page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.browseTracks")
        }
    }

    func browseAlbums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.albums(matching: query, page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.browseAlbums")
        }
    }

    func browseArtists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.artists(matching: query, page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.browseArtists")
        }
    }

    func browseGenres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.genres(matching: query, page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.browseGenres")
        }
    }

    func browseFolders(page: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        do {
            try Task.checkCancellation()
            return try await repository.folders(page: page)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.browseFolders")
        }
    }

    func recentTracks(page: LibraryPageRequest) async throws -> LibraryPage<Track> {
        let historyPage = try await recentHistory(page: page)
        return LibraryPage(
            elements: historyPage.elements.map(\.track),
            nextCursor: historyPage.nextCursor
        )
    }

    func recentHistory(page: LibraryPageRequest) async throws -> LibraryPage<PlaybackHistoryItem> {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        guard let historyRepository else {
            return LibraryPage(elements: [])
        }
        do {
            let historyPage = try await historyRepository.recentHistory(page: page)
            var items: [PlaybackHistoryItem] = []
            items.reserveCapacity(historyPage.elements.count)
            for history in historyPage.elements {
                try Task.checkCancellation()
                if let track = try await repository.track(id: history.itemID) {
                    items.append(PlaybackHistoryItem(
                        sessionID: history.sessionID,
                        track: track,
                        lastStartedAt: history.lastStartedAt,
                        lastEventAt: history.lastEventAt,
                        totalPlayedDuration: history.totalPlayedDuration,
                        lastPosition: history.lastPosition,
                        lastCompletionReason: history.lastCompletionReason
                    ))
                }
            }
            return LibraryPage(elements: items, nextCursor: historyPage.nextCursor)
        } catch {
            throw AppServiceError.mapped(error, operation: "library.recentHistory")
        }
    }

    func clearPlaybackHistory() async throws {
        guard let historyRepository else {
            throw AppServiceError.missingDependency("playbackHistoryRepository")
        }
        do {
            try Task.checkCancellation()
            try await historyRepository.clearHistory()
        } catch {
            throw AppServiceError.mapped(error, operation: "library.clearPlaybackHistory")
        }
    }

    func searchTracks(
        text: String,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track> {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppServiceError.library(.query(.emptySearchText))
        }
        return try await browseTracks(
            matching: TrackQuery(searchText: normalized),
            page: page
        )
    }

    func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        let acquired = await libraryMutationGate.enter()
        guard acquired else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            guard let current = try await track(id: itemID) else {
                throw AppServiceError.library(.constraint(.danglingReference))
            }
            guard current.isFavorite != isFavorite else {
                await libraryMutationGate.leave()
                return current
            }

            let updated = Track(
                id: current.id,
                title: current.title,
                sortTitle: current.sortTitle,
                albumID: current.albumID,
                artistIDs: current.artistIDs,
                genreIDs: current.genreIDs,
                trackNumber: current.trackNumber,
                discNumber: current.discNumber,
                fileName: current.fileName,
                folderPath: current.folderPath,
                duration: current.duration,
                technicalInfo: current.technicalInfo,
                year: current.year,
                comment: current.comment,
                lyrics: current.lyrics,
                artwork: current.artwork,
                isFavorite: isFavorite,
                statistics: current.statistics
            )
            let itemKey = Self.stableKey(prefix: "favorite", itemID: itemID)
            let operationKey = UUID().uuidString.lowercased()
            let transaction = try LibraryTransaction(
                idempotencyKey: "\(itemKey).\(operationKey)",
                mutations: [.upsert(.track(updated))]
            )
            try await repository.apply(transaction)
            await libraryMutationGate.leave()
            return updated
        } catch {
            await libraryMutationGate.leave()
            throw AppServiceError.mapped(error, operation: "library.favorite")
        }
    }

    func updateMetadata(_ update: TrackMetadataUpdate) async throws -> Track {
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        try Task.checkCancellation()
        if case .replace = update.artwork {
            await waitForArtworkPrune()
            try Task.checkCancellation()
        }
        guard !update.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppServiceError.invalidRequest(operation: "library.metadata.title")
        }

        let acquired = await libraryMutationGate.enter()
        guard acquired else { throw CancellationError() }

        var artworkWriteReceipt: ArtworkWriteReceipt?
        do {
            try Task.checkCancellation()
            guard let current = try await track(id: update.itemID) else {
                throw AppServiceError.library(.constraint(.danglingReference))
            }
            guard update.trackNumber == nil || update.trackNumber! > 0,
                  update.discNumber == nil || update.discNumber! > 0,
                  update.year == nil || (1...9_999).contains(update.year!)
            else {
                throw AppServiceError.invalidRequest(operation: "library.metadata.values")
            }

            let artistNames = update.artistNames ?? update.artistName.map { [$0] } ?? []
            let artistIDs = artistNames.map(Self.artistID)
            let explicitAlbumArtistNames: [String]?
            if let names = update.albumArtistNames {
                explicitAlbumArtistNames = names
            } else if let name = update.albumArtistName {
                explicitAlbumArtistNames = [name]
            } else {
                explicitAlbumArtistNames = nil
            }
            let genreNames = update.genreNames ?? update.genreName.map { [$0] } ?? []
            let genreIDs = genreNames.map(Self.genreID)

            let existingAlbum: Album?
            if update.albumName != nil, let currentAlbumID = current.albumID {
                existingAlbum = try await repository.album(id: currentAlbumID)
            } else {
                existingAlbum = nil
            }
            try Task.checkCancellation()

            // Editing track artists must not silently change the album artist
            // relationship of an existing album. A new album can still use
            // the track artists as its initial fallback.
            let albumArtistNames: [String]?
            let albumArtistIDs: [ArtistID]
            if let explicitAlbumArtistNames {
                albumArtistNames = explicitAlbumArtistNames
                albumArtistIDs = explicitAlbumArtistNames.map(Self.artistID)
            } else if let existingAlbum {
                albumArtistIDs = existingAlbum.artistIDs
                albumArtistNames = try await resolvedArtistNames(
                    for: existingAlbum.artistIDs,
                    repository: repository
                )
            } else {
                albumArtistNames = artistNames
                albumArtistIDs = artistIDs
            }
            let albumID: AlbumID?
            if let albumName = update.albumName {
                let candidateID: AlbumID
                if let albumArtistNames {
                    candidateID = Self.albumID(title: albumName, artistNames: albumArtistNames)
                } else {
                    candidateID = Self.albumID(title: albumName, artistIDs: albumArtistIDs)
                }
                if let currentAlbumID = current.albumID,
                   let existingAlbum,
                   existingAlbum.title == albumName,
                   existingAlbum.artistIDs == albumArtistIDs
                {
                    albumID = currentAlbumID
                } else {
                    albumID = candidateID
                }
            } else {
                albumID = nil
            }

            var artwork = current.artwork
            var artworkMutation: LibraryMutation?
            switch update.artwork {
            case .keep:
                break
            case .remove:
                artwork = nil
            case .replace(let data):
                guard !data.isEmpty else {
                    throw AppServiceError.invalidRequest(operation: "library.metadata.artwork")
                }
                guard data.count <= ArtworkDataLimits.maximumByteCount else {
                    throw AppServiceError.invalidRequest(operation: "library.metadata.artworkSize")
                }
                guard let artworkWriter else {
                    throw AppServiceError.missingDependency("artworkWriter")
                }
                let artworkID = ArtworkID(rawValue: "sha256-\(MusicContentIdentity.sha256Hex(data))")
                artworkWriteReceipt = try await artworkWriter(data, artworkID)
                try Task.checkCancellation()
                let replacement = ArtworkReference(
                    id: artworkID,
                    variants: [.original],
                    preferredVariant: .original
                )
                artwork = replacement
                artworkMutation = .upsert(.artwork(replacement))
            }

            var mutations: [LibraryMutation] = []
            if let artworkMutation { mutations.append(artworkMutation) }
            for (artistID, artistName) in zip(artistIDs, artistNames) {
                mutations.append(.upsert(.artist(Artist(id: artistID, name: artistName))))
            }
            if let albumArtistNames {
                for (albumArtistID, albumArtistName) in zip(albumArtistIDs, albumArtistNames)
                    where !artistIDs.contains(albumArtistID)
                {
                    mutations.append(.upsert(.artist(Artist(id: albumArtistID, name: albumArtistName))))
                }
            }
            for (genreID, genreName) in zip(genreIDs, genreNames) {
                mutations.append(.upsert(.genre(Genre(id: genreID, name: genreName))))
            }
            if let albumID, let albumName = update.albumName {
                let targetAlbum: Album?
                if albumID == current.albumID {
                    targetAlbum = existingAlbum
                } else {
                    targetAlbum = try await repository.album(id: albumID)
                }
                try Task.checkCancellation()
                let sourceAlbum = targetAlbum ?? existingAlbum
                // A newly split album has no reliable count until the library
                // derives it from its tracks. Never copy the old album's
                // count into that new identity; preserve counts only for an
                // already-existing target album.
                let albumTrackCount = targetAlbum?.trackCount
                let albumSortTitle = targetAlbum?.sortTitle
                    ?? (albumID == current.albumID ? existingAlbum?.sortTitle : nil)
                let albumReleaseYear = sourceAlbum?.releaseYear
                    ?? (current.albumID == nil ? update.year : nil)
                mutations.append(.upsert(.album(Album(
                    id: albumID,
                    title: albumName,
                    sortTitle: albumSortTitle,
                    artistIDs: albumArtistIDs,
                    artwork: sourceAlbum?.artwork,
                    releaseYear: albumReleaseYear,
                    trackCount: albumTrackCount,
                    albumType: sourceAlbum?.albumType
                ))))
            }

            let updatedSortTitle: String?
            if let currentSortTitle = current.sortTitle {
                updatedSortTitle = currentSortTitle == current.title
                    ? update.title
                    : currentSortTitle
            } else {
                updatedSortTitle = nil
            }

            let updated = Track(
                id: current.id,
                title: update.title,
                sortTitle: updatedSortTitle,
                albumID: albumID,
                artistIDs: artistIDs,
                genreIDs: genreIDs,
                trackNumber: update.trackNumber,
                discNumber: update.discNumber,
                fileName: current.fileName,
                folderPath: current.folderPath,
                duration: current.duration,
                technicalInfo: current.technicalInfo,
                year: update.year,
                comment: update.comment,
                lyrics: update.lyrics,
                artwork: artwork,
                isFavorite: current.isFavorite,
                statistics: current.statistics
            )
            mutations.append(.upsert(.track(updated)))
            let transaction = try LibraryTransaction(
                idempotencyKey: Self.stableKey(prefix: "metadata", itemID: update.itemID) + "." + UUID().uuidString,
                mutations: mutations
            )
            try Task.checkCancellation()
            try await repository.apply(transaction)
            if let artworkWriteReceipt {
                await artworkWriteReceipt.finish(committed: true)
            }
            scheduleArtworkPrune()
            await libraryMutationGate.leave()
            return updated
        } catch {
            if let artworkWriteReceipt {
                await artworkWriteReceipt.finish(committed: false)
            }
            await libraryMutationGate.leave()
            throw AppServiceError.mapped(error, operation: "library.metadata")
        }
    }

    func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
        guard !itemIDs.isEmpty else {
            throw AppServiceError.invalidRequest(operation: "library.delete")
        }
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        guard let remover else {
            throw AppServiceError.missingDependency("managedMediaRemover")
        }

        let acquired = await libraryMutationGate.enter()
        guard acquired else { throw CancellationError() }
        do {
            var existingIDs = Set<MediaItemID>()
            for itemID in itemIDs {
                do {
                    if try await repository.track(id: itemID) != nil {
                        existingIDs.insert(itemID)
                    }
                } catch {
                    throw AppServiceError.mapped(error, operation: "library.delete.lookup")
                }
            }
            guard !existingIDs.isEmpty else {
                await libraryMutationGate.leave()
                return LibraryDeletionResult(itemIDs: itemIDs, status: .alreadyAbsent)
            }

            try Task.checkCancellation()
            let transaction: MediaRemovalTransaction
            do {
                transaction = try await remover.prepareRemoval(of: existingIDs)
            } catch {
                throw AppServiceError.mapped(error, operation: "library.delete.prepare")
            }

            do {
                try Task.checkCancellation()
                try await repository.remove(existingIDs)
            } catch {
                do {
                    try await remover.rollbackRemoval(transaction)
                } catch {
                    throw AppServiceError.pendingRemoval(transaction)
                }
                throw AppServiceError.mapped(error, operation: "library.delete.library")
            }

            do {
                try await reconcileQueue(removing: existingIDs)
            } catch {
                throw AppServiceError.pendingRemoval(transaction)
            }

            do {
                try await remover.commitRemoval(transaction)
            } catch {
                throw AppServiceError.pendingRemoval(transaction)
            }

            scheduleArtworkPrune()

            let result = LibraryDeletionResult(
                itemIDs: existingIDs,
                status: .committed,
                transaction: transaction
            )
            await libraryMutationGate.leave()
            return result
        } catch {
            await libraryMutationGate.leave()
            throw error
        }
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        guard let remover else {
            return LibraryRecoveryResult()
        }
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }
        let acquired = await libraryMutationGate.enter()
        guard acquired else { throw CancellationError() }

        do {
            let pending: [MediaRemovalTransaction]
            do {
                pending = try await remover.pendingRemovals()
            } catch {
                throw AppServiceError.mapped(error, operation: "library.recovery.pending")
            }

            var rolledBack: [UUID] = []
            var finalized: [UUID] = []
            var stillPending: [UUID] = []

            for transaction in pending {
                do {
                    var anyRecordRemains = false
                    for itemID in transaction.itemIDs {
                        if try await repository.track(id: itemID) != nil {
                            anyRecordRemains = true
                            break
                        }
                    }

                    if anyRecordRemains {
                        try await remover.rollbackRemoval(transaction)
                        rolledBack.append(transaction.transactionID)
                    } else {
                        try await reconcileQueue(removing: transaction.itemIDs)
                        try await remover.commitRemoval(transaction)
                        finalized.append(transaction.transactionID)
                    }
                } catch {
                    stillPending.append(transaction.transactionID)
                }
            }

            if !finalized.isEmpty {
                scheduleArtworkPrune()
            }

            let result = LibraryRecoveryResult(
                rolledBackTransactionIDs: rolledBack,
                finalizedTransactionIDs: finalized,
                pendingTransactionIDs: stillPending
            )
            await libraryMutationGate.leave()
            return result
        } catch {
            await libraryMutationGate.leave()
            throw error
        }
    }

    func makeChangeStream() async -> AsyncStream<LibraryChange> {
        guard let repository else {
            return AsyncStream { $0.finish() }
        }
        return repository.changes()
    }

    private func reconcileQueue(removing itemIDs: Set<MediaItemID>) async throws {
        if let deletionHandler {
            try await deletionHandler(itemIDs)
            return
        }
        guard let queueRepository else { return }
        let current = try await queueRepository.load()
        let updated = Self.pruned(current, removing: itemIDs)
        guard updated != current else { return }
        try await queueRepository.save(updated)
    }

    private static func pruned(
        _ snapshot: PlaybackQueueSnapshot,
        removing itemIDs: Set<MediaItemID>
    ) -> PlaybackQueueSnapshot {
        let entries = snapshot.entries.filter { !itemIDs.contains($0.itemID) }
        let entryIDs = Set(entries.map(\.id))
        let currentEntryID = snapshot.currentEntryID.flatMap { entryIDs.contains($0) ? $0 : nil }
        let shuffleOrder = snapshot.shuffleOrder.filter(entryIDs.contains)
        return PlaybackQueueSnapshot(
            entries: entries,
            currentEntryID: currentEntryID,
            repeatMode: snapshot.repeatMode,
            shuffleMode: snapshot.shuffleMode,
            shuffleSeed: snapshot.shuffleSeed,
            shuffleOrder: shuffleOrder,
            resumePosition: currentEntryID == nil ? nil : snapshot.resumePosition
        )
    }

    private static func artistID(_ name: String) -> ArtistID {
        ArtistID(rawValue: "local-artist-\(MusicContentIdentity.token(name))")
    }

    private func resolvedArtistNames(
        for artistIDs: [ArtistID],
        repository: any LibraryRepository
    ) async throws -> [String]? {
        guard !artistIDs.isEmpty else { return [] }
        var names: [String] = []
        names.reserveCapacity(artistIDs.count)
        for artistID in artistIDs {
            try Task.checkCancellation()
            guard let artist = try await repository.artist(id: artistID) else {
                return nil
            }
            let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            names.append(name)
        }
        return names
    }

    private func scheduleArtworkPrune() {
        guard let artworkPruner else { return }
        guard artworkPruneTask == nil else {
            artworkPruneNeedsRerun = true
            return
        }
        startArtworkPrune(using: artworkPruner)
    }

    private func startArtworkPrune(
        using artworkPruner: @escaping @Sendable () async throws -> Void
    ) {
        artworkPruneTask = Task { [weak self, artworkPruner] in
            while true {
                var wasCancelled = false
                do {
                    try await artworkPruner()
                } catch is CancellationError {
                    wasCancelled = true
                } catch {
                    // Keep a stable, redacted diagnostic code. The raw adapter
                    // error may contain paths or framework-specific details.
                    Self.logger.error("Artwork cleanup failed [storage.artwork_prune_failed]")
                }

                guard let self else { return }
                if wasCancelled {
                    await self.finishArtworkPrune(using: artworkPruner)
                    return
                }
                guard await self.consumeArtworkPruneRerunRequest() else {
                    await self.finishArtworkPrune(using: artworkPruner)
                    return
                }
            }
        }
    }

    private func waitForArtworkPrune() async {
        while let artworkPruneTask {
            await artworkPruneTask.value
            await Task.yield()
        }
    }

    private func consumeArtworkPruneRerunRequest() -> Bool {
        guard artworkPruneNeedsRerun else { return false }
        artworkPruneNeedsRerun = false
        return true
    }

    private func finishArtworkPrune(
        using artworkPruner: @escaping @Sendable () async throws -> Void
    ) {
        artworkPruneTask = nil
        guard artworkPruneNeedsRerun else { return }
        artworkPruneNeedsRerun = false
        startArtworkPrune(using: artworkPruner)
    }

    private static func genreID(_ name: String) -> GenreID {
        GenreID(rawValue: "local-genre-\(MusicContentIdentity.token(name))")
    }

    private static func albumID(title: String, artistNames: [String]) -> AlbumID {
        let token: String
        if artistNames.count <= 1 {
            // Preserve the pre-multi-artist ID format for existing libraries.
            token = MusicContentIdentity.token(title + "|" + (artistNames.first ?? ""))
        } else {
            token = MusicContentIdentity.compositeToken([title] + artistNames)
        }
        return AlbumID(rawValue: "local-album-\(token)")
    }

    private static func albumID(title: String, artistIDs: [ArtistID]) -> AlbumID {
        let token: String
        if artistIDs.count <= 1 {
            token = MusicContentIdentity.token(title + "|" + (artistIDs.first?.rawValue ?? ""))
        } else {
            token = MusicContentIdentity.compositeToken([title] + artistIDs.map(\.rawValue))
        }
        return AlbumID(rawValue: "local-album-\(token)")
    }

    private static func stableKey(prefix: String, itemID: MediaItemID) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(itemID.sourceID.rawValue):\(itemID.externalID)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "app.\(prefix).\(String(hash, radix: 16))"
    }
}
