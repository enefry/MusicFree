import Foundation
import MusicDomain
import MusicFreePluginAPI
import MusicFreePluginRuntime

public struct PluginLyricsProviderAdapter: LyricsProviding {
    public let pluginID: PluginID
    public let runtime: PluginRuntime
    public var provider: LyricsProviderID { .init(rawValue: pluginID.rawValue) }
    public init(pluginID: PluginID, runtime: PluginRuntime) { self.pluginID = pluginID; self.runtime = runtime }
    public func fetchLyrics(for query: LyricsQuery) async throws -> TrackLyrics? {
        let dto = PluginTrackQuery(title: query.title, artist: query.artistName, album: query.albumName, durationSeconds: query.durationSeconds)
        do {
            return try await runtime.perform(pluginID: pluginID, kind: .lyrics) { instances, context in
                guard let plugin = instances.lyrics else { throw PluginError.unsupportedCapability }
                let candidates = try await plugin.candidates(for: dto, context: context).filter { dto.matches($0.track) }
                guard candidates.count <= 1 else { throw PluginError.ambiguous }
                guard let candidate = candidates.first else { return nil }
                guard candidate.rawText.utf8.count <= 2 * 1024 * 1024, candidate.lines.count <= 100_000,
                      candidate.lines.allSatisfy({ line in
                          line.startMilliseconds >= 0 && line.words.allSatisfy { $0.startMilliseconds >= 0 && $0.durationMilliseconds >= 0 }
                      }) else { throw PluginError.invalidResponse }
                // Current host renders line timing and inline translation;
                // preserve the structured words for storage and future rendering.
                let lines = candidate.lines.map { line in
                    LyricLine(timestampMilliseconds: line.startMilliseconds,
                        text: [line.text, line.translation].compactMap { $0 }.joined(separator: "\n"),
                        translation: line.translation,
                        words: line.words.map { LyricWord(startMilliseconds: $0.startMilliseconds,
                            durationMilliseconds: $0.durationMilliseconds, text: $0.text) })
                }
                return lines.isEmpty ? TrackLyrics(rawText: candidate.rawText) : TrackLyrics(rawText: candidate.rawText, timedLines: lines)
            }
        } catch is CancellationError { throw CancellationError() }
        catch PluginError.staleOperation { throw CancellationError() }
        catch PluginError.ambiguous { throw LyricsProviderError.noMatch }
        catch PluginError.invalidResponse { throw LyricsProviderError.invalidResponse }
        catch let error as PluginDataError {
            switch error {
            case .noMatch: throw LyricsProviderError.noMatch
            case .network, .offline: throw LyricsProviderError.network
            case .invalidResponse: throw LyricsProviderError.invalidResponse
            case .payloadTooLarge: throw LyricsProviderError.payloadTooLarge
            case .requestFailed(let code, let status): throw LyricsProviderError.requestFailed(code: code, httpStatus: status)
            case .rateLimited(_, let status): throw LyricsProviderError.requestFailed(code: "plugin_rate_limited", httpStatus: status)
            default: throw LyricsProviderError.unavailable
            }
        }
        catch PluginError.requestFailed { throw LyricsProviderError.requestFailed(code: "plugin_request_failed", httpStatus: nil) }
        catch { throw LyricsProviderError.unavailable }
    }
}
