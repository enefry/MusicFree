import Foundation
import MusicDomain

struct LocalMediaCollectionManifest: Sendable {
  struct Album: Sendable {
    let folderPath: String
    let title: String
    let position: Int
  }

  static let fileName = "musicfree.collection.json"

  let title: String
  let albums: [Album]

  func album(at folderPath: String) -> Album? {
    let normalizedPath = Self.normalizedPath(folderPath)
    return albums.first { $0.folderPath.caseInsensitiveCompare(normalizedPath) == .orderedSame }
  }

  func albumID(for folderPath: String) -> AlbumID? {
    album(at: folderPath).map { album in
      let token = MusicContentIdentity.compositeToken([
        "local-box-album",
        album.folderPath,
        album.title
      ])
      return AlbumID(rawValue: "local-\(token)")
    }
  }

  static func parse(data: Data) throws -> Self {
    guard data.count <= 1 * 1_024 * 1_024, !data.isEmpty else {
      throw LocalMediaError.metadataFailed
    }
    let value: RawManifest
    do {
      value = try JSONDecoder().decode(RawManifest.self, from: data)
    } catch {
      throw LocalMediaError.metadataFailed
    }

    guard value.kind.caseInsensitiveCompare("boxSet") == .orderedSame else {
      throw LocalMediaError.metadataFailed
    }
    let title = normalizedText(value.title)
    guard let title, !value.albums.isEmpty else {
      throw LocalMediaError.metadataFailed
    }

    var positions = Set<Int>()
    var paths = Set<String>()
    var albums: [Album] = []
    albums.reserveCapacity(value.albums.count)
    for (index, rawAlbum) in value.albums.enumerated() {
      guard let folderPath = normalizedRelativePath(rawAlbum.path),
            let albumTitle = normalizedText(rawAlbum.title ?? folderName(folderPath))
      else {
        throw LocalMediaError.metadataFailed
      }
      let position = rawAlbum.position ?? index
      guard position >= 0,
            positions.insert(position).inserted,
            paths.insert(folderPath.lowercased()).inserted
      else {
        throw LocalMediaError.metadataFailed
      }
      albums.append(Album(folderPath: folderPath, title: albumTitle, position: position))
    }

    return Self(
      title: title,
      albums: albums.sorted {
        $0.position == $1.position
          ? $0.folderPath.localizedStandardCompare($1.folderPath) == .orderedAscending
          : $0.position < $1.position
      }
    )
  }

  static func normalizedPath(_ value: String) -> String {
    value.split(separator: "/").map(String.init).joined(separator: "/")
  }

  private struct RawManifest: Decodable {
    let kind: String
    let title: String
    let albums: [RawAlbum]
  }

  private struct RawAlbum: Decodable {
    let path: String
    let title: String?
    let position: Int?
  }

  private static func normalizedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.count <= 512 else { return nil }
    return normalized
  }

  private static func normalizedRelativePath(_ value: String) -> String? {
    let normalizedSeparators = value.replacingOccurrences(of: "\\", with: "/")
    let components = normalizedSeparators.split(separator: "/").map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          !normalizedSeparators.hasPrefix("/"),
          !normalizedSeparators.contains(":")
    else { return nil }
    return components.joined(separator: "/")
  }

  private static func folderName(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
  }
}
