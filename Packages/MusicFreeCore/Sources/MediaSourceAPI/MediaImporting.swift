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

/// Optional source-owned metadata used only when the downloaded media does
/// not contain the same embedded field. The hint is transient application
/// input: it is normalized into the local library model and is never retained
/// as an online-source URL, credential, or session value.
public struct MediaImportMetadataHint: Codable, Equatable, Sendable {
  public let displayName: String?
  public let title: String?
  public let artist: String?
  public let album: String?
  public let duration: Duration?

  public init(
    displayName: String? = nil,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    duration: Duration? = nil
  ) {
    self.displayName = Self.normalized(displayName)
    self.title = Self.normalized(title)
    self.artist = Self.normalized(artist)
    self.album = Self.normalized(album)
    self.duration = duration.flatMap { $0 >= .zero ? $0 : nil }
  }

  private enum CodingKeys: String, CodingKey {
    case displayName
    case title
    case artist
    case album
    case duration
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
    guard duration == nil || duration! >= .zero else {
      throw mediaImportDecodingFailure(decoder, field: "MediaImportMetadataHint.duration")
    }
    self.init(
      displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
      title: try container.decodeIfPresent(String.self, forKey: .title),
      artist: try container.decodeIfPresent(String.self, forKey: .artist),
      album: try container.decodeIfPresent(String.self, forKey: .album),
      duration: duration
    )
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = MetadataTextRepair.repair(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

private func mediaImportDecodingFailure(_ decoder: Decoder, field: String) -> DecodingError {
  DecodingError.dataCorrupted(
    .init(
      codingPath: decoder.codingPath,
      debugDescription: "Invalid MediaSourceAPI value for \(field)"
    )
  )
}

/// A transient request created by the application import use case.
public struct MediaImportRequest: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let importID: UUID
  public let urls: [URL]
  public let duplicatePolicy: MediaImportDuplicatePolicy
  /// Per-input fallback metadata. Keys are standardized local file URLs and
  /// values are consulted only when embedded metadata omits a field.
  public let metadataHints: [URL: MediaImportMetadataHint]
  /// When true, an interactive folder import may pause after preflight
  /// failures and wait for the user to approve importing the remaining files.
  /// Background scans leave this disabled so they never wait on UI.
  public let allowsFolderFailureConfirmation: Bool

  public init(
    importID: UUID,
    urls: [URL],
    duplicatePolicy: MediaImportDuplicatePolicy = .skip,
    metadataHints: [URL: MediaImportMetadataHint] = [:],
    allowsFolderFailureConfirmation: Bool = false
  ) {
    self.importID = importID
    self.urls = urls
    self.duplicatePolicy = duplicatePolicy
    self.metadataHints = metadataHints.reduce(into: [:]) { result, entry in
      result[entry.key.standardizedFileURL] = entry.value
    }
    self.allowsFolderFailureConfirmation = allowsFolderFailureConfirmation
  }

  public init(
    id: UUID,
    urls: [URL],
    duplicatePolicy: MediaImportDuplicatePolicy = .skip,
    metadataHints: [URL: MediaImportMetadataHint] = [:],
    allowsFolderFailureConfirmation: Bool = false
  ) {
    self.init(
      importID: id,
      urls: urls,
      duplicatePolicy: duplicatePolicy,
      metadataHints: metadataHints,
      allowsFolderFailureConfirmation: allowsFolderFailureConfirmation
    )
  }

  public var id: UUID {
    importID
  }

  public var sourceURLs: [URL] {
    urls
  }

  public func metadataHint(for url: URL) -> MediaImportMetadataHint? {
    metadataHints[url.standardizedFileURL]
  }

  public var description: String {
    "MediaImportRequest(id: \(importID.uuidString), inputCount: \(urls.count), metadataHintCount: \(metadataHints.count))"
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
  case confirmationRequired(importID: UUID)
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
      .confirmationRequired(let importID),
      .completed(let importID, _),
      .cancelled(let importID, _):
      return importID
    }
  }

  public var isTerminal: Bool {
    switch self {
    case .completed, .cancelled:
      return true
    case .discovered, .hashing, .probing, .copying, .persisting, .itemFailed,
      .confirmationRequired:
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
    case .confirmationRequired(let importID):
      return "MediaImportEvent.confirmationRequired(\(importID.uuidString))"
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

  /// Resumes a folder import paused after preflight failures.
  func continueImport(_ importID: UUID) async

  /// Cancellation is idempotent. Unknown or already terminal IDs are
  /// ignored, while an active stream must receive a cancelled terminal event.
  func cancelImport(_ importID: UUID) async
}

public extension MediaImporting {
  func continueImport(_ importID: UUID) async {
    _ = importID
  }
}
