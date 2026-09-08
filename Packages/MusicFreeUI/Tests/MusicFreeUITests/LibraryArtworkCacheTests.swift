@testable import LibraryFeature
import AppServices
import DesignSystem
import Foundation
import MediaSourceAPI
import MusicDomain
import Testing
import UIKit

@Suite("Kingfisher library artwork", .serialized)
@MainActor
struct LibraryArtworkCacheTests {
    @Test("A decoded local cover survives deletion of its file and is synchronously reusable")
    func localMemoryHit() async throws {
        let pipeline = makePipeline()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("library-kingfisher-test.png")
        defer { try? FileManager.default.removeItem(at: file) }
        try imageData().write(to: file)
        let service = CountingArtworkService(resource: .localFile(file))
        let id = ArtworkID("local-memory")
        let image = try #require(await pipeline.image(
            artworkID: id, sourceID: .local, maximumPixelDimension: 160, serving: service
        ))
        try FileManager.default.removeItem(at: file)
        #expect(pipeline.cachedImage(artworkID: id, sourceID: .local, maximumPixelDimension: 160) === image)
        let again = await pipeline.image(
            artworkID: id, sourceID: .local, maximumPixelDimension: 160, serving: service
        )
        #expect(again === image)
        #expect(await service.requestCount == 1)
        let view = MusicFreeUIKitArtworkView()
        let binding = LibraryArtworkBinding(view: view, pipeline: pipeline)
        binding.configure(artworkID: id, maximumPixelDimension: 160, serving: service)
        // No yield: this must be true in the very same cell configuration pass.
        #expect(view.image === image)
        #expect(!view.isLoading)
    }

    @Test("Source and output size stay separate in the Kingfisher cache")
    func sourceAndSizeIsolation() async throws {
        let pipeline = makePipeline()
        let service = CountingArtworkService(data: imageData())
        let id = ArtworkID("sized-cover")
        let small = try #require(await pipeline.image(
            artworkID: id, sourceID: .local, maximumPixelDimension: 160, serving: service
        ))
        #expect(max(small.size.width, small.size.height) <= 160)
        #expect(pipeline.cachedImage(artworkID: id, sourceID: .local, maximumPixelDimension: 768) == nil)
        #expect(pipeline.cachedImage(artworkID: id, sourceID: MediaSourceID("other"), maximumPixelDimension: 160) == nil)
        let large = try #require(await pipeline.image(
            artworkID: id, sourceID: .local, maximumPixelDimension: 768, serving: service
        ))
        #expect(max(large.size.width, large.size.height) > 160)
        #expect(max(large.size.width, large.size.height) <= 768)
        #expect(await service.requestCount == 2)
    }

    @Test("Concurrent cells share one request; text reconfiguration preserves the in-flight load")
    func concurrentRequests() async throws {
        let pipeline = makePipeline()
        let service = CountingArtworkService(data: imageData(), gated: true)
        let id = ArtworkID("concurrent-cover")
        let first = MusicFreeUIKitArtworkView()
        let second = MusicFreeUIKitArtworkView()
        let binding1 = LibraryArtworkBinding(view: first, pipeline: pipeline)
        let binding2 = LibraryArtworkBinding(view: second, pipeline: pipeline)
        binding1.configure(artworkID: id, maximumPixelDimension: 160, serving: service)
        binding2.configure(artworkID: id, maximumPixelDimension: 160, serving: service)
        for _ in 0..<10 {
            binding1.configure(artworkID: id, maximumPixelDimension: 160, serving: service)
        }
        await service.release()
        try await waitUntil { first.image != nil && second.image != nil }
        #expect(first.image === second.image)
        #expect(await service.requestCount == 1)
    }

    @Test("Both album cell styles keep loaded artwork when artist subtitles arrive")
    func albumSubtitleReconfiguration() async throws {
        let id = ArtworkID("subtitle-\(UUID().uuidString)")
        let album = Album(id: AlbumID("subtitle-album"), title: "Gold", artwork: ArtworkReference(id: id))
        let service = CountingArtworkService(data: imageData())
        let grid = LibraryCollectionAlbumCell(frame: CGRect(x: 0, y: 0, width: 200, height: 260))
        let list = LibraryCollectionAlbumListCell(frame: CGRect(x: 0, y: 0, width: 400, height: 60))
        grid.configure(album: album, subtitle: "2009 · 20 tracks", artworkServing: service, artworkPixelDimension: 768)
        list.configure(album: album, subtitle: "2009 · 20 tracks", artworkServing: service)
        let gridView = try #require(artworkView(in: grid))
        let listView = try #require(artworkView(in: list))
        try await waitUntil { gridView.image != nil && listView.image != nil }
        let gridImage = gridView.image
        let listImage = listView.image
        grid.configure(album: album, subtitle: "Carpenters · 2009 · 20 tracks", artworkServing: service, artworkPixelDimension: 768)
        list.configure(album: album, subtitle: "Carpenters · 2009 · 20 tracks", artworkServing: service)
        #expect(gridView.image === gridImage)
        #expect(listView.image === listImage)
        #expect(!gridView.isLoading && !listView.isLoading)
        #expect(grid.accessibilityValue == "Carpenters")
        #expect(list.accessibilityValue == "Carpenters · 2009 · 20 tracks")
        #expect(await service.requestCount == 2) // One decode per output size.

        grid.prepareForReuse()
        #expect(gridView.image == nil)
        grid.configure(album: album, subtitle: "Carpenters", artworkServing: service, artworkPixelDimension: 768)
        #expect(gridView.image === gridImage)
        #expect(!gridView.isLoading)
    }

    @Test("A stale cover cannot overwrite a replacement, and removing artwork restores the placeholder")
    func replacementAndRemoval() async throws {
        let pipeline = makePipeline()
        let oldService = CountingArtworkService(data: imageData(), gated: true)
        let newService = CountingArtworkService(data: imageData(color: .blue))
        let view = MusicFreeUIKitArtworkView()
        let binding = LibraryArtworkBinding(view: view, pipeline: pipeline)
        binding.configure(artworkID: ArtworkID("old"), maximumPixelDimension: 160, serving: oldService)
        try await waitUntil { await oldService.requestCount == 1 }
        binding.configure(artworkID: ArtworkID("new"), maximumPixelDimension: 160, serving: newService)
        try await waitUntil { view.image != nil }
        let replacement = view.image
        await oldService.release()
        try await waitUntil {
            pipeline.cachedImage(artworkID: ArtworkID("old"), sourceID: .local, maximumPixelDimension: 160) != nil
        }
        #expect(view.image === replacement)
        binding.configure(artworkID: nil, maximumPixelDimension: 160, serving: newService)
        #expect(view.image == nil)
        #expect(!view.isLoading)
    }

    @Test("Kingfisher providers preserve the 20 MiB limit for files and streams")
    func boundedProvider() async throws {
        let oversized = Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("library-kingfisher-oversized.bin")
        defer { try? FileManager.default.removeItem(at: file) }
        try oversized.write(to: file)
        for resource in [ArtworkResource.localFile(file), .inMemory(oversized)] {
            let provider = LibraryArtworkDataProvider(
                cacheKey: "oversized", artworkID: ArtworkID("oversized"), sourceID: .local,
                serving: CountingArtworkService(resource: resource)
            )
            await #expect(throws: ArtworkImageLoaderError.self) { _ = try await provider.data() }
        }
    }

    @Test("Missing images stop the spinner and repeated requests are throttled")
    func missingImage() async throws {
        let pipeline = makePipeline()
        let service = CountingArtworkService(resource: nil)
        let view = MusicFreeUIKitArtworkView()
        let binding = LibraryArtworkBinding(view: view, pipeline: pipeline)
        binding.configure(artworkID: ArtworkID("missing"), maximumPixelDimension: 160, serving: service)
        try await waitUntil { !view.isLoading }
        #expect(view.image == nil)
        #expect(await pipeline.image(artworkID: ArtworkID("missing"), sourceID: .local, maximumPixelDimension: 160, serving: service) == nil)
        #expect(await service.requestCount == 1)
    }

    private func makePipeline() -> LibraryArtworkImagePipeline {
        LibraryArtworkImagePipeline(cacheName: "com.musicfree.tests.artwork")
    }

    private func imageData(color: UIColor = .red) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1_024, height: 512), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 512))
        }
    }

    private func artworkView(in view: UIView) -> MusicFreeUIKitArtworkView? {
        if let artwork = view as? MusicFreeUIKitArtworkView { return artwork }
        return view.subviews.lazy.compactMap { artworkView(in: $0) }.first
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum WaitError: Error { case timedOut }
}

private actor CountingArtworkService: ArtworkServing {
    let resource: ArtworkResource?
    let data: Data?
    private var gated: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    init(resource: ArtworkResource?, gated: Bool = false) {
        self.resource = resource
        self.data = nil
        self.gated = gated
    }

    init(data: Data, gated: Bool = false) {
        self.resource = nil
        self.data = data
        self.gated = gated
    }

    func artwork(for artworkID: ArtworkID, sourceID: MediaSourceID) async throws -> ArtworkResource? {
        requestCount += 1
        if gated { await withCheckedContinuation { waiters.append($0) } }
        // Each service request owns a fresh stream, as in production.
        return data.map(ArtworkResource.inMemory) ?? resource
    }

    func release() {
        gated = false
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
