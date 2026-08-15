import Foundation
import MediaSourceAPI
import MusicDomain

/// Performs recoverable deletion of files owned by the built-in local source.
@available(macOS 13.0, iOS 16.0, *)
public final class ManagedMediaRemover: ManagedMediaRemoving, @unchecked Sendable {
  private let coordinator: ImportCoordinator
  private let store: ManagedMediaStore
  private let maintenanceGate: ImportMaintenanceGate

  public init(configuration: LocalMediaConfiguration) throws {
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    self.coordinator = coordinator
    self.store = coordinator.store
    self.maintenanceGate = coordinator.maintenanceGate
  }

  public func pendingRemovals() async throws -> [MediaRemovalTransaction] {
    do {
      return try await withMaintenance {
        try await store.pendingRemovals()
      }
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func prepareRemoval(
    of itemIDs: Set<MediaItemID>
  ) async throws -> MediaRemovalTransaction {
    do {
      return try await withMaintenance {
        try await store.prepareRemoval(of: itemIDs)
      }
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func commitRemoval(_ transaction: MediaRemovalTransaction) async throws {
    do {
      try await withMaintenance {
        try await store.commitRemoval(transaction)
      }
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  public func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws {
    do {
      try await withMaintenance {
        try await store.rollbackRemoval(transaction)
      }
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  private func withMaintenance<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    let acquired = await maintenanceGate.enterMaintenance()
    guard acquired else { throw CancellationError() }
    do {
      let result = try await operation()
      await maintenanceGate.leaveMaintenance()
      return result
    } catch {
      await maintenanceGate.leaveMaintenance()
      throw error
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
