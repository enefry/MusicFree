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
        if let artwork = PlatformNowPlayingArtworkFactory.make(from: info.artworkData) {
            values[MPMediaItemPropertyArtwork] = artwork
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
    private let client: any AppleNowPlayingInfoClient
    private let artworkProvider: NowPlayingArtworkProvider
    private var publicationSerial: UInt64 = 0

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
        publicationSerial &+= 1
        let serial = publicationSerial
        currentSnapshot = snapshot
        artworkProvider.cancel()

        publishInfo(makeInfo(for: snapshot, artworkData: nil))

        guard let artwork = snapshot.artwork, artwork.provider != nil else {
            return
        }

        artworkProvider.request(artwork) { [weak self] data in
            guard let self,
                  self.publicationSerial == serial,
                  self.currentSnapshot == snapshot
            else {
                return
            }
            self.publishInfo(self.makeInfo(for: snapshot, artworkData: data))
        }
    }

    public func clear() {
        publicationSerial &+= 1
        artworkProvider.cancel()
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
