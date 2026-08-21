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
  /// Physical managed assets moved by this transaction.
  ///
  /// This is empty for a resolved logical-track removal whose assets are still
  /// referenced by another track. `nil` identifies a legacy transaction that
  /// predates explicit asset IDs.
  public let assetIDs: Set<MediaAssetID>?

  public init(
    transactionID: UUID,
    itemIDs: Set<MediaItemID>,
    assetIDs: Set<MediaAssetID>? = nil
  ) {
    self.transactionID = transactionID
    self.itemIDs = itemIDs
    self.assetIDs = assetIDs
  }

  public init(
    id: UUID,
    itemIDs: Set<MediaItemID>,
    assetIDs: Set<MediaAssetID>? = nil
  ) {
    self.init(transactionID: id, itemIDs: itemIDs, assetIDs: assetIDs)
  }

  public var id: UUID {
    transactionID
  }

  public var description: String {
    "MediaRemovalTransaction(id: \(transactionID.uuidString), itemCount: \(itemIDs.count), assetCount: \(assetIDs?.count ?? 0))"
  }

  private enum CodingKeys: String, CodingKey {
    case transactionID
    case itemIDs
    case assetIDs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      transactionID: try container.decode(UUID.self, forKey: .transactionID),
      itemIDs: try container.decode(Set<MediaItemID>.self, forKey: .itemIDs),
      assetIDs: try container.decodeIfPresent(Set<MediaAssetID>.self, forKey: .assetIDs)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(transactionID, forKey: .transactionID)
    try container.encode(itemIDs, forKey: .itemIDs)
    try container.encodeIfPresent(assetIDs, forKey: .assetIDs)
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
