import Foundation
import MediaSourceAPI
import MusicDomain

/// Stable display data captured when a resource is prepared for playback.
/// It is separate from the transient resource so UI state can remain
/// inspectable without retaining adapter objects.
public struct PlaybackDisplaySnapshot: Codable, Equatable, Hashable, Sendable {
  public let title: String
  public let artist: String?
  public let album: String?
  public let artworkID: ArtworkID?
  public let duration: Duration?

  public init(
    title: String,
    artist: String? = nil,
    album: String? = nil,
    artworkID: ArtworkID? = nil,
    duration: Duration? = nil
  ) {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(!normalizedTitle.isEmpty, "PlaybackDisplaySnapshot.title cannot be empty")
    if let duration {
      precondition(duration >= .zero, "PlaybackDisplaySnapshot.duration cannot be negative")
    }

    self.title = normalizedTitle
    self.artist = Self.normalized(artist)
    self.album = Self.normalized(album)
    self.artworkID = artworkID
    self.duration = duration
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

/// A resolved media item handed to a playback engine for one session.
/// `resource` is deliberately not Codable or part of queue snapshots.
public struct PlaybackItem: Sendable {
  public let itemID: MediaItemID
  public let resource: PlaybackResource
  public let selection: PlaybackSelection
  public let displaySnapshot: PlaybackDisplaySnapshot

  public init(
    itemID: MediaItemID,
    resource: PlaybackResource,
    selection: PlaybackSelection = .wholeFile,
    displaySnapshot: PlaybackDisplaySnapshot
  ) {
    self.itemID = itemID
    self.resource = resource
    self.selection = selection
    self.displaySnapshot = displaySnapshot
  }

  public var display: PlaybackDisplaySnapshot {
    displaySnapshot
  }
}
