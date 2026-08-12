import Foundation
import SettingsAPI

@available(macOS 13.0, iOS 16.0, *)
internal struct SettingsEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let payload: Data
    let integrity: UInt64?

    init(schemaVersion: Int, payload: Data, integrity: UInt64? = nil) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.integrity = integrity
    }

    static func integrity(for payload: Data) -> UInt64 {
        // A deterministic checksum detects accidental/truncated preference
        // data without introducing a cryptographic dependency for settings.
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in payload {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return value
    }

    static func current(for settings: AppSettings, encoder: JSONEncoder) throws -> Self {
        let payload = try encoder.encode(settings)
        return Self(
            schemaVersion: AppSettings.currentSchemaVersion,
            payload: payload,
            integrity: Self.integrity(for: payload)
        )
    }
}
