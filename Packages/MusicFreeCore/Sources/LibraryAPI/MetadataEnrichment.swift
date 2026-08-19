import Foundation
import MusicDomain

/// The catalog provider used to supplement local library metadata.
public typealias MetadataEnrichmentProvider = MetadataProviderID

/// A field that may be filled by a catalog match. Lyrics are deliberately not
/// part of this list because MusicKit catalog search does not provide lyric
/// text for this feature.
public enum MetadataEnrichmentField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case title
    case artist
    case albumArtist
    case album
    case genre
    case year
    case trackNumber
    case discNumber
    case artwork
}

public enum MetadataEnrichmentRecordStatus: String, Codable, Equatable, Hashable, Sendable {
    case queued
    case running
    case matched
    case noMatch
    case ambiguous
    case rateLimited
    case failed
    case cancelled
}

/// Durable per-track enrichment state. It intentionally contains no path,
/// token, private key, audio bytes, lyrics, or raw provider response.
public struct MetadataEnrichmentRecord: Codable, Equatable, Hashable, Sendable {
    public let itemID: MediaItemID
    public let provider: MetadataEnrichmentProvider
    public let queryFingerprint: String
    public let catalogID: String?
    /// Number of usable catalog candidates returned by the last search.
    /// This is diagnostic state only; it contains no query text or response data.
    public let candidateCount: Int?
    public let status: MetadataEnrichmentRecordStatus
    public let attemptCount: Int
    public let lastAttemptAt: Date?
    public let nextRetryAt: Date?
    public let updatedFields: Set<MetadataEnrichmentField>
    public let lastErrorCode: String?
    public let lastHTTPStatus: Int?

    public init(
        itemID: MediaItemID,
        provider: MetadataEnrichmentProvider = .musicKit,
        queryFingerprint: String,
        catalogID: String? = nil,
        candidateCount: Int? = nil,
        status: MetadataEnrichmentRecordStatus,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextRetryAt: Date? = nil,
        updatedFields: Set<MetadataEnrichmentField> = [],
        lastErrorCode: String? = nil,
        lastHTTPStatus: Int? = nil
    ) {
        self.itemID = itemID
        self.provider = provider
        self.queryFingerprint = queryFingerprint
        self.catalogID = catalogID
        self.candidateCount = candidateCount.map { max(0, $0) }
        self.status = status
        self.attemptCount = max(0, attemptCount)
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.updatedFields = updatedFields
        self.lastErrorCode = lastErrorCode
        self.lastHTTPStatus = lastHTTPStatus
    }

    private enum CodingKeys: String, CodingKey {
        case itemID
        case provider
        case queryFingerprint
        case catalogID
        case candidateCount
        case status
        case attemptCount
        case lastAttemptAt
        case nextRetryAt
        case updatedFields
        case lastErrorCode
        case lastHTTPStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            itemID: try container.decode(MediaItemID.self, forKey: .itemID),
            // Version 1 records predate the provider field and were all
            // produced by MusicKit.
            provider: try container.decodeIfPresent(
                MetadataEnrichmentProvider.self,
                forKey: .provider
            ) ?? .musicKit,
            queryFingerprint: try container.decode(
                String.self,
                forKey: .queryFingerprint
            ),
            catalogID: try container.decodeIfPresent(String.self, forKey: .catalogID),
            candidateCount: try container.decodeIfPresent(
                Int.self,
                forKey: .candidateCount
            ),
            status: try container.decode(
                MetadataEnrichmentRecordStatus.self,
                forKey: .status
            ),
            attemptCount: try container.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0,
            lastAttemptAt: try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt),
            nextRetryAt: try container.decodeIfPresent(Date.self, forKey: .nextRetryAt),
            updatedFields: try container.decodeIfPresent(
                Set<MetadataEnrichmentField>.self,
                forKey: .updatedFields
            ) ?? [],
            lastErrorCode: try container.decodeIfPresent(String.self, forKey: .lastErrorCode),
            lastHTTPStatus: try container.decodeIfPresent(Int.self, forKey: .lastHTTPStatus)
        )
    }
}

/// A transient query assembled from the current local track. `fileName` is a
/// safe basename only; callers must never pass an absolute path here.
public struct MetadataEnrichmentQuery: Hashable, Sendable {
    public let itemID: MediaItemID
    public let title: String?
    public let artistName: String?
    public let albumName: String?
    public let fileName: String?
    public let durationSeconds: TimeInterval?
    public let missingFields: Set<MetadataEnrichmentField>
    public let isFilenameFallback: Bool

    public init(
        itemID: MediaItemID,
        title: String?,
        artistName: String? = nil,
        albumName: String? = nil,
        fileName: String? = nil,
        durationSeconds: TimeInterval? = nil,
        missingFields: Set<MetadataEnrichmentField> = [],
        isFilenameFallback: Bool = false
    ) {
        self.itemID = itemID
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

    /// The record stores only normalized metadata and missing-field names.
    /// It never stores the original URL or an unbounded provider response.
    public var fingerprint: String {
        let values: [String] = [
            String(MetadataEnrichmentMatcher.revision),
            title ?? "",
            artistName ?? "",
            albumName ?? "",
            filenameStem ?? "",
            durationSeconds.map { String(format: "%.1f", $0) } ?? "",
            missingFields.map(\.rawValue).sorted().joined(separator: ","),
            String(isFilenameFallback)
        ]
        return MusicContentIdentity.token(values.joined(separator: "\u{1f}"))
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
public struct MetadataEnrichmentCandidate: Sendable, Equatable, Hashable {
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
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MetadataEnrichmentMatchResult: Sendable, Equatable {
    case matched(MetadataEnrichmentCandidate)
    case noMatch
    case ambiguous
}

/// Deterministic candidate matching shared by the provider workflow and tests.
public enum MetadataEnrichmentMatcher {
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
        query: MetadataEnrichmentQuery,
        candidates: [MetadataEnrichmentCandidate],
        minimumScore: Int = 55,
        minimumMargin: Int = 10
    ) -> MetadataEnrichmentMatchResult {
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
        query: MetadataEnrichmentQuery,
        candidate: MetadataEnrichmentCandidate
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

/// A partial metadata request. LibraryCoordinator resolves and preserves all
/// existing values before committing this request atomically.
public struct TrackMetadataSupplement: Sendable, Equatable {
    public let itemID: MediaItemID
    public let title: String?
    public let artistName: String?
    public let albumArtistName: String?
    public let albumName: String?
    public let genreName: String?
    public let trackNumber: Int?
    public let discNumber: Int?
    public let year: Int?
    public let lyrics: TrackLyrics?
    public let artworkData: Data?

    public init(
        itemID: MediaItemID,
        title: String? = nil,
        artistName: String? = nil,
        albumArtistName: String? = nil,
        albumName: String? = nil,
        genreName: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        lyrics: TrackLyrics? = nil,
        artworkData: Data? = nil
    ) {
        self.itemID = itemID
        self.title = Self.normalized(title)
        self.artistName = Self.normalized(artistName)
        self.albumArtistName = Self.normalized(albumArtistName)
        self.albumName = Self.normalized(albumName)
        self.genreName = Self.normalized(genreName)
        self.trackNumber = trackNumber.flatMap { $0 > 0 ? $0 : nil }
        self.discNumber = discNumber.flatMap { $0 > 0 ? $0 : nil }
        self.year = year.flatMap { (1...9_999).contains($0) ? $0 : nil }
        self.lyrics = lyrics.flatMap { $0.isEmpty ? nil : $0 }
        self.artworkData = artworkData?.isEmpty == false ? artworkData : nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MetadataEnrichmentAuthorizationStatus: String, Codable, Equatable, Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case unavailable
}

public enum MetadataEnrichmentScanStatus: String, Codable, Equatable, Hashable, Sendable {
    case idle
    case scanning
    case completed
    case cancelled
    case failed
}

public struct MetadataEnrichmentScanSnapshot: Codable, Equatable, Sendable {
    public let status: MetadataEnrichmentScanStatus
    public let total: Int
    public let processed: Int
    public let matched: Int
    public let noMatch: Int
    public let ambiguous: Int
    public let failed: Int
    public let currentTitle: String?
    public let errorCode: String?

    public init(
        status: MetadataEnrichmentScanStatus = .idle,
        total: Int = 0,
        processed: Int = 0,
        matched: Int = 0,
        noMatch: Int = 0,
        ambiguous: Int = 0,
        failed: Int = 0,
        currentTitle: String? = nil,
        errorCode: String? = nil
    ) {
        self.status = status
        self.total = max(0, total)
        self.processed = max(0, processed)
        self.matched = max(0, matched)
        self.noMatch = max(0, noMatch)
        self.ambiguous = max(0, ambiguous)
        self.failed = max(0, failed)
        self.currentTitle = currentTitle
        self.errorCode = errorCode
    }
}

public struct MetadataEnrichmentSnapshot: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let authorization: MetadataEnrichmentAuthorizationStatus
    public let scan: MetadataEnrichmentScanSnapshot
    public let activeProvider: MetadataProviderID?
    public let providerStatuses: [MetadataEnrichmentProviderSnapshot]

    public init(
        isEnabled: Bool = false,
        authorization: MetadataEnrichmentAuthorizationStatus = .unavailable,
        scan: MetadataEnrichmentScanSnapshot = .init(),
        activeProvider: MetadataProviderID? = nil,
        providerStatuses: [MetadataEnrichmentProviderSnapshot] = []
    ) {
        self.isEnabled = isEnabled
        self.authorization = authorization
        self.scan = scan
        self.activeProvider = activeProvider
        self.providerStatuses = providerStatuses
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case authorization
        case scan
        case activeProvider
        case providerStatuses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            authorization: try container.decodeIfPresent(
                MetadataEnrichmentAuthorizationStatus.self,
                forKey: .authorization
            ) ?? .unavailable,
            scan: try container.decodeIfPresent(
                MetadataEnrichmentScanSnapshot.self,
                forKey: .scan
            ) ?? .init(),
            activeProvider: try container.decodeIfPresent(
                MetadataProviderID.self,
                forKey: .activeProvider
            ),
            providerStatuses: try container.decodeIfPresent(
                [MetadataEnrichmentProviderSnapshot].self,
                forKey: .providerStatuses
            ) ?? []
        )
    }

    public var isAvailable: Bool {
        authorization != .unavailable
    }

    public func status(
        for provider: MetadataProviderID
    ) -> MetadataEnrichmentProviderSnapshot? {
        providerStatuses.first { $0.provider == provider }
    }
}

public struct MetadataEnrichmentProviderSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let provider: MetadataProviderID
    public let isEnabled: Bool
    public let isRegistered: Bool
    public let authorization: MetadataEnrichmentAuthorizationStatus

    public init(
        provider: MetadataProviderID,
        isEnabled: Bool = false,
        isRegistered: Bool = false,
        authorization: MetadataEnrichmentAuthorizationStatus = .unavailable
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.isRegistered = isRegistered
        self.authorization = authorization
    }

    public var id: MetadataProviderID { provider }
}

public enum MetadataEnrichmentError: Error, Equatable, Sendable {
    case unavailable
    case notAuthorized
    case rateLimited(retryAfterSeconds: Double?, httpStatus: Int?)
    case offline
    case requestFailed(code: String, httpStatus: Int?)
}

public protocol MetadataEnrichmentProviding: Sendable {
    var provider: MetadataEnrichmentProvider { get }
    func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus
    func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus
    func search(_ query: MetadataEnrichmentQuery) async throws -> [MetadataEnrichmentCandidate]
    func artworkData(for candidate: MetadataEnrichmentCandidate) async throws -> Data?
}

public extension MetadataEnrichmentProviding {
    func artworkData(for candidate: MetadataEnrichmentCandidate) async throws -> Data? {
        candidate.artworkData
    }
}

public protocol MetadataEnrichmentRecordRepository: Sendable {
    func record(for itemID: MediaItemID) async throws -> MetadataEnrichmentRecord?
    func record(
        for itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws -> MetadataEnrichmentRecord?
    func records() async throws -> [MetadataEnrichmentRecord]
    func records(for provider: MetadataProviderID) async throws -> [MetadataEnrichmentRecord]
    func save(_ record: MetadataEnrichmentRecord) async throws
    func remove(itemID: MediaItemID) async throws
    func remove(
        itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws
}

public extension MetadataEnrichmentRecordRepository {
    func record(
        for itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws -> MetadataEnrichmentRecord? {
        guard let record = try await record(for: itemID),
              record.provider == provider
        else {
            return nil
        }
        return record
    }

    func records(
        for provider: MetadataProviderID
    ) async throws -> [MetadataEnrichmentRecord] {
        let records = try await records()
        return records.filter { $0.provider == provider }
    }

    func remove(
        itemID: MediaItemID,
        provider: MetadataProviderID
    ) async throws {
        guard let record = try await record(for: itemID, provider: provider) else {
            return
        }
        guard record.itemID == itemID else { return }
        try await remove(itemID: itemID)
    }
}
