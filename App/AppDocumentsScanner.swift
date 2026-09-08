import AppServices
import Foundation
import MediaSourceAPI

enum AppDocumentsScannerError: Error, LocalizedError, Sendable {
    case documentsUnavailable
    case scanEndedWithoutResult

    var errorDescription: String? {
        switch self {
        case .documentsUnavailable:
            "The shared Documents directory could not be scanned."
        case .scanEndedWithoutResult:
            "The Documents import ended without a result."
        }
    }
}

/// Detects Finder/iTunes file-sharing changes and feeds Documents through the
/// same import boundary used by the document picker.
actor AppDocumentsScanner {
    private static let snapshotSchemaVersion = 3
    static let automaticImportPlaceholderFileName = "put_music_file_here_to_auto_import.txt"
    private static let ignoredFileNames: Set<String> = [
        automaticImportPlaceholderFileName,
    ]

    private struct Entry: Codable, Equatable, Sendable {
        let relativePath: String
        let fileSize: Int
        let modificationDate: Date?
    }

    private struct Snapshot: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let entries: [Entry]

        init(entries: [Entry]) {
            self.schemaVersion = AppDocumentsScanner.snapshotSchemaVersion
            self.entries = entries
        }
    }

    private let documentsURL: URL
    private let snapshotURL: URL?
    private let importer: any ImportServing
    private let fileManager: FileManager

    private var lastCompletedSnapshot: Snapshot?
    private var didRestoreSnapshot = false
    private var activeScanTask: Task<MediaImportResult?, Error>?

    init(
        documentsURL: URL,
        snapshotURL: URL? = nil,
        importer: any ImportServing,
        fileManager: FileManager = .default
    ) {
        self.documentsURL = documentsURL.standardizedFileURL
        self.snapshotURL = snapshotURL?.standardizedFileURL
        self.importer = importer
        self.fileManager = fileManager
    }

    /// Returns a terminal result only when the directory changed and an import ran.
    func scanIfNeeded(force: Bool = false) async throws -> MediaImportResult? {
        if let activeScanTask {
            return try await activeScanTask.value
        }

        let task = Task { [self] in
            try await performScan(force: force)
        }
        activeScanTask = task

        do {
            let result = try await task.value
            activeScanTask = nil
            return result
        } catch {
            activeScanTask = nil
            throw error
        }
    }

    private func performScan(force: Bool) async throws -> MediaImportResult? {
        restoreSnapshotIfNeeded()
        let snapshot = try makeSnapshot()
        guard force || snapshot != lastCompletedSnapshot else { return nil }

        guard !snapshot.entries.isEmpty else {
            recordCompletedSnapshot(snapshot)
            return nil
        }

        let request = MediaImportRequest(
            importID: UUID(),
            urls: [documentsURL],
            // Documents uses the same content-addressed first-version import
            // policy as the picker: existing hashes are skipped.
            duplicatePolicy: .skip
        )
        let stream = try await importer.start(request)
        var terminalResult: MediaImportResult?
        var discoveredMedia = false
        var itemFailures: [(url: URL, error: MediaImportError)] = []

        for try await event in stream {
            switch event {
            case .completed(_, let result), .cancelled(_, let result):
                terminalResult = result
            case .discovered:
                discoveredMedia = true
            case .itemFailed(_, let url, let error):
                itemFailures.append((url, error))
            case .hashing, .probing, .copying, .persisting, .confirmationRequired:
                break
            }
        }

        guard let terminalResult else {
            throw AppDocumentsScannerError.scanEndedWithoutResult
        }
        guard !terminalResult.isCancelled else { return terminalResult }

        // A Documents folder that contains only known sidecars or artwork is
        // not a failed media import. The local importer reports the directory
        // itself as unsupported without discovering an item; record that
        // snapshot so the automatic scanner waits for a real file change.
        if Self.isNonMediaOnlyDirectory(
            snapshot: snapshot,
            documentsURL: documentsURL,
            result: terminalResult,
            discoveredMedia: discoveredMedia,
            itemFailures: itemFailures
        ) {
            recordCompletedSnapshot(snapshot)
            return nil
        }

        // Keep failed inputs eligible for the next refresh. A directory snapshot
        // is only complete when every discovered item was handled successfully
        // (duplicates/skips are terminal, but failed files need another chance).
        guard terminalResult.failed == 0 else { return terminalResult }

        recordCompletedSnapshot(snapshot)
        return terminalResult
    }

    private static func isNonMediaOnlyDirectory(
        snapshot: Snapshot,
        documentsURL: URL,
        result: MediaImportResult,
        discoveredMedia: Bool,
        itemFailures: [(url: URL, error: MediaImportError)]
    ) -> Bool {
        guard !discoveredMedia,
              result.imported == 0,
              result.duplicate == 0,
              result.skipped == 0,
              result.failed == 1,
              result.cancelled == 0,
              itemFailures.count == 1,
              itemFailures[0].error == .unsupportedFormat,
              itemFailures[0].url.standardizedFileURL == documentsURL,
              !snapshot.entries.contains(where: {
                  URL(fileURLWithPath: $0.relativePath)
                      .pathExtension
                      .caseInsensitiveCompare("cue") == .orderedSame
              })
        else {
            return false
        }
        return true
    }

    private func restoreSnapshotIfNeeded() {
        guard !didRestoreSnapshot else { return }
        didRestoreSnapshot = true
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == Self.snapshotSchemaVersion
        else {
            return
        }
        lastCompletedSnapshot = snapshot
    }

    private func recordCompletedSnapshot(_ snapshot: Snapshot) {
        lastCompletedSnapshot = snapshot
        guard let snapshotURL,
              let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }

        let parent = snapshotURL.deletingLastPathComponent()
        guard (try? fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )) != nil else {
            return
        }
        try? data.write(to: snapshotURL, options: .atomic)
    }

    private func makeSnapshot() throws -> Snapshot {
        do {
            try fileManager.createDirectory(
                at: documentsURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw AppDocumentsScannerError.documentsUnavailable
        }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: documentsURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw AppDocumentsScannerError.documentsUnavailable
        }

        let rootPath = documentsURL.path
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                throw AppDocumentsScannerError.documentsUnavailable
            }

            if values.isSymbolicLink == true || values.isHidden == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard !Self.ignoredFileNames.contains(url.lastPathComponent) else { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            entries.append(
                Entry(
                    relativePath: String(path.dropFirst(rootPath.count + 1)),
                    fileSize: values.fileSize ?? 0,
                    modificationDate: values.contentModificationDate
                )
            )
        }

        entries.sort { $0.relativePath < $1.relativePath }
        return Snapshot(entries: entries)
    }
}
