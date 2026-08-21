import Foundation
import MusicDomain

/// Repeat behavior belongs to the application queue coordinator, not the
/// single-resource playback engine.
public enum PlaybackRepeatMode: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case one
  case all
}

/// Whether the coordinator should use a persisted deterministic order.
public enum PlaybackShuffleMode: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case on
}

/// A queue entry has its own stable identity so the same item can be queued
/// more than once without conflating resume or edit operations.
public struct PlaybackQueueEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let logicalTrackID: LogicalTrackID
  public let preferredVariantID: MediaItemID?

  public init(id: UUID, itemID: MediaItemID) {
    self.id = id
    self.logicalTrackID = LogicalTrackID(legacyVariantID: itemID)
    self.preferredVariantID = itemID
  }

  /// Creates a queue entry from the library's canonical track identity.
  /// `itemID` is the selected variant while `logicalTrackID` remains stable
  /// when another provider or representation is selected later.
  @available(macOS 13.0, iOS 16.0, *)
  public init(id: UUID, track: Track) {
    self.id = id
    self.logicalTrackID = track.logicalTrackID
    self.preferredVariantID = track.id
  }

  public init(
    id: UUID,
    logicalTrackID: LogicalTrackID,
    preferredVariantID: MediaItemID?
  ) {
    self.id = id
    self.logicalTrackID = logicalTrackID
    self.preferredVariantID = preferredVariantID
  }

  public init(entryID: UUID, itemID: MediaItemID) {
    self.init(id: entryID, itemID: itemID)
  }

  public var entryID: UUID {
    id
  }

  public var itemID: MediaItemID {
    guard let preferredVariantID else {
      preconditionFailure("A local playback queue entry requires a preferred variant")
    }
    return preferredVariantID
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case itemID
    case logicalTrackID
    case preferredVariantID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    if let logicalTrackID = try container.decodeIfPresent(LogicalTrackID.self, forKey: .logicalTrackID) {
      self.init(
        id: id,
        logicalTrackID: logicalTrackID,
        preferredVariantID: try container.decodeIfPresent(MediaItemID.self, forKey: .preferredVariantID)
          ?? container.decodeIfPresent(MediaItemID.self, forKey: .itemID)
      )
    } else {
      self.init(id: id, itemID: try container.decode(MediaItemID.self, forKey: .itemID))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(logicalTrackID, forKey: .logicalTrackID)
    try container.encodeIfPresent(preferredVariantID, forKey: .preferredVariantID)
  }
}

/// Errors returned by pure queue snapshot edits.
public enum PlaybackQueueError: Error, Codable, Equatable, Hashable, Sendable {
  case entryNotFound(UUID)
  case duplicateEntryID(UUID)
  case invalidPosition(Int)
  case invalidResumePosition
  case invalidShuffleOrder
}

/// A persisted queue snapshot. It contains stable IDs and playback intent only;
/// no `PlaybackResource`, URL, header, or adapter object can be stored here.
public struct PlaybackQueueSnapshot: Codable, Equatable, Hashable, Sendable {
  public let entries: [PlaybackQueueEntry]
  public let currentEntryID: UUID?
  public let repeatMode: PlaybackRepeatMode
  public let shuffleMode: PlaybackShuffleMode
  public let shuffleSeed: UInt64?
  public let shuffleOrder: [UUID]
  public let resumePosition: Duration?

  public init(
    entries: [PlaybackQueueEntry] = [],
    currentEntryID: UUID? = nil,
    repeatMode: PlaybackRepeatMode = .off,
    shuffleMode: PlaybackShuffleMode = .off,
    shuffleSeed: UInt64? = nil,
    shuffleOrder: [UUID] = [],
    resumePosition: Duration? = nil
  ) {
    let entryIDs = entries.map(\.id)
    precondition(
      Set(entryIDs).count == entryIDs.count,
      "PlaybackQueueSnapshot entries must have unique IDs"
    )
    if let currentEntryID {
      precondition(
        entryIDs.contains(currentEntryID),
        "PlaybackQueueSnapshot.currentEntryID must refer to an entry"
      )
    }
    if let resumePosition {
      precondition(
        resumePosition >= .zero,
        "PlaybackQueueSnapshot.resumePosition cannot be negative"
      )
    }

    let normalizedShuffleOrder: [UUID]
    let normalizedSeed: UInt64?
    if shuffleMode == .off {
      normalizedShuffleOrder = []
      normalizedSeed = nil
    } else {
      let shuffleIDs = Set(shuffleOrder)
      precondition(
        shuffleOrder.isEmpty || (shuffleOrder.count == entryIDs.count && shuffleIDs == Set(entryIDs)),
        "PlaybackQueueSnapshot.shuffleOrder must contain each entry exactly once"
      )
      normalizedShuffleOrder = shuffleOrder
      normalizedSeed = shuffleSeed
    }

    self.entries = entries
    self.currentEntryID = currentEntryID
    self.repeatMode = repeatMode
    self.shuffleMode = shuffleMode
    self.shuffleSeed = normalizedSeed
    self.shuffleOrder = normalizedShuffleOrder
    self.resumePosition = resumePosition
  }

  public static let empty = Self()

  public var itemIDs: [MediaItemID] {
    entries.map(\.itemID)
  }

  public var currentEntry: PlaybackQueueEntry? {
    guard let currentEntryID else {
      return nil
    }
    return entries.first { $0.id == currentEntryID }
  }

  public var currentItemID: MediaItemID? {
    currentEntry?.itemID
  }

  public var isEmpty: Bool {
    entries.isEmpty
  }

  /// Applies one deterministic value edit without owning a queue coordinator.
  public func applying(_ edit: PlaybackQueueEdit) throws -> Self {
    var updatedEntries = entries
    var updatedCurrentEntryID = currentEntryID
    var updatedRepeatMode = repeatMode
    var updatedShuffleMode = shuffleMode
    var updatedShuffleSeed = shuffleSeed
    var updatedShuffleOrder = shuffleOrder
    var updatedResumePosition = resumePosition

    switch edit {
    case .append(let entry):
      guard !updatedEntries.contains(where: { $0.id == entry.id }) else {
        throw PlaybackQueueError.duplicateEntryID(entry.id)
      }
      updatedEntries.append(entry)
      if updatedShuffleMode == .on, !updatedShuffleOrder.isEmpty {
        updatedShuffleOrder.append(entry.id)
      }

    case .insert(let entry, let position):
      guard !updatedEntries.contains(where: { $0.id == entry.id }) else {
        throw PlaybackQueueError.duplicateEntryID(entry.id)
      }
      guard (0...updatedEntries.count).contains(position) else {
        throw PlaybackQueueError.invalidPosition(position)
      }
      updatedEntries.insert(entry, at: position)
      if updatedShuffleMode == .on, !updatedShuffleOrder.isEmpty {
        updatedShuffleOrder.append(entry.id)
      }

    case .remove(let entryID):
      guard let index = updatedEntries.firstIndex(where: { $0.id == entryID }) else {
        throw PlaybackQueueError.entryNotFound(entryID)
      }
      updatedEntries.remove(at: index)
      updatedShuffleOrder.removeAll { $0 == entryID }
      if updatedCurrentEntryID == entryID {
        updatedCurrentEntryID = nil
        updatedResumePosition = nil
      }

    case .move(let entryID, let position):
      guard let index = updatedEntries.firstIndex(where: { $0.id == entryID }) else {
        throw PlaybackQueueError.entryNotFound(entryID)
      }
      guard (0..<updatedEntries.count).contains(position) else {
        throw PlaybackQueueError.invalidPosition(position)
      }
      let entry = updatedEntries.remove(at: index)
      updatedEntries.insert(entry, at: position)

    case .setCurrent(let entryID):
      if let entryID {
        guard updatedEntries.contains(where: { $0.id == entryID }) else {
          throw PlaybackQueueError.entryNotFound(entryID)
        }
      }
      updatedCurrentEntryID = entryID
      updatedResumePosition = nil

    case .setRepeatMode(let mode):
      updatedRepeatMode = mode

    case .setShuffle(let mode, let seed, let order):
      let entryIDs = Set(updatedEntries.map(\.id))
      guard mode == .off
        || order.isEmpty
        || (order.count == updatedEntries.count && Set(order) == entryIDs)
      else {
        throw PlaybackQueueError.invalidShuffleOrder
      }
      updatedShuffleMode = mode
      updatedShuffleSeed = mode == .on ? seed : nil
      updatedShuffleOrder = mode == .on ? order : []

    case .setResumePosition(let position):
      if let position {
        guard position >= .zero else {
          throw PlaybackQueueError.invalidResumePosition
        }
      }
      updatedResumePosition = position

    case .clear:
      return .empty
    }

    return Self(
      entries: updatedEntries,
      currentEntryID: updatedCurrentEntryID,
      repeatMode: updatedRepeatMode,
      shuffleMode: updatedShuffleMode,
      shuffleSeed: updatedShuffleSeed,
      shuffleOrder: updatedShuffleOrder,
      resumePosition: updatedResumePosition
    )
  }
}

/// Pure queue commands that can be persisted or sent through an application
/// service without depending on a playback adapter.
public enum PlaybackQueueEdit: Codable, Equatable, Hashable, Sendable {
  case append(PlaybackQueueEntry)
  case insert(PlaybackQueueEntry, at: Int)
  case remove(UUID)
  case move(UUID, to: Int)
  case setCurrent(UUID?)
  case setRepeatMode(PlaybackRepeatMode)
  case setShuffle(mode: PlaybackShuffleMode, seed: UInt64?, order: [UUID])
  case setResumePosition(Duration?)
  case clear

  public static func enqueue(_ entry: PlaybackQueueEntry, at position: Int? = nil) -> Self {
    if let position {
      return .insert(entry, at: position)
    }
    return .append(entry)
  }
}

/// Compatibility name for coordinators that model edits as commands.
public typealias PlaybackQueueCommand = PlaybackQueueEdit
