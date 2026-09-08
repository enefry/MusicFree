import DesignSystem
import Foundation
import MediaSourceAPI

public enum LibraryImportProgressPhase: String, Equatable, Sendable {
    case discovered
    case hashing
    case probing
    case copying
    case persisting

    public init(_ phase: MediaImportPhase) {
        switch phase {
        case .discovered: self = .discovered
        case .hashing: self = .hashing
        case .probing: self = .probing
        case .copying: self = .copying
        case .persisting: self = .persisting
        }
    }

    public var title: String {
        switch self {
        case .discovered: return L("已发现")
        case .hashing: return L("正在检查")
        case .probing: return L("正在解析")
        case .copying: return L("正在复制")
        case .persisting: return L("正在保存")
        }
    }
}

public struct LibraryImportFailure: Equatable, Sendable {
    public let itemName: String
    public let code: String
    public let message: String

    public init(itemName: String, code: String, message: String) {
        self.itemName = itemName
        self.code = code
        self.message = message
    }
}

public struct ImportProgressSnapshot: Equatable, Sendable {
    public let importID: UUID
    public let totalItems: Int
    public var processedItems: Int
    public var failedItems: Int
    public var phase: LibraryImportProgressPhase?
    public var currentItemName: String?
    public var failures: [LibraryImportFailure]
    public var result: MediaImportResult?

    public init(importID: UUID, totalItems: Int) {
        self.importID = importID
        self.totalItems = max(0, totalItems)
        self.processedItems = 0
        self.failedItems = 0
        self.phase = nil
        self.currentItemName = nil
        self.failures = []
        self.result = nil
    }
}

public enum LibraryImportState: Equatable, Sendable {
    case idle
    case importing(ImportProgressSnapshot)
    case awaitingConfirmation(ImportProgressSnapshot)
    case cancelling(ImportProgressSnapshot)
    case completed(MediaImportResult)
    case failed(String)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    public var progress: ImportProgressSnapshot? {
        switch self {
        case .importing(let progress), .awaitingConfirmation(let progress), .cancelling(let progress):
            return progress
        case .idle, .completed, .failed: return nil
        }
    }

    public var confirmationProgress: ImportProgressSnapshot? {
        guard case .awaitingConfirmation(let progress) = self else { return nil }
        return progress
    }
}

/// Converts API import events into presentation-safe state without retaining URLs.
public enum ImportEventMapper {
    public static func initialSnapshot(for request: MediaImportRequest) -> ImportProgressSnapshot {
        ImportProgressSnapshot(importID: request.importID, totalItems: request.urls.count)
    }

    public static func apply(
        _ event: MediaImportEvent,
        to snapshot: ImportProgressSnapshot
    ) -> ImportProgressSnapshot {
        guard event.importID == snapshot.importID else { return snapshot }

        var next = snapshot
        switch event {
        case .discovered(_, let url):
            next.phase = .discovered
            next.currentItemName = displayName(for: url)
        case .hashing(_, let url):
            next.phase = .hashing
            next.currentItemName = displayName(for: url)
        case .probing(_, let url):
            next.phase = .probing
            next.currentItemName = displayName(for: url)
        case .copying(_, let url):
            next.phase = .copying
            next.currentItemName = displayName(for: url)
        case .persisting:
            next.phase = .persisting
            next.currentItemName = nil
            next.processedItems = min(next.totalItems, next.processedItems + 1)
        case .itemFailed(_, let url, let error):
            next.currentItemName = nil
            next.failedItems += 1
            next.processedItems = min(next.totalItems, max(next.processedItems + 1, next.failedItems))
            next.failures.append(
                LibraryImportFailure(
                    itemName: displayName(for: url),
                    code: error.diagnosticCode,
                    message: error.userFacingReason
                )
            )
        case .confirmationRequired:
            next.phase = nil
            next.currentItemName = nil
        case .completed(_, let result), .cancelled(_, let result):
            next.phase = nil
            next.currentItemName = nil
            next.processedItems = min(next.totalItems, result.totalItems)
            next.failedItems = result.failed
            next.result = result
        }
        return next
    }

    private static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? L("未命名媒体") : name
    }
}
