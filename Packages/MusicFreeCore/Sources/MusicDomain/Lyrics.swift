import Foundation

/// One timestamped lyric line. Timestamps are kept in milliseconds so the
/// persisted value remains independent of a playback engine's clock type.
@available(macOS 13.0, iOS 16.0, *)
public struct LyricLine: Codable, Equatable, Hashable, Sendable {
    public let timestampMilliseconds: Int64
    public let text: String

    public init(timestampMilliseconds: Int64, text: String) {
        precondition(timestampMilliseconds >= 0, "LyricLine timestamp cannot be negative")
        self.timestampMilliseconds = timestampMilliseconds
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case timestampMilliseconds
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestampMilliseconds = try container.decode(Int64.self, forKey: .timestampMilliseconds)
        guard timestampMilliseconds >= 0 else {
            throw musicDomainDecodingFailure(decoder, field: "LyricLine.timestampMilliseconds")
        }
        self.init(
            timestampMilliseconds: timestampMilliseconds,
            text: try container.decode(String.self, forKey: .text)
        )
    }

    public var timestamp: Duration {
        .milliseconds(timestampMilliseconds)
    }
}

/// Offline lyrics stored with a local track. `rawText` is retained so a user
/// can edit or replace the original LRC/plain-text document without losing
/// metadata that the parser does not render.
@available(macOS 13.0, iOS 16.0, *)
public struct TrackLyrics: Codable, Equatable, Hashable, Sendable {
    public let rawText: String
    public let timedLines: [LyricLine]
    /// Offset declared by an LRC `[offset:]` tag, before the user's runtime offset.
    public let declaredOffsetMilliseconds: Int

    public init(rawText: String) {
        let lineNormalized = rawText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // UTF-8 LRC files commonly begin with a BOM. It is metadata about the
        // file encoding, not lyric text, so remove it only at the document start.
        let normalized = lineNormalized.first == "\u{FEFF}"
            ? String(lineNormalized.dropFirst())
            : lineNormalized
        let parsed = Self.parse(normalized)
        self.rawText = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timedLines = parsed.lines
        self.declaredOffsetMilliseconds = parsed.offsetMilliseconds
    }

    public init(
        rawText: String,
        timedLines: [LyricLine],
        declaredOffsetMilliseconds: Int = 0
    ) {
        self.rawText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timedLines = timedLines.sorted {
            if $0.timestampMilliseconds != $1.timestampMilliseconds {
                return $0.timestampMilliseconds < $1.timestampMilliseconds
            }
            return $0.text < $1.text
        }
        self.declaredOffsetMilliseconds = declaredOffsetMilliseconds
    }

    public var isEmpty: Bool {
        rawText.isEmpty
    }

    public var isTimed: Bool {
        !timedLines.isEmpty
    }

    public var displayText: String {
        if !timedLines.isEmpty {
            return timedLines.map(\.text).joined(separator: "\n")
        }
        return rawText
    }

    /// Returns the active line index for a playback position. A separate
    /// runtime offset lets users calibrate a file without rewriting lyrics.
    public func activeLineIndex(
        at position: Duration,
        runtimeOffsetMilliseconds: Int = 0
    ) -> Int? {
        guard !timedLines.isEmpty else { return nil }
        let positionMilliseconds = Self.milliseconds(from: position)
        // LRC offsets are stored as part of the file, while a positive runtime
        // offset means the user wants the displayed lyric to arrive earlier.
        let adjustment = Self.saturatedOffset(
            declared: declaredOffsetMilliseconds,
            runtime: runtimeOffsetMilliseconds
        )
        var activeIndex: Int?
        for (index, line) in timedLines.enumerated() {
            let (adjustedTimestamp, overflow) = line.timestampMilliseconds.addingReportingOverflow(adjustment)
            if overflow {
                if adjustment > 0 { break }
                activeIndex = index
                continue
            }
            guard adjustedTimestamp <= positionMilliseconds else { break }
            activeIndex = index
        }
        return activeIndex
    }

    private static func parse(_ text: String) -> (lines: [LyricLine], offsetMilliseconds: Int) {
        var lines: [LyricLine] = []
        var offsetMilliseconds = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var remainder = String(rawLine)
            var timestamps: [Int64] = []
            var consumedMetadata = false

            while remainder.first == "[",
                  let closingIndex = remainder.firstIndex(of: "]") {
                let tagStart = remainder.index(after: remainder.startIndex)
                let tag = String(remainder[tagStart..<closingIndex])
                remainder = String(remainder[remainder.index(after: closingIndex)...])

                if let timestamp = parseTimestamp(tag) {
                    timestamps.append(timestamp)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let value = Int(tag.dropFirst("offset:".count)) {
                    offsetMilliseconds = value
                    consumedMetadata = true
                } else if isMetadataTag(tag) {
                    consumedMetadata = true
                } else {
                    // An unknown bracketed prefix may be intentional lyric text.
                    remainder = "[\(tag)]\(remainder)"
                    break
                }
            }

            let lyricText = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !timestamps.isEmpty {
                for timestamp in timestamps where !lyricText.isEmpty {
                    lines.append(LyricLine(timestampMilliseconds: timestamp, text: lyricText))
                }
            } else if consumedMetadata {
                continue
            }
        }

        return (lines.sorted { $0.timestampMilliseconds < $1.timestampMilliseconds }, offsetMilliseconds)
    }

    private static func parseTimestamp(_ tag: String) -> Int64? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              !parts[0].hasPrefix("-"),
              let first = Int64(parts[0])
        else { return nil }

        let secondsPart: Substring
        let minutes: Int64
        if parts.count == 2 {
            minutes = first
            secondsPart = parts[1]
        } else {
            guard !parts[1].hasPrefix("-"), let minute = Int64(parts[1]) else { return nil }
            let (wholeMinutes, minuteOverflow) = first.multipliedReportingOverflow(by: 60)
            guard !minuteOverflow else { return nil }
            let (totalMinutes, additionOverflow) = wholeMinutes.addingReportingOverflow(minute)
            guard !additionOverflow else { return nil }
            minutes = totalMinutes
            secondsPart = parts[2]
        }

        let fractionParts = secondsPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !secondsPart.hasPrefix("-"),
              fractionParts.count <= 2,
              let seconds = Int64(fractionParts[0]),
              (0...59).contains(seconds)
        else {
            return nil
        }
        var fraction = 0
        if fractionParts.count == 2 {
            let digits = String(fractionParts[1]).prefix(3)
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let value = Int(digits) else {
                return nil
            }
            fraction = value * (digits.count == 1 ? 100 : digits.count == 2 ? 10 : 1)
        }
        let (wholeSeconds, secondsOverflow) = minutes.multipliedReportingOverflow(by: 60)
        guard !secondsOverflow else { return nil }
        let (totalSeconds, totalSecondsOverflow) = wholeSeconds.addingReportingOverflow(seconds)
        guard !totalSecondsOverflow else { return nil }
        let (wholeMilliseconds, millisecondsOverflow) = totalSeconds.multipliedReportingOverflow(by: 1_000)
        guard !millisecondsOverflow else { return nil }
        let (timestamp, fractionOverflow) = wholeMilliseconds.addingReportingOverflow(Int64(fraction))
        guard !fractionOverflow else { return nil }
        // Negative timestamps are not valid LRC line markers. Keep them
        // separate from the supported negative [offset:] metadata tag so a
        // malformed line cannot become active at the beginning of playback.
        guard timestamp >= 0 else { return nil }
        return timestamp
    }

    private static func isMetadataTag(_ tag: String) -> Bool {
        let lowercased = tag.lowercased()
        return lowercased.hasPrefix("ar:")
            || lowercased.hasPrefix("ti:")
            || lowercased.hasPrefix("al:")
            || lowercased.hasPrefix("by:")
            || lowercased.hasPrefix("re:")
            || lowercased.hasPrefix("ve:")
            || lowercased.hasPrefix("au:")
            || lowercased.hasPrefix("length:")
            || lowercased.hasPrefix("id:")
    }

    private static func milliseconds(from duration: Duration) -> Int64 {
        let components = duration.components
        let (wholeMilliseconds, secondsOverflow) = components.seconds.multipliedReportingOverflow(by: 1_000)
        if secondsOverflow {
            return components.seconds >= 0 ? Int64.max : Int64.min
        }
        let fractionalMilliseconds = components.attoseconds / 1_000_000_000_000_000
        let (milliseconds, fractionOverflow) = wholeMilliseconds.addingReportingOverflow(fractionalMilliseconds)
        if fractionOverflow {
            return fractionalMilliseconds >= 0 ? Int64.max : Int64.min
        }
        return milliseconds
    }

    private static func saturatedOffset(declared: Int, runtime: Int) -> Int64 {
        let declared = Int64(declared)
        let runtime = Int64(runtime)
        let (offset, overflow) = declared.subtractingReportingOverflow(runtime)
        guard overflow else { return offset }
        return declared >= 0 ? Int64.max : Int64.min
    }
}
