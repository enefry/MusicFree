import Foundation
import ImageIO
import MediaSourceAPI

enum FolderImportResourceKind: String, Equatable, Sendable {
  case mediaCandidate
  case cue
  case artwork
  case lyrics
  case manifest
  case sidecar
}

struct FolderImportResource: Sendable {
  let file: ImportFile
  let kind: FolderImportResourceKind
}

struct FolderImportBundle: Sendable {
  let rootURL: URL
  let resources: [FolderImportResource]
  let collectionManifest: LocalMediaCollectionManifest?

  init(
    rootURL: URL,
    resources: [FolderImportResource],
    collectionManifest: LocalMediaCollectionManifest? = nil
  ) {
    self.rootURL = rootURL
    self.resources = resources
    self.collectionManifest = collectionManifest
  }

  var mediaCandidates: [ImportFile] { files(of: .mediaCandidate) }
  var cueFiles: [ImportFile] { files(of: .cue) }
  var artworkFiles: [ImportFile] { files(of: .artwork) }
  var lyricsFiles: [ImportFile] { files(of: .lyrics) }

  private func files(of kind: FolderImportResourceKind) -> [ImportFile] {
    Array(resources.lazy.filter { $0.kind == kind }.map(\.file))
  }
}

struct FolderImportBundleAnalyzer: Sendable {
  func analyze(inputURL: URL, files: [ImportFile]) throws -> FolderImportBundle {
    let rootURL = try bundleRoot(for: inputURL)
    let resources = files.map { file in
      FolderImportResource(file: file, kind: classify(file.url))
    }
    let sortedResources = resources.sorted { $0.file.url.path < $1.file.url.path }
    let manifestURL = rootURL.appendingPathComponent(LocalMediaCollectionManifest.fileName)
    let manifestResource = sortedResources.first {
      $0.kind == .manifest && $0.file.url.standardizedFileURL == manifestURL.standardizedFileURL
    }
    let collectionManifest: LocalMediaCollectionManifest?
    if let manifestResource {
      do {
        collectionManifest = try LocalMediaCollectionManifest.parse(
          data: Data(contentsOf: manifestResource.file.url, options: [.mappedIfSafe])
        )
      } catch let error as LocalMediaError {
        throw error
      } catch {
        throw LocalMediaError.metadataFailed
      }
    } else {
      collectionManifest = nil
    }
    return FolderImportBundle(
      rootURL: rootURL,
      resources: sortedResources,
      collectionManifest: collectionManifest
    )
  }

  private func bundleRoot(for inputURL: URL) throws -> URL {
    let standardized = inputURL.standardizedFileURL
    let values = try standardized.resourceValues(forKeys: [.isDirectoryKey])
    return values.isDirectory == true
      ? standardized
      : standardized.deletingLastPathComponent()
  }

  private func classify(_ url: URL) -> FolderImportResourceKind {
    switch url.pathExtension.lowercased() {
    case "cue":
      return .cue
    case "lrc":
      return .lyrics
    case "jpg", "jpeg", "png", "webp", "heic", "heif":
      return .artwork
    case "json", "xml", "yaml", "yml", "m3u", "m3u8":
      return .manifest
    case "txt", "nfo", "log", "pdf",
      "sfv", "accurip", "md5", "md5sum", "sha1", "sha256", "sha512",
      "crc", "crc32", "checksum", "checksums":
      return .sidecar
    default:
      // Keep unknown extensions probeable: some valid audio containers have
      // no useful filename declaration. The importer drops an un-decodable
      // unknown file when it is an unreferenced folder sidecar.
      return .mediaCandidate
    }
  }
}

enum FolderArtworkReason: String, Equatable, Sendable {
  case coverFile
  case frontFile
  case folderFile
  case albumFile
  case uniqueImage
}

struct FolderArtworkSelection: Equatable, Sendable {
  let url: URL
  let data: Data
  let pixelWidth: Int
  let pixelHeight: Int
  let reason: FolderArtworkReason
}

struct FolderArtworkResolver: Sendable {
  static let maximumPixelCount: Int64 = 100_000_000
  static let maximumDimension = 20_000

  func selection(
    for audioURL: URL,
    in bundle: FolderImportBundle,
    allowRootArtwork: Bool
  ) -> FolderArtworkSelection? {
    let audioDirectory = audioURL.deletingLastPathComponent().standardizedFileURL
    let root = bundle.rootURL.standardizedFileURL
    let candidates = bundle.artworkFiles.compactMap { file -> RankedArtwork? in
      let imageURL = file.url.standardizedFileURL
      let imageDirectory = imageURL.deletingLastPathComponent()
      guard let distance = ancestorDistance(from: audioDirectory, to: imageDirectory),
            imageDirectory != root || allowRootArtwork,
            let decoded = decode(imageURL)
      else { return nil }
      return RankedArtwork(
        selection: decoded,
        directoryDistance: distance,
        namePriority: namePriority(imageURL)
      )
    }

    guard !candidates.isEmpty else { return nil }
    let namesAtBestDirectory = candidates.filter {
      $0.directoryDistance == candidates.map(\.directoryDistance).min()
    }
    let named = namesAtBestDirectory.filter { $0.namePriority < 4 }
    let pool: [RankedArtwork]
    if !named.isEmpty {
      pool = named
    } else if namesAtBestDirectory.count == 1 {
      pool = namesAtBestDirectory
    } else {
      return nil
    }
    return pool.sorted(by: ranksBefore).first?.selection
  }

  private struct RankedArtwork {
    let selection: FolderArtworkSelection
    let directoryDistance: Int
    let namePriority: Int

    var pixelArea: Int64 {
      Int64(selection.pixelWidth) * Int64(selection.pixelHeight)
    }
  }

  private func ranksBefore(_ lhs: RankedArtwork, _ rhs: RankedArtwork) -> Bool {
    if lhs.directoryDistance != rhs.directoryDistance {
      return lhs.directoryDistance < rhs.directoryDistance
    }
    if lhs.namePriority != rhs.namePriority {
      return lhs.namePriority < rhs.namePriority
    }
    if lhs.pixelArea != rhs.pixelArea {
      return lhs.pixelArea > rhs.pixelArea
    }
    return lhs.selection.url.standardizedFileURL.path.localizedStandardCompare(
      rhs.selection.url.standardizedFileURL.path
    ) == .orderedAscending
  }

  private func namePriority(_ url: URL) -> Int {
    switch url.deletingPathExtension().lastPathComponent.lowercased() {
    case "cover": return 0
    case "front": return 1
    case "folder": return 2
    case "album": return 3
    default: return 4
    }
  }

  private func reason(for priority: Int) -> FolderArtworkReason {
    switch priority {
    case 0: return .coverFile
    case 1: return .frontFile
    case 2: return .folderFile
    case 3: return .albumFile
    default: return .uniqueImage
    }
  }

  private func decode(_ url: URL) -> FolderArtworkSelection? {
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true,
          let byteCount = values.fileSize,
          byteCount > 0,
          byteCount <= ArtworkDataLimits.maximumByteCount,
          let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
          !data.isEmpty,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = Self.integer(properties[kCGImagePropertyPixelWidth]),
          let height = Self.integer(properties[kCGImagePropertyPixelHeight]),
          width > 0,
          height > 0,
          width <= Self.maximumDimension,
          height <= Self.maximumDimension,
          Int64(width) * Int64(height) <= Self.maximumPixelCount,
          CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceThumbnailMaxPixelSize: 512,
              kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
          ) != nil
    else { return nil }
    let priority = namePriority(url)
    return FolderArtworkSelection(
      url: url,
      data: data,
      pixelWidth: width,
      pixelHeight: height,
      reason: reason(for: priority)
    )
  }

  private static func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    return value as? Int
  }

  private func ancestorDistance(from child: URL, to ancestor: URL) -> Int? {
    let childComponents = child.standardizedFileURL.pathComponents
    let ancestorComponents = ancestor.standardizedFileURL.pathComponents
    guard childComponents.count >= ancestorComponents.count,
          Array(childComponents.prefix(ancestorComponents.count)) == ancestorComponents
    else { return nil }
    return childComponents.count - ancestorComponents.count
  }
}
