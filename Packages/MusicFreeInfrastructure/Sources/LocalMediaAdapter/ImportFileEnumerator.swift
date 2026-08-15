import Foundation

struct ImportFile: Sendable {
  let url: URL
  let folderPath: String?
}

struct ImportFileEnumerator: Sendable {
  let configuration: LocalMediaConfiguration

  func enumerate(_ inputURL: URL) throws -> [ImportFile] {
    guard inputURL.isFileURL else {
      throw LocalMediaError.inaccessibleInput
    }

    let fileManager = FileManager.default
    let rootURL = inputURL.standardizedFileURL
    let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
    let folderRoot = rootValues.isDirectory == true ? rootURL : nil
    var files: [ImportFile] = []
    var pending: [(URL, Int)] = [(inputURL.standardizedFileURL, 0)]
    var visitedDirectories = Set<String>()

    while let (url, depth) = pending.popLast() {
      try Task.checkCancellation()
      let values: URLResourceValues
      do {
        values = try url.resourceValues(forKeys: [
          .isDirectoryKey,
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .isPackageKey,
          .isHiddenKey,
          .fileSizeKey,
        ])
      } catch {
        throw LocalMediaError.enumerationFailed
      }

      if values.isSymbolicLink == true || values.isHidden == true
        || url.lastPathComponent.hasPrefix(".")
      {
        continue
      }
      if values.isPackage == true {
        continue
      }

      if values.isDirectory == true {
        guard depth < configuration.maximumDepth else { continue }

        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard visitedDirectories.insert(resolved).inserted else { continue }

        let children: [URL]
        do {
          children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
              .isDirectoryKey,
              .isRegularFileKey,
              .isSymbolicLinkKey,
              .isPackageKey,
              .isHiddenKey,
              .fileSizeKey,
            ],
            options: []
          ).sorted { $0.path < $1.path }
        } catch {
          throw LocalMediaError.enumerationFailed
        }
        pending.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        continue
      }

      guard values.isRegularFile == true else { continue }
      guard !Self.isLyricsSidecar(url) else { continue }
      if let maximumFileSize = configuration.maximumFileSize,
         let fileSize = values.fileSize,
         Int64(fileSize) > maximumFileSize
      {
        throw LocalMediaError.fileTooLarge
      }
      files.append(
        ImportFile(
          url: url,
          folderPath: folderRoot.flatMap { Self.relativeFolderPath(for: url, root: $0) }
        )
      )
      guard files.count <= configuration.maximumFileCount else {
        throw LocalMediaError.enumerationLimitExceeded
      }
    }

    return files.sorted { $0.url.path < $1.url.path }
  }

  private static func isLyricsSidecar(_ url: URL) -> Bool {
    url.pathExtension.caseInsensitiveCompare("lrc") == .orderedSame
  }

  private static func relativeFolderPath(for fileURL: URL, root: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let fileComponents = fileURL.standardizedFileURL.pathComponents
    guard fileComponents.count > rootComponents.count,
          Array(fileComponents.prefix(rootComponents.count)) == rootComponents
    else { return nil }
    let folderComponents = fileComponents.dropFirst(rootComponents.count).dropLast()
    guard !folderComponents.isEmpty,
          folderComponents.allSatisfy({ $0 != "." && $0 != ".." })
    else { return nil }
    return folderComponents.joined(separator: "/")
  }
}
