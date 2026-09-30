import Foundation
import MediaSourceAPI
import MusicDomain

actor ManagedMediaAccessCoordinator {
  private struct PendingRetirement {
    let shouldRetire: @Sendable () async throws -> Bool
    let completion: @Sendable () async -> Void
  }

  private let store: ManagedMediaStore
  private var leaseCounts: [MediaAssetID: Int] = [:]
  private var pendingRetirements: [MediaAssetID: [PendingRetirement]] = [:]
  private var retiringAssetIDs = Set<MediaAssetID>()

  init(store: ManagedMediaStore) {
    self.store = store
  }

  func resolveAndAcquire(_ assetID: MediaAssetID) async throws -> (URL, MediaResourceReadLease) {
    guard !retiringAssetIDs.contains(assetID) else {
      throw LocalMediaError.itemNotFound
    }
    let lease = acquire(assetID)
    do {
      let url = try await store.mediaURL(forExternalID: assetID.externalID)
      return (url, lease)
    } catch {
      lease.release()
      throw error
    }
  }

  func acquire(_ assetID: MediaAssetID) -> MediaResourceReadLease {
    leaseCounts[assetID, default: 0] += 1
    return MediaResourceReadLease { [weak self] in
      Task { await self?.release(assetID) }
    }
  }

  func hasActiveLease(for assetID: MediaAssetID) -> Bool {
    leaseCounts[assetID, default: 0] > 0
  }

  func withExclusiveAccess<T: Sendable>(
    to assetIDs: Set<MediaAssetID>,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    guard assetIDs.allSatisfy({
      !hasActiveLease(for: $0) && !retiringAssetIDs.contains($0)
    }) else {
      throw LocalMediaError.invalidRemovalState
    }

    retiringAssetIDs.formUnion(assetIDs)
    do {
      let result = try await operation()
      await releaseExclusiveAccess(to: assetIDs)
      return result
    } catch {
      await releaseExclusiveAccess(to: assetIDs)
      throw error
    }
  }

  @discardableResult
  func retire(
    _ assetID: MediaAssetID,
    if shouldRetire: @escaping @Sendable () async throws -> Bool = { true },
    completion: @escaping @Sendable () async -> Void = {}
  ) async throws -> Bool {
    if hasActiveLease(for: assetID) || retiringAssetIDs.contains(assetID) {
      pendingRetirements[assetID, default: []].append(PendingRetirement(
        shouldRetire: shouldRetire,
        completion: completion
      ))
      return false
    }

    retiringAssetIDs.insert(assetID)
    do {
      guard try await shouldRetire() else {
        retiringAssetIDs.remove(assetID)
        await completion()
        await processNextPendingRetirement(for: assetID)
        return false
      }
      try await store.removeManagedAsset(forExternalID: assetID.externalID)
      await completion()
      await completePendingRetirements(for: assetID)
      retiringAssetIDs.remove(assetID)
      return true
    } catch {
      retiringAssetIDs.remove(assetID)
      throw error
    }
  }

  private func release(_ assetID: MediaAssetID) async {
    let current = leaseCounts[assetID, default: 0]
    if current > 1 {
      leaseCounts[assetID] = current - 1
      return
    }
    leaseCounts[assetID] = nil
    await processNextPendingRetirement(for: assetID)
  }

  private func releaseExclusiveAccess(to assetIDs: Set<MediaAssetID>) async {
    retiringAssetIDs.subtract(assetIDs)
    for assetID in assetIDs.sorted() {
      await processNextPendingRetirement(for: assetID)
    }
  }

  private func processNextPendingRetirement(for assetID: MediaAssetID) async {
    guard !hasActiveLease(for: assetID),
          !retiringAssetIDs.contains(assetID),
          var pending = pendingRetirements[assetID],
          !pending.isEmpty
    else { return }
    let next = pending.removeFirst()
    pendingRetirements[assetID] = pending.isEmpty ? nil : pending
    do {
      _ = try await retire(
        assetID,
        if: next.shouldRetire,
        completion: next.completion
      )
    } catch {
      pendingRetirements[assetID, default: []].insert(next, at: 0)
    }
  }

  private func completePendingRetirements(for assetID: MediaAssetID) async {
    while let pending = pendingRetirements.removeValue(forKey: assetID) {
      for retirement in pending {
        await retirement.completion()
      }
    }
  }
}
