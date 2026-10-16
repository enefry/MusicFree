// LRC/NetEase YRC adaptation for the plugin SDK. See ThirdPartyNotices/163MusicLyrics-Apache-2.0.txt.
import Foundation
import MusicFreePluginAPI

enum ServiceLyrics {
    private static let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
    private static let offset = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
    private static let yrcHeader = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
    private static let yrcWord = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^()]*)"#)
    private static let maximumTime: Int64 = 86_400_000

    static func lines(raw: String, translation: String, wordTimed: String?) -> [PluginLyricLine] {
        let translated = lrc(translation)
        let original = wordTimed.map(yrc) ?? []
        let lines = original.isEmpty ? lrc(raw) : original
        var translationIndex = 0
        return lines.map { line in
            while translationIndex + 1 < translated.count,
                  abs(translated[translationIndex + 1].startMilliseconds - line.startMilliseconds)
                    < abs(translated[translationIndex].startMilliseconds - line.startMilliseconds) {
                translationIndex += 1
            }
            let nearest = translated.isEmpty ? nil : translated[translationIndex]
            let text = nearest.flatMap { abs($0.startMilliseconds - line.startMilliseconds) <= 250 ? $0.text : nil }
            return .init(startMilliseconds: line.startMilliseconds, text: line.text, translation: text, words: line.words)
        }
    }

    private static func lrc(_ text: String) -> [PluginLyricLine] {
        let offsetMatch = offset.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        let shift = offsetMatch.flatMap { capture($0, 1, in: text) }.flatMap(Int64.init).flatMap {
            abs($0 == Int64.min ? Int64.max : $0) <= maximumTime ? $0 : nil
        } ?? 0
        var result: [PluginLyricLine] = []
        for line in text.components(separatedBy: .newlines) {
            let matches = timestamp.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last, let end = Range(last.range, in: line)?.upperBound else { continue }
            let lyric = String(line[end...]).trimmingCharacters(in: .whitespaces)
            guard !lyric.isEmpty else { continue }
            for match in matches {
                guard let minutes = capture(match, 1, in: line).flatMap(Double.init),
                      let seconds = capture(match, 2, in: line).flatMap(Double.init), seconds < 60 else { continue }
                let milliseconds = (minutes * 60 + seconds) * 1_000
                guard milliseconds.isFinite, milliseconds <= Double(maximumTime) else { continue }
                result.append(.init(startMilliseconds: max(0, Int64(milliseconds.rounded()) + shift), text: lyric))
            }
        }
        return result.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }

    private static func yrc(_ text: String) -> [PluginLyricLine] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let header = yrcHeader.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let start = capture(header, 1, in: line).flatMap(Int64.init), start <= maximumTime else { return nil }
            let words = yrcWord.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { match -> PluginLyricWord? in
                guard let begin = capture(match, 1, in: line).flatMap(Int64.init), begin <= maximumTime,
                      let duration = capture(match, 2, in: line).flatMap(Int64.init), duration <= maximumTime,
                      let value = capture(match, 3, in: line), !value.isEmpty else { return nil }
                return .init(startMilliseconds: begin, durationMilliseconds: duration, text: value)
            }
            guard !words.isEmpty else { return nil }
            return PluginLyricLine(startMilliseconds: start, text: words.map(\.text).joined(), words: words)
        }.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    static func unescape(_ text: String) -> String {
        var value = text
        let entity = try! NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|\d+);"#)
        for match in entity.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let token = capture(match, 1, in: value), let range = Range(match.range, in: value),
                  let number = UInt32(token.hasPrefix("x") ? String(token.dropFirst()) : token, radix: token.hasPrefix("x") ? 16 : 10),
                  let scalar = UnicodeScalar(number) else { continue }
            value.replaceSubrange(range, with: String(scalar))
        }
        for (entity, decoded) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            value = value.replacingOccurrences(of: entity, with: decoded)
        }
        return value
    }
}
