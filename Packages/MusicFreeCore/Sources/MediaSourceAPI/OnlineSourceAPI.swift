import Foundation
import MusicDomain

/// Provider kinds that can be configured as an external media source.
///
/// The enum identifies a protocol family only. Every configured account, NAS,
/// or gateway instance still receives its own `MediaSourceID`.
public enum OnlineProviderKind: String, Codable, CaseIterable, Sendable {
  case dsAudio
  case googleDrive
  case baiduPan
  case gateway

  /// The privacy disclosure version used when a Provider has not yet supplied
  /// a more specific version through its adapter. The version is part of the
  /// consent record, never of a credential or remote URL.
  public var defaultPrivacyPolicyVersion: String {
    "1.2.0"
  }
}

/// Stable identity for a provider-owned object such as a folder, album, or
/// audio file. It is deliberately distinct from `MediaItemID`, which is the
/// identity of a playable library variant.
public struct SourceObjectID: Codable, Equatable, Hashable, Comparable, Sendable,
  CustomStringConvertible
{
  public let sourceID: MediaSourceID
  public let externalID: String

  public init(sourceID: MediaSourceID, externalID: String) {
    self.sourceID = sourceID
    self.externalID = externalID.trimmingCharacters(in: .whitespacesAndNewlines)
    precondition(!self.externalID.isEmpty, "SourceObjectID.externalID cannot be empty")
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.sourceID != rhs.sourceID {
      return lhs.sourceID < rhs.sourceID
    }
    return lhs.externalID < rhs.externalID
  }

  public var description: String {
    "SourceObjectID(source: \(sourceID), external: redacted)"
  }
}

/// Persistable, non-sensitive configuration for one online source instance.
///
/// Credentials are represented only by `credentialRecordID`. `endpoint` may
/// contain a provider base path, but never userinfo, query, or fragment.
public struct OnlineSourceConfiguration: Codable, Equatable, Hashable, Sendable {
  public let sourceID: MediaSourceID
  public let providerKind: OnlineProviderKind
  public let displayName: String
  public let endpoint: URL?
  public let rootObjectID: SourceObjectID?
  public let credentialRecordID: String?
  public let privacyPolicyVersion: String?
  public let isEnabled: Bool

  public init(
    sourceID: MediaSourceID,
    providerKind: OnlineProviderKind,
    displayName: String,
    endpoint: URL? = nil,
    rootObjectID: SourceObjectID? = nil,
    credentialRecordID: String? = nil,
    privacyPolicyVersion: String? = nil,
    isEnabled: Bool = false
  ) throws {
    let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw OnlineSourceConfigurationError.emptyDisplayName
    }

    self.sourceID = sourceID
    self.providerKind = providerKind
    self.displayName = normalizedName
    self.endpoint = try Self.normalizedEndpoint(endpoint)
    self.rootObjectID = rootObjectID

    if let credentialRecordID {
      let normalizedCredentialID = credentialRecordID
        .trimmingCharacters(in: .whitespacesAndNewlines)
      self.credentialRecordID = normalizedCredentialID.isEmpty
        ? nil
        : normalizedCredentialID
    } else {
      self.credentialRecordID = nil
    }

    self.privacyPolicyVersion = normalizedOptionalString(privacyPolicyVersion)
    self.isEnabled = isEnabled
  }

  public func settingEnabled(_ enabled: Bool) -> Self {
    Self.unchecked(
      sourceID: sourceID,
      providerKind: providerKind,
      displayName: displayName,
      endpoint: endpoint,
      rootObjectID: rootObjectID,
      credentialRecordID: credentialRecordID,
      privacyPolicyVersion: privacyPolicyVersion,
      isEnabled: enabled
    )
  }

  public func acceptingPrivacyPolicy(version: String) throws -> Self {
    guard let normalizedVersion = normalizedOptionalString(version) else {
      throw OnlineSourceConfigurationError.emptyPrivacyPolicyVersion
    }
    return Self.unchecked(
      sourceID: sourceID,
      providerKind: providerKind,
      displayName: displayName,
      endpoint: endpoint,
      rootObjectID: rootObjectID,
      credentialRecordID: credentialRecordID,
      privacyPolicyVersion: normalizedVersion,
      isEnabled: isEnabled
    )
  }

  /// Revoking a source policy immediately disables network access for this
  /// source while retaining its non-sensitive configuration for later reuse.
  public func revokingPrivacyPolicy() -> Self {
    Self.unchecked(
      sourceID: sourceID,
      providerKind: providerKind,
      displayName: displayName,
      endpoint: endpoint,
      rootObjectID: rootObjectID,
      credentialRecordID: credentialRecordID,
      privacyPolicyVersion: nil,
      isEnabled: false
    )
  }

  public func isPrivacyPolicyAccepted(currentVersion: String) -> Bool {
    guard let currentVersion = normalizedOptionalString(currentVersion) else {
      return false
    }
    return privacyPolicyVersion == currentVersion
  }

  private static func unchecked(
    sourceID: MediaSourceID,
    providerKind: OnlineProviderKind,
    displayName: String,
    endpoint: URL?,
    rootObjectID: SourceObjectID?,
    credentialRecordID: String?,
    privacyPolicyVersion: String?,
    isEnabled: Bool
  ) -> Self {
    // All values passed here have already passed validation in `init`.
    Self(
      sourceID: sourceID,
      providerKind: providerKind,
      displayName: displayName,
      endpoint: endpoint,
      rootObjectID: rootObjectID,
      credentialRecordID: credentialRecordID,
      privacyPolicyVersion: privacyPolicyVersion,
      isEnabled: isEnabled,
      validated: true
    )
  }

  private init(
    sourceID: MediaSourceID,
    providerKind: OnlineProviderKind,
    displayName: String,
    endpoint: URL?,
    rootObjectID: SourceObjectID?,
    credentialRecordID: String?,
    privacyPolicyVersion: String?,
    isEnabled: Bool,
    validated: Bool
  ) {
    self.sourceID = sourceID
    self.providerKind = providerKind
    self.displayName = displayName
    self.endpoint = endpoint
    self.rootObjectID = rootObjectID
    self.credentialRecordID = credentialRecordID
    self.privacyPolicyVersion = privacyPolicyVersion
    self.isEnabled = isEnabled
  }

  private static func normalizedEndpoint(_ endpoint: URL?) throws -> URL? {
    guard let endpoint else { return nil }
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          components.host != nil
    else {
      throw OnlineSourceConfigurationError.invalidEndpoint
    }

    guard components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil
    else {
      throw OnlineSourceConfigurationError.endpointContainsSensitiveComponents
    }

    components.scheme = scheme
    if components.path.count > 1 {
      components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path = "/" + components.path
    }
    return components.url
  }
}

public enum OnlineSourceConfigurationError: Error, Equatable, Sendable,
  LocalizedError, CustomStringConvertible
{
  case emptyDisplayName
  case emptyPrivacyPolicyVersion
  case invalidEndpoint
  case endpointContainsSensitiveComponents

  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .emptyDisplayName:
      return "The online source display name cannot be empty."
    case .emptyPrivacyPolicyVersion:
      return "The online source privacy policy version cannot be empty."
    case .invalidEndpoint:
      return "The online source endpoint must be an HTTP or HTTPS base URL."
    case .endpointContainsSensitiveComponents:
      return "The online source endpoint cannot contain credentials, query, or fragment data."
    }
  }
}

/// Capabilities exposed by an online source instance.
public struct OnlineSourceCapabilities: OptionSet, Codable, Equatable, Hashable, Sendable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static let browsing = Self(rawValue: 1 << 0)
  public static let downloading = Self(rawValue: 1 << 1)
  public static let searching = Self(rawValue: 1 << 2)
  public static let onlinePlayback = Self(rawValue: 1 << 3)
  public static let httpTranscoding = Self(rawValue: 1 << 4)
  public static let artwork = Self(rawValue: 1 << 5)
}

public enum OnlineSourcePreferencesError: Error, Equatable, Sendable,
  LocalizedError, CustomStringConvertible
{
  case duplicateSource(MediaSourceID)
  case sourceNotFound(MediaSourceID)

  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .duplicateSource(let sourceID):
      return "Online source \(sourceID) is already configured."
    case .sourceNotFound(let sourceID):
      return "Online source \(sourceID) is not configured."
    }
  }
}

/// Persistable collection-level controls for all configured online sources.
///
/// The application privacy agreement is intentionally passed into
/// `runtimeSources` instead of being duplicated here. This keeps one source of
/// truth for the app agreement while making the global online-source switch
/// independently testable and persistable.
public struct OnlineSourcePreferences: Codable, Equatable, Hashable, Sendable {
  public let isEnabled: Bool
  public let sources: [OnlineSourceConfiguration]

  public init(
    isEnabled: Bool = true,
    sources: [OnlineSourceConfiguration] = []
  ) {
    self.isEnabled = isEnabled
    self.sources = Self.unique(sources)
  }

  public static let defaults = Self()

  public func settingEnabled(_ enabled: Bool) -> Self {
    Self(isEnabled: enabled, sources: sources)
  }

  public func adding(_ configuration: OnlineSourceConfiguration) throws -> Self {
    guard !sources.contains(where: { $0.sourceID == configuration.sourceID }) else {
      throw OnlineSourcePreferencesError.duplicateSource(configuration.sourceID)
    }
    return Self(isEnabled: isEnabled, sources: sources + [configuration])
  }

  public func updating(_ configuration: OnlineSourceConfiguration) throws -> Self {
    guard let index = sources.firstIndex(where: { $0.sourceID == configuration.sourceID }) else {
      throw OnlineSourcePreferencesError.sourceNotFound(configuration.sourceID)
    }
    var updated = sources
    updated[index] = configuration
    return Self(isEnabled: isEnabled, sources: updated)
  }

  public func removing(_ sourceID: MediaSourceID) -> Self {
    Self(isEnabled: isEnabled, sources: sources.filter { $0.sourceID != sourceID })
  }

  public func settingSourceEnabled(
    _ sourceID: MediaSourceID,
    enabled: Bool
  ) throws -> Self {
    guard let source = source(for: sourceID) else {
      throw OnlineSourcePreferencesError.sourceNotFound(sourceID)
    }
    return try updating(source.settingEnabled(enabled))
  }

  public func acceptingSourcePrivacy(
    _ sourceID: MediaSourceID,
    policyVersion: String
  ) throws -> Self {
    guard let source = source(for: sourceID) else {
      throw OnlineSourcePreferencesError.sourceNotFound(sourceID)
    }
    return try updating(try source.acceptingPrivacyPolicy(version: policyVersion))
  }

  public func revokingSourcePrivacy(_ sourceID: MediaSourceID) throws -> Self {
    guard let source = source(for: sourceID) else {
      throw OnlineSourcePreferencesError.sourceNotFound(sourceID)
    }
    return try updating(source.revokingPrivacyPolicy())
  }

  /// Application-level privacy revocation disables every source and clears
  /// each source policy version, but does not delete its configuration.
  public func revokingAllPrivacy() -> Self {
    Self(
      // Revoking the app agreement is also an explicit stop for the online
      // source service. Keeping this switch on would leave the UI showing an
      // apparently active global toggle while every source is unavailable.
      isEnabled: false,
      sources: sources.map { $0.revokingPrivacyPolicy() }
    )
  }

  public func source(for sourceID: MediaSourceID) -> OnlineSourceConfiguration? {
    sources.first { $0.sourceID == sourceID }
  }

  /// Returns the only configurations that are allowed to perform a network
  /// operation at this moment. Local imported media is outside this gate.
  public func runtimeSources(applicationPrivacyAccepted: Bool) -> [OnlineSourceConfiguration] {
    guard isEnabled, applicationPrivacyAccepted else { return [] }
    return sources.filter { $0.isEnabled && $0.privacyPolicyVersion != nil }
  }

  private static func unique(
    _ configurations: [OnlineSourceConfiguration]
  ) -> [OnlineSourceConfiguration] {
    var seen = Set<MediaSourceID>()
    return configurations.filter { seen.insert($0.sourceID).inserted }
  }
}

/// Protocol-neutral online-source identity and capability boundary.
public protocol OnlineSource: MediaSource, Sendable {
  var providerKind: OnlineProviderKind { get }
  var onlineCapabilities: OnlineSourceCapabilities { get }

  /// Each installed source can advance its disclosure independently. A
  /// default keeps older protocol fixtures source-compatible while making the
  /// version explicit for real adapters.
  var privacyPolicyVersion: String { get }
}

public extension OnlineSource {
  var privacyPolicyVersion: String {
    providerKind.defaultPrivacyPolicyVersion
  }
}

/// Authentication challenges that require short-lived user input. Values such
/// as one-time codes must stay in memory and must never be persisted with the
/// source configuration or credential record.
public enum OnlineSourceAuthenticationError: Error, Equatable, Sendable,
  LocalizedError
{
  case oneTimeCodeRequired
  case invalidOneTimeCode

  public var errorDescription: String? {
    switch self {
    case .oneTimeCodeRequired:
      return "The online source requires a one-time verification code."
    case .invalidOneTimeCode:
      return "The online source rejected the one-time verification code."
    }
  }
}

/// Optional refinement for Providers that can complete a pending login with a
/// short-lived one-time code supplied interactively by the user.
public protocol OneTimeCodeAuthenticatingOnlineSource: OnlineSource {
  func authenticate(oneTimeCode: String) async throws
}

/// Constructs one runtime adapter for one persisted source instance.
///
/// The factory is configuration-driven: the same Provider kind may be
/// created more than once with different endpoints, roots or credential
/// references. Implementations must never persist or log resolved secrets.
public protocol OnlineSourceFactory: Sendable {
  func makeSource(
    for configuration: OnlineSourceConfiguration
  ) throws -> (any OnlineSource)?
}

public enum SourceCatalogItemKind: String, Codable, Sendable {
  case folder
  case album
  case artist
  case track
  case audioFile
  case unknown

  public var isContainer: Bool {
    switch self {
    case .folder, .album, .artist:
      true
    case .track, .audioFile, .unknown:
      false
    }
  }
}

/// A source-owned catalog item. It is a browsing value, not a library record.
public struct SourceCatalogItem: Codable, Equatable, Hashable, Sendable {
  public let id: SourceObjectID
  public let kind: SourceCatalogItemKind
  public let displayName: String
  public let parentID: SourceObjectID?
  public let title: String?
  public let artist: String?
  public let album: String?
  public let duration: Duration?
  public let byteSize: Int64?
  public let contentRevision: String?
  public let mimeType: String?
  public let isPlayable: Bool

  public init(
    id: SourceObjectID,
    kind: SourceCatalogItemKind,
    displayName: String,
    parentID: SourceObjectID? = nil,
    title: String? = nil,
    artist: String? = nil,
    album: String? = nil,
    duration: Duration? = nil,
    byteSize: Int64? = nil,
    contentRevision: String? = nil,
    mimeType: String? = nil,
    isPlayable: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.displayName = MetadataTextRepair.repair(displayName)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    self.parentID = parentID
    self.title = Self.normalized(title)
    self.artist = Self.normalized(artist)
    self.album = Self.normalized(album)
    self.duration = duration
    self.byteSize = byteSize.map { max(0, $0) }
    self.contentRevision = Self.normalizedRevision(contentRevision)
    self.mimeType = Self.normalized(mimeType)
    self.isPlayable = isPlayable
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case displayName
    case parentID
    case title
    case artist
    case album
    case duration
    case byteSize
    case contentRevision
    case mimeType
    case isPlayable
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
    let byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize)
    guard duration == nil || duration! >= .zero,
          byteSize == nil || byteSize! >= 0
    else {
      throw onlineSourceDecodingFailure(decoder, field: "SourceCatalogItem")
    }
    self.init(
      id: try container.decode(SourceObjectID.self, forKey: .id),
      kind: try container.decode(SourceCatalogItemKind.self, forKey: .kind),
      displayName: try container.decode(String.self, forKey: .displayName),
      parentID: try container.decodeIfPresent(SourceObjectID.self, forKey: .parentID),
      title: try container.decodeIfPresent(String.self, forKey: .title),
      artist: try container.decodeIfPresent(String.self, forKey: .artist),
      album: try container.decodeIfPresent(String.self, forKey: .album),
      duration: duration,
      byteSize: byteSize,
      contentRevision: try container.decodeIfPresent(String.self, forKey: .contentRevision),
      mimeType: try container.decodeIfPresent(String.self, forKey: .mimeType),
      isPlayable: try container.decodeIfPresent(Bool.self, forKey: .isPlayable) ?? false
    )
  }

  /// A catalog item can be imported when the Provider identified it as an
  /// audio object even if it did not use one of the known concrete kinds.
  /// This keeps older DSM responses usable without treating folders as files.
  public var isDownloadable: Bool {
    switch kind {
    case .track, .audioFile:
      true
    case .folder, .album, .artist:
      false
    case .unknown:
      isPlayable
        || mimeType?.lowercased().hasPrefix("audio/") == true
        || Self.audioFileExtensions.contains(
          URL(fileURLWithPath: displayName).pathExtension.lowercased()
        )
    }
  }

  public static func isAudioFileExtension(_ value: String?) -> Bool {
    guard let value else { return false }
    return audioFileExtensions.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  private static let audioFileExtensions: Set<String> = [
    "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "mp3", "mp4",
    "oga", "ogg", "opus", "wav", "wma"
  ]

  private static func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = MetadataTextRepair.repair(value)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func normalizedRevision(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

/// The catalog dimension used by providers that expose more than a folder
/// tree. Providers that only expose folders keep using `.folders`.
public enum SourceCatalogBrowseMode: String, Codable, CaseIterable, Hashable, Sendable {
  case folders
  case albums
  case artists
  case allMusic
}

public enum SourceCatalogSortKey: String, Codable, CaseIterable, Hashable, Sendable {
  case name
  case artist
  case album
  case year
}

public enum SourceCatalogSortDirection: String, Codable, CaseIterable, Hashable, Sendable {
  case ascending
  case descending
}

/// A provider-facing catalog order. Providers must apply this order before
/// slicing a page so that changing pages cannot reorder or duplicate items.
public struct SourceCatalogSort: Codable, Equatable, Hashable, Sendable {
  public let key: SourceCatalogSortKey
  public let direction: SourceCatalogSortDirection

  public init(
    key: SourceCatalogSortKey = .name,
    direction: SourceCatalogSortDirection = .ascending
  ) {
    self.key = key
    self.direction = direction
  }

  public static let standard = Self()

  public static func options(for mode: SourceCatalogBrowseMode) -> [Self] {
    switch mode {
    case .folders:
      return [
        Self(key: .name, direction: .ascending),
        Self(key: .name, direction: .descending),
      ]
    case .albums:
      return [
        Self(key: .name, direction: .ascending),
        Self(key: .name, direction: .descending),
        Self(key: .artist, direction: .ascending),
        Self(key: .artist, direction: .descending),
        Self(key: .year, direction: .descending),
        Self(key: .year, direction: .ascending),
      ]
    case .artists:
      return [
        Self(key: .name, direction: .ascending),
        Self(key: .name, direction: .descending),
      ]
    case .allMusic:
      return [
        Self(key: .name, direction: .ascending),
        Self(key: .name, direction: .descending),
        Self(key: .artist, direction: .ascending),
        Self(key: .artist, direction: .descending),
        Self(key: .album, direction: .ascending),
        Self(key: .album, direction: .descending),
        Self(key: .year, direction: .descending),
        Self(key: .year, direction: .ascending),
      ]
    }
  }
}

private func onlineSourceDecodingFailure(_ decoder: Decoder, field: String) -> DecodingError {
  DecodingError.dataCorrupted(
    .init(
      codingPath: decoder.codingPath,
      debugDescription: "Invalid MediaSourceAPI value for \(field)"
    )
  )
}

public struct SourceBrowseRequest: Codable, Equatable, Sendable {
  public let parentID: SourceObjectID?
  public let mode: SourceCatalogBrowseMode
  public let sort: SourceCatalogSort
  public let pageSize: Int
  public let pageToken: MediaSourceCursor?

  public init(
    parentID: SourceObjectID? = nil,
    mode: SourceCatalogBrowseMode = .folders,
    sort: SourceCatalogSort = .standard,
    pageSize: Int = 200,
    pageToken: MediaSourceCursor? = nil
  ) {
    self.parentID = parentID
    self.mode = mode
    self.sort = sort
    self.pageSize = min(max(pageSize, 1), 500)
    self.pageToken = pageToken
  }

  private enum CodingKeys: String, CodingKey {
    case parentID
    case mode
    case sort
    case pageSize
    case pageToken
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      parentID: try container.decodeIfPresent(SourceObjectID.self, forKey: .parentID),
      mode: try container.decodeIfPresent(SourceCatalogBrowseMode.self, forKey: .mode)
        ?? .folders,
      sort: try container.decodeIfPresent(SourceCatalogSort.self, forKey: .sort)
        ?? .standard,
      pageSize: try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 200,
      pageToken: try container.decodeIfPresent(MediaSourceCursor.self, forKey: .pageToken)
    )
  }
}

public struct SourceSearchRequest: Codable, Equatable, Sendable {
  public let query: String
  public let parentID: SourceObjectID?
  public let mode: SourceCatalogBrowseMode
  public let sort: SourceCatalogSort
  public let pageSize: Int
  public let pageToken: MediaSourceCursor?

  public init(
    query: String,
    parentID: SourceObjectID? = nil,
    mode: SourceCatalogBrowseMode = .folders,
    sort: SourceCatalogSort = .standard,
    pageSize: Int = 200,
    pageToken: MediaSourceCursor? = nil
  ) {
    self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    self.parentID = parentID
    self.mode = mode
    self.sort = sort
    self.pageSize = min(max(pageSize, 1), 500)
    self.pageToken = pageToken
  }

  private enum CodingKeys: String, CodingKey {
    case query
    case parentID
    case mode
    case sort
    case pageSize
    case pageToken
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      query: try container.decode(String.self, forKey: .query),
      parentID: try container.decodeIfPresent(SourceObjectID.self, forKey: .parentID),
      mode: try container.decodeIfPresent(SourceCatalogBrowseMode.self, forKey: .mode)
        ?? .folders,
      sort: try container.decodeIfPresent(SourceCatalogSort.self, forKey: .sort)
        ?? .standard,
      pageSize: try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 200,
      pageToken: try container.decodeIfPresent(MediaSourceCursor.self, forKey: .pageToken)
    )
  }
}

public struct SourceCatalogPage: Codable, Equatable, Sendable {
  public let items: [SourceCatalogItem]
  public let nextPageToken: MediaSourceCursor?

  public init(
    items: [SourceCatalogItem],
    nextPageToken: MediaSourceCursor? = nil
  ) {
    self.items = items
    self.nextPageToken = nextPageToken
  }
}

/// A transient download request. The downloaded file is handed to the
/// application import flow and is not itself a persisted library record.
public struct DownloadOptions: Codable, Equatable, Sendable {
  public let allowsResume: Bool
  public let preferredFileName: String?

  public init(
    allowsResume: Bool = true,
    preferredFileName: String? = nil
  ) {
    self.allowsResume = allowsResume
    self.preferredFileName = normalizedOptionalString(preferredFileName)
  }
}

/// The result of one source download. The file URL is intentionally
/// short-lived and must be consumed by the import coordinator immediately.
public struct DownloadReceipt: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let sourceID: MediaSourceID
  public let itemID: SourceObjectID
  public let fileURL: URL
  public let contentRevision: String?
  public let byteCount: Int64?

  public init(
    sourceID: MediaSourceID,
    itemID: SourceObjectID,
    fileURL: URL,
    contentRevision: String? = nil,
    byteCount: Int64? = nil
  ) {
    self.sourceID = sourceID
    self.itemID = itemID
    self.fileURL = fileURL
    self.contentRevision = normalizedOptionalString(contentRevision)
    self.byteCount = byteCount.map { max(0, $0) }
  }

  public var description: String {
    "DownloadReceipt(source: \(sourceID), item: redacted, file: redacted)"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

public enum PlaybackPurpose: String, Codable, Sendable {
  case audition
}

public struct TranscodeDescriptor: Codable, Equatable, Hashable, Sendable {
  public let container: String?
  public let codec: String?
  public let bitRate: Int?

  public init(
    container: String? = nil,
    codec: String? = nil,
    bitRate: Int? = nil
  ) {
    self.container = normalizedOptionalString(container)
    self.codec = normalizedOptionalString(codec)
    self.bitRate = bitRate.map { max(0, $0) }
  }
}

/// A short-lived online playback access value. It deliberately does not
/// conform to Codable and redacts URL/header data from diagnostics.
public enum PlaybackAccess: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case http(request: RemotePlaybackRequest, transcode: TranscodeDescriptor?)
  case downloadRequired

  public var isEphemeral: Bool { true }

  public var description: String {
    switch self {
    case .http:
      return "PlaybackAccess(http: redacted)"
    case .downloadRequired:
      return "PlaybackAccess(downloadRequired)"
    }
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(self, unlabeledChildren: [])
  }
}

/// A download source can browse and download. Search is an optional refined
/// capability represented by `SearchableDownloadSource`.
public protocol DownloadSource: OnlineSource {
  func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage

  func download(
    _ itemID: SourceObjectID,
    options: DownloadOptions
  ) async throws -> DownloadReceipt
}

public protocol SearchableDownloadSource: DownloadSource {
  func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage
}

/// A playback source extends download access. A Provider may expose a direct
/// HTTP URL, an HTTP transcode URL, or require the caller to download first.
public protocol PlaybackSource: DownloadSource {
  func playbackAccess(
    for itemID: SourceObjectID,
    purpose: PlaybackPurpose
  ) async throws -> PlaybackAccess
}

private func normalizedOptionalString(_ value: String?) -> String? {
  guard let value else { return nil }
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return normalized.isEmpty ? nil : normalized
}
