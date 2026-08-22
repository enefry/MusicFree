import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain

@available(macOS 13.0, iOS 16.0, *)
struct PreparedLocalMediaAsset: Sendable {
  let file: ImportFile
  let stagedURL: URL
  let contentHash: String
  let assetID: MediaAssetID
  let probe: MediaProbeResult
  let metadata: RawMediaMetadata
  let folderArtwork: FolderArtworkSelection?
}

@available(macOS 13.0, iOS 16.0, *)
struct LocalMediaBundlePlan: Sendable {
  let normalizedTracks: [NormalizedMedia]
  let structuralMutations: [LibraryMutation]

  var itemIDs: [MediaItemID] { normalizedTracks.map(\.itemID) }

  func transaction(
    including includedItemIDs: Set<MediaItemID>,
    idempotencyKey: String
  ) throws -> LibraryTransaction? {
    guard !includedItemIDs.isEmpty else { return nil }
    let included = normalizedTracks.filter { includedItemIDs.contains($0.itemID) }
    let logicalIDs = Set(included.map(\.track.logicalTrackID))
    let assetIDs = Set(included.map(\.track.assetID))
    let albumIDs = Set(included.compactMap(\.track.albumID))
    let releaseIDs = Set(albumIDs.map(AlbumReleaseID.init(legacyAlbumID:)))
    let discIDs = Set(included.compactMap { $0.track.discProjection?.id })
    let includedGroupIDs = Set(structuralMutations.compactMap { mutation -> AlbumGroupID? in
      guard case .upsert(.albumRelease(let value)) = mutation,
            releaseIDs.contains(value.id),
            let groupID = value.groupID
      else { return nil }
      return groupID
    })
    let includedCollectionIDs = Set(structuralMutations.compactMap { mutation -> LibraryCollectionID? in
      guard case .upsert(.collectionMember(let value)) = mutation,
            releaseIDs.contains(value.releaseID)
      else { return nil }
      return value.collectionID
    })
    var accumulator = LocalMediaMutationAccumulator()
    for media in included {
      for mutation in media.transaction.mutations {
        accumulator.add(mutation)
      }
    }
    for mutation in structuralMutations {
      switch mutation {
      case .upsert(.album(let value)) where !albumIDs.contains(value.id):
        continue
      case .upsert(.logicalTrack(let value)) where !logicalIDs.contains(value.id):
        continue
      case .upsert(.trackVariant(let value)) where !includedItemIDs.contains(value.id):
        continue
      case .upsert(.mediaAsset(let value)) where !assetIDs.contains(value.id):
        continue
      case .upsert(.albumGroup(let value)) where !includedGroupIDs.contains(value.id):
        continue
      case .upsert(.albumRelease(let value)) where !releaseIDs.contains(value.id):
        continue
      case .upsert(.disc(let value)) where !discIDs.contains(value.id):
        continue
      case .upsert(.collection(let value)) where !includedCollectionIDs.contains(value.id):
        continue
      case .upsert(.collectionMember(let value))
        where !includedCollectionIDs.contains(value.collectionID)
          || !releaseIDs.contains(value.releaseID):
        continue
      default:
        accumulator.add(mutation)
      }
    }
    return try LibraryTransaction(
      idempotencyKey: idempotencyKey,
      mutations: accumulator.mutations
    )
  }
}

@available(macOS 13.0, iOS 16.0, *)
struct LocalMediaBundlePlanner: Sendable {
  private struct PlannedTrack {
    let asset: PreparedLocalMediaAsset
    let itemID: MediaItemID
    let logicalTrackID: LogicalTrackID?
    let selection: PlaybackSelection
    var metadata: RawMediaMetadata
    var trackTotal: Int?
    var discTotal: Int?
    var albumType: AlbumType?
    let releaseFolder: String
    let discTitle: String?
  }

  private struct ReleaseGroupKey: Hashable {
    let releaseFolder: String
    let album: String
  }

  func plan(
    bundle: FolderImportBundle,
    assets: [PreparedLocalMediaAsset],
    importID: UUID
  ) throws -> LocalMediaBundlePlan {
    let assetsByURL = Dictionary(uniqueKeysWithValues: assets.map {
      ($0.file.url.standardizedFileURL, $0)
    })
    var referencedURLs = Set<URL>()
    var cueOwnerByAsset: [URL: String] = [:]
    var planned: [PlannedTrack] = []

    for cueFile in bundle.cueFiles {
      let cueData = try readCue(cueFile.url)
      // The CUE file is the logical object; its metadata is a mutable
      // revision. Keep track IDs tied to the object's stable source identity
      // so title/performer/encoding edits do not orphan user state.
      let cueObjectID = stableCueObjectID(for: cueFile.url)
      let sheet = try CUESheetParser().parse(data: cueData)
      var resolvedByPath: [String: PreparedLocalMediaAsset] = [:]
      var durations: [String: Duration] = [:]
      for file in sheet.files {
        let resolvedURL = try CUEReferencedFileResolver().resolve(
          file,
          cueURL: cueFile.url,
          candidates: assets.map(\.file.url)
        ).standardizedFileURL
        guard let asset = assetsByURL[resolvedURL], let duration = asset.probe.duration else {
          throw CUESheetError.missingAssetDuration
        }
        if let existingOwner = cueOwnerByAsset[resolvedURL], existingOwner != cueObjectID {
          throw LocalMediaError.metadataFailed
        }
        cueOwnerByAsset[resolvedURL] = cueObjectID
        referencedURLs.insert(resolvedURL)
        resolvedByPath[file.path.lowercased()] = asset
        durations[file.path.lowercased()] = duration
      }

      let segments = try sheet.segments(assetDurations: durations)
      for segment in segments {
        guard let asset = resolvedByPath[segment.filePath.lowercased()],
              let fileOrdinal = sheet.files.firstIndex(where: {
                $0.path.caseInsensitiveCompare(segment.filePath) == .orderedSame
              })
        else { throw CUESheetError.referencedFileNotFound }
        let externalID = "cue-\(cueObjectID)-f\(fileOrdinal + 1)-t\(segment.track.number)"
        let itemID = MediaItemID(sourceID: .local, externalID: externalID)
        let metadata = cueMetadata(
          sheet: sheet,
          track: segment.track,
          fallback: asset.metadata,
          duration: segment.end - segment.start
        )
        let folder = releaseFolder(for: asset.file, bundle: bundle)
        planned.append(PlannedTrack(
          asset: asset,
          itemID: itemID,
          logicalTrackID: LogicalTrackID("local:\(externalID)"),
          selection: PlaybackSelection(
            range: PlaybackRange(start: segment.start, end: segment.end),
            audioStream: ProbedAudioStreamSelector.preferred(in: asset.probe)
          ),
          metadata: metadata,
          trackTotal: sheet.tracks.count,
          discTotal: nil,
          albumType: nil,
          releaseFolder: folder.path,
          discTitle: folder.discTitle
        ))
      }
    }

    for asset in assets where !referencedURLs.contains(asset.file.url.standardizedFileURL) {
      let folder = releaseFolder(for: asset.file, bundle: bundle)
      planned.append(PlannedTrack(
        asset: asset,
        itemID: asset.assetID.mediaItemID,
        logicalTrackID: nil,
        selection: PlaybackSelection(audioStream: ProbedAudioStreamSelector.preferred(in: asset.probe)),
        metadata: asset.metadata,
        trackTotal: nil,
        discTotal: nil,
        albumType: nil,
        releaseFolder: folder.path,
        discTitle: folder.discTitle
      ))
    }

    planned = applyCollectionManifest(planned, bundle: bundle)
    planned = enrichReleaseStructure(planned, bundle: bundle)
    let scopedAlbumIDs = releaseScopedAlbumIDs(for: planned)
    var normalized: [NormalizedMedia] = []
    var seenItemIDs = Set<MediaItemID>()
    for value in planned.sorted(by: plannedTrackOrder) where seenItemIDs.insert(value.itemID).inserted {
      let releaseScopedAlbumID = releaseContextKey(for: value).flatMap { scopedAlbumIDs[$0] }
      let media = try MetadataNormalizer().normalize(
        fileURL: value.asset.file.url,
        stagedFileURL: value.asset.stagedURL,
        folderPath: value.asset.file.folderPath,
        contentHash: value.asset.contentHash,
        probe: value.asset.probe,
        metadata: value.metadata,
        fallbackArtwork: value.asset.folderArtwork.map {
          RawArtwork(
            data: $0.data,
            pixelWidth: $0.pixelWidth,
            pixelHeight: $0.pixelHeight
          )
        },
        itemID: value.itemID,
        logicalTrackID: value.logicalTrackID,
        assetID: value.asset.assetID,
        albumID: bundle.collectionManifest.flatMap { $0.albumID(for: value.releaseFolder) }
          ?? releaseScopedAlbumID,
        playbackSelection: value.selection,
        trackTotal: value.trackTotal,
        discTotal: value.discTotal,
        albumType: value.albumType,
        idempotencyKey: "local-bundle-item-\(importID.uuidString)-\(value.itemID.externalID)"
      )
      normalized.append(media)
    }

    return LocalMediaBundlePlan(
      normalizedTracks: normalized,
      structuralMutations: try structuralMutations(
        for: normalized,
        planned: planned,
        bundle: bundle
      )
    )
  }

  private func applyCollectionManifest(
    _ values: [PlannedTrack],
    bundle: FolderImportBundle
  ) -> [PlannedTrack] {
    guard let manifest = bundle.collectionManifest else { return values }
    return values.map { original in
      var value = original
      guard let album = manifest.album(at: value.releaseFolder) else { return value }
      value.metadata = replacing(value.metadata, album: album.title)
      return value
    }
  }

  private func enrichReleaseStructure(
    _ values: [PlannedTrack],
    bundle: FolderImportBundle
  ) -> [PlannedTrack] {
    var result = values
    let folderCounts = Dictionary(grouping: result.indices, by: { result[$0].releaseFolder })
    for indices in folderCounts.values {
      let inferredAlbumTitle: String? = indices.count > 1
        ? releaseTitle(for: result[indices[0]].releaseFolder, bundle: bundle)
        : nil
      for index in indices where result[index].metadata.album == nil {
        result[index].metadata = replacing(
          result[index].metadata,
          album: inferredAlbumTitle,
          discNumber: result[index].metadata.discNumber
            ?? inferredDiscNumber(from: result[index].asset.file.folderPath)
        )
      }
    }

    let releaseGroups = Dictionary(grouping: result.indices) { index in
      ReleaseGroupKey(
        releaseFolder: result[index].releaseFolder,
        album: normalized(result[index].metadata.album) ?? ""
      )
    }
    for indices in releaseGroups.values {
      guard !indices.isEmpty, result[indices[0]].metadata.album != nil else { continue }
      let explicitAlbumArtists = Set(indices.compactMap {
        normalized(result[$0].metadata.albumArtist)
      })
      let trackArtists = Set(indices.compactMap { normalized(result[$0].metadata.artist) })
      let commonAlbumArtist: String?
      let albumType: AlbumType?
      if explicitAlbumArtists.count == 1 {
        commonAlbumArtist = indices.compactMap { result[$0].metadata.albumArtist }.first
        albumType = commonAlbumArtist?.caseInsensitiveCompare("Various Artists") == .orderedSame
          ? .compilation : nil
      } else if explicitAlbumArtists.isEmpty, trackArtists.count > 1 {
        commonAlbumArtist = "Various Artists"
        albumType = .compilation
      } else {
        commonAlbumArtist = nil
        albumType = nil
      }
      let discNumbers = indices.compactMap { index in
        result[index].metadata.discNumber
          ?? inferredDiscNumber(from: result[index].asset.file.folderPath)
      }
      let discTotal = max(Set(discNumbers).count, discNumbers.max() ?? 0)
      let trackCountsByDisc = Dictionary(grouping: indices) { index in
        result[index].metadata.discNumber
          ?? inferredDiscNumber(from: result[index].asset.file.folderPath)
          ?? 1
      }.mapValues(\.count)
      for index in indices {
        let discNumber = result[index].metadata.discNumber
          ?? inferredDiscNumber(from: result[index].asset.file.folderPath)
        result[index].metadata = replacing(
          result[index].metadata,
          albumArtist: result[index].metadata.albumArtist ?? commonAlbumArtist,
          discNumber: discNumber
        )
        result[index].trackTotal = result[index].trackTotal
          ?? trackCountsByDisc[discNumber ?? 1]
        result[index].discTotal = discTotal > 0 ? discTotal : nil
        result[index].albumType = albumType
      }
    }
    return result
  }

  private func structuralMutations(
    for normalized: [NormalizedMedia],
    planned: [PlannedTrack],
    bundle: FolderImportBundle
  ) throws -> [LibraryMutation] {
    var mutations: [LibraryMutation] = []
    let plannedByID = planned.reduce(into: [MediaItemID: PlannedTrack]()) { result, value in
      if result[value.itemID] == nil {
        result[value.itemID] = value
      }
    }
    let groupedByAlbum = Dictionary(grouping: normalized.compactMap { media -> NormalizedMedia? in
      media.track.albumID == nil ? nil : media
    }, by: { $0.track.albumID! })

    for (albumID, tracks) in groupedByAlbum {
      guard let baseAlbum = tracks.lazy.compactMap({ media in
        media.transaction.mutations.compactMap { mutation -> Album? in
          guard case .upsert(.album(let value)) = mutation, value.id == albumID else { return nil }
          return value
        }.first
      }).first else { continue }
      let albumType = tracks.compactMap { plannedByID[$0.itemID]?.albumType }.first
      let album = Album(
        id: baseAlbum.id,
        title: baseAlbum.title,
        sortTitle: baseAlbum.sortTitle,
        artistIDs: baseAlbum.artistIDs,
        artwork: tracks.compactMap(\.track.artwork).first ?? baseAlbum.artwork,
        releaseYear: baseAlbum.releaseYear,
        trackCount: tracks.count,
        albumType: albumType ?? baseAlbum.albumType
      )
      mutations.append(.upsert(.album(album)))
      mutations.append(.upsert(.albumRelease(album.releaseProjection)))
    }

    var assetByID: [MediaAssetID: MediaAsset] = [:]
    var discByID: [DiscID: Disc] = [:]
    for media in normalized {
      let track = media.track
      assetByID[track.assetID] = track.mediaAssetProjection
      mutations.append(.upsert(.logicalTrack(track.logicalTrackProjection)))
      mutations.append(.upsert(.trackVariant(track.trackVariantProjection)))
      guard let releaseID = track.albumID.map(AlbumReleaseID.init(legacyAlbumID:)) else {
        continue
      }
      // LogicalTrack's projection uses Disc 1 as the default whenever a track
      // belongs to an album but has no explicit disc number. Materialize the
      // same default here so graph validation never sees a dangling disc ID.
      let discNumber = track.discNumber ?? 1
      let discID = DiscID(releaseID: releaseID, number: discNumber)
      let sameDiscTracks = normalized.filter {
        $0.track.albumID == track.albumID && ($0.track.discNumber ?? 1) == discNumber
      }
      discByID[discID] = Disc(
        id: discID,
        releaseID: releaseID,
        number: discNumber,
        title: plannedByID[media.itemID]?.discTitle,
        trackCount: sameDiscTracks.count
      )
    }
    mutations.append(contentsOf: assetByID.values.map { .upsert(.mediaAsset($0)) })
    mutations.append(contentsOf: discByID.values.map { .upsert(.disc($0)) })

    if let manifest = bundle.collectionManifest {
      let releasesByFolder = Dictionary(grouping: normalized.compactMap { media -> (String, AlbumReleaseID)? in
        guard let albumID = media.track.albumID,
              let planned = plannedByID[media.itemID]
        else { return nil }
        return (
          LocalMediaCollectionManifest.normalizedPath(planned.releaseFolder).lowercased(),
          AlbumReleaseID(legacyAlbumID: albumID)
        )
      }, by: { $0.0 })

      var releaseIDs: [AlbumReleaseID] = []
      for member in manifest.albums {
        let candidates = Set(releasesByFolder[member.folderPath.lowercased()]?.map { $0.1 } ?? [])
        guard candidates.count == 1, let releaseID = candidates.first else {
          throw LocalMediaError.metadataFailed
        }
        releaseIDs.append(releaseID)
      }
      guard Set(releaseIDs).count == releaseIDs.count else {
        throw LocalMediaError.metadataFailed
      }

      var collectionIdentity = [manifest.title]
      for album in manifest.albums {
        collectionIdentity.append(album.folderPath)
        collectionIdentity.append(album.title)
      }
      let collectionID = LibraryCollectionID(
        "local-box-set-\(MusicContentIdentity.compositeToken(collectionIdentity))"
      )
      let collectionArtwork = normalized
        .sorted { $0.itemID < $1.itemID }
        .compactMap(\.track.artwork)
        .first
      mutations.append(.upsert(.collection(LibraryCollection(
        id: collectionID,
        kind: .boxSet,
        title: manifest.title,
        artwork: collectionArtwork
      ))))
      for (position, releaseID) in releaseIDs.enumerated() {
        mutations.append(.upsert(.collectionMember(LibraryCollectionMember(
          collectionID: collectionID,
          releaseID: releaseID,
          position: position
        ))))
      }
    }
    return mutations
  }

  private func cueMetadata(
    sheet: CUESheet,
    track: CUETrack,
    fallback: RawMediaMetadata,
    duration: Duration
  ) -> RawMediaMetadata {
    let genre = track.remarks.first(where: { $0.key == "GENRE" })?.value
      ?? sheet.remarks.first(where: { $0.key == "GENRE" })?.value
      ?? fallback.genre
    let yearText = track.remarks.first(where: { $0.key == "DATE" })?.value
      ?? sheet.remarks.first(where: { $0.key == "DATE" })?.value
    return RawMediaMetadata(
      title: track.title ?? fallback.title,
      artist: track.performer ?? sheet.performer ?? fallback.artist,
      album: sheet.title ?? fallback.album,
      albumArtist: sheet.performer ?? fallback.albumArtist,
      composer: track.songwriter ?? sheet.songwriter ?? fallback.composer,
      genre: genre,
      comment: fallback.comment,
      lyrics: nil,
      trackNumber: track.number,
      discNumber: fallback.discNumber,
      year: yearText.flatMap(Int.init) ?? fallback.year,
      duration: duration,
      artworks: fallback.artworks
    )
  }

  private func replacing(
    _ value: RawMediaMetadata,
    album: String? = nil,
    albumArtist: String? = nil,
    discNumber: Int? = nil
  ) -> RawMediaMetadata {
    RawMediaMetadata(
      title: value.title,
      artist: value.artist,
      album: album ?? value.album,
      albumArtist: albumArtist ?? value.albumArtist,
      composer: value.composer,
      genre: value.genre,
      comment: value.comment,
      lyrics: value.lyrics,
      trackNumber: value.trackNumber,
      discNumber: discNumber ?? value.discNumber,
      year: value.year,
      duration: value.duration,
      artworks: value.artworks
    )
  }

  private func readCue(_ url: URL) throws -> Data {
    let maximumByteCount = 4 * 1_024 * 1_024
    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
          values.isRegularFile == true,
          let fileSize = values.fileSize,
          fileSize > 0,
          fileSize <= maximumByteCount
    else { throw LocalMediaError.metadataFailed }
    do {
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard !data.isEmpty, data.count <= maximumByteCount else {
        throw LocalMediaError.metadataFailed
      }
      return data
    } catch let error as LocalMediaError {
      throw error
    } catch {
      throw LocalMediaError.metadataFailed
    }
  }

  private func stableCueObjectID(for url: URL) -> String {
    let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
      .lowercased()
    return MusicContentIdentity.compositeToken(["local-cue-v1", canonicalPath])
  }

  private func releaseFolder(
    for file: ImportFile,
    bundle: FolderImportBundle
  ) -> (path: String, discTitle: String?) {
    var components = file.folderPath?.split(separator: "/").map(String.init) ?? []
    let discTitle = components.last.flatMap { inferredDiscNumber(from: $0) == nil ? nil : $0 }
    if discTitle != nil { components.removeLast() }
    let path = components.isEmpty ? "." : components.joined(separator: "/")
    return (path, discTitle)
  }

  private func releaseTitle(for path: String, bundle: FolderImportBundle) -> String? {
    let value = path == "." ? bundle.rootURL.lastPathComponent : URL(fileURLWithPath: path).lastPathComponent
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  /// A directory containing multiple releases is a source-level release
  /// context. Keep that context in the AlbumID whenever the bundle has more
  /// than one release, otherwise same-title/same-artist editions would be
  /// silently merged by the legacy metadata-derived identity.
  private func releaseScopedAlbumIDs(for values: [PlannedTrack]) -> [String: AlbumID] {
    let contexts = Set(values.compactMap(releaseContextKey(for:)))
    guard contexts.count > 1 else { return [:] }
    return Dictionary(uniqueKeysWithValues: contexts.map { context in
      let token = MusicContentIdentity.compositeToken([
        "local-release-album",
        context
      ])
      return (context, AlbumID(rawValue: "local-release-album-\(token)"))
    })
  }

  private func releaseContextKey(for value: PlannedTrack) -> String? {
    guard let album = normalized(value.metadata.album) else { return nil }
    return MusicContentIdentity.compositeToken([
      "folder", LocalMediaCollectionManifest.normalizedPath(value.releaseFolder).lowercased(),
      "album", album,
      "album-artist", normalized(value.metadata.albumArtist)
        ?? normalized(value.metadata.artist)
        ?? ""
    ])
  }

  private func inferredDiscNumber(from folderPath: String?) -> Int? {
    guard let name = folderPath?.split(separator: "/").last.map(String.init) else { return nil }
    return inferredDiscNumber(from: name)
  }

  private func inferredDiscNumber(from name: String) -> Int? {
    let compact = name.lowercased()
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
    guard let range = compact.range(
      of: #"^(?:cd|disc|disk|dvd|part|volume|vol)\s*([0-9]+)$"#,
      options: .regularExpression
    ) else { return nil }
    let match = String(compact[range])
    return Int(match.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
  }

  private func normalized(_ value: String?) -> String? {
    guard let value else { return nil }
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return result.isEmpty ? nil : result
  }

  private func plannedTrackOrder(_ lhs: PlannedTrack, _ rhs: PlannedTrack) -> Bool {
    let left = (lhs.metadata.discNumber ?? 1, lhs.metadata.trackNumber ?? Int.max)
    let right = (rhs.metadata.discNumber ?? 1, rhs.metadata.trackNumber ?? Int.max)
    if left != right { return left < right }
    return lhs.itemID < rhs.itemID
  }
}

private struct LocalMediaMutationAccumulator {
  private var values: [String: LibraryMutation] = [:]

  mutating func add(_ mutation: LibraryMutation) {
    values[key(for: mutation)] = mutation
  }

  var mutations: [LibraryMutation] {
    values.keys.sorted { lhs, rhs in
      let lhsMutation = values[lhs]!
      let rhsMutation = values[rhs]!
      let lhsPhase = Self.phase(for: lhsMutation)
      let rhsPhase = Self.phase(for: rhsMutation)
      return lhsPhase == rhsPhase ? lhs < rhs : lhsPhase < rhsPhase
    }.compactMap { values[$0] }
  }

  private static func phase(for mutation: LibraryMutation) -> Int {
    switch mutation {
    case .upsert: return 0
    case .relation: return 1
    case .statistics: return 2
    }
  }

  private func key(for mutation: LibraryMutation) -> String {
    switch mutation {
    case .upsert(let value):
      switch value {
      case .track(let item): return "upsert:track:\(item.id)"
      case .album(let item): return "upsert:album:\(item.id.rawValue)"
      case .artist(let item): return "upsert:artist:\(item.id.rawValue)"
      case .genre(let item): return "upsert:genre:\(item.id.rawValue)"
      case .artwork(let item): return "upsert:artwork:\(item.id.rawValue)"
      case .logicalTrack(let item): return "upsert:logical:\(item.id.rawValue)"
      case .trackVariant(let item): return "upsert:variant:\(item.id)"
      case .mediaAsset(let item): return "upsert:asset:\(item.id)"
      case .albumGroup(let item): return "upsert:group:\(item.id.rawValue)"
      case .albumRelease(let item): return "upsert:release:\(item.id.rawValue)"
      case .disc(let item): return "upsert:disc:\(item.id.rawValue)"
      case .collection(let item): return "upsert:collection:\(item.id.rawValue)"
      case .collectionMember(let item):
        return "upsert:member:\(item.collectionID.rawValue):\(item.releaseID.rawValue)"
      }
    case .relation(let value):
      switch value {
      case .setAlbum(let trackID, _): return "relation:album:\(trackID)"
      case .setArtists(let trackID, _): return "relation:artists:\(trackID)"
      case .setGenres(let trackID, _): return "relation:genres:\(trackID)"
      case .setArtwork(let trackID, _): return "relation:artwork:\(trackID)"
      }
    case .statistics(let value):
      switch value {
      case .replace(let trackID, _), .increment(let trackID, _):
        return "statistics:\(trackID)"
      }
    }
  }
}
