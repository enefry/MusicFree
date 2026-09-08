import Foundation

/// The result of one persisted-library metadata repair pass.
public struct LibraryMetadataRepairResult: Codable, Equatable, Sendable {
    public let scannedRecordCount: Int
    public let repairedRecordCount: Int
    public let revision: LibraryRevision

    public init(
        scannedRecordCount: Int = 0,
        repairedRecordCount: Int = 0,
        revision: LibraryRevision = .initial
    ) {
        self.scannedRecordCount = scannedRecordCount
        self.repairedRecordCount = repairedRecordCount
        self.revision = revision
    }

    public var didRepair: Bool {
        repairedRecordCount > 0
    }
}
