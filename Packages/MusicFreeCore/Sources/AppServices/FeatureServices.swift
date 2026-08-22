import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

/// The outcome of one recoverable library deletion saga.
public enum LibraryDeletionStatus: String, Codable, Equatable, Sendable {
    case committed
    case alreadyAbsent
    case pendingFinalization
}

public struct LibraryDeletionResult: Codable, Equatable, Sendable {
    public let itemIDs: Set<MediaItemID>
    public let status: LibraryDeletionStatus
    public let transaction: MediaRemovalTransaction?

    public init(
        itemIDs: Set<MediaItemID>,
        status: LibraryDeletionStatus,
        transaction: MediaRemovalTransaction? = nil
    ) {
        self.itemIDs = itemIDs
        self.status = status
        self.transaction = transaction
    }
}

/// A startup or maintenance pass over pending removal transactions.
public struct LibraryRecoveryResult: Codable, Equatable, Sendable {
    public let rolledBackTransactionIDs: [UUID]
    public let finalizedTransactionIDs: [UUID]
    public let pendingTransactionIDs: [UUID]

    public init(
        rolledBackTransactionIDs: [UUID] = [],
        finalizedTransactionIDs: [UUID] = [],
        pendingTransactionIDs: [UUID] = []
    ) {
        self.rolledBackTransactionIDs = rolledBackTransactionIDs
        self.finalizedTransactionIDs = finalizedTransactionIDs
        self.pendingTransactionIDs = pendingTransactionIDs
    }

    public var hasPendingTransactions: Bool {
        !pendingTransactionIDs.isEmpty
    }
}

public struct ImportSessionSnapshot: Equatable, Sendable {
    public let importID: UUID
    public let processedCount: Int
    public let lastItemID: MediaItemID?
    public let result: MediaImportResult?
    public let isActive: Bool

    public init(
        importID: UUID,
        processedCount: Int = 0,
        lastItemID: MediaItemID? = nil,
        result: MediaImportResult? = nil,
        isActive: Bool = true
    ) {
        self.importID = importID
        self.processedCount = processedCount
        self.lastItemID = lastItemID
        self.result = result
        self.isActive = isActive
    }
}

/// A settings value plus the current capability-clipped playback intent.
@available(macOS 13.0, iOS 16.0, *)
public struct EffectivePlaybackSettings: Codable, Equatable, Hashable, Sendable {
    public let settings: AppSettings
    public let effects: AudioEffectConfiguration
    public let playbackCapabilities: PlaybackCapabilities
    public let equalizerDescriptor: EqualizerDescriptor?
    public let systemCapabilities: SystemIntegrationCapabilitySnapshot

    public init(
        settings: AppSettings,
        effects: AudioEffectConfiguration,
        playbackCapabilities: PlaybackCapabilities,
        equalizerDescriptor: EqualizerDescriptor? = nil,
        systemCapabilities: SystemIntegrationCapabilitySnapshot
    ) {
        self.settings = settings
        self.effects = effects
        self.playbackCapabilities = playbackCapabilities
        self.equalizerDescriptor = equalizerDescriptor
        self.systemCapabilities = systemCapabilities
    }
}

public protocol LibraryServing: Sendable {
    func track(id: MediaItemID) async throws -> Track?
    func browseTracks(
        matching query: TrackQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track>
    func browseAlbums(
        matching query: AlbumQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Album>
    func browseArtists(
        matching query: ArtistQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Artist>
    func browseGenres(
        matching query: GenreQuery,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Genre>
    func browseFolders(
        page: LibraryPageRequest
    ) async throws -> LibraryPage<LibraryFolder>
    func recentTracks(
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track>
    func recentHistory(
        page: LibraryPageRequest
    ) async throws -> LibraryPage<PlaybackHistoryItem>
    func clearPlaybackHistory() async throws
    func searchTracks(
        text: String,
        page: LibraryPageRequest
    ) async throws -> LibraryPage<Track>
    func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track
    func updateMetadata(_ update: TrackMetadataUpdate) async throws -> Track
    func updateAlbumMetadata(_ update: AlbumMetadataUpdate) async throws -> Album
    func supplementMetadata(_ supplement: TrackMetadataSupplement) async throws -> Track
    func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult
    func recoverPendingRemovals() async throws -> LibraryRecoveryResult
    func makeChangeStream() async -> AsyncStream<LibraryChange>
}

/// A presentation-ready history entry that retains its playback session data.
public struct PlaybackHistoryItem: Identifiable, Equatable, Sendable {
    public let sessionID: UUID
    public let track: Track
    public let lastStartedAt: Date
    public let lastEventAt: Date
    public let totalPlayedDuration: Duration
    public let lastPosition: Duration?
    public let lastCompletionReason: PlaybackCompletionReason?

    public var id: UUID { sessionID }

    public init(
        sessionID: UUID,
        track: Track,
        lastStartedAt: Date,
        lastEventAt: Date,
        totalPlayedDuration: Duration,
        lastPosition: Duration? = nil,
        lastCompletionReason: PlaybackCompletionReason? = nil
    ) {
        self.sessionID = sessionID
        self.track = track
        self.lastStartedAt = lastStartedAt
        self.lastEventAt = lastEventAt
        self.totalPlayedDuration = totalPlayedDuration
        self.lastPosition = lastPosition
        self.lastCompletionReason = lastCompletionReason
    }

    public func replacingTrack(_ track: Track) -> Self {
        Self(
            sessionID: sessionID,
            track: track,
            lastStartedAt: lastStartedAt,
            lastEventAt: lastEventAt,
            totalPlayedDuration: totalPlayedDuration,
            lastPosition: lastPosition,
            lastCompletionReason: lastCompletionReason
        )
    }
}

/// Resolves a persisted artwork reference into a short-lived source-owned
/// resource for presentation. Artwork bytes never enter the library or
/// playback snapshots.
public protocol ArtworkServing: Sendable {
    func artwork(
        for artworkID: ArtworkID,
        sourceID: MediaSourceID
    ) async throws -> ArtworkResource?
}

/// Loads online lyrics on demand and persists a successful result in the
/// library without making the player depend on a concrete network adapter.
public protocol LyricsServing: Sendable {
    /// Returns the providers registered by the current application build.
    /// This lets settings distinguish persisted preferences from unavailable
    /// providers hidden by a feature switch or missing configuration.
    func registeredLyricsProviderIDs() async -> Set<LyricsProviderID>

    /// Applies the current application and provider privacy consent before
    /// any external lyrics request is allowed.
    func setPrivacyPreferences(_ preferences: PrivacyPreferences) async

    /// Applies the ordered, user-controlled lyrics provider preferences.
    func setProviderPreferences(
        _ preferences: [LyricsProviderPreference]
    ) async

    /// Compatibility entry point for the temporary all-providers switch.
    func setEnabled(_ enabled: Bool) async
    func fetchLyrics(
        for query: LyricsQuery,
        forceRefresh: Bool
    ) async throws -> TrackLyrics?
    func preloadSnapshot() async -> LyricsPreloadSnapshot
    func makePreloadSnapshotStream() async -> AsyncStream<LyricsPreloadSnapshot>
    func startPreload() async
    func cancelPreload() async
}

public extension LyricsServing {
    func registeredLyricsProviderIDs() async -> Set<LyricsProviderID> { [] }

    func setPrivacyPreferences(_: PrivacyPreferences) async {}

    func setProviderPreferences(
        _: [LyricsProviderPreference]
    ) async {}

    func setEnabled(_ enabled: Bool) async {}

    func preloadSnapshot() async -> LyricsPreloadSnapshot {
        LyricsPreloadSnapshot()
    }

    func makePreloadSnapshotStream() async -> AsyncStream<LyricsPreloadSnapshot> {
        let snapshot = await preloadSnapshot()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.finish()
        }
    }

    func startPreload() async {}

    func cancelPreload() async {}
}

public extension LibraryServing {
    func browseTracks(page: LibraryPageRequest) async throws -> LibraryPage<Track> {
        try await browseTracks(matching: TrackQuery(), page: page)
    }

    func searchTracks(_ text: String, page: LibraryPageRequest) async throws -> LibraryPage<Track> {
        try await searchTracks(text: text, page: page)
    }

    func favorite(_ itemID: MediaItemID, isFavorite: Bool) async throws -> Track {
        try await setFavorite(isFavorite, for: itemID)
    }

    func updateMetadata(_ update: TrackMetadataUpdate) async throws -> Track {
        throw AppServiceError.missingDependency("libraryMetadataEditor")
    }

    func updateAlbumMetadata(_ update: AlbumMetadataUpdate) async throws -> Album {
        throw AppServiceError.missingDependency("libraryMetadataEditor")
    }

    func supplementMetadata(_ supplement: TrackMetadataSupplement) async throws -> Track {
        throw AppServiceError.missingDependency("libraryMetadataEditor")
    }

    func browseGenres(
        matching _: GenreQuery,
        page _: LibraryPageRequest
    ) async throws -> LibraryPage<Genre> {
        LibraryPage(elements: [])
    }

    func browseFolders(page _: LibraryPageRequest) async throws -> LibraryPage<LibraryFolder> {
        LibraryPage(elements: [])
    }

    func recentTracks(page _: LibraryPageRequest) async throws -> LibraryPage<Track> {
        LibraryPage(elements: [])
    }

    func recentHistory(page _: LibraryPageRequest) async throws -> LibraryPage<PlaybackHistoryItem> {
        LibraryPage(elements: [])
    }

    func clearPlaybackHistory() async throws {
        throw AppServiceError.missingDependency("playbackHistoryRepository")
    }
}

public protocol ImportServing: Sendable {
    func start(_ request: MediaImportRequest)
        async throws -> AsyncThrowingStream<MediaImportEvent, Error>
    func cancel(_ importID: UUID) async
    func state(for importID: UUID) async -> ImportSessionSnapshot?
    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot>
}

/// Optional catalog metadata enrichment owned by AppServices so import and
/// settings views do not retain network tasks themselves.
public protocol MetadataEnrichmentServing: Sendable {
    func snapshot() async -> MetadataEnrichmentSnapshot
    func makeSnapshotStream() async -> AsyncStream<MetadataEnrichmentSnapshot>
    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus
    func requestAuthorization(
        for provider: MetadataProviderID
    ) async -> MetadataEnrichmentAuthorizationStatus
    /// Applies the current application and provider privacy consent before
    /// any external metadata request is allowed.
    func setPrivacyPreferences(_ preferences: PrivacyPreferences) async
    func setProviderPreferences(
        _ preferences: [MetadataProviderPreference]
    ) async
    func setEnabled(_ enabled: Bool) async
    func enqueue(itemID: MediaItemID) async
    func startScan() async
    func cancelScan() async
}

public extension MetadataEnrichmentServing {
    func requestAuthorization(
        for _: MetadataProviderID
    ) async -> MetadataEnrichmentAuthorizationStatus {
        await requestAuthorization()
    }

    func setPrivacyPreferences(_: PrivacyPreferences) async {}

    func setProviderPreferences(
        _: [MetadataProviderPreference]
    ) async {}
}

public extension ImportServing {
    func startImport(_ request: MediaImportRequest)
        async throws -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        try await start(request)
    }

    func cancelImport(_ importID: UUID) async {
        await cancel(importID)
    }
}

public protocol PlaylistServing: Sendable {
    func playlists(page: LibraryPageRequest) async throws -> LibraryPage<Playlist>
    func entries(in playlistID: PlaylistID) async throws -> [PlaylistEntry]
    func create(_ draft: PlaylistDraft) async throws -> Playlist
    func update(_ mutation: PlaylistMutation) async throws -> Playlist
    func apply(_ mutation: PlaylistEntriesMutation) async throws
    func delete(_ playlistID: PlaylistID) async throws
}

public protocol SettingsServing: Sendable {
    func load() async throws -> AppSettings
    func update(_ settings: AppSettings) async throws
    func reset() async throws
    func effective() async throws -> EffectivePlaybackSettings
    func makeChangeStream() async -> AsyncStream<AppSettings>
}

public extension SettingsServing {
    func save(_ settings: AppSettings) async throws {
        try await update(settings)
    }
}

@MainActor
public protocol PlaybackServing: AnyObject {
    var snapshot: PlaybackSessionSnapshot { get }
    func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot>
    func send(_ command: PlaybackSessionCommand) async
    func execute(_ command: PlaybackSessionCommand) async throws
}

public extension PlaybackServing {
    func execute(_ command: PlaybackSessionCommand) async throws {
        await send(command)
        if let error = snapshot.error {
            throw error
        }
    }
}

/// App-facing software output controls. This is deliberately separate from
/// `PlaybackServing` so an engine can keep volume state without making it part
/// of the persisted playback queue or remote command protocol.
@MainActor
public protocol PlaybackAudioServing: AnyObject {
    var volume: Float { get }
    var isMuted: Bool { get }
    func setVolume(_ volume: Float) async
    func setMuted(_ isMuted: Bool) async
}
