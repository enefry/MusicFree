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
    func searchLibrary(
        _ request: LibrarySearchRequest
    ) async throws -> LibrarySearchResults
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
    func repairMetadata() async throws -> LibraryMetadataRepairResult
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
    func repairMetadata() async throws -> LibraryMetadataRepairResult {
        LibraryMetadataRepairResult()
    }

    func searchLibrary(
        _ request: LibrarySearchRequest
    ) async throws -> LibrarySearchResults {
        guard let searchText = request.searchText else {
            return LibrarySearchResults()
        }
        let page = try LibraryPageRequest(limit: request.limit)
        let tracks = try await browseTracks(
            matching: TrackQuery(searchText: searchText, sourceID: request.sourceID),
            page: page
        )
        try Task.checkCancellation()
        let albums = try await browseAlbums(
            matching: AlbumQuery(searchText: searchText, sourceID: request.sourceID),
            page: page
        )
        return LibrarySearchResults(
            tracks: tracks.elements,
            albums: albums.elements
        )
    }

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
    func continueImport(_ importID: UUID) async
    func cancel(_ importID: UUID) async
    func state(for importID: UUID) async -> ImportSessionSnapshot?
    func makeStateStream() async -> AsyncStream<ImportSessionSnapshot>
}

public enum OnlineSourceServingError: Error, Equatable, Sendable, LocalizedError,
    CustomStringConvertible {
    case applicationPrivacyRequired
    case sourceNotConfigured(MediaSourceID)
    case sourcePrivacyRequired(MediaSourceID)
    case sourceDisabled(MediaSourceID)
    case sourceUnavailable(MediaSourceID)
    case authenticationRequired(MediaSourceID)
    case authenticationFailed(MediaSourceID)
    case operationUnsupported(MediaSourceID, String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .applicationPrivacyRequired:
            return "The application privacy agreement is required for online sources."
        case .sourceNotConfigured(let sourceID):
            return "Online source \(sourceID) is not configured."
        case .sourcePrivacyRequired(let sourceID):
            return "The privacy agreement for online source \(sourceID) is required."
        case .sourceDisabled(let sourceID):
            return "Online source \(sourceID) is disabled."
        case .sourceUnavailable(let sourceID):
            return "Online source \(sourceID) is not available in this build."
        case .authenticationRequired(let sourceID):
            return "Online source \(sourceID) requires authorization."
        case .authenticationFailed(let sourceID):
            return "Online source \(sourceID) authentication failed."
        case .operationUnsupported(let sourceID, let operation):
            return "Online source \(sourceID) does not support \(operation)."
        }
    }
}

/// A redacted, presentation-safe view of one configured online source.
public struct OnlineSourceSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let sourceID: MediaSourceID
    public let providerKind: OnlineProviderKind
    public let displayName: String
    public let capabilities: OnlineSourceCapabilities
    public let privacyPolicyVersion: String
    public let isRegistered: Bool
    public let isPrivacyAccepted: Bool
    public let isEnabled: Bool
    public let isRuntimeEnabled: Bool

    public var id: MediaSourceID { sourceID }

    public init(
        sourceID: MediaSourceID,
        providerKind: OnlineProviderKind,
        displayName: String,
        capabilities: OnlineSourceCapabilities = [],
        privacyPolicyVersion: String,
        isRegistered: Bool,
        isPrivacyAccepted: Bool,
        isEnabled: Bool,
        isRuntimeEnabled: Bool
    ) {
        self.sourceID = sourceID
        self.providerKind = providerKind
        self.displayName = displayName
        self.capabilities = capabilities
        self.privacyPolicyVersion = privacyPolicyVersion
        self.isRegistered = isRegistered
        self.isPrivacyAccepted = isPrivacyAccepted
        self.isEnabled = isEnabled
        self.isRuntimeEnabled = isRuntimeEnabled
    }
}

public struct OnlineSourceSnapshot: Codable, Equatable, Hashable, Sendable {
    public let isGloballyEnabled: Bool
    public let isApplicationPrivacyAccepted: Bool
    public let sources: [OnlineSourceSummary]

    public init(
        isGloballyEnabled: Bool = true,
        isApplicationPrivacyAccepted: Bool = false,
        sources: [OnlineSourceSummary] = []
    ) {
        self.isGloballyEnabled = isGloballyEnabled
        self.isApplicationPrivacyAccepted = isApplicationPrivacyAccepted
        self.sources = sources.sorted { $0.sourceID < $1.sourceID }
    }
}

/// The first local condition that prevents one online-source operation.
/// Keep this separate from credential/OAuth failures, which occur only after
/// the local privacy and enablement gates are all satisfied.
public enum OnlineSourceAvailabilityIssue: Equatable, Sendable {
    case sourceNotConfigured
    case providerUnavailable
    case applicationPrivacyRequired
    case sourcePrivacyRequired(policyVersion: String)
    case globalServiceDisabled
    case sourceDisabled
    case capabilityUnsupported(OnlineSourceCapabilities)
}

public enum OnlineSourceAvailabilityEvaluator {
    public static func issue(
        in snapshot: OnlineSourceSnapshot,
        sourceID: MediaSourceID,
        requiring capability: OnlineSourceCapabilities? = nil
    ) -> OnlineSourceAvailabilityIssue? {
        guard let source = snapshot.sources.first(where: { $0.sourceID == sourceID }) else {
            return .sourceNotConfigured
        }
        guard source.isRegistered else { return .providerUnavailable }
        guard snapshot.isApplicationPrivacyAccepted else {
            return .applicationPrivacyRequired
        }
        guard source.isPrivacyAccepted else {
            return .sourcePrivacyRequired(policyVersion: source.privacyPolicyVersion)
        }
        guard snapshot.isGloballyEnabled else { return .globalServiceDisabled }
        guard source.isEnabled else { return .sourceDisabled }
        if let capability, !source.capabilities.contains(capability) {
            return .capabilityUnsupported(capability)
        }
        return nil
    }
}

/// The only AppServices surface that can reach an external media source.
/// Implementations must apply the application agreement, source agreement,
/// global switch and source enablement before delegating to an adapter.
public protocol OnlineSourceServing: Sendable {
    func snapshot() async -> OnlineSourceSnapshot
    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot>
    func authenticate(
        sourceID: MediaSourceID,
        oneTimeCode: String
    ) async throws
    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage
    func search(
        sourceID: MediaSourceID,
        request: SourceSearchRequest
    ) async throws -> SourceCatalogPage
    func download(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt
    func playbackAccess(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        purpose: PlaybackPurpose
    ) async throws -> PlaybackAccess
}

/// A value-only entry in the temporary online audition queue.
///
/// The catalog item contains presentation metadata only. It never stores the
/// short-lived playback URL, credentials, headers, or an adapter instance.
public struct OnlineAuditionQueueItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let item: SourceCatalogItem

    public init(item: SourceCatalogItem) {
        self.item = item
    }

    public var id: SourceObjectID { item.id }
    public var sourceID: MediaSourceID { item.id.sourceID }
    public var itemID: SourceObjectID { item.id }
    public var kind: SourceCatalogItemKind { item.kind }
    public var displayName: String { item.displayName }
    public var title: String? { item.title }
    public var artist: String? { item.artist }
    public var album: String? { item.album }
    public var duration: Duration? { item.duration }
    public var isPlayable: Bool { item.isPlayable }
}

public enum OnlineAuditionPhase: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case stopped
    case ended
    case failed
}

public struct OnlineAuditionSnapshot: Codable, Equatable, Hashable, Sendable {
    public let phase: OnlineAuditionPhase
    public let sourceID: MediaSourceID?
    public let itemID: SourceObjectID?
    public let displayName: String?
    public let artist: String?
    public let album: String?
    public let sourceDisplayName: String?
    public let queue: [OnlineAuditionQueueItem]
    public let currentIndex: Int?
    public let position: Duration
    public let duration: Duration?
    public let canSeek: Bool
    public let canPrevious: Bool
    public let canNext: Bool
    public let failureReason: String?

    public init(
        phase: OnlineAuditionPhase = .idle,
        sourceID: MediaSourceID? = nil,
        itemID: SourceObjectID? = nil,
        displayName: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        sourceDisplayName: String? = nil,
        queue: [OnlineAuditionQueueItem] = [],
        currentIndex: Int? = nil,
        position: Duration = .zero,
        duration: Duration? = nil,
        canSeek: Bool = false,
        canPrevious: Bool = false,
        canNext: Bool = false,
        failureReason: String? = nil
    ) {
        self.phase = phase
        self.sourceID = sourceID
        self.itemID = itemID
        self.displayName = Self.normalizedOptionalString(displayName)
        self.artist = Self.normalizedOptionalString(artist)
        self.album = Self.normalizedOptionalString(album)
        self.sourceDisplayName = Self.normalizedOptionalString(sourceDisplayName)
        self.queue = queue
        self.currentIndex = currentIndex
        self.position = max(.zero, position)
        self.duration = duration.map { max(.zero, $0) }
        self.canSeek = canSeek
        self.canPrevious = canPrevious
        self.canNext = canNext
        self.failureReason = Self.normalizedOptionalString(failureReason)
    }

    public static let idle = Self()

    private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public var currentQueueItem: OnlineAuditionQueueItem? {
        guard let currentIndex, queue.indices.contains(currentIndex) else {
            return nil
        }
        return queue[currentIndex]
    }

    /// True while the dedicated engine can currently be interacted with.
    public var isActive: Bool {
        switch phase {
        case .preparing, .buffering, .playing, .paused:
            true
        case .idle, .stopped, .ended, .failed:
            false
        }
    }

    /// A stopped, ended, or failed snapshot can still retain the temporary
    /// session context until an explicit close or a source-permission change.
    public var hasRetainedSession: Bool {
        phase != .idle && (sourceID != nil || itemID != nil || !queue.isEmpty)
    }

    public var isTerminal: Bool {
        switch phase {
        case .ended, .failed:
            true
        case .idle, .preparing, .buffering, .playing, .paused, .stopped:
            false
        }
    }

    public var canRetry: Bool {
        phase == .failed || phase == .ended
    }
}

public enum OnlineAuditionError: Error, Equatable, Sendable, LocalizedError,
    CustomStringConvertible {
    case playbackUnavailable
    case downloadRequired
    case accessExpired
    case emptyQueue
    case itemNotInQueue
    case seekingUnavailable
    case playbackFailed(String)

    public var errorDescription: String? { description }

    public var diagnosticCode: String {
        switch self {
        case .playbackUnavailable: "playback_unavailable"
        case .downloadRequired: "download_required"
        case .accessExpired: "access_expired"
        case .emptyQueue: "empty_queue"
        case .itemNotInQueue: "item_not_in_queue"
        case .seekingUnavailable: "seeking_unavailable"
        case let .playbackFailed(code): code
        }
    }

    public var description: String {
        switch self {
        case .playbackUnavailable:
            "Online audition playback is unavailable."
        case .downloadRequired:
            "This item must be downloaded before playback."
        case .accessExpired:
            "The temporary audition access has expired."
        case .emptyQueue:
            "There are no playable songs to audition."
        case .itemNotInQueue:
            "The selected song is no longer in the audition list."
        case .seekingUnavailable:
            "Seeking is unavailable for this audition."
        case .playbackFailed:
            "The online audition could not be played."
        }
    }
}

/// A transient online-source player. Its queue is a frozen, in-memory view of
/// currently loaded catalog metadata; it owns no formal playback queue,
/// history, Now Playing, remote-command or persistence integration.
@MainActor
public protocol OnlineAuditionServing: AnyObject {
    var snapshot: OnlineAuditionSnapshot { get }
    func makeSnapshotStream() -> AsyncStream<OnlineAuditionSnapshot>

    /// Starts a frozen, in-memory queue at the selected item. The queue is
    /// expected to contain the current catalog/search display order.
    func start(
        sourceID: MediaSourceID,
        items: [SourceCatalogItem],
        startingItemID: SourceObjectID?
    ) async throws

    /// Compatibility entry point for callers that only have one item.
    func audition(
        sourceID: MediaSourceID,
        item: SourceCatalogItem
    ) async throws

    func pause() async
    func resume() async throws
    func seek(to position: Duration) async throws
    func previous() async throws
    func next() async throws
    func select(itemID: SourceObjectID) async throws
    func retry() async throws

    /// Legacy stop keeps a terminal stopped snapshot for existing callers.
    /// New UI close/lifecycle paths should use `close()` to clear the session.
    func stop() async
    func close() async
    func handleAudioSessionEvent(_ event: AudioSessionEvent) async
}

public extension OnlineAuditionServing {
    func start(
        sourceID: MediaSourceID,
        items: [SourceCatalogItem],
        startingItemID: SourceObjectID?
    ) async throws {
        guard let item = items.first(where: {
            $0.id == startingItemID || startingItemID == nil
        }) else {
            throw OnlineAuditionError.emptyQueue
        }
        try await audition(sourceID: sourceID, item: item)
    }

    func pause() async {}
    func resume() async throws {}
    func seek(to _: Duration) async throws {}
    func previous() async throws {}
    func next() async throws {}
    func select(itemID _: SourceObjectID) async throws {}
    func retry() async throws {}
    func close() async { await stop() }
    func handleAudioSessionEvent(_: AudioSessionEvent) async {}
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
    func refresh(itemIDs: Set<MediaItemID>) async throws -> MetadataEnrichmentRefreshResult
    func refresh(
        itemIDs: Set<MediaItemID>,
        albumName: String?,
        progress: (@Sendable (MetadataEnrichmentRefreshProgress) -> Void)?
    ) async throws -> MetadataEnrichmentRefreshResult
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

    func refresh(itemIDs _: Set<MediaItemID>) async throws -> MetadataEnrichmentRefreshResult {
        throw MetadataEnrichmentError.unavailable
    }

    func refresh(
        itemIDs: Set<MediaItemID>,
        albumName _: String?,
        progress _: (@Sendable (MetadataEnrichmentRefreshProgress) -> Void)?
    ) async throws -> MetadataEnrichmentRefreshResult {
        try await refresh(itemIDs: itemIDs)
    }
}

public extension ImportServing {
    func startImport(_ request: MediaImportRequest)
        async throws -> AsyncThrowingStream<MediaImportEvent, Error>
    {
        try await start(request)
    }

    func continueImport(_ importID: UUID) async {
        _ = importID
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

    func updateOnlineSourcePreferences(
        _ preferences: OnlineSourcePreferences
    ) async throws {
        let current = try await load()
        try await update(
            AppSettings(
                importPreferences: current.importPreferences
                    .settingOnlineSourcePreferences(preferences),
                playbackPreferences: current.playbackPreferences,
                storagePreferences: current.storagePreferences,
                loggingPreferences: current.loggingPreferences
            )
        )
    }

    func setOnlineSourcesEnabled(_ enabled: Bool) async throws {
        let current = try await load()
        try await updateOnlineSourcePreferences(
            current.importPreferences.onlineSourcePreferences.settingEnabled(enabled)
        )
    }

    func acceptApplicationPrivacyForOnlineSources() async throws {
        let current = try await load()
        try await update(
            AppSettings(
                importPreferences: current.importPreferences.settingPrivacyPreferences(
                    current.importPreferences.privacyPreferences.acceptingPrivacyPolicy()
                ),
                playbackPreferences: current.playbackPreferences,
                storagePreferences: current.storagePreferences,
                loggingPreferences: current.loggingPreferences
            )
        )
    }

    func revokeApplicationPrivacyForOnlineSources() async throws {
        let current = try await load()
        try await update(
            AppSettings(
                importPreferences: current.importPreferences
                    .settingPrivacyPreferences(.revokingOnlineServices())
                    .settingOnlineSourcePreferences(
                        current.importPreferences.onlineSourcePreferences.revokingAllPrivacy()
                ),
                playbackPreferences: current.playbackPreferences,
                storagePreferences: current.storagePreferences,
                loggingPreferences: current.loggingPreferences
            )
        )
    }

    func acceptOnlineSourcePrivacy(
        _ sourceID: MediaSourceID,
        policyVersion: String
    ) async throws {
        let current = try await load()
        try await updateOnlineSourcePreferences(
            try current.importPreferences.onlineSourcePreferences.acceptingSourcePrivacy(
                sourceID,
                policyVersion: policyVersion
            )
        )
    }

    func revokeOnlineSourcePrivacy(_ sourceID: MediaSourceID) async throws {
        let current = try await load()
        try await updateOnlineSourcePreferences(
            try current.importPreferences.onlineSourcePreferences.revokingSourcePrivacy(
                sourceID
            )
        )
    }

    func revokeAllOnlineSourcePrivacy() async throws {
        let current = try await load()
        try await updateOnlineSourcePreferences(
            current.importPreferences.onlineSourcePreferences.revokingAllPrivacy()
        )
    }
}

@MainActor
public protocol PlaybackServing: AnyObject {
    var snapshot: PlaybackSessionSnapshot { get }
    func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot>

    /// The formal playback coordinator is the sole owner of the audio-session
    /// adapter stream. Other transient players observe this forwarded stream
    /// so the adapter never receives a second active subscription.
    func makeAudioSessionEventStream() -> AsyncStream<AudioSessionEvent>

    func send(_ command: PlaybackSessionCommand) async
    func execute(_ command: PlaybackSessionCommand) async throws
}

public extension PlaybackServing {
    func makeAudioSessionEventStream() -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

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
