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

@Test("Metadata enrichment records keep providers isolated for one item")
func metadataEnrichmentRecordsAreScopedToProvider() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("musicfree-metadata-provider-scope-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("metadata-enrichment.json")
    let itemID = MediaItemID(sourceID: .local, externalID: "shared-item")
    let musicKitRecord = MetadataEnrichmentRecord(
        itemID: itemID,
        provider: .musicKit,
        queryFingerprint: "music-kit",
        status: .noMatch
    )
    let serverRecord = MetadataEnrichmentRecord(
        itemID: itemID,
        provider: .metadataServer,
        queryFingerprint: "metadata-server",
        status: .matched
    )

    let repository = FileMetadataEnrichmentRecordRepository(fileURL: fileURL)
    try await repository.save(musicKitRecord)
    try await repository.save(serverRecord)

    #expect(try await repository.records() == [serverRecord, musicKitRecord])
    #expect(try await repository.record(
        for: itemID,
        provider: .musicKit
    ) == musicKitRecord)
    #expect(try await repository.record(
        for: itemID,
        provider: .metadataServer
    ) == serverRecord)

    try await repository.remove(itemID: itemID, provider: .musicKit)
    #expect(try await repository.record(
        for: itemID,
        provider: .musicKit
    ) == nil)
    #expect(try await repository.record(
        for: itemID,
        provider: .metadataServer
    ) == serverRecord)
}

@Test("Version 1 metadata records migrate to MusicKit provider state")
func metadataEnrichmentRecordsMigrateVersionOne() async throws {
    struct LegacyRecord: Encodable {
        let itemID: MediaItemID
        let queryFingerprint: String
        let catalogID: String?
        let candidateCount: Int?
        let status: MetadataEnrichmentRecordStatus
        let attemptCount: Int
        let lastAttemptAt: Date?
        let nextRetryAt: Date?
        let updatedFields: Set<MetadataEnrichmentField>
        let lastErrorCode: String?
        let lastHTTPStatus: Int?
    }

    struct Envelope: Encodable {
        let version: Int
        let records: [LegacyRecord]
    }

    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("musicfree-metadata-v1-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("metadata-enrichment.json")
    let itemID = MediaItemID(sourceID: .local, externalID: "legacy-item")
    let legacyRecord = LegacyRecord(
        itemID: itemID,
        queryFingerprint: "legacy-fingerprint",
        catalogID: "legacy-catalog",
        candidateCount: 1,
        status: .matched,
        attemptCount: 1,
        lastAttemptAt: nil,
        nextRetryAt: nil,
        updatedFields: [.title],
        lastErrorCode: nil,
        lastHTTPStatus: nil
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(Envelope(version: 1, records: [legacyRecord])).write(to: fileURL)

    let repository = FileMetadataEnrichmentRecordRepository(fileURL: fileURL)
    let migrated = try #require(try await repository.record(for: itemID))
    #expect(migrated.provider == .musicKit)
    #expect(migrated.queryFingerprint == "legacy-fingerprint")
    #expect(migrated.updatedFields == [.title])
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
