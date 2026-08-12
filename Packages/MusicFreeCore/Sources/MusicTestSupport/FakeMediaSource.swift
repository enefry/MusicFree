import Foundation
import MediaSourceAPI
import MusicDomain

public enum FakeMediaSourceResolveResult: Sendable {
    case resource(PlaybackResource)
    case failure(MediaSourceError)
}

public enum FakeMediaSourceArtworkResult: Sendable {
    case resource(ArtworkResource)
    case missing
    case failure(MediaSourceError)
}

public enum FakeMediaSourceOperation: Hashable, Sendable {
    case resolve
    case artwork
    case changes
    case sourceLookup
}

/// A lock-backed source fake. It supports both the base source contract and
/// incremental changes, while making every operation observable and
/// unconfigured item resolution an explicit failure.
public final class FakeMediaSource: MediaSourceChangesProviding, MediaSourceResolving,
    @unchecked Sendable
{
    public let descriptor: MediaSourceDescriptor
    public let capabilities: MediaSourceCapabilities

    private let lock = NSLock()
    private var resolveResults: [MediaItemID: FakeMediaSourceResolveResult]
    private var artworkResults: [ArtworkID: FakeMediaSourceArtworkResult]
    private var changeScript: [MediaSourceChange]
    private var changeError: MediaSourceError?
    private var autoFinishChanges: Bool
    private var delays: [FakeMediaSourceOperation: Duration]
    private var changeContinuations: [UUID: AsyncThrowingStream<MediaSourceChange, Error>.Continuation] = [:]

    private var resolveCallLog: [MediaItemID] = []
    private var artworkCallLog: [ArtworkID] = []
    private var changeCursorLog: [MediaSourceCursor?] = []
    private var sourceLookupLog: [MediaSourceID] = []

    public init(
        descriptor: MediaSourceDescriptor = FixtureFactory.sourceDescriptor(),
        capabilities: MediaSourceCapabilities = .all,
        resolveResults: [MediaItemID: FakeMediaSourceResolveResult] = [:],
        artworkResults: [ArtworkID: FakeMediaSourceArtworkResult] = [:],
        changeScript: [MediaSourceChange] = [],
        changeError: MediaSourceError? = nil,
        autoFinishChanges: Bool = true,
        delays: [FakeMediaSourceOperation: Duration] = [:]
    ) {
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.resolveResults = resolveResults
        self.artworkResults = artworkResults
        self.changeScript = changeScript
        self.changeError = changeError
        self.autoFinishChanges = autoFinishChanges
        self.delays = delays
    }

    public func resolve(_ itemID: MediaItemID) async throws -> PlaybackResource {
        let result = withLock { () -> FakeMediaSourceResolveResult in
            resolveCallLog.append(itemID)
            return resolveResults[itemID]
                ?? .failure(.sourceNotFound(itemID.sourceID))
        }
        try await wait(for: .resolve)
        try Task.checkCancellation()
        switch result {
        case .resource(let resource):
            return resource
        case .failure(let error):
            throw error
        }
    }

    public func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? {
        let result = withLock { () -> FakeMediaSourceArtworkResult in
            artworkCallLog.append(artworkID)
            return artworkResults[artworkID]
                ?? .failure(.unsupportedCapability("artwork"))
        }
        try await wait(for: .artwork)
        try Task.checkCancellation()
        switch result {
        case .resource(let resource):
            return resource
        case .missing:
            return nil
        case .failure(let error):
            throw error
        }
    }

    public func source(for sourceID: MediaSourceID) async throws -> any MediaSource {
        let matches = withLock { () -> Bool in
            sourceLookupLog.append(sourceID)
            return sourceID == descriptor.sourceID
        }
        try await wait(for: .sourceLookup)
        try Task.checkCancellation()
        guard matches else {
            throw MediaSourceError.sourceNotFound(sourceID)
        }
        return self
    }

    public func changes(since cursor: MediaSourceCursor?)
        -> AsyncThrowingStream<MediaSourceChange, Error>
    {
        let subscriptionID = UUID()
        let script = withLock { () -> ([MediaSourceChange], MediaSourceError?, Bool) in
            changeCursorLog.append(cursor)
            return (changeScript, changeError, autoFinishChanges)
        }

        return AsyncThrowingStream { continuation in
            let shouldFinish = self.withLock {
                changeContinuations[subscriptionID] = continuation
                return false
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeChangeSubscription(subscriptionID)
            }
            if shouldFinish {
                continuation.finish()
                return
            }

            for change in script.0 {
                continuation.yield(change)
            }
            if let error = script.1 {
                continuation.finish(throwing: error)
            } else if script.2 {
                continuation.finish()
            }
        }
    }

    public func setResolveResult(
        _ result: FakeMediaSourceResolveResult,
        for itemID: MediaItemID
    ) {
        withLock { resolveResults[itemID] = result }
    }

    public func setArtworkResult(
        _ result: FakeMediaSourceArtworkResult,
        for artworkID: ArtworkID
    ) {
        withLock { artworkResults[artworkID] = result }
    }

    public func setChangeScript(
        _ changes: [MediaSourceChange],
        error: MediaSourceError? = nil,
        autoFinish: Bool = true
    ) {
        withLock {
            changeScript = changes
            changeError = error
            autoFinishChanges = autoFinish
        }
    }

    public func emitChange(_ change: MediaSourceChange) {
        let active = withLock { Array(changeContinuations.values) }
        for continuation in active {
            continuation.yield(change)
        }
    }

    public func finishChanges() {
        let active = withLock { () -> [AsyncThrowingStream<MediaSourceChange, Error>.Continuation] in
            let result = Array(changeContinuations.values)
            changeContinuations.removeAll()
            return result
        }
        for continuation in active {
            continuation.finish()
        }
    }

    public func setDelay(_ delay: Duration, for operation: FakeMediaSourceOperation) {
        withLock { delays[operation] = delay }
    }

    public var resolveCalls: [MediaItemID] {
        withLock { resolveCallLog }
    }

    public var artworkCalls: [ArtworkID] {
        withLock { artworkCallLog }
    }

    public var changeCursors: [MediaSourceCursor?] {
        withLock { changeCursorLog }
    }

    public var sourceLookupCalls: [MediaSourceID] {
        withLock { sourceLookupLog }
    }

    public var activeChangeSubscriptionCount: Int {
        withLock { changeContinuations.count }
    }

    public func resetCallHistory() {
        withLock {
            resolveCallLog.removeAll()
            artworkCallLog.removeAll()
            changeCursorLog.removeAll()
            sourceLookupLog.removeAll()
        }
    }

    private func wait(for operation: FakeMediaSourceOperation) async throws {
        let delay = withLock { delays[operation] ?? .zero }
        guard delay > .zero else { return }
        do {
            try await Task.sleep(for: delay)
        } catch {
            throw MediaSourceError.cancelled
        }
    }

    private func removeChangeSubscription(_ subscriptionID: UUID) {
        _ = withLock { changeContinuations.removeValue(forKey: subscriptionID) }
    }

    private func withLock<Result>(_ operation: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
