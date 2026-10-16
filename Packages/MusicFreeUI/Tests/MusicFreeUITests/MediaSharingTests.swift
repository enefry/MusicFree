@testable import MediaSharing
import Foundation
import MediaSourceAPI
import MusicDomain
import MusicTestSupport
import Testing
import UIKit

@Suite("Audio resource sharing")
struct MediaSharingTests {
    @MainActor
    private final class RecordingPresenter: UIViewController {
        var requestedActivity: UIViewController?

        override func present(_ viewControllerToPresent: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
            requestedActivity = viewControllerToPresent
            completion?()
        }
    }

    private struct Fixture {
        let root: URL
        let source: FakeMediaSource
        let tracks: [Track]
        let sourceURLs: [URL]
        var stagingRoot: URL { root.appendingPathComponent("shares", isDirectory: true) }

        init(titles: [String] = ["夜曲"]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusicFree-ShareTests/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var urls: [URL] = []
            var tracks: [Track] = []
            var resources: [MediaItemID: FakeMediaSourceResolveResult] = [:]
            for (index, title) in titles.enumerated() {
                let id = MediaItemID(sourceID: .local, externalID: "asset-\(index)")
                let url = root.appendingPathComponent(String(repeating: "a", count: 63) + "\(index).flac")
                try Data([0x66, 0x4c, 0x61, 0x43, UInt8(index)]).write(to: url)
                urls.append(url)
                tracks.append(Track(id: id, title: title, fileName: "original.mp3"))
                resources[id] = .resource(.localFile(url))
            }
            sourceURLs = urls
            self.tracks = tracks
            source = FakeMediaSource(
                descriptor: MediaSourceDescriptor(sourceID: .local, kind: .local, displayName: "Local"),
                resolveResults: resources
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Named hard links contain audio bytes and survive removal of the library path")
    func hardLinksKeepAudioAvailable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let share = try await MediaShareResolver(sourceResolver: fixture.source, stagingRoot: fixture.stagingRoot)
            .prepare(for: fixture.tracks)
        defer { share.cleanup() }
        let url = try #require(share.urls.first)
        #expect(url.lastPathComponent == "夜曲.flac")
        let original = try FileManager.default.attributesOfItem(atPath: fixture.sourceURLs[0].path)
        let exported = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(original[.systemFileNumber] as? NSNumber == exported[.systemFileNumber] as? NSNumber)
        let audio = try Data(contentsOf: fixture.sourceURLs[0])
        try FileManager.default.removeItem(at: fixture.sourceURLs[0])
        #expect(try Data(contentsOf: url) == audio)
        share.cleanup()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Retires each original path as soon as its last read lease is released.
    private struct RetiringSource: MediaSource, MediaSourceResolving {
        let files: [MediaItemID: URL]
        let descriptor = MediaSourceDescriptor(sourceID: .local, kind: .local, displayName: "Retiring local files")
        let capabilities: MediaSourceCapabilities = []

        func source(for sourceID: MediaSourceID) async throws -> any MediaSource { self }
        func artwork(for artworkID: ArtworkID) async throws -> ArtworkResource? { nil }
        func resolve(_ itemID: MediaItemID) async throws -> PlaybackResource {
            guard let url = files[itemID] else { throw MediaSourceError.invalidResource }
            return .leasedLocalFile(url, MediaResourceReadLease {
                try? FileManager.default.removeItem(at: url)
            })
        }
    }

    @Test("Sharing retains read leases until every named file has been staged", arguments: [false, true])
    func readLeasesProtectStaging(copyFallback: Bool) async throws {
        let fixture = try Fixture(titles: ["First", "Second"])
        defer { fixture.cleanup() }
        let bytes = try fixture.sourceURLs.map { try Data(contentsOf: $0) }
        let source = RetiringSource(files: Dictionary(uniqueKeysWithValues:
            zip(fixture.tracks.map { $0.assetID.mediaItemID }, fixture.sourceURLs)))
        let resolver = MediaShareResolver(sourceResolver: source, stagingRoot: fixture.stagingRoot,
            linkFile: { source, destination in
                if copyFallback { throw CocoaError(.fileWriteUnsupportedScheme) }
                try FileManager.default.linkItem(at: source, to: destination)
            })
        let share = try await resolver.prepare(for: fixture.tracks)
        defer { share.cleanup() }
        #expect(try share.urls.map { try Data(contentsOf: $0) } == bytes)
        #expect(fixture.sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("Filesystems that reject hard links fall back to a complete copy")
    func copyFallbackPreservesBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let resolver = MediaShareResolver(
            sourceResolver: fixture.source,
            stagingRoot: fixture.stagingRoot,
            linkFile: { _, _ in throw CocoaError(.fileWriteUnsupportedScheme) }
        )
        let share = try await resolver.prepare(for: fixture.tracks)
        defer { share.cleanup() }
        let url = try #require(share.urls.first)
        let original = try FileManager.default.attributesOfItem(atPath: fixture.sourceURLs[0].path)
        let exported = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(original[.systemFileNumber] as? NSNumber != exported[.systemFileNumber] as? NSNumber)
        #expect(try Data(contentsOf: url) == Data(contentsOf: fixture.sourceURLs[0]))
        share.cleanup()
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
    }

    @Test("Unicode titles, unsafe names, duplicates and format extensions export correctly")
    func filenamesAreSafeAndDistinct() async throws {
        let fixture = try Fixture(titles: ["Song", "song", "Song (2)", "../夜:曲.flac", "...", String(repeating: "音", count: 120)])
        defer { fixture.cleanup() }
        let share = try await MediaShareResolver(sourceResolver: fixture.source, stagingRoot: fixture.stagingRoot)
            .prepare(for: fixture.tracks)
        defer { share.cleanup() }
        #expect(Array(share.urls.prefix(5)).map(\.lastPathComponent) == [
            "Song.flac", "song (2).flac", "Song (2) (2).flac", "_夜_曲.flac", "Music.flac"
        ])
        #expect(share.urls.allSatisfy { $0.pathExtension == "flac" && $0.lastPathComponent.utf8.count <= 255 })
        #expect(Set(share.urls.map { $0.lastPathComponent.lowercased() }).count == fixture.tracks.count)
        for (index, url) in share.urls.enumerated() {
            #expect(try Data(contentsOf: url) == Data(contentsOf: fixture.sourceURLs[index]))
        }
    }

    @Test("Failed or cancelled preparation removes already staged files", arguments: [true, false])
    func failureCleansPartialShare(cancelled: Bool) async throws {
        let fixture = try Fixture(titles: ["First", "Second"])
        defer { fixture.cleanup() }
        let resolver = MediaShareResolver(
            sourceResolver: fixture.source,
            stagingRoot: fixture.stagingRoot,
            linkFile: { source, destination in
                if destination.lastPathComponent == "Second.flac" {
                    if cancelled { throw CancellationError() }
                    try FileManager.default.removeItem(at: source)
                    throw CocoaError(.fileWriteUnsupportedScheme)
                }
                try FileManager.default.linkItem(at: source, to: destination)
            }
        )
        await #expect(throws: (any Error).self) { _ = try await resolver.prepare(for: fixture.tracks) }
        if FileManager.default.fileExists(atPath: fixture.stagingRoot.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.stagingRoot.path).isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
    }

    @MainActor
    @Test("System share completion and cancellation clean only temporary audio files", arguments: [true, false])
    func activityCompletionCleansFiles(completed: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let share = try await MediaShareResolver(sourceResolver: fixture.source, stagingRoot: fixture.stagingRoot)
            .prepare(for: fixture.tracks)
        let activity = MediaShareActivityViewController(share: share)
        #expect(try Data(contentsOf: share.urls[0]) == Data(contentsOf: fixture.sourceURLs[0]))
        activity.completionWithItemsHandler?(.copyToPasteboard, completed, nil, nil)
        #expect(!FileManager.default.fileExists(atPath: share.urls[0].path))
        #expect(FileManager.default.fileExists(atPath: fixture.sourceURLs[0].path))
    }

    @MainActor
    @Test("Player sharing passes named audio file URLs to a native share controller")
    func presenterSharesResource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let presenter = RecordingPresenter()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        presenter.loadViewIfNeeded()
        presenter.view.layoutIfNeeded()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        let sharing = MediaSharePresenter(sourceResolver: fixture.source)
        defer { sharing.cancel() }
        #expect(presenter.view.window != nil)
        sharing.present(itemID: fixture.tracks[0].id, track: fixture.tracks[0], from: presenter)
        for _ in 0..<100 where presenter.requestedActivity == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.source.resolveCalls == [fixture.tracks[0].assetID.mediaItemID])
        #expect(presenter.view.window != nil)
        let activity = try #require(presenter.requestedActivity as? MediaShareActivityViewController)
        #expect(activity.share.urls[0].lastPathComponent == "夜曲.flac")
        #expect(try Data(contentsOf: activity.share.urls[0]) == Data(contentsOf: fixture.sourceURLs[0]))
        activity.completionWithItemsHandler?(nil, false, nil, nil)
    }
}
