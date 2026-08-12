import Foundation
import SwiftData

@Model
final class StoreMetadataRecord {
    @Attribute(.unique) var storageKey: String
    var revision: Int64
    var appliedTransactionKeys: Data

    init(storageKey: String, revision: Int64, appliedTransactionKeys: Data) {
        self.storageKey = storageKey
        self.revision = revision
        self.appliedTransactionKeys = appliedTransactionKeys
    }
}
