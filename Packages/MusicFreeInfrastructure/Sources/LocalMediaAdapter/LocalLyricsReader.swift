import Foundation

/// Reads a same-name sidecar without retaining the source URL in the library.
/// The caller is responsible for holding any security-scoped access required
/// by the source while this function runs.
enum LocalLyricsReader {
  static let maximumByteCount = 2 * 1024 * 1024

  static func readSidecar(for mediaURL: URL) throws -> String? {
    let exactSidecar = mediaURL
      .deletingPathExtension()
      .appendingPathExtension("lrc")
    do {
      if let lyrics = try readCandidate(at: exactSidecar) {
        return lyrics
      }
    } catch {
      // A security-scoped file may allow the exact sibling path while denying
      // directory enumeration. Keep the case-insensitive fallback available.
    }

    let directory = mediaURL.deletingLastPathComponent()
    let baseName = mediaURL.deletingPathExtension().lastPathComponent
    let candidates = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.path < $1.path }

    guard let sidecar = candidates.first(where: { candidate in
      candidate.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
        && candidate.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame
    }) else {
      return nil
    }

    return try readCandidate(at: sidecar)
  }

  private static func readCandidate(at sidecar: URL) throws -> String? {
    let values = try sidecar.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard values.isRegularFile == true,
          values.isSymbolicLink != true,
          let fileSize = values.fileSize,
          fileSize <= maximumByteCount
    else {
      return nil
    }
    // The file may grow after the resource-value check. Read at most one byte
    // beyond the limit so a raced replacement cannot allocate unbounded data.
    guard let data = try readData(at: sidecar, maximumByteCount: maximumByteCount) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .isoLatin1)
  }

  private static func readData(at url: URL, maximumByteCount: Int) throws -> Data? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var data = Data()
    while true {
      let remaining = maximumByteCount - data.count
      let readCount = remaining == 0 ? 1 : remaining + 1
      guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
        return data
      }
      guard chunk.count <= remaining else {
        return nil
      }
      data.append(chunk)
    }
  }
}
