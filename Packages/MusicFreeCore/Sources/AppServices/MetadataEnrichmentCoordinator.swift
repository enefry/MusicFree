import Foundation
import LibraryAPI
import MusicDomain
import SettingsAPI

/// AppServices owns the enrichment queue so imports and settings do not keep
/// network tasks in a view. A single serialized catalog operation keeps token
/// usage predictable and still satisfies the provider concurrency limit.
internal actor MetadataEnrichmentCoordinator: MetadataEnrichmentServing {
    private enum ItemOutcome {
        case matched
        case noMatch
        case ambiguous
        case failed
        case skipped
        case cancelled
    }

    private let provider: (any MetadataEnrichmentProviding)?
    private let recordRepository: (any MetadataEnrichmentRecordRepository)?
    private let libraryRepository: (any LibraryRepository)?
    private let library: any LibraryServing
    private let clock: any AppClock
    private let operationGate = MetadataEnrichmentOperationGate()

    private var enabled = false
    private var authorization: MetadataEnrichmentAuthorizationStatus
    private var scan = MetadataEnrichmentScanSnapshot()
    private var snapshotContinuations: [UUID: AsyncStream<MetadataEnrichmentSnapshot>.Continuation] = [:]
    private var pendingItemIDs: [MediaItemID] = []
    private var pendingItemIDSet: Set<MediaItemID> = []
    private var queueTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    init(
        provider: (any MetadataEnrichmentProviding)?,
        recordRepository: (any MetadataEnrichmentRecordRepository)?,
        libraryRepository: (any LibraryRepository)?,
        library: any LibraryServing,
        clock: any AppClock
    ) {
        self.provider = provider
        self.recordRepository = recordRepository
        self.libraryRepository = libraryRepository
        self.library = library
        self.clock = clock
        self.authorization = .unavailable
    }

    func snapshot() -> MetadataEnrichmentSnapshot {
        MetadataEnrichmentSnapshot(
            isEnabled: enabled,
            authorization: authorization,
            scan: scan
        )
    }

    func makeSnapshotStream() -> AsyncStream<MetadataEnrichmentSnapshot> {
        let subscriptionID = UUID()
        let (stream, continuation) = AsyncStream<MetadataEnrichmentSnapshot>.makeStream()
        snapshotContinuations[subscriptionID] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSnapshotSubscription(subscriptionID) }
        }
        return stream
    }

    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        guard let provider else {
            authorization = .unavailable
            publish()
            return authorization
        }
        authorization = await provider.requestAuthorization()
        publish()
        return authorization
    }

    func setEnabled(_ requestedValue: Bool) async {
        guard requestedValue else {
            enabled = false
            await cancelRunningWork()
            if let provider {
                authorization = await provider.authorizationStatus()
            } else {
                authorization = .unavailable
            }
            publish()
            return
        }

        guard let provider else {
            enabled = false
            authorization = .unavailable
            publish()
            return
        }

        authorization = await provider.authorizationStatus()
        guard authorization == .authorized else {
            enabled = false
            publish()
            return
        }

        enabled = true
        publish()
        startQueueWorkerIfNeeded()
    }

    func enqueue(itemID: MediaItemID) {
        guard enabled, provider != nil, libraryRepository != nil else { return }
        guard pendingItemIDSet.insert(itemID).inserted else { return }
        pendingItemIDs.append(itemID)
        startQueueWorkerIfNeeded()
    }

    func startScan() {
        guard enabled, provider != nil, libraryRepository != nil else {
            scan = MetadataEnrichmentScanSnapshot(
                status: .failed,
                errorCode: "metadata_enrichment_unavailable"
            )
            publish()
            return
        }
        guard scanTask == nil else { return }

        scan = MetadataEnrichmentScanSnapshot(status: .scanning)
        publish()
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.performScan()
        }
        scanTask = task
    }

    func cancelScan() async {
        scanTask?.cancel()
        await scanTask?.value
    }

    private func performScan() async {
        do {
            guard let repository = libraryRepository else {
                throw MetadataEnrichmentError.unavailable
            }
            var request = try LibraryPageRequest(limit: LibraryPageRequest.maximumLimit)
            var tracks: [Track] = []

            while true {
                try Task.checkCancellation()
                let page = try await repository.tracks(
                    matching: TrackQuery(sourceID: .local),
                    page: request
                )
                tracks.append(contentsOf: page.elements)
                guard let nextPage = try page.nextPage(
                    limit: LibraryPageRequest.maximumLimit
                ) else {
                    break
                }
                request = nextPage
            }

            scan = MetadataEnrichmentScanSnapshot(
                status: .scanning,
                total: tracks.count
            )
            publish()

            for track in tracks {
                try Task.checkCancellation()
                guard enabled else { throw CancellationError() }
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
        guard enabled,
              let provider,
              let repository = libraryRepository
        else {
            return .cancelled
        }

        do {
            guard let track = try await repository.track(id: itemID) else {
                return .skipped
            }
            let query = try await makeQuery(for: track, repository: repository)
            guard let searchTerm = query.searchTerm, !searchTerm.isEmpty else {
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
                        queryFingerprint: query.fingerprint,
                        candidateCount: 0,
                        status: .noMatch
                    )
                )
                return .noMatch
            }
            guard !query.missingFields.isEmpty else {
                return .skipped
            }

            let previous = try await recordRepository?.record(for: itemID)
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
                case .noMatch, .ambiguous:
                    if !forceRecheck {
                        return .skipped
                    }
                default:
                    break
                }
            }
            if sameQuery,
               let nextRetryAt = previous?.nextRetryAt,
               nextRetryAt > now
            {
                return .skipped
            }
            if sameQuery,
               let previous,
               previous.attemptCount >= 3,
               [.failed, .rateLimited].contains(previous.status)
            {
                return .skipped
            }

            let initialAttempts = sameQuery ? previous?.attemptCount ?? 0 : 0
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
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
                        queryFingerprint: query.fingerprint,
                        status: .running,
                        attemptCount: attemptCount,
                        lastAttemptAt: attemptDate
                    )
                )

                do {
                    candidates = try await provider.search(query)
                    try Task.checkCancellation()
                    guard enabled else { throw CancellationError() }
                    finalError = nil
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as MetadataEnrichmentError {
                    finalError = error
                    let delay = Self.retryDelay(for: error, attempt: attemptCount)
                    guard attemptCount < 3, let delay else { break }
                    let retryAt = attemptDate.addingTimeInterval(delay)
                    await saveRecord(
                        MetadataEnrichmentRecord(
                            itemID: itemID,
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
                    break
                }
            }

            if let finalError {
                let completionDate = await clock.now()
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
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
                return .failed
            }

            switch MetadataEnrichmentMatcher.match(query: query, candidates: candidates) {
            case .noMatch:
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
                        queryFingerprint: query.fingerprint,
                        candidateCount: candidates.count,
                        status: .noMatch,
                        attemptCount: attemptCount
                    )
                )
                return .noMatch
            case .ambiguous:
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
                        queryFingerprint: query.fingerprint,
                        candidateCount: candidates.count,
                        status: .ambiguous,
                        attemptCount: attemptCount
                    )
                )
                return .ambiguous
            case .matched(let matchedCandidate):
                var candidate = matchedCandidate
                var artworkErrorCode: String?
                if query.missingFields.contains(.artwork), candidate.artworkData == nil {
                    do {
                        let artworkData = try await provider.artworkData(for: candidate)
                        candidate = Self.replacingArtwork(
                            in: candidate,
                            data: artworkData
                        )
                        if artworkData == nil {
                            artworkErrorCode = "artwork_unavailable"
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error {
                        // A cover failure must not discard a valid metadata match,
                        // but it must remain visible in the durable retry record.
                        artworkErrorCode = Self.errorCode(error)
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
                _ = try await library.supplementMetadata(supplement)
                await saveRecord(
                    MetadataEnrichmentRecord(
                        itemID: itemID,
                        queryFingerprint: query.fingerprint,
                        catalogID: candidate.catalogID,
                        candidateCount: candidates.count,
                        status: .matched,
                        attemptCount: attemptCount,
                        updatedFields: updatedFields,
                        lastErrorCode: artworkErrorCode
                    )
                )
                return .matched
            }
        } catch is CancellationError {
            await saveCancelledRecord(itemID: itemID)
            return .cancelled
        } catch {
            await saveRecord(
                MetadataEnrichmentRecord(
                    itemID: itemID,
                    queryFingerprint: Self.itemFingerprint(itemID),
                    status: .failed,
                    lastErrorCode: Self.errorCode(error)
                )
            )
            return .failed
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
        try? await recordRepository?.save(record)
    }

    private func saveCancelledRecord(itemID: MediaItemID) async {
        await saveRecord(
            MetadataEnrichmentRecord(
                itemID: itemID,
                queryFingerprint: Self.itemFingerprint(itemID),
                status: .cancelled
            )
        )
    }

    private func cancelRunningWork() async {
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
        for continuation in snapshotContinuations.values {
            continuation.yield(value)
        }
    }

    private func removeSnapshotSubscription(_ id: UUID) {
        snapshotContinuations.removeValue(forKey: id)
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
