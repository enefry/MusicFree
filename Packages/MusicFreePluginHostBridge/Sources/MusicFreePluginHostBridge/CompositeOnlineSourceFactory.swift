import Foundation
import MediaSourceAPI
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginRuntime

public struct CompositeOnlineSourceFactory: OnlineSourceFactory {
    private let legacy: any OnlineSourceFactory
    private let runtime: PluginRuntime
    private let downloadRoot: URL
    public init(legacy: any OnlineSourceFactory, runtime: PluginRuntime, downloadRoot: URL) {
        self.legacy = legacy; self.runtime = runtime; self.downloadRoot = downloadRoot
    }
    public func makeSource(for configuration: OnlineSourceConfiguration) throws -> (any OnlineSource)? {
        if let registration = runtime.registry.registrations.values.first(where: {
            NativeOnlineSourceRegistrationProvider.ids.contains($0.descriptor.id) && $0.descriptor.onlineProviderID == configuration.providerKind.rawValue
        }) {
            return makeNativeRuntimeSource(configuration: configuration, plugin: registration.descriptor, runtime: runtime)
        }
        if OnlineProviderKind.allCases.contains(configuration.providerKind) { return try legacy.makeSource(for: configuration) }
        guard let registration = runtime.registry.registrations.values.first(where: {
            $0.descriptor.onlineProviderID == configuration.providerKind.rawValue && $0.onlineSource != nil
        }) else { throw PluginError.unavailable }
        // Pure construction. Loading/credential resolution starts with an authorized operation.
        let adapter = PluginOnlineSourceAdapter(configuration: configuration, plugin: registration.descriptor,
            runtime: runtime, downloadRoot: downloadRoot)
        let download = registration.descriptor.onlineCapabilities.contains(.download)
        let playback = registration.descriptor.onlineCapabilities.contains(.playbackAccess)
        if download && playback { return PlaybackDownloadPluginSource(wrapped: adapter) }
        if download { return DownloadPluginSource(wrapped: adapter) }
        if playback { return PlaybackPluginSource(wrapped: adapter) }
        return CatalogPluginSource(wrapped: adapter)
    }
}

public struct PluginOnlineSourceAdapter: OnlineSource {
    public let descriptor: MediaSourceDescriptor
    public let capabilities: MediaSourceCapabilities = []
    public let providerKind: OnlineProviderKind
    public let onlineCapabilities: OnlineSourceCapabilities
    public var privacyPolicyVersion: String { plugin.policyVersion }
    private let configuration: OnlineSourceConfiguration
    private let plugin: PluginDescriptor
    private let runtime: PluginRuntime
    private let downloadRoot: URL
    public init(configuration: OnlineSourceConfiguration, plugin: PluginDescriptor, runtime: PluginRuntime, downloadRoot: URL) {
        self.configuration = configuration; self.plugin = plugin; self.runtime = runtime; self.downloadRoot = downloadRoot
        descriptor = .init(sourceID: configuration.sourceID, kind: .remote, displayName: configuration.displayName, isReadOnly: true)
        providerKind = configuration.providerKind
        var flags: OnlineSourceCapabilities = []
        if plugin.onlineCapabilities.contains(.browse) { flags.insert(.browsing) }
        if plugin.onlineCapabilities.contains(.search) { flags.insert(.searching) }
        if plugin.onlineCapabilities.contains(.download) { flags.insert(.downloading) }
        if plugin.onlineCapabilities.contains(.playbackAccess) { flags.insert(.onlinePlayback) }
        onlineCapabilities = flags
    }
    private var instance: PluginInstanceConfiguration {
        .init(instanceID: configuration.sourceID.rawValue, credentialRecordID: configuration.credentialRecordID,
            acceptedPolicyVersion: configuration.privacyPolicyVersion)
    }
    private func check(_ capability: PluginOnlineCapability) throws {
        guard plugin.onlineCapabilities.contains(capability) else { throw PluginError.unsupportedCapability }
    }
    public func resolve(_ assetID: MediaItemID) async throws -> PlaybackResource { throw PluginError.unsupportedCapability }
    public func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? { nil }
    public func browse(_ request: SourceBrowseRequest) async throws -> SourceCatalogPage {
        try check(.browse)
        guard request.parentID == nil || request.parentID?.sourceID == descriptor.sourceID else { throw PluginError.invalidConfiguration }
        let page = try await runtime.perform(pluginID: plugin.id, configuration: instance, kind: .onlineSource) { loaded, context in
            guard let source = loaded.onlineSource as? any BrowsingSourcePlugin else { throw PluginError.invalidRegistration }
            return try await source.browse(parentID: request.parentID?.externalID, cursor: request.pageToken?.rawValue, context: context)
        }
        return try convert(page)
    }
    public func search(_ request: SourceSearchRequest) async throws -> SourceCatalogPage {
        try check(.search)
        let page = try await runtime.perform(pluginID: plugin.id, configuration: instance, kind: .onlineSource) { loaded, context in
            guard let source = loaded.onlineSource as? any SearchingSourcePlugin else { throw PluginError.invalidRegistration }
            return try await source.search(request.query, cursor: request.pageToken?.rawValue, context: context)
        }
        return try convert(page)
    }
    public func playbackAccess(for itemID: SourceObjectID, purpose: PlaybackPurpose) async throws -> PlaybackAccess {
        try check(.playbackAccess)
        guard itemID.sourceID == descriptor.sourceID else { throw PluginError.invalidConfiguration }
        return try await runtime.perform(pluginID: plugin.id, configuration: instance, kind: .onlineSource) { loaded, context in
            let access: PluginSourceAccess
            if purpose == .auditionRefresh, let source = loaded.onlineSource as? any RefreshingSourcePlugin {
                access = try await source.refresh(objectID: itemID.externalID, context: context)
            } else if let source = loaded.onlineSource as? any PlaybackSourcePlugin {
                access = try await source.playbackAccess(objectID: itemID.externalID, context: context)
            } else { throw PluginError.invalidRegistration }
            guard access.expiresAt.map({ $0 > Date() }) ?? true else { throw PluginError.invalidResponse }
            guard ["http", "https"].contains(access.url.scheme?.lowercased() ?? ""),
                  context.permissions.contains(.network) else { throw PluginError.permissionRequired }
            return .http(request: RemotePlaybackRequest(url: access.url, headers: access.headers, expiresAt: access.expiresAt), transcode: nil)
        }
    }
    public func download(_ itemID: SourceObjectID, options: DownloadOptions) async throws -> DownloadReceipt {
        try check(.download)
        guard itemID.sourceID == descriptor.sourceID else { throw PluginError.invalidConfiguration }
        // This operation owns only this fresh directory, including late-result cleanup.
        let operationRoot = downloadRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            return try await runtime.perform(pluginID: plugin.id, configuration: instance, kind: .onlineSource) { loaded, context in
                guard let source = loaded.onlineSource as? any DownloadSourcePlugin else { throw PluginError.invalidRegistration }
                let access = try await source.downloadAccess(objectID: itemID.externalID, context: context)
                guard access.expiresAt.map({ $0 > Date() }) ?? true else { throw PluginError.invalidResponse }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: operationRoot, withIntermediateDirectories: true)
                func destination(responseName: String? = nil) -> URL {
                    let names = [options.preferredFileName, access.suggestedFileName, responseName, access.url.lastPathComponent]
                    let fileExtension = names.compactMap { $0 }.map { URL(fileURLWithPath: $0).pathExtension }
                        .first { !$0.isEmpty && $0.count <= 12 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }
                    let file = operationRoot.appendingPathComponent("media")
                    return fileExtension.map { file.appendingPathExtension($0.lowercased()) } ?? file
                }
                let fileURL: URL
                if access.url.isFileURL {
                    // Local URLs are only supplied by trusted compiled reference plugins.
                    fileURL = destination()
                    try FileManager.default.copyItem(at: access.url, to: fileURL)
                } else {
                    guard ["http", "https"].contains(access.url.scheme?.lowercased() ?? ""),
                          context.permissions.contains(.network) else { throw PluginError.permissionRequired }
                    var request = URLRequest(url: access.url); request.allHTTPHeaderFields = access.headers
                    let (temporary, response) = try await URLSession.shared.download(for: request)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw PluginError.invalidResponse }
                    fileURL = destination(responseName: response.suggestedFilename)
                    try FileManager.default.moveItem(at: temporary, to: fileURL)
                }
                try Task.checkCancellation()
                let bytes = (try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value
                options.progress?(.init(receivedBytes: bytes ?? 0, totalBytes: bytes))
                return DownloadReceipt(sourceID: descriptor.sourceID, itemID: itemID, fileURL: fileURL, byteCount: bytes)
            }
        } catch { try? FileManager.default.removeItem(at: operationRoot); throw error }
    }
    private func convert(_ page: PluginSourcePage) throws -> SourceCatalogPage {
        guard page.items.count <= 500, page.items.allSatisfy({ !$0.objectID.isEmpty && !$0.title.isEmpty }),
              Set(page.items.map(\.objectID)).count == page.items.count else { throw PluginError.invalidResponse }
        return .init(items: page.items.map { item in
            SourceCatalogItem(id: .init(sourceID: descriptor.sourceID, externalID: item.objectID),
                kind: item.isContainer ? .folder : .audioFile, displayName: item.title, title: item.title, artist: item.artist,
                duration: item.durationSeconds.flatMap { $0.isFinite && $0 >= 0 ? .seconds($0) : nil },
                isPlayable: !item.isContainer && plugin.onlineCapabilities.contains(.playbackAccess))
        }, nextPageToken: page.nextCursor.map { .init(rawValue: $0) })
    }
}

private protocol PluginSourceWrapping: OnlineSource { var wrapped: PluginOnlineSourceAdapter { get } }
private extension PluginSourceWrapping {
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
}
private struct CatalogPluginSource: PluginSourceWrapping, CatalogBrowsingSource, CatalogSearchingSource { let wrapped: PluginOnlineSourceAdapter }
private struct PlaybackPluginSource: PluginSourceWrapping, PlaybackSource, CatalogBrowsingSource, CatalogSearchingSource { let wrapped: PluginOnlineSourceAdapter }
private struct DownloadPluginSource: PluginSourceWrapping, DownloadSource, CatalogSearchingSource { let wrapped: PluginOnlineSourceAdapter }
private struct PlaybackDownloadPluginSource: PluginSourceWrapping, PlaybackSource, DownloadSource, CatalogSearchingSource { let wrapped: PluginOnlineSourceAdapter }
