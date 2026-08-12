import Foundation
import MusicDomain
import Testing

@Test("Media IDs preserve source isolation and round-trip through Codable")
func mediaIDsPreserveSourceIsolation() throws {
    let firstSource = MediaSourceID.local
    let secondSource = MediaSourceID(rawValue: "another-source")
    let first = MediaItemID(sourceID: firstSource, externalID: "same-key")
    let second = MediaItemID(sourceID: secondSource, externalID: "same-key")

    #expect(first != second)
    #expect(first.sourceID == firstSource)
    #expect(first.externalID == "same-key")

    let data = try JSONEncoder().encode(first)
    let decoded = try JSONDecoder().decode(MediaItemID.self, from: data)
    #expect(decoded == first)
}

@Test("ID descriptions redact path-shaped values")
func idDescriptionsRedactPaths() {
    let item = MediaItemID(
        sourceID: MediaSourceID(rawValue: "/private/var/mobile/Library"),
        externalID: "/private/fixture/music/song.flac"
    )

    #expect(!item.description.contains("/private/fixture"))
    #expect(!item.description.contains("/private/var"))
    #expect(item.description.contains("MediaItemID"))
}

@Test("Blank optional metadata becomes nil and relationships stay deterministic")
func blankMetadataAndRelationships() {
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "track-1"),
        title: "  Song  ",
        sortTitle: " \t",
        artistIDs: [ArtistID("artist-1"), ArtistID("artist-1"), ArtistID("artist-2")],
        genreIDs: [GenreID("rock"), GenreID("rock")]
    )

    #expect(track.title == "Song")
    #expect(track.sortTitle == nil)
    #expect(track.artistIDs == [ArtistID("artist-1"), ArtistID("artist-2")])
    #expect(track.genreIDs == [GenreID("rock")])
    #expect(track.trackNumber == nil)
    #expect(track.discNumber == nil)
    #expect(track.duration == nil)
    #expect(track.technicalInfo == nil)
    #expect(track.artwork == nil)
}

@Test("Track numbering and album types use stable Codable values")
func trackNumberingAndAlbumTypesRoundTrip() throws {
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "numbered-track"),
        title: "Movement",
        trackNumber: 7,
        discNumber: 2
    )
    let decodedTrack = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track))
    #expect(decodedTrack.trackNumber == 7)
    #expect(decodedTrack.discNumber == 2)

    let album = Album(
        id: AlbumID("soundtrack"),
        title: "Original Score",
        albumType: .soundtrack
    )
    let decodedAlbum = try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(album))
    #expect(decodedAlbum == album)
    #expect(decodedAlbum.albumType?.code == "soundtrack")

    let futureType = try JSONDecoder().decode(
        AlbumType.self,
        from: #""broadcast-release""#.data(using: .utf8)!
    )
    #expect(futureType == .unknown("broadcast-release"))
    #expect(try JSONEncoder().encode(futureType) == #""broadcast-release""#.data(using: .utf8)!)
}

@Test("Domain models encode and decode with unknown values represented by nil")
func domainModelsCodableRoundTrip() throws {
    let artwork = ArtworkReference(
        id: ArtworkID("artwork-1"),
        variants: [.thumbnail, .original, .thumbnail],
        preferredVariant: .thumbnail
    )
    let stream = AudioStreamInfo(
        codec: "flac",
        sampleRate: 44_100,
        bitDepth: 24,
        channels: 2,
        channelLayout: .stereo,
        bitRate: 1_000_000
    )
    let technicalInfo = MediaTechnicalInfo(
        container: "flac",
        codec: "flac",
        duration: .seconds(180),
        audioStreams: [stream]
    )
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "track-2"),
        title: String(repeating: "音", count: 1_024),
        albumID: AlbumID("album-1"),
        artistIDs: [ArtistID("artist-1")],
        duration: .seconds(180),
        technicalInfo: technicalInfo,
        artwork: artwork,
        isFavorite: true,
        statistics: PlaybackStatistics(
            playCount: 3,
            completionCount: 2,
            skipCount: 1,
            lastCompletionReason: .ended,
            totalListeningDuration: .seconds(360)
        )
    )

    let data = try JSONEncoder().encode(track)
    let decoded = try JSONDecoder().decode(Track.self, from: data)
    #expect(decoded == track)
    #expect(decoded.technicalInfo?.primaryAudioStream?.sampleRate == 44_100)
    #expect(decoded.duration == .seconds(180))
}

@Test("Older model payloads decode with defaults for later optional fields")
func olderModelPayloadsRemainDecodable() throws {
    let oldTrack = #"{"id":{"sourceID":"local","externalID":"legacy-track"},"title":"Legacy"}"#.data(using: .utf8)!
    let track = try JSONDecoder().decode(Track.self, from: oldTrack)
    #expect(track.isFavorite == false)
    #expect(track.artistIDs.isEmpty)
    #expect(track.statistics == .empty)
    #expect(track.trackNumber == nil)
    #expect(track.discNumber == nil)

    let oldAlbum = #"{"id":"legacy-album","title":"Legacy Album"}"#.data(using: .utf8)!
    let album = try JSONDecoder().decode(Album.self, from: oldAlbum)
    #expect(album.albumType == nil)

    let oldTechnicalInfo = #"{"container":"flac"}"#.data(using: .utf8)!
    let technicalInfo = try JSONDecoder().decode(MediaTechnicalInfo.self, from: oldTechnicalInfo)
    #expect(technicalInfo.audioStreams.isEmpty)

    let oldArtwork = #"{"id":"artwork-legacy"}"#.data(using: .utf8)!
    let artwork = try JSONDecoder().decode(ArtworkReference.self, from: oldArtwork)
    #expect(artwork.variants.isEmpty)
}

@Test("Decoding rejects values that violate domain ranges")
func invalidPersistedValuesAreRejected() {
    let invalidStream = #"{"sampleRate":0}"#.data(using: .utf8)!
    let invalidEntry = #"{"playlistID":"playlist-1","trackID":{"sourceID":"local","externalID":"track-1"},"position":-1}"#.data(using: .utf8)!
    let invalidTrackNumber = #"{"id":{"sourceID":"local","externalID":"track-1"},"title":"Track","trackNumber":0}"#.data(using: .utf8)!
    let invalidDiscNumber = #"{"id":{"sourceID":"local","externalID":"track-1"},"title":"Track","discNumber":-1}"#.data(using: .utf8)!

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AudioStreamInfo.self, from: invalidStream)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PlaylistEntry.self, from: invalidEntry)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Track.self, from: invalidTrackNumber)
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Track.self, from: invalidDiscNumber)
    }
}

@Test("Playlist entries sort by position with a deterministic tie breaker")
func playlistEntryOrdering() {
    let playlist = PlaylistID("playlist-1")
    let earlier = PlaylistEntry(
        playlistID: playlist,
        trackID: MediaItemID(sourceID: .local, externalID: "b"),
        position: 0
    )
    let later = PlaylistEntry(
        playlistID: playlist,
        trackID: MediaItemID(sourceID: .local, externalID: "a"),
        position: 1
    )
    let samePosition = PlaylistEntry(
        playlistID: playlist,
        trackID: MediaItemID(sourceID: .local, externalID: "a"),
        position: 0
    )

    #expect(earlier < later)
    #expect(samePosition < earlier)
    #expect([later, earlier, samePosition].sorted() == [samePosition, earlier, later])
}

@Test("Technical fields enforce units and keep unknown fields absent")
func technicalInfoInvariants() {
    let info = MediaTechnicalInfo(
        container: "mystery-container",
        duration: nil,
        audioStreams: [AudioStreamInfo(channels: 2)]
    )

    #expect(info.container == "mystery-container")
    #expect(info.codec == nil)
    #expect(info.duration == nil)
    #expect(info.primaryAudioStream?.channels == 2)
    #expect(info.primaryAudioStream?.sampleRate == nil)
    #expect(info.primaryAudioStream?.bitDepth == nil)
}

@Test("Domain errors expose retry and cancellation semantics without paths")
func domainErrorSemantics() throws {
    let context = DiagnosticContext(
        code: "resource-unavailable",
        operation: "/private/fixture/music/import",
        sourceID: .local
    )
    let error = MusicDomainError.resourceUnavailable(context: context)

    #expect(error.isRetryable)
    #expect(!error.isCancellation)
    #expect(!error.description.contains("/private/fixture"))

    let encoded = try JSONEncoder().encode(error)
    let decoded = try JSONDecoder().decode(MusicDomainError.self, from: encoded)
    #expect(decoded == error)
    #expect(MusicDomainError.cancelled.isCancellation)
    #expect(!MusicDomainError.cancelled.isRetryable)
}

@Test("Playback completion reasons keep unknown persisted values")
func playbackCompletionReasonForwardCompatibility() throws {
    let reason = PlaybackCompletionReason.unknown("future-reason")
    let data = try JSONEncoder().encode(reason)
    let decoded = try JSONDecoder().decode(PlaybackCompletionReason.self, from: data)
    #expect(decoded == reason)
}
