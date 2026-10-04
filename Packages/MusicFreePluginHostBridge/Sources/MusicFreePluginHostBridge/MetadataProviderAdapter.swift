import Foundation
import MusicDomain
import LibraryAPI
import MusicFreePluginAPI
import MusicFreePluginRuntime

public actor PluginMetadataProviderAdapter: MetadataEnrichmentProviding {
    public nonisolated let pluginID: PluginID
    public nonisolated var provider: MetadataEnrichmentProvider { .init(rawValue: pluginID.rawValue) }
    private let runtime: PluginRuntime
    public init(pluginID: PluginID, runtime: PluginRuntime) { self.pluginID = pluginID; self.runtime = runtime }
    public func authorizationStatus() async -> MetadataEnrichmentAuthorizationStatus {
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
        (try? await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, _ in
            guard let plugin = instances.metadata else { return MetadataEnrichmentAuthorizationStatus.unavailable }
            return MetadataEnrichmentAuthorizationStatus(rawValue: await plugin.requestAuthorization().rawValue) ?? .unavailable
        }) ?? .unavailable
    }
    public func search(_ query: MetadataEnrichmentQuery) async throws -> [MetadataEnrichmentCandidate] {
        let title = query.isFilenameFallback ? query.filenameTitle : query.title
        let artist = query.artistName ?? (query.isFilenameFallback ? query.filenameArtist : nil)
        let dto = PluginTrackQuery(title: title ?? "", artist: artist, album: query.albumName, durationSeconds: query.durationSeconds)
        let fields = Set(query.missingFields.compactMap { PluginMetadataField(rawValue: $0.rawValue) })
        do {
            return try await runtime.perform(pluginID: pluginID, kind: .metadata) { instances, context in
                guard let plugin = instances.metadata else { throw PluginError.unsupportedCapability }
                let candidates = try await plugin.candidates(for: dto, fields: fields, context: context)
                guard candidates.count <= 100 else { throw PluginError.invalidResponse }
                var result: [MetadataEnrichmentCandidate] = []
                for candidate in candidates {
                    let evidence = MetadataEnrichmentCandidate(catalogID: candidate.id, title: candidate.track.title,
                        artistName: candidate.track.artist, albumName: candidate.track.album,
                        durationSeconds: candidate.track.durationSeconds)
                    // Catalog releases can differ from local album tags. Apply the same
                    // title/artist/version matcher as legacy enrichment before fetching artwork.
                    guard !candidate.id.isEmpty,
                          case .matched = MetadataEnrichmentMatcher.match(query: query, candidates: [evidence]) else { continue }
                    func text(_ field: PluginMetadataField) -> String? { fields.contains(field) ? candidate.patch.text[field] : nil }
                    func number(_ field: PluginMetadataField) -> Int? { fields.contains(field) ? candidate.patch.numbers[field] : nil }
                    var artwork: Data?
                    if fields.contains(.artwork), let reference = candidate.artworkReference {
                        artwork = try await plugin.artwork(reference: reference, context: context)
                        guard (artwork?.count ?? 0) <= 20 * 1024 * 1024 else { throw PluginError.invalidResponse }
                    }
                    result.append(MetadataEnrichmentCandidate(catalogID: candidate.id, title: text(.title) ?? candidate.track.title,
                        artistName: text(.artist), albumArtistName: text(.albumArtist), albumName: text(.album),
                        genreName: text(.genre), trackNumber: number(.trackNumber), discNumber: number(.discNumber),
                        year: number(.year), durationSeconds: candidate.track.durationSeconds, artworkData: artwork))
                }
                return result
            }
        } catch is CancellationError { throw CancellationError() }
        catch PluginError.staleOperation { throw CancellationError() }
        catch let error as PluginDataError {
            switch error {
            case .notAuthorized: throw MetadataEnrichmentError.notAuthorized
            case .offline, .network: throw MetadataEnrichmentError.offline
            case .rateLimited(let retry, let status): throw MetadataEnrichmentError.rateLimited(retryAfterSeconds: retry, httpStatus: status)
            case .requestFailed(let code, let status): throw MetadataEnrichmentError.requestFailed(code: code, httpStatus: status)
            case .invalidResponse, .payloadTooLarge: throw MetadataEnrichmentError.requestFailed(code: "plugin_invalid_response", httpStatus: nil)
            default: throw MetadataEnrichmentError.unavailable
            }
        }
        catch PluginError.requestFailed { throw MetadataEnrichmentError.requestFailed(code: "plugin_request_failed", httpStatus: nil) }
        catch { throw MetadataEnrichmentError.unavailable }
    }
}
