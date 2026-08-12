import Foundation
import MusicDomain

/// How an importer handles an input whose content is already present.
///
/// The first local importer implements `skip` and `report`. Replacement and
/// duplicate-copy behavior stays out of this request until the library model
/// can represent those operations without breaking content-addressed IDs.
public enum MediaImportDuplicatePolicy: String, Codable, Sendable {
  case skip
  case report
}

/// A transient request created by the application import use case.
public struct MediaImportRequest: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let importID: UUID
  public let urls: [URL]
  public let duplicatePolicy: MediaImportDuplicatePolicy

  public init(
    importID: UUID,
    urls: [URL],
    duplicatePolicy: MediaImportDuplicatePolicy = .skip
  ) {
    self.importID = importID
    self.urls = urls
    self.duplicatePolicy = duplicatePolicy
  }

  public init(
    id: UUID,
    urls: [URL],
    duplicatePolicy: MediaImportDuplicatePolicy = .skip
  ) {
    self.init(importID: id, urls: urls, duplicatePolicy: duplicatePolicy)
  }

  public var id: UUID {
    importID
  }

  public var sourceURLs: [URL] {
    urls
  }

  public var description: String {
    "MediaImportRequest(id: \(importID.uuidString), inputCount: \(urls.count))"
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

/// The terminal state of a batch import stream.
public enum MediaImportCompletionStatus: String, Codable, Sendable {
  case completed
  case cancelled
}

/// A stable summary emitted by the terminal import event.
public struct MediaImportResult: Codable, Equatable, Sendable {
  public let importID: UUID
  public let imported: Int
  public let duplicate: Int
  public let skipped: Int
  public let failed: Int
  public let cancelled: Int
  public let status: MediaImportCompletionStatus

  public init(
    importID: UUID,
    imported: Int,
    duplicate: Int,
    skipped: Int,
    failed: Int,
    cancelled: Int,
    status: MediaImportCompletionStatus = .completed
  ) {
    self.importID = importID
    self.imported = max(0, imported)
    self.duplicate = max(0, duplicate)
    self.skipped = max(0, skipped)
    self.failed = max(0, failed)
    self.cancelled = max(0, cancelled)
    self.status = status
  }

  public init(
    importID: UUID,
    imported: Int,
    duplicates: Int,
    skipped: Int,
    failed: Int,
    cancelled: Int,
    status: MediaImportCompletionStatus = .completed
  ) {
    self.init(
      importID: importID,
      imported: imported,
      duplicate: duplicates,
      skipped: skipped,
      failed: failed,
      cancelled: cancelled,
      status: status
    )
  }

  public var duplicates: Int {
    duplicate
  }

  public var totalItems: Int {
    imported + duplicate + skipped + failed + cancelled
  }

  public var isCancelled: Bool {
    status == .cancelled
  }
}

/// The non-terminal phases an importer may report for each input.
public enum MediaImportPhase: String, Codable, Sendable {
  case discovered
  case hashing
  case probing
  case copying
  case persisting
}

/// Progress and terminal events for one import request.
public enum MediaImportEvent: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case discovered(importID: UUID, url: URL)
  case hashing(importID: UUID, url: URL)
  case probing(importID: UUID, url: URL)
  case copying(importID: UUID, url: URL)
  case persisting(importID: UUID, itemID: MediaItemID)
  case itemFailed(importID: UUID, url: URL, error: MediaImportError)
  case completed(importID: UUID, result: MediaImportResult)
  case cancelled(importID: UUID, result: MediaImportResult)

  public var importID: UUID {
    switch self {
    case .discovered(let importID, _),
      .hashing(let importID, _),
      .probing(let importID, _),
      .copying(let importID, _),
      .persisting(let importID, _),
      .itemFailed(let importID, _, _),
      .completed(let importID, _),
      .cancelled(let importID, _):
      return importID
    }
  }

  public var isTerminal: Bool {
    switch self {
    case .completed, .cancelled:
      return true
    case .discovered, .hashing, .probing, .copying, .persisting, .itemFailed:
      return false
    }
  }

  public var description: String {
    switch self {
    case .discovered(let importID, _):
      return "MediaImportEvent.discovered(\(importID.uuidString))"
    case .hashing(let importID, _):
      return "MediaImportEvent.hashing(\(importID.uuidString))"
    case .probing(let importID, _):
      return "MediaImportEvent.probing(\(importID.uuidString))"
    case .copying(let importID, _):
      return "MediaImportEvent.copying(\(importID.uuidString))"
    case .persisting(let importID, _):
      return "MediaImportEvent.persisting(\(importID.uuidString))"
    case .itemFailed(let importID, _, let error):
      return "MediaImportEvent.itemFailed(\(importID.uuidString), \(error.diagnosticCode))"
    case .completed(let importID, let result):
      return "MediaImportEvent.completed(\(importID.uuidString), total: \(result.totalItems))"
    case .cancelled(let importID, let result):
      return "MediaImportEvent.cancelled(\(importID.uuidString), total: \(result.totalItems))"
    }
  }

  public var debugDescription: String {
    description
  }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

/// Starts a batch import and exposes progress through a cancellable stream.
public protocol MediaImporting: Sendable {
  /// A normal cancellation emits one cancelled result and then finishes
  /// without throwing. A consumer that stops iterating must still cause the
  /// adapter to release its continuation through onTermination.
  func importMedia(_ request: MediaImportRequest)
    -> AsyncThrowingStream<MediaImportEvent, Error>

  /// Cancellation is idempotent. Unknown or already terminal IDs are
  /// ignored, while an active stream must receive a cancelled terminal event.
  func cancelImport(_ importID: UUID) async
}
