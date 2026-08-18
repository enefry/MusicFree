import Foundation
import LibraryAPI
import MusicDomain

/// Independent Codable storage for enrichment state. Keeping this outside the
/// SwiftData schema lets the 1.0 library store reopen without a migration.
public actor FileMetadataEnrichmentRecordRepository: MetadataEnrichmentRecordRepository {
    private struct Envelope: Codable {
        let version: Int
        let records: [MetadataEnrichmentRecord]
    }

    private let fileURL: URL?
    private var loaded = false
    private var values: [MediaItemID: MetadataEnrichmentRecord] = [:]

    /// Pass nil for an in-memory repository, which is useful for previews and
    /// unit tests.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    public func record(for itemID: MediaItemID) throws -> MetadataEnrichmentRecord? {
        try loadIfNeeded()
        return values[itemID]
    }

    public func records() throws -> [MetadataEnrichmentRecord] {
        try loadIfNeeded()
        return values.values.sorted { $0.itemID < $1.itemID }
    }

    public func save(_ record: MetadataEnrichmentRecord) throws {
        try loadIfNeeded()
        values[record.itemID] = record
        try persist()
    }

    public func remove(itemID: MediaItemID) throws {
        try loadIfNeeded()
        guard values.removeValue(forKey: itemID) != nil else { return }
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        guard let fileURL else {
            loaded = true
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loaded = true
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.version == 1 else {
                throw LibraryPersistenceError.migrationFailed(version: envelope.version)
            }
            var decodedValues: [MediaItemID: MetadataEnrichmentRecord] = [:]
            decodedValues.reserveCapacity(envelope.records.count)
            for record in envelope.records {
                guard decodedValues.updateValue(record, forKey: record.itemID) == nil else {
                    throw LibraryPersistenceError.corruptedRecord
                }
            }
            values = decodedValues
            loaded = true
        } catch let error as LibraryPersistenceError {
            throw error
        } catch {
            throw LibraryPersistenceError.corruptedRecord
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(Envelope(
                version: 1,
                records: values.values.sorted { $0.itemID < $1.itemID }
            ))
            try data.write(to: fileURL, options: .atomic)
        } catch let error as LibraryPersistenceError {
            throw error
        } catch {
            throw LibraryPersistenceError.encodingFailed
        }
    }
}
