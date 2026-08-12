import Foundation

struct AppDiagnosticEntry: Codable, Equatable, Identifiable, Sendable {
    let sequence: Int
    let code: String
    let message: String
    let timestamp: Date

    var id: Int { sequence }
}

struct AppDiagnosticsReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let entries: [AppDiagnosticEntry]
}

@MainActor
final class AppDiagnosticsExporter {
    private let now: @Sendable () -> Date
    private(set) var entries: [AppDiagnosticEntry] = []

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func record(startupState: AppStartupState) {
        for issue in startupState.issues {
            record(code: issue.diagnosticCode, message: issue.message)
        }
    }

    func record(_ issue: AppStartupIssue, detail: String? = nil) {
        record(code: issue.diagnosticCode, message: detail ?? issue.message)
    }

    func record(code: String, message: String) {
        let entry = AppDiagnosticEntry(
            sequence: entries.count,
            code: Self.sanitizeCode(code),
            message: Self.sanitize(message),
            timestamp: now()
        )
        entries.append(entry)
    }

    func report() -> AppDiagnosticsReport {
        AppDiagnosticsReport(
            schemaVersion: 1,
            generatedAt: now(),
            entries: entries
        )
    }

    /// Creates export data only when a user-facing export action calls it.
    /// No file, share sheet, or network operation is performed here.
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report())
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private static func sanitizeCode(_ code: String) -> String {
        let normalized = code.map { character in
            character.isLetter || character.isNumber || ".-_".contains(character)
                ? character
                : "-"
        }
        let value = String(normalized.prefix(80))
        return value.isEmpty ? "app.unknown" : value
    }

    private static func sanitize(_ message: String) -> String {
        let patterns: [(String, String)] = [
            (#"(?i)\bBearer\s+[^\s,;]+"#, "Bearer <redacted>"),
            (#"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie)\s*[:=]\s*[^\r\n]+"#, "<redacted-header>"),
            (#"(?i)(?:file://)?/(?:Users|private|var|tmp|Volumes)/[^\r\n\s]+"#, "<redacted-path>"),
            (#"(?i)[?&](?:token|access_token|authorization|signature|secret|password|api[_-]?key)=[^&\s]+"#, "<redacted-query>"),
            (#"(?i)\b(?:password|secret|token|access_token|api[_-]?key)\s*[:=]\s*[^\s,;]+"#, "<redacted-value>")
        ]

        let sanitized = patterns.reduce(message) { value, pattern in
            value.replacingOccurrences(
                of: pattern.0,
                with: pattern.1,
                options: .regularExpression
            )
        }
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? "No diagnostic details were provided."
            : String(trimmed.prefix(512))
    }
}
