import CoreFoundation
import Foundation

/// Repairs a narrow class of legacy Chinese/UTF-8 mojibake without changing
/// normal user-facing text. The source text has already been decoded by a
/// metadata reader, so this recovers the original bytes and tries a small set
/// of likely encodings.
public enum MetadataTextRepair {
  private enum TargetEncoding: Equatable {
    case utf8
    case gb18030
  }

  private struct Candidate {
    let value: String
    let cjkCount: Int
    let cjkRatio: Double
    let target: TargetEncoding
  }

  private struct DecodedTextCandidate {
    let value: String
    let encodingRank: Int
    let scriptScore: Int
    let printableRatio: Double
  }

  private static let gb18030Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
  ))
  private static let big5Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
    CFStringEncoding(CFStringEncodings.big5.rawValue)
  ))

  // These characters occur frequently when Chinese GBK bytes are displayed
  // as Windows-1252/Latin-1 text. They are intentionally only a gate; the
  // decoded candidate still has to pass the CJK and printable-text checks.
  private static let gb18030Markers: Set<UInt32> = [
    0x00B5, // micro sign
    0x00B7, // middle dot
    0x00B8, // cedilla
    0x00BA, // masculine ordinal
    0x00BB, // right angle quote
    0x00BC, // one-quarter
    0x00BD, // one-half
    0x00BE, // three-quarters
    0x00C4, // A diaeresis
    0x00D4, // O circumflex
    0x00D6  // O diaeresis
  ]

  // UTF-8 Chinese mojibake commonly starts with these Latin-1-looking
  // lead bytes (for example, "ä¸­æ–‡").
  private static let utf8Markers: Set<UInt32> = [
    0x00C2, 0x00C3, 0x00E0, 0x00E1, 0x00E2, 0x00E3,
    0x00E4, 0x00E5, 0x00E6, 0x00E7, 0x00E8, 0x00E9,
    0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF
  ]

  /// Decodes text files at the shared media-text boundary and repairs a
  /// second-pass mojibake decode when the source already contains it.
  public static func decode(_ data: Data) -> String? {
    if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
      return String(data: data.dropFirst(4), encoding: .utf32LittleEndian).map(repair)
    }
    if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
      return String(data: data.dropFirst(4), encoding: .utf32BigEndian).map(repair)
    }
    if data.starts(with: [0xFF, 0xFE]) {
      return String(data: data.dropFirst(2), encoding: .utf16LittleEndian).map(repair)
    }
    if data.starts(with: [0xFE, 0xFF]) {
      return String(data: data.dropFirst(2), encoding: .utf16BigEndian).map(repair)
    }

    let normalized = data.starts(with: [0xEF, 0xBB, 0xBF])
      ? Data(data.dropFirst(3))
      : data

    // Valid UTF-8 is authoritative. It may still contain a second-pass
    // mojibake string such as `ä¸­æ–‡`, which repair() can recover without
    // asking the legacy byte decoders to reinterpret the file.
    if let decoded = String(data: normalized, encoding: .utf8) {
      return repair(decoded)
    }

    // UTF-16 without a BOM is only safe to consider when the byte pattern
    // clearly looks like ASCII UTF-16. Otherwise Foundation can decode
    // arbitrary byte pairs into plausible but incorrect text.
    var encodings: [(encoding: String.Encoding, rank: Int)] = [
      (gb18030Encoding, 0),
      (big5Encoding, 1),
      (.shiftJIS, 2)
    ]
    if looksLikeUTF16WithoutBOM(normalized) {
      encodings.append((.utf16LittleEndian, 3))
      encodings.append((.utf16BigEndian, 4))
    }
    encodings.append((.windowsCP1252, 5))
    encodings.append((.isoLatin1, 6))

    let candidates: [DecodedTextCandidate] = encodings.compactMap { entry -> DecodedTextCandidate? in
      let encoding = entry.encoding
      let rank = entry.rank
      guard let decoded = String(data: normalized, encoding: encoding),
            let metrics = textMetrics(for: decoded)
      else { return nil }
      return DecodedTextCandidate(
        value: decoded,
        encodingRank: rank,
        scriptScore: metrics.scriptScore,
        printableRatio: metrics.printableRatio
      )
    }
    return candidates.min(by: isPreferredDecodedTextCandidate).map { repair($0.value) }
  }

  public static func repair(_ value: String) -> String {
    if let candidate = bestCandidate(for: value) {
      return candidate.value
    }

    // Lyric files and comments often mix a short tag/prefix with a longer
    // malformed value. Repair each line/token while preserving separators.
    if value.contains("\n") {
      return value.components(separatedBy: "\n")
        .map(repairLine)
        .joined(separator: "\n")
    }
    if value.contains("\r") {
      return value.components(separatedBy: "\r")
        .map(repairLine)
        .joined(separator: "\r")
    }
    return repairLine(value)
  }

  public static func isLikelyMojibake(_ value: String) -> Bool {
    repair(value) != value
  }

  private static func bestCandidate(for value: String) -> Candidate? {
    guard !value.isEmpty,
          !containsCJK(value),
          suspiciousScalarCount(in: value) >= 2
    else { return nil }

    var best: Candidate?
    var seen = Set<String>()
    for sourceEncoding in [String.Encoding.windowsCP1252, .isoLatin1] {
      guard let data = value.data(using: sourceEncoding) else { continue }
      let highByteCount = data.reduce(into: 0) { count, byte in
        if byte >= 0x80 { count += 1 }
      }
      for target in [TargetEncoding.utf8, .gb18030] {
        guard let decoded = decode(data, as: target),
              decoded != value,
              seen.insert(decoded).inserted,
              let cjk = validatedCJKCount(in: decoded),
              cjk >= 2
        else { continue }
        let ratio = cjkRatio(cjk, in: decoded)
        guard ratio >= 0.4 else { continue }
        guard passesMarkerGate(
          source: value,
          target: target,
          highByteCount: highByteCount,
          cjkRatio: ratio
        ) else { continue }

        let candidate = Candidate(
          value: decoded,
          cjkCount: cjk,
          cjkRatio: ratio,
          target: target
        )
        if best == nil || isBetter(candidate, than: best!) {
          best = candidate
        }
      }
    }
    return best
  }

  private static func repairLine(_ line: String) -> String {
    if let candidate = bestCandidate(for: line) {
      return candidate.value
    }

    // Keep one or more LRC-style bracketed prefixes structured, repairing
    // metadata values such as `[ar:...]` as well as the lyric text after a
    // timestamp. Numeric timestamps and offsets remain unchanged.
    var prefix = ""
    var remainder = line
    while remainder.first == "[",
          let closingIndex = remainder.firstIndex(of: "]") {
      let bracket = String(remainder[...closingIndex])
      prefix += repairBracketedPrefix(bracket)
      remainder = String(remainder[remainder.index(after: closingIndex)...])
    }
    if !prefix.isEmpty {
      return prefix + (bestCandidate(for: remainder)?.value ?? remainder)
    }

    var result = ""
    var token = ""
    func flushToken() {
      guard !token.isEmpty else { return }
      result += bestCandidate(for: token)?.value ?? token
      token.removeAll(keepingCapacity: true)
    }

    for character in line {
      if character.isWhitespace {
        flushToken()
        result.append(character)
      } else {
        token.append(character)
      }
    }
    flushToken()
    return result
  }

  private static func repairBracketedPrefix(_ bracket: String) -> String {
    guard bracket.first == "[",
          bracket.last == "]",
          let separator = bracket.firstIndex(of: ":")
    else { return bracket }

    let valueStart = bracket.index(after: separator)
    let valueEnd = bracket.index(before: bracket.endIndex)
    guard valueStart <= valueEnd else { return bracket }

    let value = String(bracket[valueStart..<valueEnd])
    let repairedValue = repair(value)
    guard repairedValue != value else { return bracket }
    return String(bracket[..<valueStart]) + repairedValue + "]"
  }

  private static func decode(_ data: Data, as target: TargetEncoding) -> String? {
    switch target {
    case .utf8:
      return String(data: data, encoding: .utf8)
    case .gb18030:
      return String(data: data, encoding: gb18030Encoding)
    }
  }

  private static func looksLikeUTF16WithoutBOM(_ data: Data) -> Bool {
    guard data.count >= 4, data.count.isMultiple(of: 2) else { return false }
    let zeroCount = data.reduce(into: 0) { count, byte in
      if byte == 0 { count += 1 }
    }
    return Double(zeroCount) / Double(data.count) >= 0.25
  }

  private static func textMetrics(
    for value: String
  ) -> (scriptScore: Int, printableRatio: Double)? {
    var meaningfulCount = 0
    var printableCount = 0
    var cjkCount = 0
    var kanaCount = 0
    var hangulCount = 0

    for scalar in value.unicodeScalars {
      if scalar == "\u{FFFD}" || isPrivateUse(scalar) {
        return nil
      }
      if CharacterSet.controlCharacters.contains(scalar),
         scalar != "\n",
         scalar != "\r",
         scalar != "\t"
      {
        return nil
      }
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
        meaningfulCount += 1
      }
      if !CharacterSet.controlCharacters.contains(scalar) {
        printableCount += 1
      }
      if isCJK(scalar) { cjkCount += 1 }
      if isKana(scalar) { kanaCount += 1 }
      if isHangul(scalar) { hangulCount += 1 }
    }

    guard meaningfulCount > 0 else { return (0, 1) }
    let scriptScore = cjkCount * 100 + kanaCount * 90 + hangulCount * 90
    return (
      scriptScore,
      Double(printableCount) / Double(value.unicodeScalars.count)
    )
  }

  private static func isPreferredDecodedTextCandidate(
    _ lhs: DecodedTextCandidate,
    _ rhs: DecodedTextCandidate
  ) -> Bool {
    if lhs.scriptScore != rhs.scriptScore {
      return lhs.scriptScore > rhs.scriptScore
    }
    if lhs.printableRatio != rhs.printableRatio {
      return lhs.printableRatio > rhs.printableRatio
    }
    return lhs.encodingRank < rhs.encodingRank
  }

  private static func passesMarkerGate(
    source: String,
    target: TargetEncoding,
    highByteCount: Int,
    cjkRatio: Double
  ) -> Bool {
    let scalarValues = Set(source.unicodeScalars.map(\.value))
    switch target {
    case .utf8:
      return !scalarValues.isDisjoint(with: utf8Markers)
    case .gb18030:
      return !scalarValues.isDisjoint(with: gb18030Markers)
        || (highByteCount >= 6 && cjkRatio >= 0.75)
    }
  }

  private static func isBetter(_ lhs: Candidate, than rhs: Candidate) -> Bool {
    if lhs.cjkCount != rhs.cjkCount {
      return lhs.cjkCount > rhs.cjkCount
    }
    if lhs.cjkRatio != rhs.cjkRatio {
      return lhs.cjkRatio > rhs.cjkRatio
    }
    // Prefer UTF-8 when both decoders produce equally plausible text. This
    // avoids accepting GB18030's private-use artifacts for UTF-8 mojibake.
    if lhs.target != rhs.target {
      if case .utf8 = lhs.target { return true }
      return false
    }
    return lhs.value.count < rhs.value.count
  }

  private static func validatedCJKCount(in value: String) -> Int? {
    var count = 0
    for scalar in value.unicodeScalars {
      if scalar == "\u{FFFD}" || isPrivateUse(scalar) {
        return nil
      }
      if CharacterSet.controlCharacters.contains(scalar),
         scalar != "\n",
         scalar != "\r",
         scalar != "\t"
      {
        return nil
      }
      if isCJK(scalar) {
        count += 1
      }
    }
    return count
  }

  private static func cjkRatio(_ count: Int, in value: String) -> Double {
    let meaningfulCount = value.unicodeScalars.reduce(into: 0) { result, scalar in
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
        result += 1
      }
    }
    guard meaningfulCount > 0 else { return 0 }
    return Double(count) / Double(meaningfulCount)
  }

  private static func suspiciousScalarCount(in value: String) -> Int {
    value.unicodeScalars.reduce(into: 0) { result, scalar in
      if (0x80...0xFF).contains(scalar.value) {
        result += 1
      }
    }
  }

  private static func containsCJK(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: isCJK)
  }

  private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
      return true
    default:
      return false
    }
  }

  private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x31F0...0x31FF:
      return true
    default:
      return false
    }
  }

  private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
      return true
    default:
      return false
    }
  }

  private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
      return true
    default:
      return false
    }
  }
}
