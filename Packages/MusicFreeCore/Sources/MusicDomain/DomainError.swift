import Foundation

/// Redacted, structured diagnostic context safe to carry across API boundaries.
public struct DiagnosticContext: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let code: String
    public let operation: String?
    public let sourceID: MediaSourceID?
    public let itemID: MediaItemID?

    public init(
        code: String,
        operation: String? = nil,
        sourceID: MediaSourceID? = nil,
        itemID: MediaItemID? = nil
    ) {
        self.code = musicDomainRequiredText(code, field: "DiagnosticContext.code")
        self.operation = musicDomainDiagnosticText(operation)
        self.sourceID = sourceID
        self.itemID = itemID
    }

    public var description: String {
        var fields = ["code: \(musicDomainDisplayToken(code))"]
        if let operation {
            fields.append("operation: \(musicDomainDisplayToken(operation))")
        }
        if let sourceID {
            fields.append("source: \(sourceID)")
        }
        if let itemID {
            fields.append("item: \(itemID)")
        }
        return "DiagnosticContext(\(fields.joined(separator: ", ")))"
    }
}

/// Categorized errors owned by the domain layer rather than a third-party adapter.
public enum MusicDomainError: Error, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    case invalidValue(field: String, context: DiagnosticContext?)
    case missingMetadata(field: String, context: DiagnosticContext?)
    case unsupportedMedia(context: DiagnosticContext?)
    case corruptedData(context: DiagnosticContext?)
    case resourceUnavailable(context: DiagnosticContext?)
    case conflict(context: DiagnosticContext?)
    case cancelled
    case unknown(code: String, context: DiagnosticContext?)

    public var isRetryable: Bool {
        switch self {
        case .resourceUnavailable, .conflict, .unknown:
            return true
        case .invalidValue, .missingMetadata, .unsupportedMedia, .corruptedData, .cancelled:
            return false
        }
    }

    public var isCancellation: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }

    public var diagnosticContext: DiagnosticContext? {
        switch self {
        case .invalidValue(_, let context),
             .missingMetadata(_, let context),
             .unsupportedMedia(let context),
             .corruptedData(let context),
             .resourceUnavailable(let context),
             .conflict(let context),
             .unknown(_, let context):
            return context
        case .cancelled:
            return nil
        }
    }

    public var userMessage: String {
        switch self {
        case .invalidValue(let field, _):
            return "The value for \(musicDomainDisplayToken(field)) is invalid."
        case .missingMetadata(let field, _):
            return "Required metadata is missing: \(musicDomainDisplayToken(field))."
        case .unsupportedMedia:
            return "This media is not supported."
        case .corruptedData:
            return "The saved media data is corrupted."
        case .resourceUnavailable:
            return "The media resource is temporarily unavailable."
        case .conflict:
            return "The media library changed before this operation finished."
        case .cancelled:
            return "The operation was cancelled."
        case .unknown:
            return "The media operation could not be completed."
        }
    }

    public var description: String {
        if let context = diagnosticContext {
            return "MusicDomainError(\(userMessage), \(context))"
        }
        return "MusicDomainError(\(userMessage))"
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case field
        case code
        case context
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invalidValue(let field, let context):
            try container.encode("invalidValue", forKey: .kind)
            try container.encode(musicDomainDisplayToken(field), forKey: .field)
            try container.encodeIfPresent(context, forKey: .context)
        case .missingMetadata(let field, let context):
            try container.encode("missingMetadata", forKey: .kind)
            try container.encode(musicDomainDisplayToken(field), forKey: .field)
            try container.encodeIfPresent(context, forKey: .context)
        case .unsupportedMedia(let context):
            try container.encode("unsupportedMedia", forKey: .kind)
            try container.encodeIfPresent(context, forKey: .context)
        case .corruptedData(let context):
            try container.encode("corruptedData", forKey: .kind)
            try container.encodeIfPresent(context, forKey: .context)
        case .resourceUnavailable(let context):
            try container.encode("resourceUnavailable", forKey: .kind)
            try container.encodeIfPresent(context, forKey: .context)
        case .conflict(let context):
            try container.encode("conflict", forKey: .kind)
            try container.encodeIfPresent(context, forKey: .context)
        case .cancelled:
            try container.encode("cancelled", forKey: .kind)
        case .unknown(let code, let context):
            try container.encode("unknown", forKey: .kind)
            try container.encode(musicDomainDisplayToken(code), forKey: .code)
            try container.encodeIfPresent(context, forKey: .context)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let context = try container.decodeIfPresent(DiagnosticContext.self, forKey: .context)

        switch kind {
        case "invalidValue":
            self = .invalidValue(
                field: try container.decode(String.self, forKey: .field),
                context: context
            )
        case "missingMetadata":
            self = .missingMetadata(
                field: try container.decode(String.self, forKey: .field),
                context: context
            )
        case "unsupportedMedia":
            self = .unsupportedMedia(context: context)
        case "corruptedData":
            self = .corruptedData(context: context)
        case "resourceUnavailable":
            self = .resourceUnavailable(context: context)
        case "conflict":
            self = .conflict(context: context)
        case "cancelled":
            self = .cancelled
        case "unknown":
            self = .unknown(
                code: try container.decode(String.self, forKey: .code),
                context: context
            )
        default:
            self = .unknown(code: kind, context: context)
        }
    }
}
