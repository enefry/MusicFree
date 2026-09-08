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
    public let onlineSources: [any OnlineSource]
    public let onlineSourceFactory: (any OnlineSourceFactory)?
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
    public let onlineDownloadQueueStore: (any OnlineDownloadQueueStore)?
    public let metadataEnrichmentProviders: [any MetadataEnrichmentProviding]
    public let lyricsProviders: [any LyricsProviding]
    public let metadataEnrichmentRecordRepository: (any MetadataEnrichmentRecordRepository)?
    public let storageMaintenance: (any StorageMaintenanceServing)?
    public let playbackEngine: (any PlaybackEngine)?
    public let onlineAuditionEngine: (any PlaybackEngine)?
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
        onlineSources: [any OnlineSource] = [],
        onlineSourceFactory: (any OnlineSourceFactory)? = nil,
        mediaImporter: (any MediaImporting)? = nil,
        managedMediaRemover: (any ManagedMediaRemoving)? = nil,
        artworkWriter: (@Sendable (Data, ArtworkID) async throws -> ArtworkWriteReceipt)? = nil,
        libraryRepository: (any LibraryRepository)? = nil,
        playlistRepository: (any PlaylistRepository)? = nil,
        playbackQueueRepository: (any PlaybackQueueRepository)? = nil,
        playbackHistoryRepository: (any PlaybackHistoryRepository)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        onlineDownloadQueueStore: (any OnlineDownloadQueueStore)? = nil,
        metadataEnrichmentProviders: [any MetadataEnrichmentProviding] = [],
        /// Compatibility injection for the original single-provider graph.
        metadataEnrichmentProvider: (any MetadataEnrichmentProviding)? = nil,
        lyricsProviders: [any LyricsProviding] = [],
        metadataEnrichmentRecordRepository: (any MetadataEnrichmentRecordRepository)? = nil,
        storageMaintenance: (any StorageMaintenanceServing)? = nil,
        playbackEngine: (any PlaybackEngine)? = nil,
        onlineAuditionEngine: (any PlaybackEngine)? = nil,
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

        var seenOnlineSources = Set<MediaSourceID>()
        for source in onlineSources {
            guard seenOnlineSources.insert(source.descriptor.sourceID).inserted else {
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
        self.onlineSources = onlineSources
        self.onlineSourceFactory = onlineSourceFactory
        self.mediaImporter = mediaImporter
        self.managedMediaRemover = managedMediaRemover
        self.artworkWriter = artworkWriter
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.playbackQueueRepository = playbackQueueRepository
        self.playbackHistoryRepository = playbackHistoryRepository
        self.settingsRepository = settingsRepository
        self.onlineDownloadQueueStore = onlineDownloadQueueStore
        var resolvedMetadataProviders = metadataEnrichmentProviders
        if let metadataEnrichmentProvider {
            guard !resolvedMetadataProviders.contains(where: {
                $0.provider == metadataEnrichmentProvider.provider
            }) else {
                throw AppServiceError.incompatibleDependency(
                    "metadataEnrichmentProviders.\(metadataEnrichmentProvider.provider.rawValue)"
                )
            }
            resolvedMetadataProviders.insert(metadataEnrichmentProvider, at: 0)
        }
        var seenMetadataProviders = Set<MetadataProviderID>()
        for provider in resolvedMetadataProviders {
            guard seenMetadataProviders.insert(provider.provider).inserted else {
                throw AppServiceError.incompatibleDependency(
                    "metadataEnrichmentProviders.\(provider.provider.rawValue)"
                )
            }
        }
        self.metadataEnrichmentProviders = resolvedMetadataProviders
        var seenLyricsProviders = Set<LyricsProviderID>()
        for provider in lyricsProviders {
            guard seenLyricsProviders.insert(provider.provider).inserted else {
                throw AppServiceError.incompatibleDependency(
                    "lyricsProviders.\(provider.provider.rawValue)"
                )
            }
        }
        self.lyricsProviders = lyricsProviders
        self.metadataEnrichmentRecordRepository = metadataEnrichmentRecordRepository
        self.storageMaintenance = storageMaintenance
        self.playbackEngine = playbackEngine
        self.onlineAuditionEngine = onlineAuditionEngine
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

    /// Compatibility view for the original single-provider graph.
    public var metadataEnrichmentProvider: (any MetadataEnrichmentProviding)? {
        metadataEnrichmentProviders.first
    }
}
