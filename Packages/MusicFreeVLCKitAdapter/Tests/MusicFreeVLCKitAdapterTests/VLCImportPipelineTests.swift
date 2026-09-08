import Foundation
import LibraryAPI
import LibraryPersistenceAdapter
import LocalMediaAdapter
import MediaSourceAPI
import MusicDomain
import Testing
@testable import VLCKitPlaybackAdapter

struct VLCImportPipelineTests {
  @Test("Real VLCKit importer reports the failing ALAC file and import stage")
  func importWorkspaceALAC() async throws {
    let sourceURL = try importSourceURL()

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MusicFree-VLCImport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try LocalMediaConfiguration(
      managedRoot: root.appendingPathComponent("managed", isDirectory: true),
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
    )
    let vlcConfiguration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.import-probe",
      applicationVersion: "1.0",
      applicationName: "MusicFree Import Probe",
      parserTimeout: .seconds(15)
    )
    let importer = try LocalMediaImporter(
      configuration: configuration,
      probe: VLCMediaProbe(configuration: vlcConfiguration),
      metadataReader: VLCMetadataReader(configuration: vlcConfiguration),
      libraryRepository: RecordingLibraryRepository()
    )

    let request = MediaImportRequest(importID: UUID(), urls: [sourceURL])
    var events: [MediaImportEvent] = []
    print("REAL_VLC_IMPORT_SOURCE source=\(sourceURL.path)")
    do {
      for try await event in importer.importMedia(request) {
        events.append(event)
        print("REAL_VLC_IMPORT_EVENT \(event)")
      }
    } catch {
      print("REAL_VLC_IMPORT_STREAM_FAILURE error=\(String(reflecting: error))")
      throw error
    }

    let failures = events.compactMap { event -> (URL, MediaImportError)? in
      guard case .itemFailed(_, let url, let error) = event else { return nil }
      return (url, error)
    }
    for (url, error) in failures {
      print(
        "REAL_VLC_IMPORT_FAILURE file=\(url.lastPathComponent) "
          + "code=\(error.diagnosticCode) reason=\(error.localizedDescription)"
      )
    }
    let failureDescription = failures
      .map { "\($0.0.lastPathComponent):\($0.1.diagnosticCode)" }
      .joined(separator: ",")
    if case .completed(_, let result) = events.last {
      print(
        "REAL_VLC_IMPORT_RESULT imported=\(result.imported) duplicate=\(result.duplicate) "
          + "skipped=\(result.skipped) failed=\(result.failed)"
      )
      #expect(
        result.imported == 1 && result.failed == 0,
        "source=\(sourceURL.path) failures=\(failureDescription)"
      )
    }
    #expect(events.contains { event in
      if case .completed = event { return true }
      return false
    })
  }

  @Test("Real VLCKit importer with the production SwiftData repository")
  func importWorkspaceALACWithSwiftData() async throws {
    let sourceURL = try importSourceURL()

    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MusicFree-VLC-SwiftDataImport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = try LocalMediaConfiguration(
      managedRoot: root.appendingPathComponent("managed", isDirectory: true),
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
    )
    let vlcConfiguration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.import-swiftdata-probe",
      applicationVersion: "1.0",
      applicationName: "MusicFree SwiftData Import Probe",
      parserTimeout: .seconds(30)
    )
    let persistenceStore = try LibraryPersistenceStore(configuration: .inMemory)
    let importer = try LocalMediaImporter(
      configuration: configuration,
      probe: VLCMediaProbe(configuration: vlcConfiguration),
      metadataReader: VLCMetadataReader(configuration: vlcConfiguration),
      libraryRepository: SwiftDataLibraryRepository(store: persistenceStore)
    )

    let request = MediaImportRequest(importID: UUID(), urls: [sourceURL])
    var events: [MediaImportEvent] = []
    for try await event in importer.importMedia(request) {
      events.append(event)
    }
    let result = events.compactMap { event -> MediaImportResult? in
      guard case .completed(_, let result) = event else { return nil }
      return result
    }.last
    let failures = events.compactMap { event -> String? in
      guard case .itemFailed(_, let url, let error) = event else { return nil }
      return "\(url.path):\(error.diagnosticCode)"
    }
    print(
      "REAL_VLC_SWIFTDATA_IMPORT source=\(sourceURL.path) "
        + "result=\(String(describing: result)) failures=\(failures)"
    )
    #expect(result?.imported == 1, "failures=\(failures)")
    #expect(result?.failed == 0, "failures=\(failures)")
  }

  @Test(
    "Probe every audio file in the user's Music folder with the real VLCKit",
    .enabled(if: ProcessInfo.processInfo.environment["MUSICFREE_RUN_USER_MUSIC_DIAGNOSTICS"] == "1")
  )
  func probeUserMusicFolder() async throws {
    let root = try userMusicFolderURL()
    let files = try audioFiles(in: root)
    let configuration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.folder-probe",
      applicationVersion: "1.0",
      applicationName: "MusicFree Folder Probe",
      parserTimeout: .seconds(30)
    )
    let probe = try VLCMediaProbe(configuration: configuration)
    let metadataReader = try VLCMetadataReader(configuration: configuration)

    var failures: [String] = []
    for (index, url) in files.enumerated() {
      print("REAL_VLC_FOLDER_FILE index=\(index + 1)/\(files.count) file=\(url.path)")
      do {
        let result = try await probe.probe(.local(url)).validated()
        print(
          "REAL_VLC_FOLDER_PROBE status=success file=\(url.lastPathComponent) "
            + "tracks=\(result.audioTracks.count) hasVideo=\(result.hasVideoTrack)"
        )
      } catch {
        failures.append("probe|\(url.path)|\(String(reflecting: error))")
        continue
      }

      do {
        _ = try await metadataReader.readMetadata(from: .local(url))
        print("REAL_VLC_FOLDER_METADATA status=success file=\(url.lastPathComponent)")
      } catch {
        failures.append("metadata|\(url.path)|\(String(reflecting: error))")
      }
    }

    let report = [
      "count=\(files.count)",
      "failures=\(failures.count)",
      failures.joined(separator: "\n")
    ].joined(separator: "\n") + "\n"
    let reportURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MusicFree-vlc-folder-probe.txt")
    try Data(report.utf8).write(to: reportURL)
    #expect(
      failures.isEmpty,
      "folder probe failures=\(failures.count); report=\(reportURL.path)"
    )
  }

  @Test(
    "Run the complete local importer for the user's Music folder",
    .enabled(if: ProcessInfo.processInfo.environment["MUSICFREE_RUN_USER_MUSIC_DIAGNOSTICS"] == "1")
  )
  func importUserMusicFolder() async throws {
    let sourceURL = try userMusicFolderURL()
    let expectedImportCount = try audioFiles(in: sourceURL).count
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("MusicFree-VLCFolderImport-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let localConfiguration = try LocalMediaConfiguration(
      managedRoot: root.appendingPathComponent("managed", isDirectory: true),
      stagingRoot: root.appendingPathComponent("staging", isDirectory: true),
      quarantineRoot: root.appendingPathComponent("quarantine", isDirectory: true)
    )
    let vlcConfiguration = try VLCKitAdapterConfiguration(
      applicationIdentifier: "com.example.musicfree.folder-import",
      applicationVersion: "1.0",
      applicationName: "MusicFree Folder Import",
      parserTimeout: .seconds(15)
    )
    let recorder = StageFailureRecorder()
    let importer = try LocalMediaImporter(
      configuration: localConfiguration,
      probe: RecordingProbe(
        base: VLCMediaProbe(configuration: vlcConfiguration),
        recorder: recorder
      ),
      metadataReader: RecordingMetadataReader(
        base: VLCMetadataReader(configuration: vlcConfiguration),
        recorder: recorder
      ),
      libraryRepository: RecordingLibraryRepository()
    )

    let request = MediaImportRequest(importID: UUID(), urls: [sourceURL])
    var events: [MediaImportEvent] = []
    do {
      for try await event in importer.importMedia(request) {
        events.append(event)
      }
    } catch {
      print("REAL_VLC_FOLDER_IMPORT_STREAM_FAILURE error=\(String(reflecting: error))")
      throw error
    }

    let itemFailures = events.compactMap { event -> String? in
      guard case .itemFailed(_, let url, let error) = event else { return nil }
      return "item|\(url.path)|\(error.diagnosticCode)"
    }
    let stageFailures = await recorder.failures
    let result = events.compactMap { event -> MediaImportResult? in
      guard case .completed(_, let result) = event else { return nil }
      return result
    }.last
    let report = [
      "source=\(sourceURL.path)",
      "itemFailures=\(itemFailures.count)",
      itemFailures.joined(separator: "\n"),
      "stageFailures=\(stageFailures.count)",
      stageFailures.joined(separator: "\n"),
      "result=\(String(describing: result))"
    ].joined(separator: "\n") + "\n"
    let reportURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MusicFree-vlc-folder-import.txt")
    try Data(report.utf8).write(to: reportURL)
    #expect(
      result?.imported == expectedImportCount && result?.failed == 0,
      "folder import report=\(reportURL.path)"
    )
  }

  private func userMusicFolderURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    let path = try #require(environment["MUSICFREE_USER_MUSIC_PATH"])
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try #require(FileManager.default.fileExists(atPath: url.path))
    return url
  }

  private func importSourceURL() throws -> URL {
    if let path = ProcessInfo.processInfo.environment["MUSICFREE_VLC_SAMPLE_PATH"] {
      let url = URL(fileURLWithPath: path)
      try #require(FileManager.default.fileExists(atPath: url.path))
      return url
    }

    let workspaceRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent() // MusicFreeVLCKitAdapterTests
      .deletingLastPathComponent() // Tests
      .deletingLastPathComponent() // MusicFreeVLCKitAdapter
      .deletingLastPathComponent() // Packages
      .deletingLastPathComponent() // MusicPlayer
    let workspaceFiles = [
      "432Hz - Fall Into Dee_ Slee_ in 3 Minutes - Heal All Da__ge In The _ody and S_irit, Relieve Stress.m4a",
      "江山无限 《康熙微服私访记》主题曲.m4a",
    ].map { workspaceRoot.appendingPathComponent($0) }
    if let workspaceFile = workspaceFiles.first(where: {
      FileManager.default.fileExists(atPath: $0.path)
    }) {
      return workspaceFile
    }

    return try #require(Bundle.module.url(
      forResource: "reencoded",
      withExtension: "m4a",
      subdirectory: "Fixtures"
    ))
  }

  private func audioFiles(in root: URL) throws -> [URL] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isPackageKey]
    let enumerator = try #require(FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ))
    return enumerator.compactMap { element in
      guard let url = element as? URL,
            let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true,
            ["m4a", "mp3"].contains(url.pathExtension.lowercased())
      else { return nil }
      return url
    }.sorted { $0.path < $1.path }
  }
}

private actor StageFailureRecorder {
  private(set) var failures: [String] = []

  func record(stage: String, url: URL, error: Error) {
    failures.append("\(stage)|\(url.path)|\(String(reflecting: error))")
  }
}

private struct RecordingProbe: MediaProbing {
  let base: VLCMediaProbe
  let recorder: StageFailureRecorder

  func probe(_ resource: PlaybackResource) async throws -> MediaProbeResult {
    do {
      return try await base.probe(resource)
    } catch {
      if case .localFile(let url) = resource {
        await recorder.record(stage: "probe", url: url, error: error)
      }
      throw error
    }
  }
}

private struct RecordingMetadataReader: MetadataReading {
  let base: VLCMetadataReader
  let recorder: StageFailureRecorder

  func readMetadata(from resource: PlaybackResource) async throws -> RawMediaMetadata {
    do {
      return try await base.readMetadata(from: resource)
    } catch {
      if case .localFile(let url) = resource {
        await recorder.record(stage: "metadata", url: url, error: error)
      }
      throw error
    }
  }
}

private final class RecordingLibraryRepository: LibraryRepository, @unchecked Sendable {
  func track(id: MediaItemID) async throws -> Track? { nil }
  func album(id: AlbumID) async throws -> Album? { nil }
  func artist(id: ArtistID) async throws -> Artist? { nil }
  func artwork(id: ArtworkID) async throws -> ArtworkReference? { nil }

  func tracks(
    matching query: TrackQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: [])
  }

  func albums(
    matching query: AlbumQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Album> {
    LibraryPage(elements: [])
  }

  func artists(
    matching query: ArtistQuery,
    page: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    LibraryPage(elements: [])
  }

  func apply(_ transaction: LibraryTransaction) async throws {}
  func remove(_ itemIDs: Set<MediaItemID>) async throws {}
  func changes() -> AsyncStream<LibraryChange> {
    AsyncStream { continuation in continuation.finish() }
  }
}
