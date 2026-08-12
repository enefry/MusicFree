import Foundation
import SettingsAPI

@available(macOS 13.0, iOS 16.0, *)
internal enum SettingsMigration {
    static func encode(_ settings: AppSettings) throws -> Data {
        let validated = try settings.validated()
        let encoder = JSONEncoder()
        let envelope = try SettingsEnvelope.current(for: validated, encoder: encoder)
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> AppSettings {
        if let envelope = try decodeEnvelopeIfPresent(from: data) {
            guard (0...AppSettings.currentSchemaVersion).contains(envelope.schemaVersion) else {
                throw SettingsError.unsupportedSchemaVersion(
                    found: envelope.schemaVersion,
                    current: AppSettings.currentSchemaVersion
                )
            }

            if let integrity = envelope.integrity {
                guard integrity == SettingsEnvelope.integrity(for: envelope.payload) else {
                    throw SettingsError.decoding
                }
            } else if envelope.schemaVersion >= AppSettings.currentSchemaVersion {
                // Current envelopes must carry integrity metadata. Version 0
                // remains readable for the initial migration path.
                throw SettingsError.decoding
            }

            return try decodePayload(envelope.payload)
        }

        // The first adapter release also accepts the pre-envelope payload as
        // schema 0. It is upgraded in memory and never rewritten by load().
        return try decodePayload(data)
    }

    private static func decodePayload(_ data: Data) throws -> AppSettings {
        do {
            let settings = try JSONDecoder().decode(AppSettings.self, from: data)
            return try settings.validated()
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.decoding
        }
    }

    private static func decodeEnvelopeIfPresent(from data: Data) throws -> SettingsEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            return nil
        }

        // A raw AppSettings payload can contain schemaVersion but never
        // payload/integrity. This keeps the legacy fallback unambiguous.
        guard root["payload"] != nil || root["integrity"] != nil else {
            return nil
        }

        let schemaVersion = try decodeInteger(root["schemaVersion"]) ?? 0
        guard (0...AppSettings.currentSchemaVersion).contains(schemaVersion) else {
            throw SettingsError.unsupportedSchemaVersion(
                found: schemaVersion,
                current: AppSettings.currentSchemaVersion
            )
        }

        guard let payloadObject = root["payload"] else {
            throw SettingsError.decoding
        }

        let payload: Data
        if let encodedPayload = payloadObject as? String {
            guard let decodedPayload = Data(base64Encoded: encodedPayload) else {
                throw SettingsError.decoding
            }
            payload = decodedPayload
        } else if JSONSerialization.isValidJSONObject(payloadObject) {
            do {
                payload = try JSONSerialization.data(withJSONObject: payloadObject)
            } catch {
                throw SettingsError.decoding
            }
        } else {
            throw SettingsError.decoding
        }

        let integrity = try decodeUnsignedInteger(root["integrity"])
        return SettingsEnvelope(
            schemaVersion: schemaVersion,
            payload: payload,
            integrity: integrity
        )
    }

    private static func decodeInteger(_ value: Any?) throws -> Int? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int.min),
              number.doubleValue <= Double(Int.max)
        else {
            throw SettingsError.decoding
        }
        return number.intValue
    }

    private static func decodeUnsignedInteger(_ value: Any?) throws -> UInt64? {
        guard let value else { return nil }
        guard let number = value as? NSNumber,
              number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt64.max)
        else {
            throw SettingsError.decoding
        }
        return number.uint64Value
    }
}
