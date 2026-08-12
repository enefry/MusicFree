import Foundation
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
import SettingsAPI

/// Creates small, original, deterministic domain values for contract tests.
/// The factory does not read or write files; local resource URLs are merely
/// stable values passed to fakes.
@available(macOS 13.0, iOS 16.0, *)
public enum FixtureFactory {
    public static let sourceID = MediaSourceID("fixture")

    public static func itemID(
        _ index: Int = 0,
        sourceID: MediaSourceID = Self.sourceID
    ) -> MediaItemID {
        MediaItemID(sourceID: sourceID, externalID: "item-\(index)")
    }

    public static func albumID(_ index: Int = 0) -> AlbumID {
        AlbumID("album-\(index)")
    }

    public static func artistID(_ index: Int = 0) -> ArtistID {
        ArtistID("artist-\(index)")
    }

    public static func genreID(_ index: Int = 0) -> GenreID {
        GenreID("genre-\(index)")
    }

    public static func artworkID(_ index: Int = 0) -> ArtworkID {
        ArtworkID("artwork-\(index)")
    }

    public static func playlistID(_ index: Int = 0) -> PlaylistID {
        PlaylistID("playlist-\(index)")
    }

    public static func track(
        _ index: Int = 0,
        sourceID: MediaSourceID = Self.sourceID,
        title: String? = nil,
        duration: Duration? = .seconds(180),
        isFavorite: Bool = false
    ) -> Track {
        Track(
            id: itemID(index, sourceID: sourceID),
            title: title ?? "Fixture Track \(index)",
            sortTitle: title ?? "fixture track \(index)",
            albumID: albumID(index),
            artistIDs: [artistID(index)],
            genreIDs: [genreID(index)],
            duration: duration,
            technicalInfo: duration.map { technicalInfo(duration: $0) },
            artwork: ArtworkReference(
                id: artworkID(index),
                variants: [.thumbnail, .medium, .original],
                preferredVariant: .medium
            ),
            isFavorite: isFavorite
        )
    }

    public static func tracks(
        count: Int,
        sourceID: MediaSourceID = Self.sourceID
    ) -> [Track] {
        precondition(count >= 0, "fixture count cannot be negative")
        return (0..<count).map { track($0, sourceID: sourceID) }
    }

    public static func album(_ index: Int = 0) -> Album {
        Album(
            id: albumID(index),
            title: "Fixture Album \(index)",
            sortTitle: "fixture album \(index)",
            artistIDs: [artistID(index)],
            artwork: ArtworkReference(id: artworkID(index)),
            releaseYear: 2020 + (index % 5),
            trackCount: 1
        )
    }

    public static func artist(_ index: Int = 0) -> Artist {
        Artist(id: artistID(index), name: "Fixture Artist \(index)", sortName: "fixture artist \(index)")
    }

    public static func genre(_ index: Int = 0) -> Genre {
        Genre(id: genreID(index), name: "Fixture Genre \(index)", sortName: "fixture genre \(index)")
    }

    public static func playlist(_ index: Int = 0) -> Playlist {
        let date = Date(timeIntervalSince1970: TimeInterval(index))
        return Playlist(
            id: playlistID(index),
            name: "Fixture Playlist \(index)",
            sortName: "fixture playlist \(index)",
            createdAt: date,
            updatedAt: date
        )
    }

    public static func playlistEntry(
        playlistIndex: Int = 0,
        trackIndex: Int = 0,
        position: Int = 0
    ) -> PlaylistEntry {
        PlaylistEntry(
            playlistID: playlistID(playlistIndex),
            trackID: itemID(trackIndex),
            position: position
        )
    }

    public static func playbackItem(
        _ index: Int = 0,
        duration: Duration? = .seconds(180)
    ) -> PlaybackItem {
        PlaybackItem(
            itemID: itemID(index),
            resource: .local(fixtureURL(index)),
            displaySnapshot: PlaybackDisplaySnapshot(
                title: "Fixture Track \(index)",
                artist: "Fixture Artist \(index)",
                album: "Fixture Album \(index)",
                artworkID: artworkID(index),
                duration: duration
            )
        )
    }

    public static func queueEntry(_ index: Int = 0) -> PlaybackQueueEntry {
        PlaybackQueueEntry(id: stableUUID(index), itemID: itemID(index))
    }

    public static func queueSnapshot(
        count: Int = 1,
        currentIndex: Int? = 0
    ) -> PlaybackQueueSnapshot {
        let entries = (0..<count).map(queueEntry)
        let currentEntryID = currentIndex.flatMap { index in
            entries.first { $0.itemID == itemID(index) }?.id
        }
        return PlaybackQueueSnapshot(entries: entries, currentEntryID: currentEntryID)
    }

    public static func sourceDescriptor(
        sourceID: MediaSourceID = Self.sourceID,
        kind: MediaSourceKind = .local,
        displayName: String = "Fixture Source",
        isReadOnly: Bool = false
    ) -> MediaSourceDescriptor {
        MediaSourceDescriptor(
            sourceID: sourceID,
            kind: kind,
            displayName: displayName,
            isReadOnly: isReadOnly
        )
    }

    public static func fixtureURL(_ index: Int = 0) -> URL {
        URL(fileURLWithPath: "/fixture/music/item-\(index).audio")
    }

    public static func stableUUID(_ index: Int = 0) -> UUID {
        precondition(index >= 0 && index <= 0xFFFF_FFFF_FFFF, "fixture index is out of range")
        let value = String(index, radix: 16)
        let suffix = String(repeating: "0", count: 12 - value.count) + value
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    public static func date(_ seconds: TimeInterval = 0) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private static func technicalInfo(duration: Duration) -> MediaTechnicalInfo {
        MediaTechnicalInfo(
            container: "fixture",
            codec: "fixture-audio",
            duration: duration,
            audioStreams: [
                AudioStreamInfo(
                    codec: "fixture-audio",
                    sampleRate: 44_100,
                    bitDepth: 16,
                    channels: 2,
                    channelLayout: .stereo,
                    bitRate: 128_000
                )
            ],
            bitRate: 128_000
        )
    }
}
