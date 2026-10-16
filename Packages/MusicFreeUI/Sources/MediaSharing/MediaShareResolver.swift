import DesignSystem
import Foundation
import MediaSourceAPI
import MusicDomain

public struct MediaShareResolver: Sendable {
    public enum ShareError: LocalizedError, Equatable {
        case emptySelection
        case unavailableTrack(String)
        case nonLocalTrack(String)
        case unreadableTrack(String)

        public var errorDescription: String? {
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
    private let stagingRoot: URL
    private let linkFile: @Sendable (URL, URL) throws -> Void

    public init(sourceResolver: any MediaSourceResolving) {
        self.sourceResolver = sourceResolver
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicFree/MediaShares", isDirectory: true)
        linkFile = { try FileManager.default.linkItem(at: $0, to: $1) }
    }

    init(
        sourceResolver: any MediaSourceResolving,
        stagingRoot: URL,
        linkFile: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.linkItem(at: $0, to: $1)
        }
    ) {
        self.sourceResolver = sourceResolver
        self.stagingRoot = stagingRoot
        self.linkFile = linkFile
    }

    @concurrent
    public func prepare(for tracks: [Track]) async throws -> PreparedMediaShare {
        guard !tracks.isEmpty else { throw ShareError.emptySelection }

        var sources: [MediaSourceID: any MediaSource] = [:]
        var seenURLs = Set<URL>()
        var files: [(track: Track, url: URL)] = []
        var readLeases: [MediaResourceReadLease] = []
        // Keep managed originals alive until all hard links/copies are ready.
        // Retaining only their URLs allows conversion or removal to retire them.
        defer { withExtendedLifetime(readLeases) {} }

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

            guard let url = resource.localFileURL, url.isFileURL else {
                throw ShareError.nonLocalTrack(track.title)
            }
            if case .leasedLocalFile(_, let lease) = resource {
                readLeases.append(lease)
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
                files.append((track, resolvedURL))
            }
        }

        try Task.checkCancellation()
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var names = Set<String>()
            var urls: [URL] = []
            for file in files {
                try Task.checkCancellation()
                let name = Self.fileName(for: file.track, sourceURL: file.url, usedNames: &names)
                let destination = directory.appendingPathComponent(name)
                do {
                    try linkFile(file.url, destination)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Cross-volume files and some providers cannot be hard linked.
                    try Task.checkCancellation()
                    try fileManager.copyItem(at: file.url, to: destination)
                }
                urls.append(destination)
            }
            try Task.checkCancellation()
            return PreparedMediaShare(urls: urls, directory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private static func fileName(for track: Track, sourceURL: URL, usedNames: inout Set<String>) -> String {
        let fileExtension = sourceURL.pathExtension
        var title = track.title
        if !fileExtension.isEmpty, title.lowercased().hasSuffix("." + fileExtension.lowercased()) {
            title = String(title.dropLast(fileExtension.count + 1))
        }
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|")
            .union(.controlCharacters)
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        var stem = title.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: trim)
        if stem.isEmpty { stem = "Music" }
        // Keep multibyte titles within common filesystem filename limits.
        while stem.utf8.count > 180 { stem.removeLast() }
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        var name = stem + suffix
        var index = 2
        while !usedNames.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted {
            name = "\(stem) (\(index))\(suffix)"
            index += 1
        }
        return name
    }
}
