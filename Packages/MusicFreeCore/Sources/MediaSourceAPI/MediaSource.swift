import Foundation
import MusicDomain

/// The protocol-neutral category of a media source.
public enum MediaSourceKind: String, Codable, Sendable {
  case local
  case remote
}

/// Stable, user-visible information about a media source.
public struct MediaSourceDescriptor: Codable, Equatable, Hashable, Sendable {
  public let sourceID: MediaSourceID
  public let kind: MediaSourceKind
  public let displayName: String
  public let isReadOnly: Bool

  public init(
    sourceID: MediaSourceID,
    kind: MediaSourceKind,
    displayName: String,
    isReadOnly: Bool = false
  ) {
    self.sourceID = sourceID
    self.kind = kind
    self.displayName = displayName
    self.isReadOnly = isReadOnly
  }

  /// Short alias useful when a descriptor is used as a source registry value.
  public var id: MediaSourceID {
    sourceID
  }
}

/// Capabilities that a source explicitly supports.
public struct MediaSourceCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let importing = Self(rawValue: 1 << 0)
  public static let incrementalSync = Self(rawValue: 1 << 1)
  public static let managedRemoval = Self(rawValue: 1 << 2)
  public static let artwork = Self(rawValue: 1 << 3)
  public static let metadataReading = Self(rawValue: 1 << 4)

  public static let incrementalChanges = incrementalSync
  public static let managedMediaRemoval = managedRemoval

  public static let all: Self = [
    .importing,
    .incrementalSync,
    .managedRemoval,
    .artwork,
    .metadataReading,
  ]

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(UInt64.self))
  }
}

/// Opaque, source-owned position used to resume an incremental change stream.
public struct MediaSourceCursor: Codable, Equatable, Hashable, RawRepresentable, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }

  public var description: String {
    "MediaSourceCursor(redacted)"
  }

  public var debugDescription: String {
    description
  }
}

/// A single durable change emitted by a source.
public struct MediaSourceChange: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case added
    case updated
    case removed

    public static let inserted = Self.added
  }

  public let kind: Kind
  public let itemID: MediaItemID
  public let cursor: MediaSourceCursor

  public init(
    kind: Kind,
    itemID: MediaItemID,
    cursor: MediaSourceCursor
  ) {
    self.kind = kind
    self.itemID = itemID
    self.cursor = cursor
  }
}

/// Resolves stable physical-asset IDs into short-lived playback and artwork
/// resources. A logical track's range and audio-stream selection stay outside
/// this protocol in `PlaybackSelection`.
public protocol MediaSource: Sendable {
  var descriptor: MediaSourceDescriptor { get }
  var capabilities: MediaSourceCapabilities { get }

  func resolve(_ assetID: MediaItemID) async throws -> PlaybackResource
  func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource?
}

/// Optional incremental changes are separate from the base source contract.
public protocol MediaSourceChangesProviding: MediaSource {
  /// The returned stream must finish normally after cancellation or consumer
  /// termination and must release its continuation in onTermination.
  func changes(since cursor: MediaSourceCursor?)
    -> AsyncThrowingStream<MediaSourceChange, Error>
}
