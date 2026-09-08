import Foundation
import MediaSourceAPI
import MusicDomain
import SettingsAPI

/// Applies the online-source runtime gate at the application boundary.
///
/// The coordinator intentionally does not persist settings and does not own
/// credentials. SettingsCoordinator owns the durable preference aggregate;
/// this object only keeps the current redacted snapshot and delegates to
/// already-composed source adapters after authorization has been checked.
@MainActor
final class OnlineSourceCoordinator: OnlineSourceServing {
    private static let logger = MusicLogger(
        subsystem: "com.musicfree.app",
        category: "online-source-coordinator"
    )

    private var adapters: [MediaSourceID: any OnlineSource]
    private let factory: (any OnlineSourceFactory)?
    private var preferences = OnlineSourcePreferences.defaults
    private var applicationPrivacyAccepted = false
    private var currentSnapshot = OnlineSourceSnapshot()
    private var continuations: [UUID: AsyncStream<OnlineSourceSnapshot>.Continuation] = [:]

    init(
        sources: [any OnlineSource],
        factory: (any OnlineSourceFactory)? = nil
    ) throws {
        var adapters: [MediaSourceID: any OnlineSource] = [:]
        for source in sources {
            let sourceID = source.descriptor.sourceID
            guard adapters[sourceID] == nil else {
                throw AppServiceError.duplicateSource(sourceID)
            }
            adapters[sourceID] = source
        }
        self.adapters = adapters
        self.factory = factory
    }

    /// Replaces the runtime gate after startup or a successful settings
    /// commit. This is deliberately separate from persistence so a stale
    /// settings stream can never silently authorize an adapter.
    func apply(_ importPreferences: ImportPreferences) {
        preferences = importPreferences.onlineSourcePreferences
        applicationPrivacyAccepted = importPreferences.privacyPreferences.isPrivacyPolicyAccepted
        let globalEnabled = preferences.isEnabled
        let appPrivacyAccepted = applicationPrivacyAccepted
        let sourceCount = preferences.sources.count
        let sourceIDs = preferences.sources
            .map { $0.sourceID.rawValue }
            .joined(separator: ",")
        Self.logger.info(
            "apply online settings global=\(globalEnabled) appPrivacy=\(appPrivacyAccepted) sourceCount=\(sourceCount) sourceIDs=\(sourceIDs)"
        )
        rebuildAdapters(for: preferences.sources)
        let registeredSourceIDs = adapters.keys
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let adapterCount = adapters.count
        Self.logger.info(
            "online adapters rebuilt count=\(adapterCount) registeredSourceIDs=\(registeredSourceIDs)"
        )
        publishSnapshot()
    }

    func snapshot() async -> OnlineSourceSnapshot {
        currentSnapshot
    }

    func makeSnapshotStream() async -> AsyncStream<OnlineSourceSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<OnlineSourceSnapshot>.makeStream()
        continuations[id] = continuation
        continuation.yield(currentSnapshot)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations.removeValue(forKey: id)
            }
        }
        return stream
    }

    func authenticate(
        sourceID: MediaSourceID,
        oneTimeCode: String
    ) async throws {
        let source = try authorizedAdapter(for: sourceID)
        guard let source = source as? any OneTimeCodeAuthenticatingOnlineSource else {
            throw OnlineSourceServingError.operationUnsupported(
                sourceID,
                "one-time-code authentication"
            )
        }
        try await source.authenticate(oneTimeCode: oneTimeCode)
    }

    func browse(
        sourceID: MediaSourceID,
        request: SourceBrowseRequest
    ) async throws -> SourceCatalogPage {
        Self.logger.info(
            "browse begin source=\(sourceID.rawValue) parent=\(request.parentID?.externalID ?? "root")"
        )
        let source = try authorizedAdapter(for: sourceID)
        guard let source = source as? any DownloadSource else {
            throw OnlineSourceServingError.operationUnsupported(sourceID, "browse")
        }
        do {
            let page = try await source.browse(request)
            Self.logger.info(
                "browse completed source=\(sourceID.rawValue) items=\(page.items.count)"
            )
            return page
        } catch {
            Self.logger.error(
                "browse failed source=\(sourceID.rawValue) error=\(String(describing: error))"
            )
            throw error
        }
    }

    func search(
        sourceID: MediaSourceID,
        request: SourceSearchRequest
    ) async throws -> SourceCatalogPage {
        let source = try authorizedAdapter(for: sourceID)
        guard let source = source as? any SearchableDownloadSource else {
            throw OnlineSourceServingError.operationUnsupported(sourceID, "search")
        }
        return try await source.search(request)
    }

    func download(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        options: DownloadOptions
    ) async throws -> DownloadReceipt {
        let source = try authorizedAdapter(for: sourceID)
        guard let source = source as? any DownloadSource else {
            throw OnlineSourceServingError.operationUnsupported(sourceID, "download")
        }
        guard itemID.sourceID == sourceID else {
            throw OnlineSourceServingError.sourceNotConfigured(itemID.sourceID)
        }
        return try await source.download(itemID, options: options)
    }

    func playbackAccess(
        sourceID: MediaSourceID,
        itemID: SourceObjectID,
        purpose: PlaybackPurpose
    ) async throws -> PlaybackAccess {
        let source = try authorizedAdapter(for: sourceID)
        guard let source = source as? any PlaybackSource else {
            throw OnlineSourceServingError.operationUnsupported(sourceID, "audition")
        }
        guard itemID.sourceID == sourceID else {
            throw OnlineSourceServingError.sourceNotConfigured(itemID.sourceID)
        }
        return try await source.playbackAccess(for: itemID, purpose: purpose)
    }

    private func authorizedAdapter(for sourceID: MediaSourceID) throws -> any OnlineSource {
        guard applicationPrivacyAccepted else {
            Self.logger.error(
                "adapter authorization blocked source=\(sourceID.rawValue) reason=applicationPrivacy"
            )
            throw OnlineSourceServingError.applicationPrivacyRequired
        }
        guard let configuration = preferences.source(for: sourceID) else {
            Self.logger.error(
                "adapter authorization blocked source=\(sourceID.rawValue) reason=notConfigured"
            )
            throw OnlineSourceServingError.sourceNotConfigured(sourceID)
        }
        guard preferences.isEnabled, configuration.isEnabled else {
            let globalEnabled = preferences.isEnabled
            let sourceEnabled = configuration.isEnabled
            Self.logger.error(
                "adapter authorization blocked source=\(sourceID.rawValue) reason=disabled global=\(globalEnabled) sourceEnabled=\(sourceEnabled)"
            )
            throw OnlineSourceServingError.sourceDisabled(sourceID)
        }

        let expectedVersion = adapters[sourceID]?.privacyPolicyVersion
            ?? configuration.providerKind.defaultPrivacyPolicyVersion
        guard configuration.isPrivacyPolicyAccepted(currentVersion: expectedVersion) else {
            Self.logger.error(
                "adapter authorization blocked source=\(sourceID.rawValue) reason=sourcePrivacy expectedVersion=\(expectedVersion) configuredVersion=\(configuration.privacyPolicyVersion ?? "none")"
            )
            throw OnlineSourceServingError.sourcePrivacyRequired(sourceID)
        }
        guard let adapter = adapters[sourceID] else {
            Self.logger.error(
                "adapter authorization blocked source=\(sourceID.rawValue) reason=adapterUnavailable provider=\(configuration.providerKind.rawValue)"
            )
            throw OnlineSourceServingError.sourceUnavailable(sourceID)
        }
        return adapter
    }

    private func publishSnapshot() {
        currentSnapshot = makeSnapshot()
        for continuation in continuations.values {
            continuation.yield(currentSnapshot)
        }
    }

    private func rebuildAdapters(for configurations: [OnlineSourceConfiguration]) {
        var rebuilt: [MediaSourceID: any OnlineSource] = [:]
        for configuration in configurations {
            Self.logger.info(
                "adapter build begin source=\(configuration.sourceID.rawValue) provider=\(configuration.providerKind.rawValue) hasEndpoint=\(configuration.endpoint != nil)"
            )
            if let factory {
                // A source instance is configuration-scoped. Reusing only by
                // Provider kind would leave an old endpoint or credential
                // reference active after the user edits the same source ID.
                let source: (any OnlineSource)?
                do {
                    source = try factory.makeSource(for: configuration)
                } catch {
                    Self.logger.error(
                        "adapter build failed source=\(configuration.sourceID.rawValue) provider=\(configuration.providerKind.rawValue) error=\(String(describing: error))"
                    )
                    continue
                }
                guard let source,
                      source.descriptor.sourceID == configuration.sourceID,
                      source.providerKind == configuration.providerKind
                else {
                    Self.logger.error(
                        "adapter build rejected source=\(configuration.sourceID.rawValue) provider=\(configuration.providerKind.rawValue)"
                    )
                    continue
                }
                rebuilt[configuration.sourceID] = source
                Self.logger.info(
                    "adapter build succeeded source=\(configuration.sourceID.rawValue) provider=\(configuration.providerKind.rawValue)"
                )
            } else if let existing = adapters[configuration.sourceID],
                      existing.providerKind == configuration.providerKind {
                // Compatibility path for callers that compose already-built
                // adapters and intentionally do not provide a factory.
                rebuilt[configuration.sourceID] = existing
            }
        }
        adapters = rebuilt
    }

    private func makeSnapshot() -> OnlineSourceSnapshot {
        let sources = preferences.sources.map { configuration in
            let adapter = adapters[configuration.sourceID]
            let privacyVersion = adapter?.privacyPolicyVersion
                ?? configuration.providerKind.defaultPrivacyPolicyVersion
            let privacyAccepted = configuration.isPrivacyPolicyAccepted(
                currentVersion: privacyVersion
            )
            let runtimeEnabled = preferences.isEnabled
                && applicationPrivacyAccepted
                && configuration.isEnabled
                && privacyAccepted
                && adapter != nil

            return OnlineSourceSummary(
                sourceID: configuration.sourceID,
                providerKind: configuration.providerKind,
                displayName: configuration.displayName,
                capabilities: adapter?.onlineCapabilities ?? [],
                privacyPolicyVersion: privacyVersion,
                isRegistered: adapter != nil,
                isPrivacyAccepted: privacyAccepted,
                isEnabled: configuration.isEnabled,
                isRuntimeEnabled: runtimeEnabled
            )
        }
        return OnlineSourceSnapshot(
            isGloballyEnabled: preferences.isEnabled,
            isApplicationPrivacyAccepted: applicationPrivacyAccepted,
            sources: sources
        )
    }
}
