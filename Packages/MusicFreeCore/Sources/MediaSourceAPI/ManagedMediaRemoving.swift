import Foundation
import MusicDomain

/// Opaque handle for a prepared managed-media removal.
///
/// Adapter-private staging or quarantine paths are intentionally absent.
public struct MediaRemovalTransaction: Codable, Equatable, Hashable, Sendable,
  CustomStringConvertible
{
  public let transactionID: UUID
  public let itemIDs: Set<MediaItemID>

  public init(transactionID: UUID, itemIDs: Set<MediaItemID>) {
    self.transactionID = transactionID
    self.itemIDs = itemIDs
  }

  public init(id: UUID, itemIDs: Set<MediaItemID>) {
    self.init(transactionID: id, itemIDs: itemIDs)
  }

  public var id: UUID {
    transactionID
  }

  public var description: String {
    "MediaRemovalTransaction(id: \(transactionID.uuidString), itemCount: \(itemIDs.count))"
  }
}

/// A recoverable prepare/commit/rollback contract for managed media.
public protocol ManagedMediaRemoving: Sendable {
  func pendingRemovals() async throws -> [MediaRemovalTransaction]
  func prepareRemoval(of itemIDs: Set<MediaItemID>) async throws
    -> MediaRemovalTransaction
  func commitRemoval(_ transaction: MediaRemovalTransaction) async throws
  func rollbackRemoval(_ transaction: MediaRemovalTransaction) async throws
}
