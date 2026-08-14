import AppServices
import DesignSystem
import Foundation
import LibraryAPI
import MusicDomain
import SwiftUI

enum LibraryCollectionQueueTarget: Hashable, Sendable {
    case album(AlbumID)
    case artist(ArtistID)
    case genre(GenreID)
    case folder(String)

    fileprivate var query: TrackQuery {
        switch self {
        case .album(let albumID):
            return TrackQuery(sourceID: .local, albumID: albumID)
        case .artist(let artistID):
            return TrackQuery(sourceID: .local, artistID: artistID)
        case .genre(let genreID):
            return TrackQuery(sourceID: .local, genreID: genreID)
        case .folder:
            return TrackQuery(sourceID: .local)
        }
    }

    fileprivate func includes(_ track: Track) -> Bool {
        switch self {
        case .folder(let path):
            return track.folderPath == path
        case .album, .artist, .genre:
            return true
        }
    }

    fileprivate func ordered(_ tracks: [Track]) -> [Track] {
        switch self {
        case .album:
            return LibraryAlbumTrackOrdering.ordered(tracks)
        case .artist, .genre, .folder:
            return tracks
        }
    }

    fileprivate var accessibilityValue: String {
        switch self {
        case .album(let albumID): return "album.\(albumID.rawValue)"
        case .artist(let artistID): return "artist.\(artistID.rawValue)"
        case .genre(let genreID): return "genre.\(genreID.rawValue)"
        case .folder(let path): return "folder.\(path)"
        }
    }
}

enum LibraryCollectionQueuePlacement: Equatable, Sendable {
    case next
    case end
}

struct LibraryCollectionQueueMenuActions: View {
    let target: LibraryCollectionQueueTarget
    let accessibilityPrefix: String
    let enqueueNext: ((LibraryCollectionQueueTarget) -> Void)?
    let enqueue: ((LibraryCollectionQueueTarget) -> Void)?
    let addToPlaylist: ((LibraryCollectionQueueTarget) -> Void)?
    let isPending: Bool

    init(
        target: LibraryCollectionQueueTarget,
        accessibilityPrefix: String,
        enqueueNext: ((LibraryCollectionQueueTarget) -> Void)?,
        enqueue: ((LibraryCollectionQueueTarget) -> Void)?,
        addToPlaylist: ((LibraryCollectionQueueTarget) -> Void)? = nil,
        isPending: Bool
    ) {
        self.target = target
        self.accessibilityPrefix = accessibilityPrefix
        self.enqueueNext = enqueueNext
        self.enqueue = enqueue
        self.addToPlaylist = addToPlaylist
        self.isPending = isPending
    }

    var body: some View {
        Button {
            enqueueNext?(target)
        } label: {
            Label(L("下一首播放"), systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(enqueueNext == nil || isPending)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).playNext.\(target.accessibilityValue)"
        )

        Button {
            enqueue?(target)
        } label: {
            Label(L("加入队列"), systemImage: "text.append")
        }
        .disabled(enqueue == nil || isPending)
        .accessibilityIdentifier(
            "\(accessibilityPrefix).enqueue.\(target.accessibilityValue)"
        )

        if let addToPlaylist {
            Button {
                addToPlaylist(target)
            } label: {
                Label(L("添加到播放列表"), systemImage: "text.badge.plus")
            }
            .disabled(isPending)
            .accessibilityIdentifier(
                "\(accessibilityPrefix).addToPlaylist.\(target.accessibilityValue)"
            )
        }
    }
}

enum LibraryCollectionTrackLoader {
    static func itemIDs(
        for target: LibraryCollectionQueueTarget,
        from library: any LibraryServing
    ) async throws -> [MediaItemID] {
        var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
        var seenCursors = Set<LibraryCursor>()
        var tracks: [Track] = []

        while true {
            try Task.checkCancellation()
            let page = try await library.browseTracks(
                matching: target.query,
                page: request
            )
            try Task.checkCancellation()
            tracks.append(contentsOf: page.elements.filter(target.includes))

            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                break
            }
            guard let cursor = nextRequest.cursor,
                  seenCursors.insert(cursor).inserted
            else {
                throw LibraryCollectionQueueLoadError.repeatedCursor
            }
            request = nextRequest
        }

        var seenIDs = Set<MediaItemID>()
        return target.ordered(tracks).compactMap { track in
            seenIDs.insert(track.id).inserted ? track.id : nil
        }
    }

    static func itemIDs(
        for targets: Set<LibraryCollectionQueueTarget>,
        from library: any LibraryServing
    ) async throws -> Set<MediaItemID> {
        var collectedIDs = Set<MediaItemID>()
        for target in targets {
            collectedIDs.formUnion(try await Self.itemIDs(for: target, from: library))
        }
        return collectedIDs
    }
}

private enum LibraryCollectionQueueLoadError: LocalizedError {
    case repeatedCursor

    var errorDescription: String? {
        L("集合歌曲分页状态无效，请刷新资料库后重试。")
    }
}
