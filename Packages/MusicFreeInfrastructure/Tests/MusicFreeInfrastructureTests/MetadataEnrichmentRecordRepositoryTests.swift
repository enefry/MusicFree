import Foundation
import LibraryAPI
import MusicDomain
import Testing

@testable import LibraryPersistenceAdapter

@Test("Metadata enrichment records persist independently from the SwiftData store")
func metadataEnrichmentRecordsRoundTripAcrossRepositoryInstances() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("musicfree-metadata-record-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("metadata-enrichment.json")
    let itemID = MediaItemID(sourceID: .local, externalID: "record-track")
    let record = MetadataEnrichmentRecord(
        itemID: itemID,
        queryFingerprint: "fingerprint",
        catalogID: "catalog-id",
        candidateCount: 2,
        status: .matched,
        attemptCount: 2,
        updatedFields: [.title, .artwork]
    )

    let first = FileMetadataEnrichmentRecordRepository(fileURL: fileURL)
    try await first.save(record)

    let second = FileMetadataEnrichmentRecordRepository(fileURL: fileURL)
    #expect(try await second.record(for: itemID) == record)
    #expect(try await second.records() == [record])
}

@Test("Metadata enrichment records reject duplicate item IDs without crashing")
func metadataEnrichmentRecordsRejectDuplicateItemIDs() async throws {
    struct Envelope: Encodable {
        let version: Int
        let records: [MetadataEnrichmentRecord]
    }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("musicfree-metadata-duplicate-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("metadata-enrichment.json")
    let record = MetadataEnrichmentRecord(
        itemID: MediaItemID(sourceID: .local, externalID: "duplicate-track"),
        queryFingerprint: "fingerprint",
        status: .failed
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Envelope(version: 1, records: [record, record]))
        .write(to: fileURL)

    let repository = FileMetadataEnrichmentRecordRepository(fileURL: fileURL)
    await #expect(throws: LibraryPersistenceError.corruptedRecord) {
        try await repository.records()
    }
}
