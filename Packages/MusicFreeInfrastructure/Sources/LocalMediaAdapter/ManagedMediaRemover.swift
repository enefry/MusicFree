import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

/// Performs recoverable deletion of files owned by the built-in local source.
@available(macOS 13.0, iOS 16.0, *)
public final class ManagedMediaRemover: ManagedMediaRemoving, @unchecked Sendable {
  private let coordinator: ImportCoordinator
  private let store: ManagedMediaStore
  private let maintenanceGate: ImportMaintenanceGate
  private let libraryRepository: (any LibraryRepository)?

  public init(
    configuration: LocalMediaConfiguration,
    libraryRepository: (any LibraryRepository)? = nil
  ) throws {
    let coordinator = try ImportCoordinatorRegistry.shared.coordinator(for: configuration)
    self.coordinator = coordinator
    self.store = coordinator.store
    self.maintenanceGate = coordinator.maintenanceGate
    self.libraryRepository = libraryRepository
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
        guard let libraryRepository else {
          return try await store.prepareRemoval(of: itemIDs)
        }
        let assetIDs = try await self.assetIDsToRemove(
          for: itemIDs,
          from: libraryRepository
        )
        return try await store.prepareRemoval(of: itemIDs, assetIDs: assetIDs)
      }
    } catch {
      throw Self.mapRemovalError(error)
    }
  }

  private func assetIDsToRemove(
    for itemIDs: Set<MediaItemID>,
    from libraryRepository: any LibraryRepository
  ) async throws -> Set<MediaAssetID> {
    guard !itemIDs.isEmpty,
          itemIDs.allSatisfy({
            $0.sourceID == .local && !$0.externalID.isEmpty
          })
    else {
      throw LocalMediaError.invalidItemID
    }

    var requestedAssetIDs = Set<MediaAssetID>()
    for itemID in itemIDs.sorted() {
        if let track = try await libraryRepository.track(id: itemID) {
            requestedAssetIDs.insert(track.assetID)
        } else if let variant = try await libraryRepository.trackVariant(id: itemID) {
            requestedAssetIDs.insert(variant.assetID)
        } else {
            // Keep deletion compatible with old library rows that predate the
            // explicit Track.assetID field.
            requestedAssetIDs.insert(MediaAssetID(legacyVariantID: itemID))
        }
    }

    var removableAssetIDs = Set<MediaAssetID>()
    for assetID in requestedAssetIDs.sorted() {
      if try await !libraryRepository.isMediaAssetReferenced(assetID, excluding: itemIDs) {
        removableAssetIDs.insert(assetID)
      }
    }
    return removableAssetIDs
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
