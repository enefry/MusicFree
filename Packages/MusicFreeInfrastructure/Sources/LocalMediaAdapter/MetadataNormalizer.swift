import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

@available(macOS 13.0, iOS 16.0, *)
struct NormalizedMedia: Sendable {
  let itemID: MediaItemID
  let track: Track
  let transaction: LibraryTransaction
  let artworkID: ArtworkID?
  let artworkData: Data?
}

@available(macOS 13.0, iOS 16.0, *)
struct MetadataNormalizer: Sendable {
  func normalize(
    fileURL: URL,
    stagedFileURL: URL? = nil,
    folderPath: String? = nil,
    contentHash: String,
    probe: MediaProbeResult,
    metadata: RawMediaMetadata,
    fallbackArtwork: RawArtwork? = nil,
    itemID explicitItemID: MediaItemID? = nil,
    logicalTrackID: LogicalTrackID? = nil,
    assetID explicitAssetID: MediaAssetID? = nil,
    albumID explicitAlbumID: AlbumID? = nil,
    playbackSelection: PlaybackSelection = .wholeFile,
    trackTotal: Int? = nil,
    discTotal: Int? = nil,
    albumType: AlbumType? = nil,
    idempotencyKey: String? = nil
  ) throws -> NormalizedMedia {
    let hash = contentHash.lowercased()
    guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else {
      throw LocalMediaError.hashingFailed
    }

    let defaultItemID = MediaItemID(sourceID: .local, externalID: "sha256-\(hash)")
    let itemID = explicitItemID ?? defaultItemID
    let assetID = explicitAssetID ?? MediaAssetID(legacyVariantID: defaultItemID)
    guard itemID.sourceID == .local, assetID.sourceID == .local else {
      throw LocalMediaError.invalidItemID
    }
    let title = Self.clean(metadata.title)
      ?? Self.clean(fileURL.deletingPathExtension().lastPathComponent)
      ?? "Untitled"

    let artistName = Self.clean(metadata.artist)
    let albumArtistName = Self.clean(metadata.albumArtist) ?? artistName
    let albumArtistNames = albumArtistName.map { [$0] } ?? []
    let albumTitle = Self.clean(metadata.album)
    let genreName = Self.clean(metadata.genre)

    let artistID = artistName.map { Self.artistID(for: $0) }
    let albumArtistIDs = albumArtistNames.map(Self.artistID)
    let genreID = genreName.map { Self.genreID(for: $0) }
    let albumID = explicitAlbumID ?? albumTitle.map {
      Self.albumID(for: $0, artistNames: albumArtistNames)
    }

    let artworkID: ArtworkID?
    let selectedArtwork = metadata.firstArtwork ?? fallbackArtwork
    if let artwork = selectedArtwork, !artwork.data.isEmpty {
      artworkID = ArtworkID(rawValue: "sha256-\(MusicContentIdentity.sha256Hex(artwork.data))")
    } else {
      artworkID = nil
    }
    let artworkReference = artworkID.map {
      ArtworkReference(id: $0, variants: [.original], preferredVariant: .original)
    }

    // Probe duration is the canonical media value. Metadata readers may
    // expose a stale tag/parser duration that is not the playable length.
    let resolvedPlaybackSelection: PlaybackSelection
    if playbackSelection.audioStream == nil,
       let preferredAudioStream = ProbedAudioStreamSelector.preferred(in: probe)
    {
      resolvedPlaybackSelection = PlaybackSelection(
        range: playbackSelection.range,
        audioStream: preferredAudioStream
      )
    } else {
      resolvedPlaybackSelection = playbackSelection
    }
    let assetDuration = Self.nonNegative(probe.duration ?? metadata.duration)
    let duration = resolvedPlaybackSelection.logicalDuration ?? assetDuration
    var seenStreamIDs = Set<String>()
    let streams = probe.decodableAudioTracks.compactMap { track in
      let stableID = Self.uniqueStableID(track.stableID, seen: &seenStreamIDs)
      return Self.audioStreamInfo(track, stableID: stableID)
    }
    let technicalInfo = MediaTechnicalInfo(
      container: Self.clean(probe.container),
      codec: streams.first?.codec,
      duration: assetDuration,
      audioStreams: streams,
      bitRate: Self.aggregateBitRate(streams),
      fileSizeBytes: Self.fileSize(stagedFileURL ?? fileURL)
    )

    let track = Track(
      id: itemID,
      logicalTrackID: logicalTrackID,
      assetID: assetID,
      playbackSelection: resolvedPlaybackSelection,
      title: title,
      sortTitle: title,
      albumID: albumID,
      artistIDs: artistID.map { [$0] } ?? [],
      genreIDs: genreID.map { [$0] } ?? [],
      trackNumber: Self.positive(metadata.trackNumber),
      trackTotal: Self.positive(trackTotal),
      discNumber: Self.positive(metadata.discNumber),
      discTotal: Self.positive(discTotal),
      fileName: fileURL.lastPathComponent,
      folderPath: folderPath,
      duration: duration,
      technicalInfo: technicalInfo,
      year: Self.validYear(metadata.year),
      comment: metadata.comment,
      lyrics: metadata.lyrics.map(TrackLyrics.init(rawText:)),
      artwork: artworkReference
    )

    var mutations: [LibraryMutation] = []
    if let artworkReference {
      mutations.append(.upsert(.artwork(artworkReference)))
    }
    if let artistName, let artistID {
      mutations.append(.upsert(.artist(Artist(id: artistID, name: artistName))))
    }
    for (albumArtistID, albumArtistName) in zip(albumArtistIDs, albumArtistNames)
      where albumArtistID != artistID
    {
      mutations.append(.upsert(.artist(Artist(id: albumArtistID, name: albumArtistName))))
    }
    if let genreName, let genreID {
      mutations.append(.upsert(.genre(Genre(id: genreID, name: genreName))))
    }
    if let albumTitle, let albumID {
      mutations.append(
        .upsert(
          .album(
            Album(
              id: albumID,
              title: albumTitle,
              artistIDs: albumArtistIDs,
              artwork: artworkReference,
              releaseYear: Self.validYear(metadata.year),
              trackCount: nil,
              albumType: albumType
            )
          )
        )
      )
    }
    mutations.append(.upsert(.track(track)))
    mutations.append(.relation(.setAlbum(trackID: itemID, albumID: albumID)))
    mutations.append(.relation(.setArtists(trackID: itemID, artistIDs: artistID.map { [$0] } ?? [])))
    mutations.append(.relation(.setGenres(trackID: itemID, genreIDs: genreID.map { [$0] } ?? [])))
    mutations.append(.relation(.setArtwork(trackID: itemID, artworkID: artworkID)))

    let transaction = try LibraryTransaction(
      // The content hash is the stable media identity, but it must not be the
      // permanent transaction identity: after a user deletes a track, the
      // same bytes are allowed to be imported again. The importer supplies an
      // operation-scoped key so retries remain idempotent without blocking a
      // later re-import.
      idempotencyKey: idempotencyKey ?? "local-import-\(itemID.externalID)",
      mutations: mutations
    )
    return NormalizedMedia(
      itemID: itemID,
      track: track,
      transaction: transaction,
      artworkID: artworkID,
      artworkData: selectedArtwork?.data
    )
  }

  private static func clean(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  private static func nonNegative(_ duration: Duration?) -> Duration? {
    guard let duration, duration >= .zero else { return nil }
    return duration
  }

  private static func validYear(_ year: Int?) -> Int? {
    guard let year, (1...9_999).contains(year) else { return nil }
    return year
  }

  private static func positive(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return value
  }

  private static func fileSize(_ fileURL: URL) -> Int64? {
    guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
          let fileSize = values.fileSize,
          fileSize >= 0
    else { return nil }
    return Int64(fileSize)
  }

  private static func audioStreamInfo(
    _ track: ProbedAudioTrack,
    stableID: String?
  ) -> AudioStreamInfo? {
    let channels = track.channelCount.flatMap { $0 > 0 ? $0 : nil }
    let channelLayout = channels.map { ChannelLayout(channelCount: $0) }
    let sampleRate = track.sampleRate.flatMap { value -> Int? in
      guard value.isFinite, value > 0 else { return nil }
      let rounded = value.rounded()
      guard rounded >= 1, rounded < Double(Int.max) else { return nil }
      return Int(rounded)
    }
    let bitDepth = track.bitDepth.flatMap { $0 > 0 ? $0 : nil }
    return AudioStreamInfo(
      streamID: stableID.map { AudioStreamID($0) },
      indexHint: track.index >= 0 ? track.index : nil,
      language: clean(track.language),
      title: clean(track.title),
      isDefault: track.isDefault,
      codec: clean(track.codec),
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      channelLayout: channelLayout,
      bitRate: track.bitRate.flatMap { $0 > 0 ? $0 : nil }
    )
  }

  private static func uniqueStableID(
    _ value: String?,
    seen: inout Set<String>
  ) -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
    return normalized
  }

  private static func aggregateBitRate(_ streams: [AudioStreamInfo]) -> Int? {
    var total = 0
    var hasValue = false
    for stream in streams {
      guard let bitRate = stream.bitRate else { continue }
      let (nextTotal, overflow) = total.addingReportingOverflow(bitRate)
      guard !overflow else { return nil }
      total = nextTotal
      hasValue = true
    }
    return hasValue ? total : nil
  }

  private static func artistID(for name: String) -> ArtistID {
    ArtistID(rawValue: "local-artist-\(stableToken(name))")
  }

  private static func albumID(for title: String, artistNames: [String]) -> AlbumID {
    let token: String
    if artistNames.count <= 1 {
      // Preserve the pre-multi-artist ID format for existing libraries.
      token = stableToken(title + "|" + (artistNames.first ?? ""))
    } else {
      token = MusicContentIdentity.compositeToken([title] + artistNames)
    }
    return AlbumID(rawValue: "local-album-\(token)")
  }

  private static func genreID(for name: String) -> GenreID {
    GenreID(rawValue: "local-genre-\(stableToken(name))")
  }

  private static func stableToken(_ value: String) -> String {
    MusicContentIdentity.token(value)
  }
}
