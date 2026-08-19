import Foundation
import LibraryAPI
import MusicDomain
import OSLog
import SettingsAPI

/// AppServices owns the enrichment queue so imports and settings do not keep
/// network tasks in a view. Providers are attempted serially in user-defined
/// order, keeping each provider's rate limit and persisted state isolated.
internal actor MetadataEnrichmentCoordinator: MetadataEnrichmentServing {
    private enum ItemOutcome {
        case matched
        case noMatch
        case ambiguous
        case failed
        case skipped
        case cancelled
    }

    private let providers: [MetadataProviderID: any MetadataEnrichmentProviding]
    private let recordRepository: (any MetadataEnrichmentRecordRepository)?
    private let libraryRepository: (any LibraryRepository)?
    private let library: any LibraryServing
    private let clock: any AppClock
    private let operationGate = MetadataEnrichmentOperationGate()

    private static let logger = Logger(
        subsystem: "com.musicfree.app",
        category: "metadata-enrichment"
    )

    private var providerPreferences: [MetadataProviderPreference]
    private var enabled = false
    private var authorization: MetadataEnrichmentAuthorizationStatus
    private var activeProvider: MetadataProviderID?
    private var providerStatuses: [MetadataEnrichmentProviderSnapshot] = []
    private var scan = MetadataEnrichmentScanSnapshot()
    private var snapshotContinuations: [UUID: AsyncStream<MetadataEnrichmentSnapshot>.Continuation] = [:]
    private var pendingItemIDs: [MediaItemID] = []
    private var pendingItemIDSet: Set<MediaItemID> = []
    private var queueTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init(
        providers: [any MetadataEnrichmentProviding],
        recordRepository: (any MetadataEnrichmentRecordRepository)?,
        libraryRepository: (any LibraryRepository)?,
        library: any LibraryServing,
        clock: any AppClock
    ) {
        var registered: [MetadataProviderID: any MetadataEnrichmentProviding] = [:]
        for provider in providers where registered[provider.provider] == nil {
            registered[provider.provider] = provider
        }
        self.providers = registered
        self.recordRepository = recordRepository
        self.libraryRepository = libraryRepository
        self.library = library
        self.clock = clock
        self.authorization = .unavailable
        self.activeProvider = nil

        var initialPreferences = ImportPreferences.defaultMetadataProviders
        var seen = Set<MetadataProviderID>()
        for provider in providers where seen.insert(provider.provider).inserted {
            if let index = initialPreferences.firstIndex(where: {
                $0.provider == provider.provider
            }) {
                initialPreferences[index] = initialPreferences[index].settingEnabled(true)
            } else {
                initialPreferences.append(
                    MetadataProviderPreference(provider: provider.provider, isEnabled: true)
                )
            }
        }
        self.providerPreferences = initialPreferences
    }

    func snapshot() -> MetadataEnrichmentSnapshot {
        MetadataEnrichmentSnapshot(
            isEnabled: enabled,
            authorization: authorization,
            scan: scan,
            activeProvider: activeProvider,
            providerStatuses: providerStatuses
        )
    }

    func makeSnapshotStream() -> AsyncStream<MetadataEnrichmentSnapshot> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<MetadataEnrichmentSnapshot>.makeStream()
        snapshotContinuations[subscriptionID] = continuation
        continuation.yield(snapshot())
        Self.logger.debug(
            "snapshot subscriber connected id=\(subscriptionID.uuidString, privacy: .public) subscribers=\(self.snapshotContinuations.count, privacy: .public)"
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSnapshotSubscription(subscriptionID) }
        }
        return stream
    }

    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        let providerID = providerPreferences.first {
            $0.isEnabled && providers[$0.provider] != nil
        }?.provider
            ?? providerPreferences.first(where: { providers[$0.provider] != nil })?.provider
        guard let providerID else {
            authorization = .unavailable
            publish()
            return authorization
        }
        return await requestAuthorization(for: providerID)
    }

    func requestAuthorization(
        for providerID: MetadataProviderID
    ) async -> MetadataEnrichmentAuthorizationStatus {
        guard let provider = providers[providerID] else {
            await refreshProviderStatuses()
            publish()
            return .unavailable
        }
        _ = await provider.requestAuthorization()
        await refreshProviderStatuses()
        let requestedAuthorization = providerStatuses.first {
            $0.provider == providerID
        }?.authorization ?? .unavailable
        publish()
        return requestedAuthorization
    }

    func setProviderPreferences(
        _ preferences: [MetadataProviderPreference]
    ) async {
        let normalized = Self.normalizedProviderPreferences(preferences)
        guard normalized != providerPreferences else {
            await refreshProviderStatuses()
            publish()
            return
        }

        providerPreferences = normalized
        if enabled {
            await cancelRunningWork()
        }
        await refreshProviderStatuses()
        publish()
        startQueueWorkerIfNeeded()
    }

    func setEnabled(_ requestedValue: Bool) async {
        guard requestedValue else {
            enabled = false
            await cancelRunningWork()
            await refreshProviderStatuses()
            publish()
            return
        }

        guard providerPreferences.contains(where: \.isEnabled), !providers.isEmpty else {
            enabled = false
            authorization = .unavailable
            activeProvider = nil
            await refreshProviderStatuses()
            publish()
            return
        }

        await refreshProviderStatuses()
        guard providerStatuses.contains(where: {
            $0.isEnabled && $0.authorization == .authorized
        }) else {
            enabled = false
            publish()
            return
        }

        enabled = true
        updateActiveProvider()
        publish()
        startQueueWorkerIfNeeded()
    }

    private static func normalizedProviderPreferences(
        _ preferences: [MetadataProviderPreference]
    ) -> [MetadataProviderPreference] {
        var seen = Set<MetadataProviderID>()
        let normalized = preferences.filter { seen.insert($0.provider).inserted }
        return normalized.isEmpty ? ImportPreferences.defaultMetadataProviders : normalized
    }

    private func refreshProviderStatuses() async {
        var statuses: [MetadataEnrichmentProviderSnapshot] = []
        statuses.reserveCapacity(providerPreferences.count)
        for preference in providerPreferences {
            let authorization: MetadataEnrichmentAuthorizationStatus
            if let provider = providers[preference.provider] {
                authorization = await provider.authorizationStatus()
            } else {
                authorization = .unavailable
            }
            statuses.append(
                MetadataEnrichmentProviderSnapshot(
                    provider: preference.provider,
                    isEnabled: preference.isEnabled,
                    isRegistered: providers[preference.provider] != nil,
                    authorization: authorization
                )
            )
        }
        providerStatuses = statuses
        updateActiveProvider()
        authorization = activeProvider.flatMap { activeID in
            statuses.first { $0.provider == activeID }?.authorization
        } ?? .unavailable
    }

    private func updateActiveProvider() {
        activeProvider = providerStatuses.first {
            $0.isEnabled && $0.authorization == .authorized
        }?.provider ?? providerStatuses.first {
            $0.isEnabled && $0.isRegistered
        }?.provider
    }

    private func enabledProviderIDs() -> [MetadataProviderID] {
        providerPreferences.compactMap { preference in
            guard preference.isEnabled, providers[preference.provider] != nil else {
                return nil
            }
            return preference.provider
        }
    }

    func enqueue(itemID: MediaItemID) {
        guard enabled, !providers.isEmpty, libraryRepository != nil else { return }
        guard pendingItemIDSet.insert(itemID).inserted else { return }
        pendingItemIDs.append(itemID)
        startQueueWorkerIfNeeded()
    }

    func startScan() {
        Self.logger.info(
            "scan requested enabled=\(self.enabled, privacy: .public) status=\(self.scan.status.rawValue, privacy: .public) providers=\(self.enabledProviderIDs().count, privacy: .public)"
        )
        guard enabled, !enabledProviderIDs().isEmpty, libraryRepository != nil else {
            scan = MetadataEnrichmentScanSnapshot(
                status: .failed,
                errorCode: "metadata_enrichment_unavailable"
            )
            Self.logger.error("scan rejected reason=metadata_enrichment_unavailable")
            publish()
            return
        }
        guard scanTask == nil else {
            Self.logger.debug("scan rejected reason=already_running")
            return
        }

        scan = MetadataEnrichmentScanSnapshot(status: .scanning)
        publish()
        Self.logger.info("scan state published status=scanning")
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performScan()
        }
        scanTask = task
    }

    func cancelScan() async {
        guard let task = scanTask else {
            Self.logger.debug(
                "cancel requested but no scan worker exists status=\(self.scan.status.rawValue, privacy: .public)"
            )
            return
        }

        Self.logger.info(
            "cancel requested processed=\(self.scan.processed, privacy: .public)/\(self.scan.total, privacy: .public) current=\(self.scan.currentTitle ?? "-", privacy: .public)"
        )
        task.cancel()
        if scan.status == .scanning {
            scan = MetadataEnrichmentScanSnapshot(
                status: .cancelled,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed
            )
            publish()
            Self.logger.info("cancel state published status=cancelled")
        }
        await task.value
        Self.logger.info("cancel worker finished status=\(self.scan.status.rawValue, privacy: .public)")
    }

    private func performScan() async {
        let scanStartedAt = Date()
        Self.logger.info("scan worker started")
        do {
            guard let repository = libraryRepository else {
                throw MetadataEnrichmentError.unavailable
            }
            var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            var tracks: [Track] = []

            var pageIndex = 0
            while true {
                try Task.checkCancellation()
                let page = try await repository.tracks(
                    matching: TrackQuery(sourceID: .local),
                    page: request
                )
                tracks.append(contentsOf: page.elements)
                Self.logger.debug(
                    "library page loaded page=\(pageIndex, privacy: .public) count=\(page.elements.count, privacy: .public) total=\(tracks.count, privacy: .public) hasNext=\(page.hasNextPage, privacy: .public)"
                )
                guard let nextPage = try page.nextPage(
                    limit: LibraryPageRequest.maximumLimit
                ) else {
                    break
                }
                request = nextPage
                pageIndex += 1
            }

            scan = MetadataEnrichmentScanSnapshot(
                status: .scanning,
                total: tracks.count
            )
            publish()
            Self.logger.info(
                "library pagination completed tracks=\(tracks.count, privacy: .public)"
            )

            for (index, track) in tracks.enumerated() {
                try Task.checkCancellation()
                guard enabled else { throw CancellationError() }
                let trackStartedAt = Date()
                Self.logger.info(
                    "track begin index=\(index + 1, privacy: .public)/\(tracks.count, privacy: .public) item=\(track.id.externalID, privacy: .public) title=\(track.title, privacy: .public)"
                )
                scan = MetadataEnrichmentScanSnapshot(
                    status: .scanning,
                    total: scan.total,
                    processed: scan.processed,
                    matched: scan.matched,
                    noMatch: scan.noMatch,
                    ambiguous: scan.ambiguous,
                    failed: scan.failed,
                    currentTitle: track.title
                )
                publish()

                // A user-triggered scan is an explicit request to retry prior
                // no-match and ambiguous decisions after catalog or matcher changes.
                let outcome = await process(itemID: track.id, forceRecheck: true)
                let outcomeCode = Self.itemOutcomeCode(outcome)
                Self.logger.info(
                    "track end index=\(index + 1, privacy: .public)/\(tracks.count, privacy: .public) item=\(track.id.externalID, privacy: .public) outcome=\(outcomeCode, privacy: .public) elapsed=\(Date().timeIntervalSince(trackStartedAt), privacy: .public)"
                )
                try Task.checkCancellation()
                guard enabled else { throw CancellationError() }
                var matched = scan.matched
                var noMatch = scan.noMatch
                var ambiguous = scan.ambiguous
                var failed = scan.failed
                switch outcome {
                case .matched:
                    matched += 1
                case .noMatch:
                    noMatch += 1
                case .ambiguous:
                    ambiguous += 1
                case .failed:
                    failed += 1
                case .skipped, .cancelled:
                    break
                }
                scan = MetadataEnrichmentScanSnapshot(
                    status: .scanning,
                    total: scan.total,
                    processed: scan.processed + 1,
                    matched: matched,
                    noMatch: noMatch,
                    ambiguous: ambiguous,
                    failed: failed
                )
                publish()
            }

            scan = MetadataEnrichmentScanSnapshot(
                status: .completed,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed
            )
            Self.logger.info(
                "scan worker completed processed=\(self.scan.processed, privacy: .public) matched=\(self.scan.matched, privacy: .public) noMatch=\(self.scan.noMatch, privacy: .public) ambiguous=\(self.scan.ambiguous, privacy: .public) failed=\(self.scan.failed, privacy: .public) elapsed=\(Date().timeIntervalSince(scanStartedAt), privacy: .public)"
            )
        } catch is CancellationError {
            scan = MetadataEnrichmentScanSnapshot(
                status: .cancelled,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed
            )
            Self.logger.info(
                "scan worker cancelled processed=\(self.scan.processed, privacy: .public)/\(self.scan.total, privacy: .public) elapsed=\(Date().timeIntervalSince(scanStartedAt), privacy: .public)"
            )
        } catch {
            scan = MetadataEnrichmentScanSnapshot(
                status: .failed,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed,
                errorCode: Self.errorCode(error)
            )
            Self.logger.error(
                "scan worker failed code=\(Self.errorCode(error), privacy: .public) processed=\(self.scan.processed, privacy: .public)/\(self.scan.total, privacy: .public)"
            )
        }

        scanTask = nil
        publish()
        startQueueWorkerIfNeeded()
    }

    private func startQueueWorkerIfNeeded() {
        guard enabled, scanTask == nil, queueTask == nil, !pendingItemIDs.isEmpty else {
            return
        }
        queueTask = Task { [weak self] in
            guard let self else { return }
            await self.drainQueue()
        }
    }

    private func drainQueue() async {
        while !Task.isCancelled, enabled, !pendingItemIDs.isEmpty {
            let itemID = pendingItemIDs.removeFirst()
            pendingItemIDSet.remove(itemID)
            _ = await process(itemID: itemID)
        }
        queueTask = nil
        startQueueWorkerIfNeeded()
    }

    private func process(
        itemID: MediaItemID,
        forceRecheck: Bool = false
    ) async -> ItemOutcome {
        let acquired = await operationGate.enter()
        guard acquired else { return .cancelled }
        let outcome = await processSerialized(
            itemID: itemID,
            forceRecheck: forceRecheck
        )
        await operationGate.leave()
        return outcome
    }

    private func processSerialized(
        itemID: MediaItemID,
        forceRecheck: Bool
    ) async -> ItemOutcome {
        guard enabled, let repository = libraryRepository else {
            return .cancelled
        }

        var currentProviderID: MetadataProviderID?
        do {
            guard let track = try await repository.track(id: itemID) else {
                return .skipped
            }
            let query = try await makeQuery(for: track, repository: repository)
            guard let searchTerm = query.searchTerm, !searchTerm.isEmpty else {
                return .noMatch
            }
            guard !query.missingFields.isEmpty else {
                return .skipped
            }

            var sawProvider = false
            var sawAmbiguous = false
            var sawFailure = false

            for providerID in enabledProviderIDs() {
                try Task.checkCancellation()
                guard let provider = providers[providerID] else {
                    Self.logger.error(
                        "provider missing item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public)"
                    )
                    continue
                }
                Self.logger.info(
                    "provider begin item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public)"
                )
                let authorization = await provider.authorizationStatus()
                guard authorization == .authorized else {
                    Self.logger.debug(
                        "provider skipped item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) authorization=\(authorization.rawValue, privacy: .public)"
                    )
                    continue
                }

                sawProvider = true
                currentProviderID = providerID
                let providerStartedAt = Date()
                let providerOutcome: ItemOutcome
                do {
                    providerOutcome = try await processWithProvider(
                        itemID: itemID,
                        query: query,
                        providerID: providerID,
                        provider: provider,
                        forceRecheck: forceRecheck
                    )
                } catch {
                    Self.logger.error(
                        "provider error item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) code=\(Self.errorCode(error), privacy: .public)"
                    )
                    throw error
                }
                Self.logger.info(
                    "provider end item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) outcome=\(Self.itemOutcomeCode(providerOutcome), privacy: .public) elapsed=\(Date().timeIntervalSince(providerStartedAt), privacy: .public)"
                )
                switch providerOutcome {
                case .matched:
                    return .matched
                case .ambiguous:
                    sawAmbiguous = true
                case .failed:
                    sawFailure = true
                case .noMatch:
                    break
                case .skipped:
                    return .skipped
                case .cancelled:
                    return .cancelled
                }
            }

            if sawAmbiguous { return .ambiguous }
            if sawFailure { return .failed }
            return sawProvider ? .noMatch : .failed
        } catch is CancellationError {
            await saveCancelledRecord(
                itemID: itemID,
                provider: currentProviderID ?? enabledProviderIDs().first ?? .musicKit
            )
            return .cancelled
        } catch {
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: currentProviderID ?? enabledProviderIDs().first ?? .musicKit,
                    queryFingerprint: Self.itemFingerprint(itemID),
                    status: .failed,
                    lastErrorCode: Self.errorCode(error)
                )
            )
            return .failed
        }
    }

    private func processWithProvider(
        itemID: MediaItemID,
        query: MetadataEnrichmentQuery,
        providerID: MetadataProviderID,
        provider: any MetadataEnrichmentProviding,
        forceRecheck: Bool
    ) async throws -> ItemOutcome {
        let previous = try await recordRepository?.record(
            for: itemID,
            provider: providerID
        )
        let sameQuery = previous?.queryFingerprint == query.fingerprint
        let now = await clock.now()
        if sameQuery, let previous {
            switch previous.status {
            case .matched:
                let artworkStillNeedsRetry = query.missingFields.contains(.artwork)
                    && !previous.updatedFields.contains(.artwork)
                if !artworkStillNeedsRetry {
                    return .skipped
                }
            case .noMatch where !forceRecheck:
                return .noMatch
            case .ambiguous where !forceRecheck:
                return .ambiguous
            default:
                break
            }
        }
        if !forceRecheck,
           sameQuery,
           let nextRetryAt = previous?.nextRetryAt,
           nextRetryAt > now
        {
            return .failed
        }
        if !forceRecheck,
           sameQuery,
           let previous,
           previous.attemptCount >= 3,
           [.failed, .rateLimited].contains(previous.status)
        {
            return .failed
        }

        // A manual scan is an explicit request to retry the current catalog
        // state. Start a fresh retry budget so an outage recorded previously
        // cannot permanently suppress a later successful scan.
        let initialAttempts = sameQuery && !forceRecheck
            ? previous?.attemptCount ?? 0
            : 0
        await saveRecord(
            MetadataEnrichmentRecord(
                itemID: itemID,
                provider: providerID,
                queryFingerprint: query.fingerprint,
                status: .queued,
                attemptCount: initialAttempts
            )
        )

        var candidates: [MetadataEnrichmentCandidate] = []
        var attemptCount = initialAttempts
        var finalError: MetadataEnrichmentError?

        for _ in 0..<3 {
            try Task.checkCancellation()
            attemptCount += 1
            let attemptDate = await clock.now()
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: providerID,
                    queryFingerprint: query.fingerprint,
                    status: .running,
                    attemptCount: attemptCount,
                    lastAttemptAt: attemptDate
                )
            )

            do {
                let searchStartedAt = Date()
                Self.logger.info(
                    "provider search begin item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) attempt=\(attemptCount, privacy: .public)"
                )
                candidates = try await provider.search(query)
                try Task.checkCancellation()
                guard enabled else { throw CancellationError() }
                finalError = nil
                Self.logger.info(
                    "provider search end item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) attempt=\(attemptCount, privacy: .public) candidates=\(candidates.count, privacy: .public) elapsed=\(Date().timeIntervalSince(searchStartedAt), privacy: .public)"
                )
                break
            } catch is CancellationError {
                Self.logger.info(
                    "provider search cancelled item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) attempt=\(attemptCount, privacy: .public)"
                )
                throw CancellationError()
            } catch let error as MetadataEnrichmentError {
                finalError = error
                let delay = Self.retryDelay(for: error, attempt: attemptCount)
                Self.logger.error(
                    "provider search failed item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) attempt=\(attemptCount, privacy: .public) code=\(Self.errorCode(error), privacy: .public) retryDelay=\(delay ?? 0, privacy: .public)"
                )
                guard attemptCount < 3, let delay else { break }
                let retryAt = attemptDate.addingTimeInterval(delay)
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
                        provider: providerID,
                        queryFingerprint: query.fingerprint,
                        status: Self.recordStatus(for: error),
                        attemptCount: attemptCount,
                        lastAttemptAt: attemptDate,
                        nextRetryAt: retryAt,
                        lastErrorCode: Self.errorCode(error),
                        lastHTTPStatus: Self.httpStatus(error)
                    )
                )
                try await clock.sleep(for: .seconds(delay))
            } catch {
                finalError = .requestFailed(code: "provider_failed", httpStatus: nil)
                Self.logger.error(
                    "provider search failed item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) attempt=\(attemptCount, privacy: .public) code=provider_failed"
                )
                break
            }
        }

        if let finalError {
            let completionDate = await clock.now()
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: providerID,
                    queryFingerprint: query.fingerprint,
                    status: Self.recordStatus(for: finalError),
                    attemptCount: attemptCount,
                    lastAttemptAt: completionDate,
                    nextRetryAt: Self.nextRetryDate(
                        for: finalError,
                        from: completionDate
                    ),
                    lastErrorCode: Self.errorCode(finalError),
                    lastHTTPStatus: Self.httpStatus(finalError)
                )
            )
            Self.logger.error(
                "provider finished without match item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) code=\(Self.errorCode(finalError), privacy: .public) attempts=\(attemptCount, privacy: .public)"
            )
            return .failed
        }

        Self.logger.debug(
            "provider matching item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        switch MetadataEnrichmentMatcher.match(query: query, candidates: candidates) {
        case .noMatch:
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: providerID,
                    queryFingerprint: query.fingerprint,
                    candidateCount: candidates.count,
                    status: .noMatch,
                    attemptCount: attemptCount
                )
            )
            Self.logger.info(
                "provider match result item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) result=no_match candidates=\(candidates.count, privacy: .public)"
            )
            return .noMatch
        case .ambiguous:
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: providerID,
                    queryFingerprint: query.fingerprint,
                    candidateCount: candidates.count,
                    status: .ambiguous,
                    attemptCount: attemptCount
                )
            )
            Self.logger.info(
                "provider match result item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) result=ambiguous candidates=\(candidates.count, privacy: .public)"
            )
            return .ambiguous
        case .matched(let matchedCandidate):
            var candidate = matchedCandidate
            var artworkErrorCode: String?
            if query.missingFields.contains(.artwork), candidate.artworkData == nil {
                do {
                    Self.logger.info(
                        "artwork download begin item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) catalog=\(candidate.catalogID, privacy: .public)"
                    )
                    let artworkData = try await provider.artworkData(for: candidate)
                    candidate = Self.replacingArtwork(
                        in: candidate,
                        data: artworkData
                    )
                    if artworkData == nil {
                        artworkErrorCode = "artwork_unavailable"
                    }
                    Self.logger.info(
                        "artwork download end item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) available=\(artworkData != nil, privacy: .public)"
                    )
                } catch is CancellationError {
                    Self.logger.info(
                        "artwork download cancelled item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public)"
                    )
                    throw CancellationError()
                } catch let error {
                    // A cover failure must not discard a valid metadata match,
                    // but it must remain visible in the durable retry record.
                    artworkErrorCode = Self.errorCode(error)
                    Self.logger.error(
                        "artwork download failed item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) code=\(Self.errorCode(error), privacy: .public)"
                    )
                }
            }

            try Task.checkCancellation()
            guard enabled else { throw CancellationError() }

            let supplement = Self.supplement(
                for: query,
                candidate: candidate
            )
            let updatedFields = Self.updatedFields(
                for: query,
                candidate: candidate
            )
            Self.logger.info(
                "library supplement begin item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) fields=\(updatedFields.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)"
            )
            do {
                _ = try await library.supplementMetadata(supplement)
            } catch {
                Self.logger.error(
                    "library supplement failed item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) code=\(Self.errorCode(error), privacy: .public)"
                )
                throw error
            }
            Self.logger.info(
                "library supplement end item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public)"
            )
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    provider: providerID,
                    queryFingerprint: query.fingerprint,
                    catalogID: candidate.catalogID,
                    candidateCount: candidates.count,
                    status: .matched,
                    attemptCount: attemptCount,
                    updatedFields: updatedFields,
                    lastErrorCode: artworkErrorCode
                )
            )
            Self.logger.info(
                "provider match result item=\(itemID.externalID, privacy: .public) provider=\(providerID.rawValue, privacy: .public) result=matched catalog=\(candidate.catalogID, privacy: .public)"
            )
            return .matched
        }
    }

    private func makeQuery(
        for track: Track,
        repository: any LibraryRepository
    ) async throws -> MetadataEnrichmentQuery {
        let artistNames = try await resolvedArtistNames(track.artistIDs, repository: repository)
        let album: Album?
        if let albumID = track.albumID {
            album = try await repository.album(id: albumID)
        } else {
            album = nil
        }
        let albumArtistNames = try await resolvedArtistNames(
            album?.artistIDs ?? [],
            repository: repository
        )
        let genreNames = try await resolvedGenreNames(track.genreIDs, repository: repository)
        let isFilenameFallback = Self.isFilenameFallback(track)
        var missingFields = Set<MetadataEnrichmentField>()
        if isFilenameFallback { missingFields.insert(.title) }
        if artistNames.isEmpty { missingFields.insert(.artist) }
        if albumArtistNames.isEmpty { missingFields.insert(.albumArtist) }
        if album == nil { missingFields.insert(.album) }
        if genreNames.isEmpty { missingFields.insert(.genre) }
        if track.year == nil { missingFields.insert(.year) }
        if track.trackNumber == nil { missingFields.insert(.trackNumber) }
        if track.discNumber == nil { missingFields.insert(.discNumber) }
        if track.artwork == nil { missingFields.insert(.artwork) }

        return MetadataEnrichmentQuery(
            itemID: track.id,
            title: track.title,
            artistName: artistNames.first,
            albumName: album?.title,
            fileName: track.fileName,
            durationSeconds: track.duration.map(Self.durationSeconds),
            missingFields: missingFields,
            isFilenameFallback: isFilenameFallback
        )
    }

    private func resolvedArtistNames(
        _ ids: [ArtistID],
        repository: any LibraryRepository
    ) async throws -> [String] {
        var names: [String] = []
        for id in ids {
            guard let artist = try await repository.artist(id: id) else { continue }
            let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    private func resolvedGenreNames(
        _ ids: [GenreID],
        repository: any LibraryRepository
    ) async throws -> [String] {
        var names: [String] = []
        for id in ids {
            guard let genre = try await repository.genre(id: id) else { continue }
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    private func saveRecord(_ record: MetadataEnrichmentRecord) async {
        do {
            try await recordRepository?.save(record)
        } catch {
            Self.logger.error(
                "record save failed item=\(record.itemID.externalID, privacy: .public) provider=\(record.provider.rawValue, privacy: .public) status=\(record.status.rawValue, privacy: .public) code=\(Self.errorCode(error), privacy: .public)"
            )
        }
    }

    private func saveCancelledRecord(
        itemID: MediaItemID,
        provider: MetadataProviderID
    ) async {
        await saveRecord(
            MetadataEnrichmentRecord(
                itemID: itemID,
                provider: provider,
                queryFingerprint: Self.itemFingerprint(itemID),
                status: .cancelled
            )
        )
    }

    private func cancelRunningWork() async {
        Self.logger.info(
            "cancelling active work scan=\(self.scanTask != nil, privacy: .public) queue=\(self.queueTask != nil, privacy: .public)"
        )
        scanTask?.cancel()
        queueTask?.cancel()
        await scanTask?.value
        await queueTask?.value
        scanTask = nil
        queueTask = nil
        pendingItemIDs.removeAll()
        pendingItemIDSet.removeAll()
        if scan.status == .scanning {
            scan = MetadataEnrichmentScanSnapshot(
                status: .cancelled,
                total: scan.total,
                processed: scan.processed,
                matched: scan.matched,
                noMatch: scan.noMatch,
                ambiguous: scan.ambiguous,
                failed: scan.failed
            )
        }
    }

    private func publish() {
        let value = snapshot()
        Self.logger.debug(
            "snapshot published status=\(value.scan.status.rawValue, privacy: .public) processed=\(value.scan.processed, privacy: .public)/\(value.scan.total, privacy: .public) current=\(value.scan.currentTitle ?? "-", privacy: .public) subscribers=\(self.snapshotContinuations.count, privacy: .public)"
        )
        for continuation in snapshotContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeSnapshotSubscription(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
        Self.logger.debug(
            "snapshot subscriber disconnected id=\(id.uuidString, privacy: .public) subscribers=\(self.snapshotContinuations.count, privacy: .public)"
        )
    }

    private static func isFilenameFallback(_ track: Track) -> Bool {
        guard let fileName = track.fileName else { return false }
        let rawStem = URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
        if equivalent(track.title, rawStem) {
            return true
        }
        if track.title.compare(
            "Untitled",
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) == .orderedSame {
            return true
        }
        let query = MetadataEnrichmentQuery(
            itemID: track.id,
            title: track.title,
            fileName: fileName
        )
        return equivalent(track.title, query.filenameStem)
    }

    private static func equivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let normalize: (String) -> String = {
            $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        }
        return !normalize(lhs).isEmpty && normalize(lhs) == normalize(rhs)
    }

    private static func durationSeconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func itemFingerprint(_ itemID: MediaItemID) -> String {
        MusicContentIdentity.token(
            "\(itemID.sourceID.rawValue)\u{1f}\(itemID.externalID)"
        )
    }

    private static func supplement(
        for query: MetadataEnrichmentQuery,
        candidate: MetadataEnrichmentCandidate
    ) -> TrackMetadataSupplement {
        TrackMetadataSupplement(
            itemID: query.itemID,
            title: query.missingFields.contains(.title) ? candidate.title : nil,
            artistName: query.missingFields.contains(.artist) ? candidate.artistName : nil,
            albumArtistName: query.missingFields.contains(.albumArtist) ? candidate.albumArtistName : nil,
            albumName: query.missingFields.contains(.album) ? candidate.albumName : nil,
            genreName: query.missingFields.contains(.genre) ? candidate.genreName : nil,
            trackNumber: query.missingFields.contains(.trackNumber) ? candidate.trackNumber : nil,
            discNumber: query.missingFields.contains(.discNumber) ? candidate.discNumber : nil,
            year: query.missingFields.contains(.year) ? candidate.year : nil,
            artworkData: query.missingFields.contains(.artwork) ? candidate.artworkData : nil
        )
    }

    private static func updatedFields(
        for query: MetadataEnrichmentQuery,
        candidate: MetadataEnrichmentCandidate
    ) -> Set<MetadataEnrichmentField> {
        var fields = Set<MetadataEnrichmentField>()
        if query.missingFields.contains(.title), !candidate.title.isEmpty { fields.insert(.title) }
        if query.missingFields.contains(.artist), candidate.artistName != nil { fields.insert(.artist) }
        if query.missingFields.contains(.albumArtist), candidate.albumArtistName != nil { fields.insert(.albumArtist) }
        if query.missingFields.contains(.album), candidate.albumName != nil { fields.insert(.album) }
        if query.missingFields.contains(.genre), candidate.genreName != nil { fields.insert(.genre) }
        if query.missingFields.contains(.trackNumber), candidate.trackNumber != nil { fields.insert(.trackNumber) }
        if query.missingFields.contains(.discNumber), candidate.discNumber != nil { fields.insert(.discNumber) }
        if query.missingFields.contains(.year), candidate.year != nil { fields.insert(.year) }
        if query.missingFields.contains(.artwork), candidate.artworkData != nil { fields.insert(.artwork) }
        return fields
    }

    private static func replacingArtwork(
        in candidate: MetadataEnrichmentCandidate,
        data: Data?
    ) -> MetadataEnrichmentCandidate {
        MetadataEnrichmentCandidate(
            catalogID: candidate.catalogID,
            title: candidate.title,
            artistName: candidate.artistName,
            albumArtistName: candidate.albumArtistName,
            albumName: candidate.albumName,
            genreName: candidate.genreName,
            trackNumber: candidate.trackNumber,
            discNumber: candidate.discNumber,
            year: candidate.year,
            durationSeconds: candidate.durationSeconds,
            artworkData: data
        )
    }

    private static func retryDelay(
        for error: MetadataEnrichmentError,
        attempt: Int
    ) -> TimeInterval? {
        switch error {
        case .rateLimited(let retryAfterSeconds, _):
            return min(max(retryAfterSeconds ?? pow(2, Double(attempt)), 1), 60)
        case .requestFailed(_, let httpStatus):
            guard let httpStatus, (500...599).contains(httpStatus) else { return nil }
            return min(pow(2, Double(attempt - 1)), 30)
        case .offline, .unavailable, .notAuthorized:
            return nil
        }
    }

    private static func nextRetryDate(
        for error: MetadataEnrichmentError,
        from date: Date
    ) -> Date? {
        switch error {
        case .rateLimited(let retryAfterSeconds, _):
            return date.addingTimeInterval(min(max(retryAfterSeconds ?? 60, 1), 300))
        default:
            return nil
        }
    }

    private static func recordStatus(
        for error: MetadataEnrichmentError
    ) -> MetadataEnrichmentRecordStatus {
        if case .rateLimited = error { return .rateLimited }
        if case .notAuthorized = error { return .failed }
        return .failed
    }

    private static func httpStatus(_ error: Error) -> Int? {
        guard let error = error as? MetadataEnrichmentError else { return nil }
        switch error {
        case .rateLimited(_, let status), .requestFailed(_, let status): return status
        case .unavailable, .notAuthorized, .offline: return nil
        }
    }

    private static func itemOutcomeCode(_ outcome: ItemOutcome) -> String {
        switch outcome {
        case .matched: return "matched"
        case .noMatch: return "no_match"
        case .ambiguous: return "ambiguous"
        case .failed: return "failed"
        case .skipped: return "skipped"
        case .cancelled: return "cancelled"
        }
    }

    private static func errorCode(_ error: Error) -> String {
        if let error = error as? MetadataEnrichmentError {
            switch error {
            case .unavailable: return "unavailable"
            case .notAuthorized: return "not_authorized"
            case .offline: return "offline"
            case .rateLimited: return "rate_limited"
            case .requestFailed(let code, _): return code
            }
        }
        if error is CancellationError { return "cancelled" }
        return "enrichment_failed"
    }
}

private actor MetadataEnrichmentOperationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var active = false
    private var waiters: [Waiter] = []

    func enter() async -> Bool {
        guard !Task.isCancelled else { return false }
        if !active {
            active = true
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
            active = false
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}
