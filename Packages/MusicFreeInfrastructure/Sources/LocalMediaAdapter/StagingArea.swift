import Foundation
import Darwin

actor StagingArea {
  private let configuration: LocalMediaConfiguration
  private let fileManager = FileManager.default

  init(configuration: LocalMediaConfiguration) throws {
    self.configuration = configuration
    try fileManager.createDirectory(
      at: configuration.stagingRoot,
      withIntermediateDirectories: true
    )
  }

  static func prepareRoot(configuration: LocalMediaConfiguration) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: configuration.stagingRoot,
      withIntermediateDirectories: true
    )
  }

  func stage(sourceURL: URL, importID: UUID) async throws -> URL {
    try Task.checkCancellation()
    let values: URLResourceValues
    do {
      values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw LocalMediaError.inaccessibleInput
    }
    guard values.isRegularFile == true else {
      throw LocalMediaError.unsupportedInput
    }
    if let maximumFileSize = configuration.maximumFileSize,
       let fileSize = values.fileSize,
       Int64(fileSize) > maximumFileSize
    {
      throw LocalMediaError.fileTooLarge
    }

    let batchRoot = configuration.stagingRoot
      .appendingPathComponent(importID.uuidString, isDirectory: true)
    try fileManager.createDirectory(at: batchRoot, withIntermediateDirectories: true)

    let extensionName = Self.safeExtension(for: sourceURL)
    let fileName = UUID().uuidString + (extensionName.isEmpty ? ".media" : ".\(extensionName)")
    let destination = batchRoot.appendingPathComponent(fileName, isDirectory: false)
    guard Self.isContained(destination, in: configuration.stagingRoot) else {
      throw LocalMediaError.rootContainmentViolation
    }

    do {
      try Task.checkCancellation()
      if cloneFileIfPossible(from: sourceURL, to: destination) {
        try Task.checkCancellation()
      } else {
        try copyStream(from: sourceURL, to: destination)
      }
      return destination
    } catch is CancellationError {
      try? fileManager.removeItem(at: destination)
      throw LocalMediaError.cancelled
    } catch let error as LocalMediaError {
      try? fileManager.removeItem(at: destination)
      throw error
    } catch {
      try? fileManager.removeItem(at: destination)
      throw Self.isOutOfSpace(error) ? LocalMediaError.insufficientStorage : .copyFailed
    }
  }

  func remove(_ url: URL) {
    guard Self.isContained(url, in: configuration.stagingRoot) else { return }
    try? fileManager.removeItem(at: url)
    removeEmptyParents(of: url)
  }

  func removeBatch(for importID: UUID) {
    let url = configuration.stagingRoot.appendingPathComponent(importID.uuidString, isDirectory: true)
    guard Self.isContained(url, in: configuration.stagingRoot) else { return }
    try? fileManager.removeItem(at: url)
  }

  private func cloneFileIfPossible(from source: URL, to destination: URL) -> Bool {
    let result = source.path.withCString { sourcePath in
      destination.path.withCString { destinationPath in
        Darwin.clonefile(sourcePath, destinationPath, 0)
      }
    }
    guard result == 0 else {
      try? fileManager.removeItem(at: destination)
      return false
    }
    return true
  }

  private func copyStream(from source: URL, to destination: URL) throws {
    fileManager.createFile(atPath: destination.path, contents: nil)
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
      try? input.close()
      try? output.close()
    }

    while true {
      try Task.checkCancellation()
      guard let data = try input.read(upToCount: 64 * 1024), !data.isEmpty else {
        break
      }
      try output.write(contentsOf: data)
    }
  }

  private func removeEmptyParents(of url: URL) {
    var parent = url.deletingLastPathComponent()
    while parent != configuration.stagingRoot,
          Self.isContained(parent, in: configuration.stagingRoot),
          let entries = try? fileManager.contentsOfDirectory(atPath: parent.path),
          entries.isEmpty
    {
      try? fileManager.removeItem(at: parent)
      parent = parent.deletingLastPathComponent()
    }
  }

  private static func safeExtension(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    guard !ext.isEmpty,
          ext.count <= 16,
          ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    else {
      return ""
    }
    return ext
  }

  private static func isContained(_ url: URL, in root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private static func isOutOfSpace(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
      || (error.domain == NSPOSIXErrorDomain && error.code == 28)
  }
}
