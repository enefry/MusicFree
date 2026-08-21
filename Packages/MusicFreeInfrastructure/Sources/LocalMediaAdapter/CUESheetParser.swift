import CoreFoundation
import Foundation

struct CUETime: Equatable, Comparable, Sendable {
  static let framesPerSecond = 75
  let totalFrames: Int

  init(totalFrames: Int) throws {
    guard totalFrames >= 0 else { throw CUESheetError.invalidTime(line: 0) }
    self.totalFrames = totalFrames
  }

  init(token: String, line: Int) throws {
    let fields = token.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 3,
          let minutes = Int(fields[0]),
          let seconds = Int(fields[1]),
          let frames = Int(fields[2]),
          minutes >= 0,
          (0..<60).contains(seconds),
          (0..<Self.framesPerSecond).contains(frames)
    else { throw CUESheetError.invalidTime(line: line) }
    let (minuteFrames, minuteOverflow) = minutes.multipliedReportingOverflow(
      by: 60 * Self.framesPerSecond
    )
    let (secondFrames, secondOverflow) = seconds.multipliedReportingOverflow(
      by: Self.framesPerSecond
    )
    let (subtotal, firstAddOverflow) = minuteFrames.addingReportingOverflow(secondFrames)
    let (total, secondAddOverflow) = subtotal.addingReportingOverflow(frames)
    guard !minuteOverflow, !secondOverflow, !firstAddOverflow, !secondAddOverflow else {
      throw CUESheetError.invalidTime(line: line)
    }
    totalFrames = total
  }

  var duration: Duration {
    .seconds(Double(totalFrames) / Double(Self.framesPerSecond))
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.totalFrames < rhs.totalFrames
  }
}

struct CUERemark: Equatable, Sendable {
  let key: String
  let value: String
}

struct CUETrack: Equatable, Sendable {
  let number: Int
  let title: String?
  let performer: String?
  let songwriter: String?
  let index00: CUETime?
  let index01: CUETime
  let pregap: CUETime?
  let postgap: CUETime?
  let remarks: [CUERemark]
}

struct CUEFile: Equatable, Sendable {
  let path: String
  let type: String
  let tracks: [CUETrack]
}

struct CUESheet: Equatable, Sendable {
  let title: String?
  let performer: String?
  let songwriter: String?
  let remarks: [CUERemark]
  let files: [CUEFile]

  var tracks: [CUETrack] { files.flatMap(\.tracks) }

  func segments(assetDurations: [String: Duration]) throws -> [CUETrackSegment] {
    var result: [CUETrackSegment] = []
    for file in files {
      let durations = Dictionary(
        assetDurations.map { ($0.key.lowercased(), $0.value) },
        uniquingKeysWith: { _, last in last }
      )
      guard let assetDuration = durations[file.path.lowercased()], assetDuration > .zero else {
        throw CUESheetError.missingAssetDuration
      }
      for (index, track) in file.tracks.enumerated() {
        let start = track.index01.duration
        let nextTrack = index + 1 < file.tracks.count ? file.tracks[index + 1] : nil
        let end: Duration
        if let nextTrack {
          // INDEX 00 is the boundary at which the next track's pregap starts.
          // The pregap is not exposed as part of either logical track. When a
          // sheet has only PREGAP, derive the same boundary from INDEX 01;
          // PREGAP belongs to the next track and must not shorten the current
          // track's outgoing range.
          let indexedEnd = nextTrack.index00?.duration ?? nextTrack.index01.duration
          let declaredPregapEnd = nextTrack.index00 == nil
            ? nextTrack.index01.duration - (nextTrack.pregap?.duration ?? .zero)
            : indexedEnd
          end = min(indexedEnd, declaredPregapEnd)
        } else {
          end = assetDuration
        }

        // POSTGAP is trailing silence and therefore excluded from the logical
        // duration. The source asset remains the authority when the declared
        // gap reaches beyond its actual end.
        let effectiveEnd = max(start, end - (track.postgap?.duration ?? .zero))
        guard start < effectiveEnd, effectiveEnd <= assetDuration else {
          throw CUESheetError.invalidTrackRange(track: track.number)
        }
        result.append(CUETrackSegment(
          filePath: file.path,
          track: track,
          start: start,
          end: effectiveEnd
        ))
      }
    }
    return result
  }
}

struct CUETrackSegment: Equatable, Sendable {
  let filePath: String
  let track: CUETrack
  let start: Duration
  let end: Duration
}

enum CUESheetError: Error, Equatable, Sendable {
  case unsupportedEncoding
  case malformedCommand(line: Int)
  case invalidTrack(line: Int)
  case invalidTime(line: Int)
  case unsafeFileReference(line: Int)
  case missingFile(line: Int)
  case missingIndex01(track: Int)
  case duplicateTrackNumber(Int)
  case nonMonotonicIndex(track: Int)
  case missingAssetDuration
  case invalidTrackRange(track: Int)
  case referencedFileNotFound
  case ambiguousFileReference
}

struct CUESheetParser: Sendable {
  func parse(data: Data) throws -> CUESheet {
    guard let text = Self.decode(data) else { throw CUESheetError.unsupportedEncoding }
    return try parse(text: text)
  }

  func parse(text: String) throws -> CUESheet {
    var sheetTitle: String?
    var sheetPerformer: String?
    var sheetSongwriter: String?
    var sheetRemarks: [CUERemark] = []
    var files: [FileBuilder] = []
    var currentFileIndex: Int?
    var currentTrackIndex: Int?

    for (offset, rawLine) in text.split(
      omittingEmptySubsequences: false,
      whereSeparator: \Character.isNewline
    ).enumerated() {
      let lineNumber = offset + 1
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty else { continue }
      let commandAndRest = Self.commandAndRest(line)
      let command = commandAndRest.command.uppercased()
      let rest = commandAndRest.rest

      switch command {
      case "FILE":
        let tokens = try Self.tokens(rest, line: lineNumber)
        guard tokens.count >= 2 else { throw CUESheetError.malformedCommand(line: lineNumber) }
        let filePath = try Self.normalizedReference(tokens.dropLast().joined(separator: " "), line: lineNumber)
        files.append(FileBuilder(path: filePath, type: tokens.last!.uppercased()))
        currentFileIndex = files.count - 1
        currentTrackIndex = nil
      case "TRACK":
        guard let fileIndex = currentFileIndex else {
          throw CUESheetError.missingFile(line: lineNumber)
        }
        let tokens = try Self.tokens(rest, line: lineNumber)
        guard tokens.count == 2,
              let number = Int(tokens[0]),
              number > 0,
              tokens[1].caseInsensitiveCompare("AUDIO") == .orderedSame
        else { throw CUESheetError.invalidTrack(line: lineNumber) }
        files[fileIndex].tracks.append(TrackBuilder(number: number))
        currentTrackIndex = files[fileIndex].tracks.count - 1
      case "TITLE":
        let value = try Self.singleValue(rest, line: lineNumber)
        if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
          files[fileIndex].tracks[trackIndex].title = value
        } else {
          sheetTitle = value
        }
      case "PERFORMER":
        let value = try Self.singleValue(rest, line: lineNumber)
        if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
          files[fileIndex].tracks[trackIndex].performer = value
        } else {
          sheetPerformer = value
        }
      case "SONGWRITER":
        let value = try Self.singleValue(rest, line: lineNumber)
        if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
          files[fileIndex].tracks[trackIndex].songwriter = value
        } else {
          sheetSongwriter = value
        }
      case "INDEX":
        guard let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex else {
          throw CUESheetError.invalidTrack(line: lineNumber)
        }
        let tokens = try Self.tokens(rest, line: lineNumber)
        guard tokens.count == 2, let indexNumber = Int(tokens[0]) else {
          throw CUESheetError.malformedCommand(line: lineNumber)
        }
        let time = try CUETime(token: tokens[1], line: lineNumber)
        switch indexNumber {
        case 0:
          files[fileIndex].tracks[trackIndex].index00 = time
        case 1:
          files[fileIndex].tracks[trackIndex].index01 = time
        default:
          break
        }
      case "PREGAP", "POSTGAP":
        guard let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex else {
          throw CUESheetError.invalidTrack(line: lineNumber)
        }
        let time = try CUETime(token: try Self.singleValue(rest, line: lineNumber), line: lineNumber)
        if command == "PREGAP" {
          files[fileIndex].tracks[trackIndex].pregap = time
        } else {
          files[fileIndex].tracks[trackIndex].postgap = time
        }
      case "REM":
        let remark = try Self.remark(rest, line: lineNumber)
        if let fileIndex = currentFileIndex, let trackIndex = currentTrackIndex {
          files[fileIndex].tracks[trackIndex].remarks.append(remark)
        } else {
          sheetRemarks.append(remark)
        }
      case "CATALOG", "CDTEXTFILE", "FLAGS", "ISRC":
        continue
      default:
        continue
      }
    }

    var seenTrackNumbers = Set<Int>()
    var builtFiles: [CUEFile] = []
    for file in files {
      var previousIndex: CUETime?
      var builtTracks: [CUETrack] = []
      for track in file.tracks {
        guard seenTrackNumbers.insert(track.number).inserted else {
          throw CUESheetError.duplicateTrackNumber(track.number)
        }
        guard let index01 = track.index01 else {
          throw CUESheetError.missingIndex01(track: track.number)
        }
        if let index00 = track.index00, index00 > index01 {
          throw CUESheetError.nonMonotonicIndex(track: track.number)
        }
        if let previousIndex, index01 <= previousIndex {
          throw CUESheetError.nonMonotonicIndex(track: track.number)
        }
        previousIndex = index01
        builtTracks.append(CUETrack(
          number: track.number,
          title: track.title,
          performer: track.performer,
          songwriter: track.songwriter,
          index00: track.index00,
          index01: index01,
          pregap: track.pregap,
          postgap: track.postgap,
          remarks: track.remarks
        ))
      }
      guard !builtTracks.isEmpty else { continue }
      builtFiles.append(CUEFile(path: file.path, type: file.type, tracks: builtTracks))
    }
    guard !builtFiles.isEmpty else { throw CUESheetError.invalidTrack(line: 0) }
    return CUESheet(
      title: Self.clean(sheetTitle),
      performer: Self.clean(sheetPerformer),
      songwriter: Self.clean(sheetSongwriter),
      remarks: sheetRemarks,
      files: builtFiles
    )
  }

  private struct FileBuilder {
    let path: String
    let type: String
    var tracks: [TrackBuilder] = []
  }

  private struct TrackBuilder {
    let number: Int
    var title: String?
    var performer: String?
    var songwriter: String?
    var index00: CUETime?
    var index01: CUETime?
    var pregap: CUETime?
    var postgap: CUETime?
    var remarks: [CUERemark] = []
  }

  private static func decode(_ data: Data) -> String? {
    if data.starts(with: [0xFF, 0xFE]) {
      return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
    }
    if data.starts(with: [0xFE, 0xFF]) {
      return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
    }
    let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
    let normalized = Data(bytes)
    if let utf8 = String(data: normalized, encoding: .utf8) { return utf8 }
    for encoding in [gb18030Encoding, big5Encoding, .shiftJIS] {
      if let decoded = String(data: normalized, encoding: encoding) { return decoded }
    }
    return nil
  }

  private static let gb18030Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
    )
  )

  private static let big5Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.big5.rawValue)
    )
  )

  private static func commandAndRest(_ line: String) -> (command: String, rest: String) {
    guard let separator = line.firstIndex(where: \Character.isWhitespace) else {
      return (line, "")
    }
    return (
      String(line[..<separator]),
      String(line[separator...]).trimmingCharacters(in: .whitespaces)
    )
  }

  private static func tokens(_ value: String, line: Int) throws -> [String] {
    var tokens: [String] = []
    var current = ""
    var quoted = false
    for character in value {
      if character == "\"" {
        quoted.toggle()
      } else if character.isWhitespace, !quoted {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
      } else {
        current.append(character)
      }
    }
    guard !quoted else { throw CUESheetError.malformedCommand(line: line) }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  private static func singleValue(_ value: String, line: Int) throws -> String {
    let parsed = try tokens(value, line: line).joined(separator: " ")
    guard let cleaned = clean(parsed) else {
      throw CUESheetError.malformedCommand(line: line)
    }
    return cleaned
  }

  private static func remark(_ value: String, line: Int) throws -> CUERemark {
    let parsed = try tokens(value, line: line)
    guard let first = parsed.first, !first.isEmpty else {
      throw CUESheetError.malformedCommand(line: line)
    }
    return CUERemark(
      key: first.uppercased(),
      value: parsed.dropFirst().joined(separator: " ")
    )
  }

  private static func normalizedReference(_ value: String, line: Int) throws -> String {
    let normalized = value.replacingOccurrences(of: "\\", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !normalized.isEmpty,
          !normalized.hasPrefix("/"),
          normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
          !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw CUESheetError.unsafeFileReference(line: line) }
    return components.joined(separator: "/")
  }

  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }
}

struct CUEReferencedFileResolver: Sendable {
  func resolve(_ file: CUEFile, cueURL: URL, candidates: [URL]) throws -> URL {
    let cueDirectory = cueURL.deletingLastPathComponent().standardizedFileURL
    let expectedComponents = file.path.split(separator: "/").map(String.init)
    let exact = expectedComponents.reduce(cueDirectory) { partial, component in
      partial.appendingPathComponent(component, isDirectory: false)
    }.standardizedFileURL
    let matches = candidates.filter { candidate in
      let standardized = candidate.standardizedFileURL
      guard Self.isContained(standardized, in: cueDirectory) else { return false }
      let relative = standardized.pathComponents.dropFirst(cueDirectory.pathComponents.count)
        .joined(separator: "/")
      return relative.caseInsensitiveCompare(file.path) == .orderedSame
    }
    if matches.count > 1 { throw CUESheetError.ambiguousFileReference }
    if let match = matches.first { return match }
    if FileManager.default.fileExists(atPath: exact.path), Self.isContained(exact, in: cueDirectory) {
      return exact
    }
    throw CUESheetError.referencedFileNotFound
  }

  private static func isContained(_ child: URL, in root: URL) -> Bool {
    let childComponents = child.standardizedFileURL.pathComponents
    let rootComponents = root.standardizedFileURL.pathComponents
    return childComponents.count > rootComponents.count
      && Array(childComponents.prefix(rootComponents.count)) == rootComponents
  }
}
