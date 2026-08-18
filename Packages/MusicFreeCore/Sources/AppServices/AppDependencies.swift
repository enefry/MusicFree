import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI
import SystemIntegrationAPI

/// All application ports and nondeterministic services supplied by the
/// composition root. No adapter or framework is constructed by AppServices.
public struct AppDependencies {
    public let mediaSources: [any MediaSource]
    public let mediaImporter: (any MediaImporting)?
    public let managedMediaRemover: (any ManagedMediaRemoving)?
    /// Writes artwork bytes and returns a receipt that keeps a new file
    /// reserved until the metadata transaction commits or rolls back.
    public let artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)?
    public let libraryRepository: (any LibraryRepository)?
    public let playlistRepository: (any PlaylistRepository)?
    public let playbackQueueRepository: (any PlaybackQueueRepository)?
    public let playbackHistoryRepository: (any PlaybackHistoryRepository)?
    public let settingsRepository: (any SettingsRepository)?
    public let metadataEnrichmentProvider: (any MetadataEnrichmentProviding)?
    public let metadataEnrichmentRecordRepository: (any MetadataEnrichmentRecordRepository)?
    public let storageMaintenance: (any StorageMaintenanceServing)?
    public let playbackEngine: (any PlaybackEngine)?
    public let audioSession: (any AudioSessionManaging)?
    public let nowPlaying: (any NowPlayingPublishing)?
    public let remoteCommands: (any RemoteCommandReceiving)?
    public let systemCapabilities: SystemIntegrationCapabilitySnapshot
    public let playbackCapabilities: PlaybackCapabilities
    public let clock: any AppClock
    public let calendar: Calendar
    public let idGenerator: any AppIDGenerating
    public let randomSource: any AppRandomSource

    /// Creates a validated dependency graph. Individual optional ports let a
    /// focused composition root opt out of an unsupported feature; invoking
    /// that feature then returns `missingDependency` instead of crashing.
    @MainActor
    public init(
        mediaSources: [any MediaSource] = [],
        mediaImporter: (any MediaImporting)? = nil,
        managedMediaRemover: (any ManagedMediaRemoving)? = nil,
        artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)? = nil,
        libraryRepository: (any LibraryRepository)? = nil,
        playlistRepository: (any PlaylistRepository)? = nil,
        playbackQueueRepository: (any PlaybackQueueRepository)? = nil,
        playbackHistoryRepository: (any PlaybackHistoryRepository)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        metadataEnrichmentProvider: (any MetadataEnrichmentProviding)? = nil,
        metadataEnrichmentRecordRepository: (any MetadataEnrichmentRecordRepository)? = nil,
        storageMaintenance: (any StorageMaintenanceServing)? = nil,
        playbackEngine: (any PlaybackEngine)? = nil,
        audioSession: (any AudioSessionManaging)? = nil,
        nowPlaying: (any NowPlayingPublishing)? = nil,
        remoteCommands: (any RemoteCommandReceiving)? = nil,
        systemCapabilities: SystemIntegrationCapabilitySnapshot = .init(),
        playbackCapabilities: PlaybackCapabilities? = nil,
        clock: any AppClock = WallAppClock(),
        calendar: Calendar = .autoupdatingCurrent,
        idGenerator: any AppIDGenerating = UUIDAppIDGenerator(),
        randomSource: any AppRandomSource = SystemAppRandomSource()
    ) throws {
        var seen = Set<MediaSourceID>()
        for source in mediaSources {
            guard seen.insert(source.descriptor.sourceID).inserted else {
                throw AppServiceError.duplicateSource(source.descriptor.sourceID)
            }
        }

        if systemCapabilities.supports(.audioSession), audioSession == nil {
            throw AppServiceError.incompatibleDependency("audioSession")
        }
        if systemCapabilities.supports(.nowPlaying), nowPlaying == nil {
            throw AppServiceError.incompatibleDependency("nowPlaying")
        }
        if systemCapabilities.supports(.remoteCommands), remoteCommands == nil {
            throw AppServiceError.incompatibleDependency("remoteCommands")
        }

        self.mediaSources = mediaSources
        self.mediaImporter = mediaImporter
        self.managedMediaRemover = managedMediaRemover
        self.artworkWriter = artworkWriter
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.playbackQueueRepository = playbackQueueRepository
        self.playbackHistoryRepository = playbackHistoryRepository
        self.settingsRepository = settingsRepository
        self.metadataEnrichmentProvider = metadataEnrichmentProvider
        self.metadataEnrichmentRecordRepository = metadataEnrichmentRecordRepository
        self.storageMaintenance = storageMaintenance
        self.playbackEngine = playbackEngine
        self.audioSession = audioSession
        self.nowPlaying = nowPlaying
        self.remoteCommands = remoteCommands
        self.systemCapabilities = systemCapabilities
        self.playbackCapabilities = playbackCapabilities ?? playbackEngine?.capabilities ?? []
        self.clock = clock
        self.calendar = calendar
        self.idGenerator = idGenerator
        self.randomSource = randomSource
    }

    public var sources: [any MediaSource] {
        mediaSources
    }

    public var importer: (any MediaImporting)? {
        mediaImporter
    }

    public var remover: (any ManagedMediaRemoving)? {
        managedMediaRemover
    }

    public var queueRepository: (any PlaybackQueueRepository)? {
        playbackQueueRepository
    }

    public var historyRepository: (any PlaybackHistoryRepository)? {
        playbackHistoryRepository
    }
}
