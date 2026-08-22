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

@Test("Legacy TrackVariant payloads decode without source refresh fields")
func legacyTrackVariantPayloadDecodesWithoutSourceRefreshFields() throws {
    let variant = TrackVariant(
        id: MediaItemID(sourceID: .local, externalID: "legacy-variant"),
        logicalTrackID: LogicalTrackID("local:legacy-variant"),
        assetID: MediaAssetID(sourceID: .local, externalID: "legacy-asset")
    )
    let encoded = try JSONEncoder().encode(variant)
    var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "sourceIdentityHint")
    payload.removeValue(forKey: "sourceMetadataRevision")
    payload.removeValue(forKey: "sourceMetadata")

    let legacyData = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try JSONDecoder().decode(TrackVariant.self, from: legacyData)

    #expect(decoded == variant)
    #expect(decoded.sourceIdentityHint == nil)
    #expect(decoded.sourceMetadataRevision == nil)
    #expect(decoded.sourceMetadata == nil)
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

@Test("Composite content identities preserve ordered value boundaries")
func compositeContentIdentityIsUnambiguous() {
    #expect(
        MusicContentIdentity.compositeToken(["ab", "c"])
            != MusicContentIdentity.compositeToken(["a", "bc"])
    )
    #expect(
        MusicContentIdentity.token("Album|Artist")
            == MusicContentIdentity.token("Album|Artist")
    )
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

@Test("LRC lyrics preserve plain text, offsets, and active-line lookup")
func lyricsParseAndTrackPlaybackPosition() {
    let timed = TrackLyrics(rawText: """
    [ar:Fixture]
    [offset:-500]
    [00:01.50]First line
    [00:03.000][00:04.2]Second line
    """)

    #expect(timed.isTimed)
    #expect(timed.declaredOffsetMilliseconds == -500)
    #expect(timed.timedLines.map(\.timestampMilliseconds) == [1_500, 3_000, 4_200])
    #expect(timed.activeLineIndex(at: .seconds(1)) == 0)
    #expect(timed.activeLineIndex(at: .seconds(2), runtimeOffsetMilliseconds: 1_000) == 1)
    #expect(timed.activeLineIndex(at: .milliseconds(2_499)) == 0)
    #expect(timed.activeLineIndex(at: .milliseconds(2_500)) == 1)

    let plain = TrackLyrics(rawText: "First line\nSecond line")
    #expect(!plain.isTimed)
    #expect(plain.displayText == "First line\nSecond line")
}

@Test("LRC lyrics ignore a document-start UTF-8 BOM")
func lyricsIgnoreDocumentStartBOM() {
    let lyrics = TrackLyrics(rawText: "\u{FEFF}[00:01.00]BOM line")

    #expect(lyrics.timedLines == [
        LyricLine(timestampMilliseconds: 1_000, text: "BOM line")
    ])
    #expect(lyrics.rawText == "[00:01.00]BOM line")
}

@Test("Malformed or overflowing LRC timestamps are ignored")
func lyricsIgnoreMalformedTimestamps() {
    let lyrics = TrackLyrics(rawText: """
    [999999999999999999999:00]Overflow
    [153722867280912931:00:00]Three-part overflow
    [00:01.2.3]Malformed fraction
    [00:02]Valid
    """)

    #expect(lyrics.timedLines.map(\.text) == ["Valid"])
}

@Test("Negative LRC line timestamps are ignored without affecting valid lines")
func lyricsIgnoreNegativeLineTimestamps() {
    let lyrics = TrackLyrics(rawText: """
    [-1:00]Negative minute
    [-0:01]Negative zero hour
    [00:-0]Negative zero seconds
    [00:-0.5]Negative zero fraction
    [00:01.00]Valid
    """)

    #expect(lyrics.timedLines.map(\.text) == ["Valid"])
    #expect(lyrics.activeLineIndex(at: .zero) == nil)
    #expect(lyrics.activeLineIndex(at: .seconds(1)) == 0)
}

@Test("Persisted lyrics reject negative timestamps")
func invalidPersistedLyricTimestampIsRejected() {
    let payload = #"{"rawText":"Bad","timedLines":[{"timestampMilliseconds":-1,"text":"Bad"}],"declaredOffsetMilliseconds":0}"#.data(using: .utf8)!

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(TrackLyrics.self, from: payload)
    }
}

@Test("Older model payloads decode with defaults for later optional fields")
func olderModelPayloadsRemainDecodable() throws {
    let oldTrack = #"{"id":{"sourceID":"local","externalID":"legacy-track"},"title":"Legacy"}"#.data(using: .utf8)!
    let track = try JSONDecoder().decode(Track.self, from: oldTrack)
    #expect(track.isFavorite == false)
    #expect(track.artistIDs.isEmpty)
    #expect(track.statistics == .empty)
    #expect(track.trackNumber == nil)
    #expect(track.trackTotal == nil)
    #expect(track.discNumber == nil)
    #expect(track.discTotal == nil)
    #expect(track.logicalTrackID == LogicalTrackID(legacyVariantID: track.id))
    #expect(track.assetID == MediaAssetID(legacyVariantID: track.id))
    #expect(track.playbackSelection == .wholeFile)

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

@Test("Local media graph keeps logical, variant, asset, and segment identities separate")
func localMediaGraphIdentityAndRangeMapping() throws {
    let variantID = MediaItemID(sourceID: .local, externalID: "cue-variant-02")
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-shared-image")
    let logicalTrackID = LogicalTrackID("cue-logical-02")
    let range = PlaybackRange(start: .seconds(125), end: .seconds(245))
    let track = Track(
        id: variantID,
        logicalTrackID: logicalTrackID,
        assetID: assetID,
        playbackSelection: PlaybackSelection(
            range: range,
            audioStream: AudioStreamSelection(index: 1)
        ),
        title: "Second Movement",
        trackNumber: 2,
        trackTotal: 8,
        discNumber: 1,
        discTotal: 2,
        duration: range.duration
    )

    #expect(track.id != assetID.mediaItemID)
    #expect(track.logicalTrackProjection.id == logicalTrackID)
    #expect(track.trackVariantProjection.assetID == assetID)
    #expect(track.trackVariantProjection.selection.range == range)
    #expect(range.absolutePosition(forLogicalPosition: .seconds(10)) == .seconds(135))
    #expect(range.logicalPosition(forAbsolutePosition: .seconds(250)) == .seconds(120))
    #expect(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)) == track)
}

@Test("Audio stream selections decode legacy indexes and round trip stable identities")
func audioStreamSelectionCodableCompatibility() throws {
    let current = AudioStreamSelection(
        streamID: AudioStreamID("vlc-media-id:42"),
        fallbackSignature: AudioStreamSignature(
            language: "eng",
            title: "Stereo Mix",
            codec: "aac",
            channelCount: 2,
            indexHint: 3
        )
    )

    let currentData = try JSONEncoder().encode(current)
    #expect(try JSONDecoder().decode(AudioStreamSelection.self, from: currentData) == current)

    let legacy = try JSONDecoder().decode(
        AudioStreamSelection.self,
        from: Data("3".utf8)
    )
    #expect(legacy.streamID == nil)
    #expect(legacy.fallbackSignature == AudioStreamSignature(indexHint: 3))
    #expect(legacy.index == 3)

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AudioStreamSelection.self, from: Data("-1".utf8))
    }
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
