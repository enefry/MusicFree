import Foundation
import AppServices
import LibraryAPI
import MusicDomain
import Observation

/// Compatibility namespace retained while AppServices is still being built.
public enum PlaylistFeatureModule {}

/// The coarse loading state shared by the playlist list and detail screens.
public enum PlaylistFeatureLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)

    public var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}

/// Mutation feedback is intentionally small so a view can render it without
/// knowing which store implementation is underneath.
public enum PlaylistFeatureMutationState: Equatable, Sendable {
    case idle
    case submitting
    case succeeded(String)
    case failed(String)

    public var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}

public enum PlaylistFeatureCommandState: Equatable, Sendable {
    case idle
    case submitting
    case succeeded
    case failed(String)

    public var failureMessage: String? {
        guard case .failed(let message) = self else {
            return nil
        }
        return message
    }
}

public enum PlaylistFeatureConfirmation: Equatable, Sendable, Identifiable {
    case deletePlaylist(PlaylistID)
    case removeTracks(Set<MediaItemID>)

    public var id: String {
        switch self {
        case .deletePlaylist(let playlistID):
            return "delete-playlist-\(playlistID.rawValue)"
        case .removeTracks(let itemIDs):
            return "remove-tracks-\(itemIDs.map(\.description).sorted().joined(separator: ","))"
        }
    }
}

public enum PlaylistFeatureError: Error, LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong(maximum: Int)
    case duplicateName
    case emptyPlaylist
    case serviceUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "请输入歌单名称。"
        case .nameTooLong(let maximum):
            return "歌单名称不能超过 \(maximum) 个字符。"
        case .duplicateName:
            return "歌单名称已存在。"
        case .emptyPlaylist:
            return "歌单中没有可用歌曲。"
        case .serviceUnavailable:
            return "歌单服务暂不可用。"
        }
    }
}

public enum PlaylistNameValidation: Equatable, Sendable {
    case valid(String)
    case empty
    case tooLong(maximum: Int)
}

public enum PlaylistNameValidator {
    public static let maximumLength = 80

    public static func validate(_ name: String) -> PlaylistNameValidation {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return .empty
        }
        guard normalized.count <= maximumLength else {
            return .tooLong(maximum: maximumLength)
        }
        return .valid(normalized)
    }

    public static func validatedName(
        _ name: String,
        existingPlaylists: [Playlist] = [],
        excludingID: PlaylistID? = nil
    ) throws -> String {
        let normalized: String
        switch validate(name) {
        case .valid(let value):
            normalized = value
        case .empty:
            throw PlaylistFeatureError.emptyName
        case .tooLong(let maximum):
            throw PlaylistFeatureError.nameTooLong(maximum: maximum)
        }

        let hasDuplicate = existingPlaylists.contains { playlist in
            guard playlist.id != excludingID else {
                return false
            }
            return playlist.name.caseInsensitiveCompare(normalized) == .orderedSame
        }
        if hasDuplicate {
            throw PlaylistFeatureError.duplicateName
        }
        return normalized
    }
}

/// The feature-facing port. AppServices can conform its playlist façade to
/// this port without exposing a repository or an adapter to SwiftUI.
@MainActor
public protocol PlaylistFeatureStore: AnyObject {
    func loadPlaylists() async throws -> [Playlist]
    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry]
    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist
    func updatePlaylist(_ mutation: PlaylistMutation) async throws -> Playlist
    func applyEntries(_ mutation: PlaylistEntriesMutation) async throws
    func deletePlaylist(_ playlistID: PlaylistID) async throws
}

public enum PlaylistPlaybackIntent: String, CaseIterable, Equatable, Sendable {
    case playAll
    case shuffle
    case playNext
    case enqueue
}

/// A value command that can be translated to PlaybackSessionCommand by the
/// eventual AppServices composition root.
public struct PlaylistPlaybackCommand: Equatable, Sendable {
    public let playlistID: PlaylistID
    public let itemIDs: [MediaItemID]
    public let intent: PlaylistPlaybackIntent

    public init(
        playlistID: PlaylistID,
        itemIDs: [MediaItemID],
        intent: PlaylistPlaybackIntent
    ) {
        self.playlistID = playlistID
        self.itemIDs = Self.unique(itemIDs)
        self.intent = intent
    }

    public static func make(
        playlistID: PlaylistID,
        itemIDs: [MediaItemID],
        intent: PlaylistPlaybackIntent
    ) -> Self? {
        let command = Self(playlistID: playlistID, itemIDs: itemIDs, intent: intent)
        return command.itemIDs.isEmpty ? nil : command
    }

    /// Expands the feature command into the existing AppServices command
    /// vocabulary. Queue ownership remains in PlaybackCoordinator.
    public var appServicesCommands: [PlaybackSessionCommand] {
        guard !itemIDs.isEmpty else {
            return []
        }
        switch intent {
        case .playAll:
            return [.playItems(itemIDs: itemIDs, shuffle: false)]
        case .shuffle:
            return [.playItems(itemIDs: itemIDs, shuffle: true)]
        case .playNext:
            return [.enqueueNext(itemIDs: itemIDs)]
        case .enqueue:
            return [.enqueueItems(itemIDs: itemIDs)]
        }
    }

    private static func unique(_ itemIDs: [MediaItemID]) -> [MediaItemID] {
        var seen = Set<MediaItemID>()
        return itemIDs.filter { seen.insert($0).inserted }
    }
}

/// Playback is kept separate from the playlist store so queue ownership
/// remains outside this feature.
@MainActor
public protocol PlaylistFeaturePlaybackServing: AnyObject {
    func send(_ command: PlaylistPlaybackCommand) async throws
}

public struct PlaylistTrackCandidate: Identifiable, Equatable, Sendable {
    public let id: MediaItemID
    public let title: String
    public let subtitle: String?

    public init(id: MediaItemID, title: String, subtitle: String? = nil) {
        self.id = id
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = normalizedTitle.isEmpty ? id.externalID : normalizedTitle
        let normalizedSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtitle = normalizedSubtitle?.isEmpty == true ? nil : normalizedSubtitle
    }
}

public enum PlaylistRoute: Equatable, Sendable {
    case addTracks(PlaylistID)
}

public typealias PlaylistRouteAction = @MainActor (PlaylistRoute) -> Void

@MainActor
final class UnconfiguredPlaylistStore: PlaylistFeatureStore {
    func loadPlaylists() async throws -> [Playlist] {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func updatePlaylist(_ mutation: PlaylistMutation) async throws -> Playlist {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func applyEntries(_ mutation: PlaylistEntriesMutation) async throws {
        throw PlaylistFeatureError.serviceUnavailable
    }

    func deletePlaylist(_ playlistID: PlaylistID) async throws {
        throw PlaylistFeatureError.serviceUnavailable
    }
}

@MainActor
final class UnconfiguredPlaylistPlaybackServing: PlaylistFeaturePlaybackServing {
    func send(_ command: PlaylistPlaybackCommand) async throws {
        throw PlaylistFeatureError.serviceUnavailable
    }
}

@MainActor
final class AppServicesPlaylistStore: PlaylistFeatureStore {
    private let serving: any PlaylistServing

    init(serving: any PlaylistServing) {
        self.serving = serving
    }

    func loadPlaylists() async throws -> [Playlist] {
        var request = try LibraryPageRequest()
        var result: [Playlist] = []
        while true {
            try Task.checkCancellation()
            let page = try await serving.playlists(page: request)
            result.append(contentsOf: page.items)
            guard let nextRequest = try page.nextPage(limit: request.limit) else {
                return result
            }
            request = nextRequest
        }
    }

    func loadEntries(in playlistID: PlaylistID) async throws -> [PlaylistEntry] {
        try await serving.entries(in: playlistID)
    }

    func createPlaylist(_ draft: PlaylistDraft) async throws -> Playlist {
        try await serving.create(draft)
    }

    func updatePlaylist(_ mutation: PlaylistMutation) async throws -> Playlist {
        try await serving.update(mutation)
    }

    func applyEntries(_ mutation: PlaylistEntriesMutation) async throws {
        try await serving.apply(mutation)
    }

    func deletePlaylist(_ playlistID: PlaylistID) async throws {
        try await serving.delete(playlistID)
    }
}

@MainActor
final class AppServicesPlaybackBridge: PlaylistFeaturePlaybackServing {
    private let serving: any PlaybackServing

    init(serving: any PlaybackServing) {
        self.serving = serving
    }

    func send(_ command: PlaylistPlaybackCommand) async throws {
        for playbackCommand in command.appServicesCommands {
            try Task.checkCancellation()
            try await serving.execute(playbackCommand)
        }
    }
}

func playlistFeatureMessage(for error: Error) -> String {
    if let error = error as? PlaylistFeatureError {
        return error.localizedDescription
    }
    if let error = error as? AppServiceError {
        return error.failureReason
    }
    if let error = error as? LibraryError {
        return error.userMessage
    }
    return "操作未完成，请重试。"
}

func playlistFeatureIsCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    return (error as? AppServiceError)?.isCancellation == true
}

func playlistFeatureIsRevisionConflict(_ error: Error) -> Bool {
    if let error = error as? AppServiceError,
       case .library(.conflict(.revisionMismatch)) = error {
        return true
    }
    guard let error = error as? LibraryError else {
        return false
    }
    if case .conflict(.revisionMismatch) = error {
        return true
    }
    return false
}

extension Playlist {
    func playlistFeatureRenamed(to name: String) -> Self {
        Self(
            id: id,
            name: name,
            sortName: sortName,
            artwork: artwork,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
