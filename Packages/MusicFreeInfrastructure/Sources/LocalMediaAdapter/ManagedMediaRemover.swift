import Foundation
import MediaSourceAPI
import MusicDomain

/// Performs recoverable deletion of files owned by the built-in local source.
@available(macOS 13.0, iOS 16.0, *)
public final class ManagedMediaRemover: ManagedMediaRemoving, @unchecked Sendable {
  private let store: ManagedMediaStore

  public init(configuration: LocalMediaConfiguration) throws {
    self.store = try ManagedMediaStore(configuration: configuration)
  }

  public func pendingRemovals() async throws -> [MediaRemovalTransaction] {
    do {
      return try await store.pendingRemovals()
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func prepareRemoval(
    of itemIDs: Set<MediaItemID>
  ) async throws -> MediaRemovalTransaction {
    do {
      return try await store.prepareRemoval(of: itemIDs)
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {
    do {
      try await store.commitRemoval(transaction)
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {
    do {
      try await store.rollbackRemoval(transaction)
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  private static func mapRemovalError(_ error: Error) -> Error {
    if let error = error as? MediaSourceError {
      return error
    }
    if let error = error as? LocalMediaError {
      let removalError: MediaRemovalError
      switch error {
      case .unknownTransaction:
        removalError = .unknownTransaction
      case .alreadyCommitted:
        removalError = .alreadyCommitted
      case .alreadyRolledBack:
        removalError = .alreadyRolledBack
      case .invalidRemovalState, .invalidItemID, .invalidRelativePath:
        removalError = .invalidState
      case .restoreConflict:
        removalError = .restoreConflict
      case .deleteFailed:
        removalError = .deleteFailed
      case .moveFailed, .recoveryFailed, .rootContainmentViolation, .itemNotFound:
        removalError = .moveFailed
      case .cancelled:
        removalError = .cancelled
      default:
        removalError = .moveFailed
      }
      return MediaSourceError.removalFailed(removalError)
    }
    if error is CancellationError {
      return MediaSourceError.removalFailed(.cancelled)
    }
    return MediaSourceError.removalFailed(.moveFailed)
  }
}
