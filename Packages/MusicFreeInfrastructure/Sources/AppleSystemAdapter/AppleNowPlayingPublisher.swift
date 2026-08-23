import Foundation
import MusicDomain
import SystemIntegrationAPI

#if canImport(MediaPlayer)
import MediaPlayer
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
#endif

struct AppleNowPlayingInfo: Equatable, Sendable {
    let itemID: MediaItemID
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval?
    let elapsed: TimeInterval
    let playbackState: NowPlayingPlaybackState
    let rate: Float
    let queuePosition: Int?
    let queueCount: Int?
    let artworkData: Data?
}

@MainActor
protocol AppleNowPlayingInfoClient: AnyObject {
    func publish(_ info: AppleNowPlayingInfo) throws
    func clear() throws
}

#if canImport(MediaPlayer)
enum PlatformNowPlayingArtworkFactory {
    nonisolated static func make(from data: Data?) -> MPMediaItemArtwork? {
        guard let data else { return nil }

#if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let requestHandler: @Sendable (CGSize) -> UIImage = { requestedSize in
            Self.scaled(image: image, to: requestedSize)
        }
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: requestHandler)
#elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let requestHandler: @Sendable (CGSize) -> NSImage = { requestedSize in
            Self.scaled(image: image, to: requestedSize)
        }
        return MPMediaItemArtwork(boundsSize: image.size, requestHandler: requestHandler)
#else
        return nil
#endif
    }

#if os(iOS)
    nonisolated private static func scaled(image: UIImage, to requestedSize: CGSize) -> UIImage {
        guard requestedSize.width > 0, requestedSize.height > 0,
              image.size.width > 0, image.size.height > 0
        else {
            return image
        }

        let scale = min(
            requestedSize.width / image.size.width,
            requestedSize.height / image.size.height
        )
        guard scale > 0, scale < 1 else { return image }

        let size = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
#elseif os(macOS)
    nonisolated private static func scaled(image: NSImage, to requestedSize: CGSize) -> NSImage {
        guard requestedSize.width > 0, requestedSize.height > 0,
              image.size.width > 0, image.size.height > 0
        else {
            return image
        }

        let scale = min(
            requestedSize.width / image.size.width,
            requestedSize.height / image.size.height
        )
        guard scale > 0, scale < 1 else { return image }

        let size = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let scaledImage = NSImage(size: size)
        scaledImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        scaledImage.unlockFocus()
        return scaledImage
    }
#endif
}
#endif

@MainActor
private final class PlatformNowPlayingInfoClient: AppleNowPlayingInfoClient {
#if canImport(MediaPlayer)
    private let center = MPNowPlayingInfoCenter.default()
    // REGRESSION GUARD: the coordinator publishes progress frequently. Reuse
    // the same MediaPlayer artwork object while its bytes are unchanged so
    // the system does not treat every progress tick as a new cover image.
    private var cachedArtworkData: Data?
    private var cachedArtwork: MPMediaItemArtwork?

    func publish(_ info: AppleNowPlayingInfo) throws {
        var values: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: info.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: info.playbackState == .playing ? info.rate : 0,
        ]

        if let artist = info.artist {
            values[MPMediaItemPropertyArtist] = artist
        }
        if let album = info.album {
            values[MPMediaItemPropertyAlbumTitle] = album
        }
        if let duration = info.duration {
            values[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let queuePosition = info.queuePosition {
            values[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queuePosition
        }
        if let queueCount = info.queueCount {
            values[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
        }
        // REGRESSION GUARD: assigning `nowPlayingInfo` replaces the complete
        // dictionary. Every progress publication must therefore carry the
        // last known artwork; omitting it makes the lock-screen artwork
        // disappear even when the song has not changed.
        if let artworkData = info.artworkData {
            if cachedArtworkData != artworkData {
                cachedArtworkData = artworkData
                cachedArtwork = PlatformNowPlayingArtworkFactory.make(from: artworkData)
            }
            if let cachedArtwork {
                values[MPMediaItemPropertyArtwork] = cachedArtwork
            }
        } else {
            cachedArtworkData = nil
            cachedArtwork = nil
        }

        center.nowPlayingInfo = values
    }

    func clear() throws {
        center.nowPlayingInfo = nil
    }

#else
    func publish(_ info: AppleNowPlayingInfo) throws {
        throw AppleSystemAdapterError.unavailable(
            platform: AppleSystemCapabilityDetector.current.platform,
            capability: .nowPlaying
        )
    }

    func clear() throws {
        throw AppleSystemAdapterError.unavailable(
            platform: AppleSystemCapabilityDetector.current.platform,
            capability: .nowPlaying
        )
    }
#endif
}

@MainActor
public final class AppleNowPlayingPublisher: NowPlayingPublishing {
    private struct ArtworkPublicationKey: Equatable {
        let itemID: MediaItemID
        let artworkID: ArtworkID?
        let hasProvider: Bool
    }

    private let client: any AppleNowPlayingInfoClient
    private let artworkProvider: NowPlayingArtworkProvider
    private var artworkRequestSerial: UInt64 = 0
    // REGRESSION GUARD: playback progress changes much more often than
    // artwork identity. Keep the bytes in the publisher so a progress-only
    // update can rebuild the complete system metadata without clearing the
    // cover. Do not make this cache follow `NowPlayingSnapshot` equality:
    // elapsed time and `updatedAt` intentionally change on every tick.
    private var artworkPublicationKey: ArtworkPublicationKey?
    private var cachedArtworkData: Data?

    public private(set) var currentSnapshot: NowPlayingSnapshot?
    public private(set) var lastError: AppleSystemAdapterError?

    public init() {
        self.client = PlatformNowPlayingInfoClient()
        self.artworkProvider = NowPlayingArtworkProvider()
    }

    init(
        client: any AppleNowPlayingInfoClient,
        artworkProvider: NowPlayingArtworkProvider = NowPlayingArtworkProvider()
    ) {
        self.client = client
        self.artworkProvider = artworkProvider
    }

    public func publish(_ snapshot: NowPlayingSnapshot) {
        currentSnapshot = snapshot

        let nextArtworkKey = Self.artworkPublicationKey(for: snapshot)
        let artworkIdentityChanged = artworkPublicationKey != nextArtworkKey

        if artworkIdentityChanged {
            // REGRESSION GUARD: cancel and reload only when the song/artwork
            // identity changes. Cancelling here for every position event
            // creates the visible "no cover -> cover" loop on the system
            // Now Playing surface and can starve slow artwork providers.
            artworkRequestSerial &+= 1
            artworkProvider.cancel()
            artworkPublicationKey = nextArtworkKey
            cachedArtworkData = nil
        }

        // Keep the current cover in every complete metadata replacement. The
        // first publication for a new song may legitimately have no artwork
        // yet; subsequent progress publications must reuse the cache above.
        publishInfo(
            makeInfo(
                for: snapshot,
                artworkData: cachedArtworkData
            )
        )

        guard artworkIdentityChanged,
              let artwork = snapshot.artwork,
              artwork.provider != nil
        else {
            return
        }

        let requestSerial = artworkRequestSerial
        artworkProvider.request(artwork) { [weak self] data in
            guard let self,
                  self.artworkRequestSerial == requestSerial,
                  self.artworkPublicationKey == nextArtworkKey,
                  let latestSnapshot = self.currentSnapshot,
                  Self.artworkPublicationKey(for: latestSnapshot) == nextArtworkKey
            else {
                return
            }

            self.cachedArtworkData = data
            // Use the latest progress snapshot when the asynchronous artwork
            // request completes. The request belongs to the artwork key, not
            // to the particular 100 ms progress snapshot that started it.
            self.publishInfo(
                self.makeInfo(
                    for: latestSnapshot,
                    artworkData: data
                )
            )
        }
    }

    public func clear() {
        artworkRequestSerial &+= 1
        artworkProvider.cancel()
        artworkPublicationKey = nil
        cachedArtworkData = nil
        currentSnapshot = nil

        do {
            try client.clear()
            lastError = nil
        } catch let error as AppleSystemAdapterError {
            lastError = error
        } catch {
            lastError = .nowPlayingClearFailed
        }
    }

    public var capabilities: SystemIntegrationCapabilitySnapshot {
        AppleSystemCapabilityDetector.current
    }

    public func dispose() {
        clear()
    }

    private static func artworkPublicationKey(
        for snapshot: NowPlayingSnapshot
    ) -> ArtworkPublicationKey {
        ArtworkPublicationKey(
            itemID: snapshot.itemID,
            artworkID: snapshot.artwork?.artworkID,
            hasProvider: snapshot.artwork?.provider != nil
        )
    }

    private func makeInfo(
        for snapshot: NowPlayingSnapshot,
        artworkData: Data?
    ) -> AppleNowPlayingInfo {
        AppleNowPlayingInfo(
            itemID: snapshot.itemID,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            duration: snapshot.duration.map(Self.timeInterval),
            elapsed: Self.timeInterval(
                snapshot.projectedElapsed(at: Date())
            ),
            playbackState: snapshot.playbackState,
            rate: snapshot.rate,
            queuePosition: snapshot.queuePosition,
            queueCount: snapshot.queueCount,
            artworkData: artworkData
        )
    }

    private func publishInfo(_ info: AppleNowPlayingInfo) {
        do {
            try client.publish(info)
            lastError = nil
        } catch let error as AppleSystemAdapterError {
            lastError = error
        } catch {
            lastError = .nowPlayingPublicationFailed
        }
    }

    private static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
