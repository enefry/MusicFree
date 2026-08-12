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
    private struct Entry: Codable, Equatable, Sendable {
        let relativePath: String
        let fileSize: Int
        let modificationDate: Date?
    }

    private struct Snapshot: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let entries: [Entry]

        init(entries: [Entry]) {
            self.schemaVersion = 1
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

        for try await event in stream {
            switch event {
            case .completed(_, let result), .cancelled(_, let result):
                terminalResult = result
            case .discovered, .hashing, .probing, .copying, .persisting, .itemFailed:
                break
            }
        }

        guard let terminalResult else {
            throw AppDocumentsScannerError.scanEndedWithoutResult
        }
        guard !terminalResult.isCancelled else { return terminalResult }

        // Keep failed inputs eligible for the next refresh. A directory snapshot
        // is only complete when every discovered item was handled successfully
        // (duplicates/skips are terminal, but failed files need another chance).
        guard terminalResult.failed == 0 else { return terminalResult }

        recordCompletedSnapshot(snapshot)
        return terminalResult
    }

    private func restoreSnapshotIfNeeded() {
        guard !didRestoreSnapshot else { return }
        didRestoreSnapshot = true
        guard let snapshotURL,
              let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.schemaVersion == 1
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
