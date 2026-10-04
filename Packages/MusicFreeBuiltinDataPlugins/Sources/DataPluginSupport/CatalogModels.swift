import Foundation
import MusicFreePluginAPI

public struct CatalogQuery: Hashable, Sendable {
    public let title: String?
    public let artistName: String?
    public let albumName: String?
    public let fileName: String?
    public let durationSeconds: TimeInterval?
    public let missingFields: Set<PluginMetadataField>
    public let isFilenameFallback: Bool

    public init(
        title: String?,
        artistName: String? = nil,
        albumName: String? = nil,
        fileName: String? = nil,
        durationSeconds: TimeInterval? = nil,
        missingFields: Set<PluginMetadataField> = [],
        isFilenameFallback: Bool = false
    ) {
        self.title = Self.normalized(title)
        self.artistName = Self.normalized(artistName)
        self.albumName = Self.normalized(albumName)
        self.fileName = Self.normalized(fileName).map {
            URL(fileURLWithPath: $0).lastPathComponent
        }
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.missingFields = missingFields
        self.isFilenameFallback = isFilenameFallback
    }

    public var filenameStem: String? {
        guard let fileName else { return nil }
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return Self.cleanedFilename(stem)
    }

    /// A filename such as "01 - Artist - Title" is reduced to the title for
    /// matching while retaining the artist portion in the search term.
    public var filenameTitle: String? {
        let parts = filenameParts
        return Self.normalized(parts.last) ?? filenameStem
    }

    public var filenameArtist: String? {
        let parts = filenameParts
        guard parts.count > 1 else { return nil }
        return Self.normalized(parts.dropLast().joined(separator: " - "))
    }

    /// MusicKit receives a compact title/artist term. Album is used as a
    /// fallback when the local artist is absent.
    public var searchTerm: String? {
        if let filenameArtist, isFilenameFallback, artistName == nil {
            return makeSearchTerm(
                title: filenameTitle,
                secondary: filenameArtist,
                secondaryComesFirst: true
            )
        }
        if let artistName {
            return makeSearchTerm(title: preferredSearchTitle, secondary: artistName)
        }
        if let albumName {
            return makeSearchTerm(title: preferredSearchTitle, secondary: albumName)
        }
        return makeSearchTerm(title: preferredSearchTitle, secondary: nil)
            ?? makeSearchTerm(title: nil, secondary: fileName)
    }

    /// Search terms are ordered from most specific to most tolerant. Providers
    /// can stop as soon as a reliable candidate is found, while still handling
    /// titles whose embedded soundtrack/version description prevents a strict
    /// title-plus-artist search from returning anything.
    public var searchTerms: [String] {
        var terms: [String] = []
        appendSearchTerm(searchTerm, to: &terms)

        guard let preferredSearchTitle else { return terms }
        let simplifiedTitle = Self.searchTitle(preferredSearchTitle)
        let searchArtist = artistName ?? (
            isFilenameFallback ? filenameArtist : nil
        )

        if let simplifiedTitle, simplifiedTitle != preferredSearchTitle,
           let searchArtist
        {
            appendSearchTerm(
                makeSearchTerm(title: simplifiedTitle, secondary: searchArtist),
                to: &terms
            )
        }
        if let albumName {
            appendSearchTerm(
                makeSearchTerm(title: preferredSearchTitle, secondary: albumName),
                to: &terms
            )
        }
        appendSearchTerm(
            makeSearchTerm(title: preferredSearchTitle, secondary: nil),
            to: &terms
        )
        if let simplifiedTitle, simplifiedTitle != preferredSearchTitle {
            appendSearchTerm(simplifiedTitle, to: &terms)
        }
        return terms
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = MetadataTextRepair.repair(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var filenameParts: [String] {
        guard let filenameStem else { return [] }
        return filenameStem
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func cleanedFilename(_ value: String) -> String? {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(
            of: "^\\s*\\d{1,3}\\s*[-._)]+\\s*",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "\\s*[\\[(](?i:official|audio|video|lyrics?|remaster(?:ed)?|radio edit|explicit|clean)[^\\])]*[\\])]",
            with: "",
            options: .regularExpression
        )
        return normalized(cleaned)
    }

    private var preferredSearchTitle: String? {
        isFilenameFallback ? filenameTitle : title
    }

    private func makeSearchTerm(
        title: String?,
        secondary: String?,
        secondaryComesFirst: Bool = false
    ) -> String? {
        let parts: [String]
        if secondaryComesFirst {
            parts = [secondary, title].compactMap { $0 }
        } else {
            parts = [title, secondary].compactMap { $0 }
        }
        let term = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? nil : term
    }

    private func appendSearchTerm(_ term: String?, to terms: inout [String]) {
        guard let term, !terms.contains(term) else { return }
        terms.append(term)
    }

    private static func searchTitle(_ value: String) -> String? {
        let openingDelimiters: Set<Character> = ["(", "[", "{", "（", "【"]
        let endIndex = value.firstIndex {
            openingDelimiters.contains($0)
        } ?? value.endIndex
        return normalized(String(value[..<endIndex]))
    }
}

/// The catalog candidate returned by a provider. Artwork bytes are transient
/// and are committed only through the library metadata editor.
public struct CatalogCandidate: Sendable, Equatable, Hashable {
    public let catalogID: String
    public let title: String
    public let artistName: String?
    public let albumArtistName: String?
    public let albumName: String?
    public let genreName: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let durationSeconds: TimeInterval?
    public let artworkData: Data?

    public init(
        catalogID: String,
        title: String,
        artistName: String? = nil,
        albumArtistName: String? = nil,
        albumName: String? = nil,
        genreName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        durationSeconds: TimeInterval? = nil,
        artworkData: Data? = nil
    ) {
        self.catalogID = catalogID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = MetadataTextRepair.repair(title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.artistName = Self.normalized(artistName)
        self.albumArtistName = Self.normalized(albumArtistName)
        self.albumName = Self.normalized(albumName)
        self.genreName = Self.normalized(genreName)
        self.trackNumber = trackNumber.flatMap { $0 > 0 ? $0 : nil }
        self.discNumber = discNumber.flatMap { $0 > 0 ? $0 : nil }
        self.year = year.flatMap { (1...9_999).contains($0) ? $0 : nil }
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.artworkData = artworkData?.isEmpty == false ? artworkData : nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = MetadataTextRepair.repair(value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CatalogMatchResult: Sendable, Equatable {
    case matched(CatalogCandidate)
    case noMatch
    case ambiguous
}

/// Deterministic candidate matching shared by the provider workflow and tests.
public enum CatalogMatcher {
    /// Bump this when matching semantics change so persisted no-match decisions
    /// are evaluated again after an app update.
    public static let revision = 3

    private static let titleExtensionMarkers: Set<String> = [
        "acoustic",
        "alternate",
        "clean",
        "demo",
        "deluxe",
        "explicit",
        "featuring",
        "from",
        "instrumental",
        "karaoke",
        "live",
        "mono",
        "ost",
        "radio",
        "remastered",
        "remix",
        "soundtrack",
        "stereo",
        "version"
    ]

    public static func match(
        query: CatalogQuery,
        candidates: [CatalogCandidate],
        minimumScore: Int = 55,
        minimumMargin: Int = 10
    ) -> CatalogMatchResult {
        let ranked = candidates
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { (candidate: $0, score: score(query: query, candidate: $0)) }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.candidate.catalogID < $1.candidate.catalogID
            }

        guard let first = ranked.first, first.score >= minimumScore else {
            return .noMatch
        }
        if let second = ranked.dropFirst().first,
           first.score - second.score < minimumMargin
        {
            return .ambiguous
        }
        return .matched(first.candidate)
    }

    private static func score(
        query: CatalogQuery,
        candidate: CatalogCandidate
    ) -> Int {
        var score = 0
        let candidateTitle = normalized(candidate.title)
        let localTitles = ([query.title] + (query.isFilenameFallback
            ? [query.filenameTitle, query.filenameStem]
            : []))
            .compactMap { $0 }
            .map(normalized)
        score += localTitles
            .map { titleMatchScore(local: $0, candidate: candidateTitle) }
            .max() ?? 0

        let localArtist = query.artistName ?? (
            query.isFilenameFallback ? query.filenameArtist : nil
        )
        if let localArtist, let candidateArtist = candidate.artistName {
            let localArtistValue = normalized(localArtist)
            let candidateArtistValue = normalized(candidateArtist)
            if equivalent(localArtistValue, candidateArtistValue) {
                score += 30
            } else if tokenOverlap(localArtistValue, candidateArtistValue) >= 0.5
                        || tokenOverlap(
                            latinNormalized(localArtist),
                            latinNormalized(candidateArtist)
                        ) >= 0.5
            {
                score += 15
            } else if hasDifferentScripts(localArtist, candidateArtist) {
                // A catalog often returns a romanized artist for a local CJK
                // tag. An unresolved script difference is weaker evidence than
                // a same-script mismatch, so leave the title score intact.
            } else {
                score -= 30
            }
        }
        if let albumName = query.albumName, let candidateAlbum = candidate.albumName {
            if equivalent(normalized(albumName), normalized(candidateAlbum)) {
                score += 15
            } else if tokenOverlap(normalized(albumName), normalized(candidateAlbum)) >= 0.5
                        || tokenOverlap(
                            latinNormalized(albumName),
                            latinNormalized(candidateAlbum)
                        ) >= 0.5
            {
                score += 8
            }
        }
        if let localDuration = query.durationSeconds,
           let candidateDuration = candidate.durationSeconds
        {
            let difference = abs(localDuration - candidateDuration)
            if difference <= 2 { score += 12 }
            else if difference <= 6 { score += 6 }
        }
        if let year = candidate.year,
           query.missingFields.contains(.year),
           year > 0
        {
            score += 2
        }
        return score
    }

    private static func titleMatchScore(local: String, candidate: String) -> Int {
        guard !local.isEmpty, !candidate.isEmpty else { return 0 }
        if local == candidate {
            return 55
        }
        if equivalent(local, candidate) {
            // A catalog may expose a CJK title as its Latin transliteration.
            // Keep this below an exact title match so transliteration alone
            // cannot accept a weak candidate without artist/album evidence.
            return 52
        }

        // MusicKit commonly appends source and version labels, for example
        // "Title (From ... ) [Instrumental Version]". A word boundary keeps
        // "Love" from matching an unrelated "Lovely" result.
        if candidate.hasPrefix(local + " "),
           isKnownTitleExtension(String(candidate.dropFirst(local.count)))
        {
            return 55
        }
        if local.hasPrefix(candidate + " "),
           isKnownTitleExtension(String(local.dropFirst(candidate.count)))
        {
            return 48
        }
        if candidate.contains(local) || local.contains(candidate) {
            return 35
        }
        if tokenOverlap(local, candidate) >= 0.5 {
            return 25
        }
        return 0
    }

    private static func isKnownTitleExtension(_ value: String) -> Bool {
        value
            .split(separator: " ")
            .contains { titleExtensionMarkers.contains(String($0)) }
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || latinCompacted(lhs) == latinCompacted(rhs)
    }

    private static func latinNormalized(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        return latin
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func latinCompacted(_ value: String) -> String {
        latinNormalized(value).filter { $0 != " " }
    }

    private static func hasDifferentScripts(_ lhs: String, _ rhs: String) -> Bool {
        containsCJK(lhs) != containsCJK(rhs)
    }

    private static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(String.init)
            .joined()
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let left = Set(lhs.split(separator: " ").map(String.init))
        let right = Set(rhs.split(separator: " ").map(String.init))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }
}
