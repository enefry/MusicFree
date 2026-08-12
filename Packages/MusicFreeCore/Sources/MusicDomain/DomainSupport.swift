import Foundation

@inline(__always)
internal func musicDomainRequiredText(_ value: String, field: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(!normalized.isEmpty, "MusicDomain requires a non-empty \(field)")
    return normalized
}

internal func musicDomainOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}

@inline(__always)
internal func musicDomainIdentifier(_ value: String, typeName: String) -> String {
    precondition(!value.isEmpty, "\(typeName) cannot be empty")
    precondition(
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "\(typeName) cannot contain only whitespace"
    )
    return value
}

internal func musicDomainDecodedIdentifier(
    from decoder: Decoder,
    typeName: String
) throws -> String {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard !value.isEmpty,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Decoded \(typeName) cannot be empty"
        )
    }
    return value
}

internal func musicDomainEncodeIdentifier(_ value: String, to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
}

internal func musicDomainUnique<T: Hashable>(_ values: [T]) -> [T] {
    var seen = Set<T>()
    return values.filter { seen.insert($0).inserted }
}

internal func musicDomainNonNegative(_ value: Int, field: String) -> Int {
    precondition(value >= 0, "MusicDomain \(field) cannot be negative")
    return value
}

internal func musicDomainPositive(_ value: Int, field: String) -> Int {
    precondition(value > 0, "MusicDomain \(field) must be positive")
    return value
}

@available(macOS 13.0, *)
internal func musicDomainNonNegativeDuration(_ value: Duration, field: String) -> Duration {
    precondition(value >= .zero, "MusicDomain \(field) cannot be negative")
    return value
}

internal func musicDomainFingerprint(_ value: String) -> String {
    var hash: UInt64 = 14695981039346656037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1099511628211
    }

    let hexadecimal = String(hash, radix: 16)
    return String(repeating: "0", count: max(0, 16 - hexadecimal.count)) + hexadecimal
}

internal func musicDomainDisplayToken(_ value: String) -> String {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "<empty>" }

    let containsPathSyntax = normalized.contains("/")
        || normalized.contains("\\")
        || normalized.contains("://")
        || normalized.hasPrefix("~")

    if containsPathSyntax || normalized.count > 64 {
        return "id-\(musicDomainFingerprint(normalized))"
    }
    return normalized
}

internal func musicDomainDiagnosticText(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    return musicDomainDisplayToken(normalized)
}

internal func musicDomainDecodingFailure(_ decoder: Decoder, field: String) -> DecodingError {
    DecodingError.dataCorrupted(
        .init(
            codingPath: decoder.codingPath,
            debugDescription: "Invalid MusicDomain value for \(field)"
        )
    )
}
