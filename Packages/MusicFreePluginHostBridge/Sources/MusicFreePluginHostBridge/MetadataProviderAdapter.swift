import Foundation
import MusicDomain
import LibraryAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime

public actor PluginMetadataProviderAdapter: MetadataEnrichmentProviding {
    public nonisolated let pluginID: PluginID
    public nonisolated var provider: MetadataEnrichmentProvider { .init(rawValue: runtime.registry.descriptors[pluginID]?.dataProviderID ?? pluginID.rawValue) }
    private let runtime: PluginRuntime
    private let durationProvider: (@Sendable (MediaItemID) async -> TimeInterval?)?
    private var artworkReferences: [MetadataEnrichmentCandidate: String] = [:]
    public init(pluginID: PluginID, runtime: PluginRuntime, durationProvider: (@Sendable (MediaItemID) async -> TimeInterval?)? = nil) {
        self.pluginID = pluginID; self.runtime = runtime; self.durationProvider = durationProvider
    }
    public func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
        if let status = try? await runtime.metadataAuthorization(pluginID: pluginID, requesting: false) {
            return MetadataEnrichmentAuthorizationStatus(rawValue: status.rawValue) ?? .unavailable
        }
        guard let snapshot = await runtime.snapshots().first(where: { $0.id == pluginID }) else { return .unavailable }
        switch snapshot.state {
        case .registered, .loading, .ready, .running, .failed:
            return (try? await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, _ in
                guard let plugin = instances.metadata else { return MetadataEnrichmentAuthorizationStatus.unavailable }
                return MetadataEnrichmentAuthorizationStatus(rawValue: await plugin.authorizationStatus().rawValue) ?? .unavailable
            }) ?? .unavailable
        case .permissionRequired: return .denied
        default: return .unavailable
        }
    }
    public func requestAuthorization() async -> MetadataEnrichmentAuthorizationStatus {
        if let status = try? await runtime.metadataAuthorization(pluginID: pluginID, requesting: true) {
            return MetadataEnrichmentAuthorizationStatus(rawValue: status.rawValue) ?? .unavailable
        }
        return (try? await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, _ in
            guard let plugin = instances.metadata else { return MetadataEnrichmentAuthorizationStatus.unavailable }
            return MetadataEnrichmentAuthorizationStatus(rawValue: await plugin.requestAuthorization().rawValue) ?? .unavailable
        }) ?? .unavailable
    }
    public func search(_ input: MetadataEnrichmentQuery) async throws -> [MetadataEnrichmentCandidate] {
        let refreshed = await durationProvider?(input.itemID)
        let query = MetadataEnrichmentQuery(itemID: input.itemID, title: input.title, artistName: input.artistName,
            albumName: input.albumName, fileName: input.fileName, durationSeconds: refreshed ?? input.durationSeconds,
            missingFields: input.missingFields, isFilenameFallback: input.isFilenameFallback)
        let title = query.isFilenameFallback ? query.filenameTitle : query.title
        let artist = query.artistName ?? (query.isFilenameFallback ? query.filenameArtist : nil)
        let dto = PluginTrackQuery(title: title ?? "", artist: artist, album: query.albumName, durationSeconds: query.durationSeconds)
        let fields = Set(query.missingFields.compactMap { PluginMetadataField(rawValue: $0.rawValue) })
        do {
            let (result, references) = try await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, context in
                guard let plugin = instances.metadata else { throw PluginError.unsupportedCapability }
                let candidates = try await plugin.candidates(for: dto, fields: fields, context: context)
                guard candidates.count <= 100 else { throw PluginError.invalidResponse }
                var result: [MetadataEnrichmentCandidate] = []
                var references: [MetadataEnrichmentCandidate: String] = [:]
                for candidate in candidates {
                    let evidence = MetadataEnrichmentCandidate(catalogID: candidate.id, title: candidate.track.title,
                        artistName: candidate.track.artist, albumName: candidate.track.album,
                        durationSeconds: candidate.track.durationSeconds)
                    // Catalog releases can differ from local album tags. Apply the same
                    // title/artist/version matcher as legacy enrichment.
                    guard !candidate.id.isEmpty,
                          case .matched = MetadataEnrichmentMatcher.match(query: query, candidates: [evidence]) else { continue }
                    func text(_ field: PluginMetadataField) -> String? { fields.contains(field) ? candidate.patch.text[field] : nil }
                    func number(_ field: PluginMetadataField) -> Int? { fields.contains(field) ? candidate.patch.numbers[field] : nil }
                    // Keep unrequested identity fields for the coordinator's final
                    // match. It filters existing fields when creating the supplement.
                    let converted = MetadataEnrichmentCandidate(catalogID: candidate.id, title: text(.title) ?? candidate.track.title,
                        artistName: fields.contains(.artist) ? text(.artist) : candidate.track.artist,
                        albumArtistName: text(.albumArtist),
                        albumName: fields.contains(.album) ? text(.album) : candidate.track.album,
                        genreName: text(.genre), trackNumber: number(.trackNumber), discNumber: number(.discNumber),
                        year: number(.year), durationSeconds: candidate.track.durationSeconds)
                    result.append(converted)
                    if fields.contains(.artwork), let reference = candidate.artworkReference {
                        references[converted] = reference
                    }
                }
                return (result, references)
            }
            // Bound transient references while keeping the current search batch.
            // Key by the full candidate so a repeated catalog ID cannot mix tracks.
            if artworkReferences.count + references.count > 1_000 {
                artworkReferences.removeAll(keepingCapacity: true)
            }
            for candidate in result { artworkReferences[candidate] = references[candidate] }
            return result
        } catch { throw Self.enrichmentError(error) }
    }

    public func artworkData(for candidate: MetadataEnrichmentCandidate) async throws -> Data? {
        let reference = artworkReferences[candidate]
        do {
            return try await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, context in
                guard let plugin = instances.metadata else { throw PluginError.unsupportedCapability }
                let data: Data?
                if let embedded = candidate.artworkData {
                    data = embedded
                } else if let reference {
                    data = try await plugin.artwork(reference: reference, context: context)
                } else {
                    return nil
                }
                guard (data?.count ?? 0) <= 20 * 1024 * 1024 else { throw PluginDataError.payloadTooLarge }
                return data
            }
        } catch { throw Self.enrichmentError(error) }
    }

    private static func enrichmentError(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError, PluginError.staleOperation: return CancellationError()
        case let error as PluginDataError:
            switch error {
            case .notAuthorized: return MetadataEnrichmentError.notAuthorized
            case .offline, .network: return MetadataEnrichmentError.offline
            case .rateLimited(let retry, let status): return MetadataEnrichmentError.rateLimited(retryAfterSeconds: retry, httpStatus: status)
            case .requestFailed(let code, let status): return MetadataEnrichmentError.requestFailed(code: code, httpStatus: status)
            case .invalidResponse, .payloadTooLarge: return MetadataEnrichmentError.requestFailed(code: "plugin_invalid_response", httpStatus: nil)
            default: return MetadataEnrichmentError.unavailable
            }
        case PluginError.requestFailed: return MetadataEnrichmentError.requestFailed(code: "plugin_request_failed", httpStatus: nil)
        default: return MetadataEnrichmentError.unavailable
        }
    }
}
