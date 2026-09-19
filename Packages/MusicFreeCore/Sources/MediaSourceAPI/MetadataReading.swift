import Foundation
import MusicDomain

/// Embedded artwork returned by a raw metadata reader.
public struct RawArtwork: Codable, Equatable, Sendable {
  public let data: Data
  public let mimeType: String?
  public let pixelWidth: Int?
  public let pixelHeight: Int?

  public init(
    data: Data,
    mimeType: String? = nil,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    self.data = data
    self.mimeType = mimeType
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

/// Format-neutral tags returned before normalization into MusicDomain.
///
/// This is an adapter boundary value. It must not be passed to a library
/// repository or retained as the persisted representation of a track.
public struct RawMediaMetadata: Codable, Equatable, Sendable {
  public let title: String?
  public let artist: String?
  public let album: String?
  public let albumArtist: String?
  public let composer: String?
  public let genre: String?
  public let comment: String?
  /// Embedded plain-text or timestamped lyrics, when exposed by the source.
  public let lyrics: String?
  public let trackNumber: Int?
  public let discNumber: Int?
  public let year: Int?
  public let duration: Duration?
  public let artworks: [RawArtwork]

  public init(
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    albumArtist: String? = nil,
    composer: String? = nil,
    genre: String? = nil,
    comment: String? = nil,
    lyrics: String? = nil,
    trackNumber: Int? = nil,
    discNumber: Int? = nil,
    year: Int? = nil,
    duration: Duration? = nil,
    artworks: [RawArtwork] = []
  ) {
    self.title = Self.normalized(title)
    self.artist = Self.normalized(artist)
    self.album = Self.normalized(album)
    self.albumArtist = Self.normalized(albumArtist)
    self.composer = Self.normalized(composer)
    self.genre = Self.normalized(genre)
    self.comment = Self.normalized(comment)
    self.lyrics = Self.normalized(lyrics)
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.year = year
    self.duration = duration
    self.artworks = artworks
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      title: try container.decodeIfPresent(String.self, forKey: .title),
      artist: try container.decodeIfPresent(String.self, forKey: .artist),
      album: try container.decodeIfPresent(String.self, forKey: .album),
      albumArtist: try container.decodeIfPresent(String.self, forKey: .albumArtist),
      composer: try container.decodeIfPresent(String.self, forKey: .composer),
      genre: try container.decodeIfPresent(String.self, forKey: .genre),
      comment: try container.decodeIfPresent(String.self, forKey: .comment),
      lyrics: try container.decodeIfPresent(String.self, forKey: .lyrics),
      trackNumber: try container.decodeIfPresent(Int.self, forKey: .trackNumber),
      discNumber: try container.decodeIfPresent(Int.self, forKey: .discNumber),
      year: try container.decodeIfPresent(Int.self, forKey: .year),
      duration: try container.decodeIfPresent(Duration.self, forKey: .duration),
      artworks: try container.decodeIfPresent([RawArtwork].self, forKey: .artworks) ?? []
    )
  }

  public var firstArtwork: RawArtwork? {
    artworks.first
  }

  public func replacingLyrics(_ lyrics: String?) -> Self {
    Self(
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      composer: composer,
      genre: genre,
      comment: comment,
      lyrics: lyrics,
      trackNumber: trackNumber,
      discNumber: discNumber,
      year: year,
      duration: duration,
      artworks: artworks
    )
  }

  private static func normalized(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = MetadataTextRepair.repair(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private enum CodingKeys: String, CodingKey {
    case title
    case artist
    case album
    case albumArtist
    case composer
    case genre
    case comment
    case lyrics
    case trackNumber
    case discNumber
    case year
    case duration
    case artworks
  }
}

/// Reads raw tags and embedded artwork from a short-lived media resource.
public protocol MetadataReading: Sendable {
  func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata
}
