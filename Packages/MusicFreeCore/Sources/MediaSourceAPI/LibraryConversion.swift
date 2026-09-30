import Foundation
import MusicDomain

public enum LibraryConversionScope: Codable, Equatable, Sendable {
    case allLocalMedia
    case items(Set<MediaItemID>)
}

public enum LibraryConversionSkipReason: String, Codable, Equatable, Sendable {
    case nonLocal
    case missingResource
    case lossySource
    case alreadyTargetFormat
    case unsupportedAudio
    case alreadyInProgress
}

public struct LibraryConversionCandidate: Codable, Equatable, Identifiable, Sendable {
    public let assetID: MediaAssetID
    public let itemIDs: Set<MediaItemID>
    public let sourceByteCount: Int64?
    public let estimatedOutputByteCount: Int64?
    public let skipReason: LibraryConversionSkipReason?

    public init(
        assetID: MediaAssetID,
        itemIDs: Set<MediaItemID>,
        sourceByteCount: Int64? = nil,
        estimatedOutputByteCount: Int64? = nil,
        skipReason: LibraryConversionSkipReason? = nil
    ) {
        self.assetID = assetID
        self.itemIDs = itemIDs
        self.sourceByteCount = sourceByteCount
        self.estimatedOutputByteCount = estimatedOutputByteCount
        self.skipReason = skipReason
    }

    public var id: MediaAssetID { assetID }
    public var isEligible: Bool { skipReason == nil }
}

public struct LibraryConversionPreflight: Codable, Equatable, Sendable {
    public let scope: LibraryConversionScope
    public let target: AudioConversionTarget
    public let candidates: [LibraryConversionCandidate]

    public init(
        scope: LibraryConversionScope,
        target: AudioConversionTarget,
        candidates: [LibraryConversionCandidate]
    ) {
        self.scope = scope
        self.target = target
        self.candidates = candidates
    }

    public var eligibleAssetCount: Int { candidates.count(where: \.isEligible) }
    public var eligibleItemCount: Int {
        candidates.filter(\.isEligible).reduce(0) { $0 + $1.itemIDs.count }
    }
    public var skippedAssetCount: Int { candidates.count - eligibleAssetCount }
    public var sourceByteCount: Int64 {
        candidates.filter(\.isEligible).compactMap(\.sourceByteCount).reduce(0, +)
    }
    public var estimatedOutputByteCount: Int64? {
        let eligible = candidates.filter(\.isEligible)
        let values = eligible.compactMap(\.estimatedOutputByteCount)
        return values.count == eligible.count ? values.reduce(0, +) : nil
    }
}

public enum LibraryConversionBatchState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case paused
    case cancelling
    case completed
    case cancelled
}

public struct LibraryConversionFailure: Codable, Equatable, Identifiable, Sendable {
    public let assetID: MediaAssetID
    public let code: String

    public init(assetID: MediaAssetID, code: String) {
        self.assetID = assetID
        self.code = code
    }

    public var id: MediaAssetID { assetID }
}

public struct LibraryConversionBatchSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scope: LibraryConversionScope
    public let target: AudioConversionTarget
    public let state: LibraryConversionBatchState
    public let totalAssetCount: Int
    public let completedAssetCount: Int
    public let skippedAssetCount: Int
    public let cancelledAssetCount: Int
    public let failures: [LibraryConversionFailure]
    public let currentProgress: [MediaAssetID: MediaTranscodeProgress]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        scope: LibraryConversionScope,
        target: AudioConversionTarget,
        state: LibraryConversionBatchState,
        totalAssetCount: Int,
        completedAssetCount: Int = 0,
        skippedAssetCount: Int = 0,
        cancelledAssetCount: Int = 0,
        failures: [LibraryConversionFailure] = [],
        currentProgress: [MediaAssetID: MediaTranscodeProgress] = [:],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.target = target
        self.state = state
        self.totalAssetCount = max(0, totalAssetCount)
        self.completedAssetCount = max(0, completedAssetCount)
        self.skippedAssetCount = max(0, skippedAssetCount)
        self.cancelledAssetCount = max(0, cancelledAssetCount)
        self.failures = failures
        self.currentProgress = currentProgress
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var failedAssetCount: Int { failures.count }
    public var processedAssetCount: Int {
        completedAssetCount + skippedAssetCount + cancelledAssetCount + failedAssetCount
    }
}

public enum LibraryConversionEvent: Sendable {
    case updated(LibraryConversionBatchSnapshot)
}

/// Adapter boundary for durable conversion of resources already in the local library.
public protocol ManagedLibraryConverting: Sendable {
    func preflight(
        scope: LibraryConversionScope,
        target: AudioConversionTarget
    ) async throws -> LibraryConversionPreflight
    func start(
        scope: LibraryConversionScope,
        target: AudioConversionTarget
    ) async throws -> UUID
    func snapshots() async -> [LibraryConversionBatchSnapshot]
    func snapshot(id: UUID) async -> LibraryConversionBatchSnapshot?
    func pause(id: UUID) async
    func resume(id: UUID) async
    func cancel(id: UUID) async
    func retryFailures(id: UUID) async throws -> UUID
    func recover() async
    func makeEventStream() async -> AsyncStream<LibraryConversionEvent>
}
