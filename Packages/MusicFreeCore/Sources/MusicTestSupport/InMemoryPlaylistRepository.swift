import Foundation
import LibraryAPI
import MusicDomain

public struct InMemoryPlaylistFailureScript: Sendable {
    public var readError: LibraryError?
    public var writeError: LibraryError?

    public init(readError: LibraryError? = nil, writeError: LibraryError? = nil) {
        self.readError = readError
        self.writeError = writeError
    }
}

/// An actor-backed playlist repository. Entry operations are applied to a
/// copied order and committed only after every validation succeeds.
public actor InMemoryPlaylistRepository: PlaylistRepository {
    private var playlistStore: [PlaylistID: Playlist]
    private var entryStore: [PlaylistID: [MediaItemID]]
    private var revision = LibraryRevision.initial
    private var nextPlaylistIndex = 0
    private var failureScript: InMemoryPlaylistFailureScript

    public private(set) var createCalls: [PlaylistDraft] = []
    public private(set) var updateCalls: [PlaylistMutation] = []
    public private(set) var entryMutationCalls: [PlaylistEntriesMutation] = []
    public private(set) var deleteCalls: [PlaylistID] = []

    public init(
        playlists: [Playlist] = [],
        entries: [PlaylistID: [MediaItemID]] = [:],
        failureScript: InMemoryPlaylistFailureScript = .init()
    ) {
        playlistStore = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        entryStore = entries
        self.failureScript = failureScript
        if let maximum = playlists.compactMap({ Int($0.id.rawValue.split(separator: "-").last ?? "") }).max() {
            nextPlaylistIndex = maximum + 1
        }
    }

    public func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist> {
        try checkReadFailure()
        let sorted = playlistStore.values.sorted {
            let left = ($0.sortName ?? $0.name).lowercased()
            let right = ($1.sortName ?? $1.name).lowercased()
            return left == right ? $0.id < $1.id : left < right
        }
        return try makePage(Array(sorted), request: page)
    }

    public func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        try checkReadFailure()
        guard playlistStore[playlistID] != nil else {
            throw LibraryError.constraint(.danglingReference)
        }
        return (entryStore[playlistID] ?? []).enumerated().map {
            PlaylistEntry(playlistID: playlistID, trackID: $0.element, position: $0.offset)
        }
    }

    public func create(_ draft: PlaylistDraft) async throws -> Playlist {
        try checkWriteFailure()
        createCalls.append(draft)
        guard !draft.name.isEmpty else {
            throw LibraryError.constraint(.invalidPlaylistName)
        }
        var id: PlaylistID
        repeat {
            id = PlaylistID("playlist-\(nextPlaylistIndex)")
            nextPlaylistIndex += 1
        } while playlistStore[id] != nil

        let now = Date(timeIntervalSince1970: TimeInterval(revision.rawValue + 1))
        let playlist = Playlist(
            id: id,
            name: draft.name,
            sortName: draft.sortName,
            artwork: draft.artworkID.map { ArtworkReference(id: $0) },
            createdAt: now,
            updatedAt: now
        )
        playlistStore[id] = playlist
        entryStore[id] = []
        revision = LibraryRevision(revision.rawValue + 1)
        return playlist
    }

    public func update(_ mutation: PlaylistMutation) async throws -> Playlist {
        try checkWriteFailure()
        updateCalls.append(mutation)
        try checkExpectedRevision(mutation.expectedRevision)
        guard let existing = playlistStore[mutation.playlistID] else {
            throw LibraryError.constraint(.danglingReference)
        }

        var name = existing.name
        var sortName = existing.sortName
        var artworkID = existing.artworkID
        switch mutation.change {
        case .rename(let value):
            name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .setSortName(let value):
            sortName = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .setArtwork(let value):
            artworkID = value
        case .replace(let value, let newSortName, let newArtworkID):
            name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            sortName = newSortName?.trimmingCharacters(in: .whitespacesAndNewlines)
            artworkID = newArtworkID
        }
        guard !name.isEmpty else {
            throw LibraryError.constraint(.invalidPlaylistName)
        }

        let updated = Playlist(
            id: existing.id,
            name: name,
            sortName: sortName,
            artwork: artworkID.map { ArtworkReference(id: $0) },
            createdAt: existing.createdAt,
            updatedAt: Date(timeIntervalSince1970: TimeInterval(revision.rawValue + 1))
        )
        playlistStore[mutation.playlistID] = updated
        revision = LibraryRevision(revision.rawValue + 1)
        return updated
    }

    public func apply(_ mutation: PlaylistEntriesMutation) async throws {
        try checkWriteFailure()
        entryMutationCalls.append(mutation)
        try checkExpectedRevision(mutation.expectedRevision)
        guard playlistStore[mutation.playlistID] != nil else {
            throw LibraryError.constraint(.danglingReference)
        }

        var updatedOrder = entryStore[mutation.playlistID] ?? []
        switch mutation.operation {
        case .insert(let insertions):
            var inserted = Set<MediaItemID>()
            for insertion in insertions {
                guard insertion.hasValidPosition else {
                    throw LibraryError.constraint(.invalidPlaylistPosition)
                }
                guard !updatedOrder.contains(insertion.itemID), inserted.insert(insertion.itemID).inserted else {
                    throw LibraryError.constraint(.duplicatePlaylistMember)
                }
            }
            for insertion in insertions.sorted(by: { $0.position < $1.position }) {
                guard insertion.position <= updatedOrder.count else {
                    throw LibraryError.constraint(.invalidPlaylistPosition)
                }
                updatedOrder.insert(insertion.itemID, at: insertion.position)
            }

        case .move(let moves):
            for move in moves {
                guard move.hasValidPosition,
                      let currentIndex = updatedOrder.firstIndex(of: move.itemID),
                      move.position < updatedOrder.count
                else {
                    throw LibraryError.constraint(.invalidPlaylistPosition)
                }
                let item = updatedOrder.remove(at: currentIndex)
                updatedOrder.insert(item, at: min(move.position, updatedOrder.count))
            }

        case .remove(let itemIDs):
            updatedOrder.removeAll { itemIDs.contains($0) }

        case .reorder(let desiredOrder):
            guard Set(desiredOrder).count == desiredOrder.count else {
                throw LibraryError.constraint(.duplicatePlaylistMember)
            }
            guard Set(desiredOrder) == Set(updatedOrder), desiredOrder.count == updatedOrder.count else {
                throw LibraryError.constraint(.danglingReference)
            }
            updatedOrder = desiredOrder
        }

        entryStore[mutation.playlistID] = updatedOrder
        revision = LibraryRevision(revision.rawValue + 1)
    }

    public func delete(_ playlistID: PlaylistID) async throws {
        try checkWriteFailure()
        deleteCalls.append(playlistID)
        guard playlistStore.removeValue(forKey: playlistID) != nil else {
            throw LibraryError.constraint(.danglingReference)
        }
        entryStore.removeValue(forKey: playlistID)
        revision = LibraryRevision(revision.rawValue + 1)
    }

    public func setFailureScript(_ script: InMemoryPlaylistFailureScript) {
        failureScript = script
    }

    public func currentRevision() -> LibraryRevision {
        revision
    }

    private func checkReadFailure() throws {
        if let error = failureScript.readError { throw error }
    }

    private func checkWriteFailure() throws {
        if let error = failureScript.writeError { throw error }
    }

    private func checkExpectedRevision(_ expected: LibraryRevision?) throws {
        guard expected == nil || expected == revision else {
            throw LibraryError.conflict(.revisionMismatch(expected: expected, actual: revision))
        }
    }

    private func makePage<Element: Sendable>(
        _ values: [Element],
        request: LibraryPageRequest
    ) throws -> LibraryPage<Element> {
        let offset = try pageOffset(request.cursor)
        guard offset <= values.count else { throw LibraryError.query(.expiredCursor) }
        let end = min(offset + request.limit, values.count)
        let next = end < values.count ? LibraryCursor("offset:\(end)") : nil
        return LibraryPage(elements: Array(values[offset..<end]), nextCursor: next)
    }

    private func pageOffset(_ cursor: LibraryCursor?) throws -> Int {
        guard let cursor else { return 0 }
        guard cursor.rawValue.hasPrefix("offset:"),
              let value = Int(cursor.rawValue.dropFirst("offset:".count)), value >= 0
        else { throw LibraryError.query(.invalidCursor) }
        return value
    }
}
