import Foundation
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginRuntime

/// Built-in native adapters retain their rich catalog, authentication and
/// download contracts. Runtime owns construction and every operation lease.
public struct NativeOnlineSourceRegistrationProvider: BuiltInPluginRegistrationProvider {
    public static let dsAudioID = PluginID(rawValue: "builtin.source.dsAudio")
    public static let googleDriveID = PluginID(rawValue: "builtin.source.googleDrive")
    public static let ids: Set<PluginID> = [dsAudioID, googleDriveID]
    public let registrations: [BuiltInPluginRegistration]
    public init(factory: any OnlineSourceFactory) {
        registrations = [OnlineProviderKind.dsAudio, .googleDrive].map { kind in
            let descriptor = Self.descriptor(kind)
            return .init(descriptor: descriptor, onlineSource: { context in
                guard case .text(let json) = context.configuration.values["nativeSource"] else { throw PluginError.invalidConfiguration }
                let configuration = try JSONDecoder().decode(OnlineSourceConfiguration.self, from: Data(json.utf8))
                guard configuration.providerKind == kind, configuration.sourceID.rawValue == context.configuration.instanceID,
                      let source = try factory.makeSource(for: configuration), source.providerKind == kind,
                      source.descriptor.sourceID == configuration.sourceID,
                      source is any DownloadSource else { throw PluginError.invalidRegistration }
                if kind == .dsAudio {
                    guard source is any PlaybackSource, source is any CatalogSearchingSource else { throw PluginError.invalidRegistration }
                    return NativeDSAudioPlugin(source: source)
                }
                return NativeDownloadPlugin(source: source)
            })
        }
    }
    static func descriptor(_ kind: OnlineProviderKind) -> PluginDescriptor {
        .init(id: kind == .dsAudio ? dsAudioID : googleDriveID, name: kind == .dsAudio ? "DS Audio" : "Google Drive",
            kinds: [.onlineSource], permissions: [.network, .credentials], policyVersion: kind.defaultPrivacyPolicyVersion,
            sourceConfiguration: .init(fields: [.init(id: "nativeSource", title: "Source configuration", kind: .text, required: true)]),
            onlineProviderID: kind.rawValue,
            onlineCapabilities: kind == .dsAudio ? [.browse, .search, .download, .playbackAccess, .refresh] : [.browse, .download])
    }
    static func instance(_ configuration: OnlineSourceConfiguration) throws -> PluginInstanceConfiguration {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(configuration), as: UTF8.self)
        return .init(instanceID: configuration.sourceID.rawValue, values: ["nativeSource": .text(json)],
            credentialRecordID: configuration.credentialRecordID, acceptedPolicyVersion: configuration.privacyPolicyVersion)
    }
}

private protocol NativeSourcePlugin: OnlineSourcePlugin { var source: any OnlineSource { get } }
private extension NativeSourcePlugin {
    func object(_ id: String) -> SourceObjectID { .init(sourceID: source.descriptor.sourceID, externalID: id) }
    func browse(parentID: String?, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage {
        try context.requireNetwork()
        guard let source = source as? any CatalogBrowsingSource else { throw PluginError.unsupportedCapability }
        return Self.page(try await source.browse(.init(parentID: parentID.map(object), pageToken: cursor.map { .init(rawValue: $0) })))
    }
    func downloadAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess {
        try context.requireNetwork()
        guard let source = source as? any DownloadSource else { throw PluginError.unsupportedCapability }
        let receipt = try await source.download(object(objectID), options: .init())
        return .init(url: receipt.fileURL)
    }
    static func page(_ page: SourceCatalogPage) -> PluginSourcePage {
        .init(items: page.items.map { .init(objectID: $0.id.externalID, title: $0.displayName,
            artist: $0.artist, isContainer: $0.kind == .folder) }, nextCursor: page.nextPageToken?.rawValue)
    }
}
private struct NativeDownloadPlugin: NativeSourcePlugin, BrowsingSourcePlugin, DownloadSourcePlugin { let source: any OnlineSource }
private struct NativeDSAudioPlugin: NativeSourcePlugin, BrowsingSourcePlugin, DownloadSourcePlugin, SearchingSourcePlugin, PlaybackSourcePlugin, RefreshingSourcePlugin {
    let source: any OnlineSource
    func search(_ text: String, cursor: String?, context: PluginOperationContext) async throws -> PluginSourcePage {
        try context.requireNetwork()
        guard let source = source as? any CatalogSearchingSource else { throw PluginError.unsupportedCapability }
        return Self.page(try await source.search(.init(query: text, pageToken: cursor.map { .init(rawValue: $0) })))
    }
    func playbackAccess(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess {
        try await access(objectID, purpose: .audition, context: context)
    }
    func refresh(objectID: String, context: PluginOperationContext) async throws -> PluginSourceAccess {
        try await access(objectID, purpose: .auditionRefresh, context: context)
    }
    private func access(_ id: String, purpose: PlaybackPurpose, context: PluginOperationContext) async throws -> PluginSourceAccess {
        try context.requireNetwork()
        guard let source = source as? any PlaybackSource,
              case .http(let request, _) = try await source.playbackAccess(for: object(id), purpose: purpose) else { throw PluginError.unsupportedCapability }
        return .init(url: request.url, headers: request.headers)
    }
}

struct NativeRuntimeSource: OnlineSource {
    let configuration: OnlineSourceConfiguration
    let plugin: PluginDescriptor
    let runtime: PluginRuntime
    var descriptor: MediaSourceDescriptor { .init(sourceID: configuration.sourceID, kind: .remote, displayName: configuration.displayName, isReadOnly: true) }
    var capabilities: MediaSourceCapabilities { [] }
    var providerKind: OnlineProviderKind { configuration.providerKind }
    var privacyPolicyVersion: String { plugin.policyVersion }
    var onlineCapabilities: OnlineSourceCapabilities {
        providerKind == .dsAudio ? [.browsing, .searching, .downloading, .onlinePlayback, .httpTranscoding, .artwork] : [.browsing, .downloading]
    }
    func perform<Result: Sendable>(discardResult: (@Sendable (Result) async -> Void)? = nil, _ operation: @escaping @Sendable (any OnlineSource) async throws -> Result) async throws -> Result {
        try await runtime.perform(pluginID: plugin.id, configuration: NativeOnlineSourceRegistrationProvider.instance(configuration), kind: .onlineSource, discardResult: discardResult) { loaded, context in
            try context.requireNetwork()
            guard let plugin = loaded.onlineSource as? any NativeSourcePlugin else { throw PluginError.invalidRegistration }
            return try await operation(plugin.source)
        }
    }
    func resolve(_ id: MediaItemID) async throws -> PlaybackResource { try await perform { try await $0.resolve(id) } }
    func artwork(for id: ArtworkID) async throws -> ArtworkResource? { try await perform { try await $0.artwork(for: id) } }
    func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
        try await perform { guard let source = $0 as? any CatalogBrowsingSource else { throw PluginError.unsupportedCapability }; return try await source.browse(request) }
    }
    func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage {
        try await perform { guard let source = $0 as? any CatalogSearchingSource else { throw PluginError.unsupportedCapability }; return try await source.search(request) }
    }
    func download(_ id: SourceObjectID, options: DownloadOptions) async throws -> DownloadReceipt {
        try await perform(discardResult: { receipt in try? FileManager.default.removeItem(at: receipt.fileURL) }) { guard let source = $0 as? any DownloadSource else { throw PluginError.unsupportedCapability }; return try await source.download(id, options: options) }
    }
    func playbackAccess(for id: SourceObjectID, purpose: PlaybackPurpose) async throws -> PlaybackAccess {
        try await perform { guard let source = $0 as? any PlaybackSource else { throw PluginError.unsupportedCapability }; return try await source.playbackAccess(for: id, purpose: purpose) }
    }
    func authenticate(oneTimeCode: String) async throws {
        try await perform { guard let source = $0 as? any OneTimeCodeAuthenticatingOnlineSource else { throw PluginError.unsupportedCapability }; try await source.authenticate(oneTimeCode: oneTimeCode) }
    }
}
private protocol NativeRuntimeWrapping: OnlineSource { var wrapped: NativeRuntimeSource { get } }
private extension NativeRuntimeWrapping {
    var descriptor: MediaSourceDescriptor { wrapped.descriptor }
    var capabilities: MediaSourceCapabilities { wrapped.capabilities }
    var providerKind: OnlineProviderKind { wrapped.providerKind }
    var onlineCapabilities: OnlineSourceCapabilities { wrapped.onlineCapabilities }
    var privacyPolicyVersion: String { wrapped.privacyPolicyVersion }
    func resolve(_ id: MediaItemID) async throws -> PlaybackResource { try await wrapped.resolve(id) }
    func artwork(for id: ArtworkID) async throws -> ArtworkResource? { try await wrapped.artwork(for: id) }
    func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage { try await wrapped.browse(request) }
    func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage { try await wrapped.search(request) }
    func download(_ id: SourceObjectID, options: DownloadOptions) async throws -> DownloadReceipt { try await wrapped.download(id, options: options) }
    func playbackAccess(for id: SourceObjectID, purpose: PlaybackPurpose) async throws -> PlaybackAccess { try await wrapped.playbackAccess(for: id, purpose: purpose) }
    func authenticate(oneTimeCode: String) async throws { try await wrapped.authenticate(oneTimeCode: oneTimeCode) }
}
private struct NativeDriveRuntimeSource: NativeRuntimeWrapping, DownloadSource { let wrapped: NativeRuntimeSource }
private struct NativeDSAudioRuntimeSource: NativeRuntimeWrapping, SearchableDownloadSource, PlaybackSource, OneTimeCodeAuthenticatingOnlineSource { let wrapped: NativeRuntimeSource }

func makeNativeRuntimeSource(configuration: OnlineSourceConfiguration, plugin: PluginDescriptor, runtime: PluginRuntime) -> any OnlineSource {
    let wrapped = NativeRuntimeSource(configuration: configuration, plugin: plugin, runtime: runtime)
    return configuration.providerKind == .dsAudio ? NativeDSAudioRuntimeSource(wrapped: wrapped) : NativeDriveRuntimeSource(wrapped: wrapped)
}
