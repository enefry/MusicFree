import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI

internal actor LibraryCoordinator: LibraryServing {
    private let repository: (any LibraryRepository)?
    private let remover: (any ManagedMediaRemoving)?
    private let queueRepository: (any PlaybackQueueRepository)?
    private let historyRepository: (any PlaybackHistoryRepository)?
    private let deletionHandler: (@Sendable (Set<MediaItemID>) async throws -> Void)?

    init(
        repository: (any LibraryRepository)?,
        remover: (any ManagedMediaRemoving)?,
        queueRepository: (any PlaybackQueueRepository)?,
        historyRepository: (any PlaybackHistoryRepository)?,
        deletionHandler: (@Sendable (Set<MediaItemID>) async throws -> Void)? = nil
    ) {
        self.repository = repository
        self.remover = remover
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
        guard let current = try await track(id: itemID) else {
            throw AppServiceError.library(.constraint(.danglingReference))
        }
        guard current.isFavorite != isFavorite else { return current }

        let updated = Track(
            id: current.id,
            title: current.title,
            sortTitle: current.sortTitle,
            albumID: current.albumID,
            artistIDs: current.artistIDs,
            genreIDs: current.genreIDs,
            folderPath: current.folderPath,
            duration: current.duration,
            technicalInfo: current.technicalInfo,
            artwork: current.artwork,
            isFavorite: isFavorite,
            statistics: current.statistics
        )
        do {
            let itemKey = Self.stableKey(prefix: "favorite", itemID: itemID)
            let operationKey = UUID().uuidString.lowercased()
            let transaction = try LibraryTransaction(
                idempotencyKey: "\(itemKey).\(operationKey)",
                mutations: [.upsert(.track(updated))]
            )
            try await repository.apply(transaction)
            return updated
        } catch {
            throw AppServiceError.mapped(error, operation: "library.favorite")
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
            return LibraryDeletionResult(itemIDs: itemIDs, status: .alreadyAbsent)
        }

        let transaction: MediaRemovalTransaction
        do {
            try Task.checkCancellation()
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

        return LibraryDeletionResult(
            itemIDs: existingIDs,
            status: .committed,
            transaction: transaction
        )
    }

    func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
        guard let remover else {
            return LibraryRecoveryResult()
        }
        guard let repository else {
            throw AppServiceError.missingDependency("libraryRepository")
        }

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

        return LibraryRecoveryResult(
            rolledBackTransactionIDs: rolledBack,
            finalizedTransactionIDs: finalized,
            pendingTransactionIDs: stillPending
        )
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

    private static func stableKey(prefix: String, itemID: MediaItemID) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(itemID.sourceID.rawValue):\(itemID.externalID)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "app.\(prefix).\(String(hash, radix: 16))"
    }
}
