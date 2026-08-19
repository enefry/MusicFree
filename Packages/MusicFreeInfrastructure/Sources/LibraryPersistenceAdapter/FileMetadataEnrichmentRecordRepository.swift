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

    private struct RecordKey: Hashable {
        let itemID: MediaItemID
        let provider: MetadataProviderID
    }

    private let fileURL: URL?
    private var loaded = false
    private var values: [RecordKey: MetadataEnrichmentRecord] = [:]

    /// Pass nil for an in-memory repository, which is useful for previews and
    /// unit tests.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    public func record(for itemID: MediaItemID) async throws -> MetadataEnrichmentRecord? {
        try loadIfNeeded()
        return values.values
            .filter { $0.itemID == itemID }
            .sorted { $0.provider < $1.provider }
            .first
    }

    public func record(
        for itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws -> MetadataEnrichmentRecord? {
        try loadIfNeeded()
        return values.values.first {
            $0.itemID == itemID && $0.provider == provider
        }
    }

    public func records() async throws -> [MetadataEnrichmentRecord] {
        try loadIfNeeded()
        return values.values.sorted {
            if $0.itemID != $1.itemID { return $0.itemID < $1.itemID }
            return $0.provider < $1.provider
        }
    }

    public func records(
        for provider: MetadataProviderID
    ) async throws -> [MetadataEnrichmentRecord] {
        try loadIfNeeded()
        return values.values
            .filter { $0.provider == provider }
            .sorted { $0.itemID < $1.itemID }
    }

    public func save(_ record: MetadataEnrichmentRecord) async throws {
        try loadIfNeeded()
        values[RecordKey(itemID: record.itemID, provider: record.provider)] = record
        try persist()
    }

    public func remove(itemID: MediaItemID) async throws {
        try loadIfNeeded()
        let keys = values.keys.filter { $0.itemID == itemID }
        guard !keys.isEmpty else { return }
        for key in keys {
            values.removeValue(forKey: key)
        }
        try persist()
    }

    public func remove(
        itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws {
        try loadIfNeeded()
        let keys = values.keys.filter {
            $0.itemID == itemID && $0.provider == provider
        }
        guard !keys.isEmpty else { return }
        for key in keys {
            values.removeValue(forKey: key)
        }
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
            guard (1...2).contains(envelope.version) else {
                throw LibraryPersistenceError.migrationFailed(version: envelope.version)
            }
            var decodedValues: [RecordKey: MetadataEnrichmentRecord] = [:]
            decodedValues.reserveCapacity(envelope.records.count)
            for record in envelope.records {
                let key = RecordKey(itemID: record.itemID, provider: record.provider)
                guard decodedValues.updateValue(record, forKey: key) == nil else {
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
                version: 2,
                records: values.values.sorted {
                    if $0.itemID != $1.itemID { return $0.itemID < $1.itemID }
                    return $0.provider < $1.provider
                }
            ))
            try data.write(to: fileURL, options: .atomic)
        } catch let error as LibraryPersistenceError {
            throw error
        } catch {
            throw LibraryPersistenceError.encodingFailed
        }
    }
}
