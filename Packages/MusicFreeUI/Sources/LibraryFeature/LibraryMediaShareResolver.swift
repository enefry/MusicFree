import DesignSystem
import Foundation
import MediaSourceAPI
import MusicDomain

struct LibraryMediaShareResolver: Sendable {
    enum ShareError: LocalizedError, Equatable {
        case emptySelection
        case unavailableTrack(String)
        case nonLocalTrack(String)
        case unreadableTrack(String)

        var errorDescription: String? {
            switch self {
            case .emptySelection:
                return L("没有可分享的歌曲。")
            case .unavailableTrack(let title):
                return L("“%@”的媒体文件不可用，无法分享。", title)
            case .nonLocalTrack(let title):
                return L("“%@”不是可分享的本地文件。", title)
            case .unreadableTrack(let title):
                return L("“%@”的媒体文件不存在或无法读取。", title)
            }
        }
    }

    private let sourceResolver: any MediaSourceResolving

    init(sourceResolver: any MediaSourceResolving) {
        self.sourceResolver = sourceResolver
    }

    func urls(for tracks: [Track]) async throws -> [URL] {
        guard !tracks.isEmpty else { throw ShareError.emptySelection }

        var sources: [MediaSourceID: any MediaSource] = [:]
        var seenURLs = Set<URL>()
        var urls: [URL] = []

        for track in tracks {
            try Task.checkCancellation()

            let source: any MediaSource
            if let cached = sources[track.assetID.sourceID] {
                source = cached
            } else {
                do {
                    source = try await sourceResolver.source(for: track.assetID.sourceID)
                    sources[track.assetID.sourceID] = source
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ShareError.unavailableTrack(track.title)
                }
            }

            let resource: PlaybackResource
            do {
                resource = try await source.resolve(track.assetID.mediaItemID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ShareError.unavailableTrack(track.title)
            }

            guard case .localFile(let url) = resource, url.isFileURL else {
                throw ShareError.nonLocalTrack(track.title)
            }

            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: resolvedURL.path,
                isDirectory: &isDirectory
            ),
                !isDirectory.boolValue,
                FileManager.default.isReadableFile(atPath: resolvedURL.path)
            else {
                throw ShareError.unreadableTrack(track.title)
            }

            if seenURLs.insert(resolvedURL).inserted {
                urls.append(resolvedURL)
            }
        }

        guard !urls.isEmpty else { throw ShareError.emptySelection }
        return urls
    }
}
