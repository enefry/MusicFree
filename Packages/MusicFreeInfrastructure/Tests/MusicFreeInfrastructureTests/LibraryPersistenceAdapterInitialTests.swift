import Foundation
import LibraryAPI
import MusicDomain
import PlaybackAPI
import SwiftData
import Testing

@testable import LibraryPersistenceAdapter

@Test("persistence dates retain precision and read legacy millisecond payloads")
func persistenceCodecDateCompatibility() throws {
    let preciseDate = Date(timeIntervalSinceReferenceDate: 123_456.789123)
    let preciseData = try PersistenceCodec.encode(DatePayload(date: preciseDate))
    let preciseRoundTrip = try PersistenceCodec.decode(DatePayload.self, from: preciseData)
    #expect(preciseRoundTrip.date == preciseDate)

    let legacyDate = Date(timeIntervalSince1970: 100.123)
    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .millisecondsSince1970
    let legacyData = try legacyEncoder.encode(DatePayload(date: legacyDate))
    let legacyRoundTrip = try PersistenceCodec.decode(DatePayload.self, from: legacyData)
    #expect(legacyRoundTrip.date == legacyDate)
}

@Test("persisted metadata repair rewrites every metadata record and survives reopen")
func persistedMetadataRepairRewritesAllSupportedRecords() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("metadata-repair.store")
    let fixture = try makePersistedMojibakeFixture(at: storeURL)

    let store = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let library = SwiftDataLibraryRepository(store: store)
    let changes = library.changes()
    var changeIterator = changes.makeAsyncIterator()

    #expect(try await store.currentRevision() == LibraryRevision(7))
    let result = try await library.repairMetadata()
    let change = try #require(await changeIterator.next())

    #expect(result.scannedRecordCount == 12)
    #expect(result.repairedRecordCount == 12)
    #expect(result.revision == LibraryRevision(8))
    #expect(change.revision == result.revision)
    #expect(change.categories == [.tracks, .albums, .artists, .genres, .playlists])
    #expect(change.affectedIDs.trackIDs == [fixture.track.id])
    #expect(change.affectedIDs.albumIDs == [fixture.album.id])
    #expect(change.affectedIDs.artistIDs == [fixture.artist.id])
    #expect(change.affectedIDs.genreIDs == [fixture.genre.id])
    #expect(change.affectedIDs.playlistIDs == [fixture.playlist.id])
    await store.close()

    let reopenedStore = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let reopenedLibrary = SwiftDataLibraryRepository(store: reopenedStore)
    let reopenedPlaylists = SwiftDataPlaylistRepository(store: reopenedStore)
    let secondResult = try await reopenedLibrary.repairMetadata()

    #expect(secondResult.scannedRecordCount == 12)
    #expect(secondResult.repairedRecordCount == 0)
    #expect(secondResult.revision == LibraryRevision(8))
    #expect(try await reopenedLibrary.track(id: fixture.track.id) == fixture.track)
    #expect(try await reopenedLibrary.album(id: fixture.album.id) == fixture.album)
    #expect(try await reopenedLibrary.artist(id: fixture.artist.id) == fixture.artist)
    #expect(try await reopenedLibrary.genre(id: fixture.genre.id) == fixture.genre)
    #expect(
        try await reopenedLibrary.logicalTrack(id: fixture.logicalTrack.id)
            == fixture.logicalTrack
    )
    #expect(try await reopenedLibrary.mediaAsset(id: fixture.asset.id) == fixture.asset)
    #expect(try await reopenedLibrary.trackVariant(id: fixture.variant.id) == fixture.variant)
    #expect(try await reopenedLibrary.release(id: fixture.release.id) == fixture.release)
    #expect(try await reopenedLibrary.discs(for: fixture.release.id) == [fixture.disc])
    #expect(try await reopenedLibrary.collections().contains(fixture.collection))
    let playlistPage = try await reopenedPlaylists.playlists(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(playlistPage.elements == [fixture.playlist])
    await reopenedStore.close()
}

@Test("metadata repair merges three split local albums and local graph references")
func persistedMetadataRepairMergesThreeSplitLocalAlbums() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("split-album-repair.store")

    let title = "Split Album"
    let albumIDs = (1...3).map { AlbumID("local-album-split-\($0)") }
    let artistIDs = (1...3).map { ArtistID("split-album-artist-\($0)") }
    let artworks = (1...3).map {
        ArtworkReference(
            id: ArtworkID("split-album-cover-\($0)"),
            variants: [.original],
            preferredVariant: .original
        )
    }
    let canonicalAlbumID = albumIDs[0]
    let canonicalReleaseID = AlbumReleaseID(legacyAlbumID: canonicalAlbumID)
    let collectionID = LibraryCollectionID("split-album-collection")

    let tracks = (0..<3).flatMap { albumIndex in
        (1...2).map { (trackNumber: Int) in
            Track(
                id: MediaItemID(
                    sourceID: .local,
                    externalID: "split-\(albumIndex + 1)-track-\(trackNumber)"
                ),
                logicalTrackID: LogicalTrackID(
                    "split-\(albumIndex + 1)-logical-\(trackNumber)"
                ),
                title: "Track \(albumIndex + 1)-\(trackNumber)",
                albumID: albumIDs[albumIndex],
                artistIDs: [artistIDs[albumIndex]],
                trackNumber: trackNumber,
                trackTotal: 2,
                discNumber: 1,
                discTotal: 1
            )
        }
    }
    let albums = albumIDs.enumerated().map { index, albumID in
        Album(
            id: albumID,
            title: title,
            artistIDs: [artistIDs[index]],
            artwork: artworks[index],
            trackCount: 2
        )
    }
    let releases = albums.map(\.releaseProjection)
    let discs = releases.map { release in
        Disc(
            id: DiscID(releaseID: release.id, number: 1),
            releaseID: release.id,
            number: 1,
            trackCount: 2
        )
    }
    let logicalTracks = tracks.map(\.logicalTrackProjection)
    let collection = LibraryCollection(
        id: collectionID,
        kind: .boxSet,
        title: "Split Album Collection"
    )

    let schema = Schema(versionedSchema: MusicFreeSchema.self)
    let configuration = ModelConfiguration(
        "MusicFreeLibrary",
        schema: schema,
        url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    for track in tracks {
        context.insert(try LibraryRecordMapper.makeTrack(track))
    }
    for (index, album) in albums.enumerated() {
        context.insert(try LibraryRecordMapper.makeAlbum(
            album,
            dateAddedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
        ))
        context.insert(try LibraryRecordMapper.makeArtist(
            Artist(id: artistIDs[index], name: "Split Artist \(index + 1)")
        ))
        context.insert(try LibraryRecordMapper.makeArtwork(artworks[index]))
    }
    for logicalTrack in logicalTracks {
        context.insert(try LocalMediaGraphRecordMapper.makeLogicalTrack(logicalTrack))
    }
    for release in releases {
        context.insert(try LocalMediaGraphRecordMapper.makeRelease(release))
    }
    for disc in discs {
        context.insert(try LocalMediaGraphRecordMapper.makeDisc(disc))
    }
    context.insert(try LocalMediaGraphRecordMapper.makeCollection(collection))
    for release in releases {
        context.insert(try LocalMediaGraphRecordMapper.makeMember(LibraryCollectionMember(
            collectionID: collectionID,
            releaseID: release.id,
            position: 0
        )))
    }
    try context.save()

    let store = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let library = SwiftDataLibraryRepository(store: store)
    let result = try await library.repairMetadata()

    let albumPage = try await library.albums(
        matching: AlbumQuery(),
        page: try LibraryPageRequest(limit: 10)
    )
    let mergedAlbum = try #require(await library.album(id: canonicalAlbumID))
    let canonicalRelease = try #require(await library.release(id: canonicalReleaseID))
    let mergedDiscs = try await library.discs(for: canonicalReleaseID)
    let members = try await library.members(in: collectionID)

    #expect(result.repairedRecordCount > 0)
    #expect(albumPage.elements == [mergedAlbum])
    #expect(mergedAlbum.artistIDs == artistIDs)
    #expect(mergedAlbum.artwork == artworks[0])
    #expect(mergedAlbum.trackCount == 6)
    #expect(mergedAlbum.albumType == .compilation)
    #expect(canonicalRelease.artwork == artworks[0])
    #expect(canonicalRelease.albumType == .compilation)
    #expect(try await library.album(id: albumIDs[1]) == nil)
    #expect(try await library.album(id: albumIDs[2]) == nil)
    for (index, track) in tracks.enumerated() {
        let stored = try #require(await library.track(id: track.id))
        #expect(stored.albumID == canonicalAlbumID)
        #expect(stored.trackTotal == 2)
        #expect(stored.discNumber == index / 2 + 1)
        #expect(stored.discTotal == 3)
    }
    #expect(try await library.release(id: releases[1].id) == nil)
    #expect(try await library.release(id: releases[2].id) == nil)
    #expect(mergedDiscs.map(\.number) == [1, 2, 3])
    #expect(mergedDiscs.map(\.trackCount) == [2, 2, 2])
    for (index, logicalTrack) in logicalTracks.enumerated() {
        let stored = try #require(await library.logicalTrack(id: logicalTrack.id))
        let discNumber = index / 2 + 1
        #expect(stored.releaseID == canonicalReleaseID)
        #expect(stored.discID == DiscID(releaseID: canonicalReleaseID, number: discNumber))
        #expect(stored.trackTotal == 2)
        #expect(stored.discNumber == discNumber)
        #expect(stored.discTotal == 3)
    }
    #expect(members == [LibraryCollectionMember(
        collectionID: collectionID,
        releaseID: canonicalReleaseID,
        position: 0
    )])
    #expect(try await library.artwork(id: artworks[0].id) == artworks[0])
    #expect(try await library.artwork(id: artworks[1].id) == nil)
    #expect(try await library.artwork(id: artworks[2].id) == nil)

    let secondResult = try await library.repairMetadata()
    #expect(secondResult.repairedRecordCount == 0)

    await store.close()
}

@Test("records keep numbering and album type scalar fields in sync with payloads")
func recordMappersPersistNumberingAndAlbumType() throws {
    let album = Album(
        id: AlbumID("typed-album"),
        title: "Typed Album",
        albumType: .soundtrack
    )
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "numbered-track"),
        title: "Numbered Track",
        albumID: album.id,
        trackNumber: 8,
        discNumber: 2
    )

    let albumRecord = try LibraryRecordMapper.makeAlbum(album)
    let trackRecord = try LibraryRecordMapper.makeTrack(track)
    #expect(albumRecord.albumType == "soundtrack")
    #expect(trackRecord.trackNumber == 8)
    #expect(trackRecord.discNumber == 2)
    #expect(try LibraryRecordMapper.album(from: albumRecord) == album)
    #expect(try LibraryRecordMapper.track(from: trackRecord) == track)
}

@Test("local graph record mappers reject mismatched redundant relationship scalars")
func localGraphRecordMappersRejectMismatchedScalars() throws {
    let albumID = AlbumID("mapper-album")
    let releaseID = AlbumReleaseID("mapper-release")
    let groupID = AlbumGroupID("mapper-group")
    let discID = DiscID(releaseID: releaseID, number: 1)
    let logical = LogicalTrack(
        id: LogicalTrackID("mapper-logical"),
        releaseID: releaseID,
        discID: discID,
        title: "Track",
        discNumber: 1
    )
    let release = AlbumRelease(
        id: releaseID,
        legacyAlbumID: albumID,
        groupID: groupID,
        title: "Release"
    )

    let logicalRecord = try LocalMediaGraphRecordMapper.makeLogicalTrack(logical)
    logicalRecord.releaseID = "other-release"
    #expect(throws: LibraryPersistenceError.corruptedRecord) {
        try LocalMediaGraphRecordMapper.logicalTrack(from: logicalRecord)
    }

    let discRecord = try LocalMediaGraphRecordMapper.makeLogicalTrack(logical)
    discRecord.discID = "other-disc"
    #expect(throws: LibraryPersistenceError.corruptedRecord) {
        try LocalMediaGraphRecordMapper.logicalTrack(from: discRecord)
    }

    let releaseRecord = try LocalMediaGraphRecordMapper.makeRelease(release)
    releaseRecord.groupID = "other-group"
    #expect(throws: LibraryPersistenceError.corruptedRecord) {
        try LocalMediaGraphRecordMapper.release(from: releaseRecord)
    }

    let member = LibraryCollectionMember(
        collectionID: LibraryCollectionID("mapper-collection"),
        releaseID: releaseID,
        position: 0
    )
    let mismatchedLegacyMemberRecord = try LocalMediaGraphRecordMapper.makeMember(member)
    mismatchedLegacyMemberRecord.collectionID = "other-collection"
    mismatchedLegacyMemberRecord.storageKey = PersistenceKey.legacyCollectionMember(member)
    #expect(throws: LibraryPersistenceError.corruptedRecord) {
        try LocalMediaGraphRecordMapper.member(from: mismatchedLegacyMemberRecord)
    }
}

@Test("composite persistence keys avoid separator collisions and read legacy records")
func compositePersistenceKeysAvoidSeparatorCollisionsAndReadLegacyRecords() async throws {
    let firstMember = LibraryCollectionMember(
        collectionID: LibraryCollectionID("box|one"),
        releaseID: AlbumReleaseID("release"),
        position: 0
    )
    let secondMember = LibraryCollectionMember(
        collectionID: LibraryCollectionID("box"),
        releaseID: AlbumReleaseID("one|release"),
        position: 0
    )

    #expect(PersistenceKey.legacyCollectionMember(firstMember)
        == PersistenceKey.legacyCollectionMember(secondMember))
    #expect(PersistenceKey.collectionMember(firstMember)
        != PersistenceKey.collectionMember(secondMember))

    let legacyMemberRecord = try LocalMediaGraphRecordMapper.makeMember(firstMember)
    legacyMemberRecord.storageKey = PersistenceKey.legacyCollectionMember(firstMember)
    #expect(try LocalMediaGraphRecordMapper.member(from: legacyMemberRecord) == firstMember)

    let entry = PlaylistEntry(
        playlistID: PlaylistID("playlist|one"),
        trackID: MediaItemID(sourceID: .local, externalID: "track|one"),
        position: 0
    )
    let legacyEntryRecord = LibraryRecordMapper.makeEntry(entry)
    legacyEntryRecord.storageKey = PersistenceKey.legacyEntry(
        playlistID: entry.playlistID,
        itemID: entry.trackID
    )
    #expect(try LibraryRecordMapper.entry(from: legacyEntryRecord) == entry)

    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let firstCollection = LibraryCollection(
        id: firstMember.collectionID,
        kind: .boxSet,
        title: "First Box"
    )
    let secondCollection = LibraryCollection(
        id: secondMember.collectionID,
        kind: .boxSet,
        title: "Second Box"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "composite-collection-member-keys",
        mutations: [
            .upsert(.albumRelease(AlbumRelease(id: firstMember.releaseID, title: "First Release"))),
            .upsert(.albumRelease(AlbumRelease(id: secondMember.releaseID, title: "Second Release"))),
            .upsert(.collection(firstCollection)),
            .upsert(.collection(secondCollection)),
            .upsert(.collectionMember(firstMember)),
            .upsert(.collectionMember(secondMember)),
        ]
    ))

    #expect(try await library.members(in: firstMember.collectionID) == [firstMember])
    #expect(try await library.members(in: secondMember.collectionID) == [secondMember])
    await store.close()
}

@Test("legacy collection member migration preserves colliding identities")
func legacyCollectionMemberMigrationPreservesCollidingIdentities() async throws {
    let firstMember = LibraryCollectionMember(
        collectionID: LibraryCollectionID("box|one"),
        releaseID: AlbumReleaseID("release"),
        position: 0
    )
    let secondMember = LibraryCollectionMember(
        collectionID: LibraryCollectionID("box"),
        releaseID: AlbumReleaseID("one|release"),
        position: 0
    )
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("legacy-member-collision.store")
    try makeCurrentStoreWithLegacyCollectionMember(at: storeURL, member: firstMember)

    let store = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let library = SwiftDataLibraryRepository(store: store)
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "legacy-member-collision-migration",
        mutations: [
            .upsert(.albumRelease(AlbumRelease(id: firstMember.releaseID, title: "First Release"))),
            .upsert(.albumRelease(AlbumRelease(id: secondMember.releaseID, title: "Second Release"))),
            .upsert(.collection(LibraryCollection(
                id: firstMember.collectionID,
                kind: .boxSet,
                title: "First Box"
            ))),
            .upsert(.collection(LibraryCollection(
                id: secondMember.collectionID,
                kind: .boxSet,
                title: "Second Box"
            ))),
            .upsert(.collectionMember(secondMember)),
        ]
    ))

    #expect(try await library.members(in: firstMember.collectionID) == [firstMember])
    #expect(try await library.members(in: secondMember.collectionID) == [secondMember])
    await store.close()
}

@Test("local graph records round trip CUE variants and preserve shared assets")
func localMediaGraphRoundTripAndSharedAssetPruning() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-shared-cue-audio")
    let firstID = MediaItemID(sourceID: .local, externalID: "cue-shared-01")
    let secondID = MediaItemID(sourceID: .local, externalID: "cue-shared-02")
    let first = Track(
        id: firstID,
        logicalTrackID: LogicalTrackID("cue-shared-logical-01"),
        assetID: assetID,
        playbackSelection: PlaybackSelection(range: PlaybackRange(
            start: .zero,
            end: .seconds(60)
        )),
        title: "Part One",
        trackNumber: 1,
        trackTotal: 2,
        duration: .seconds(60)
    )
    let second = Track(
        id: secondID,
        logicalTrackID: LogicalTrackID("cue-shared-logical-02"),
        assetID: assetID,
        playbackSelection: PlaybackSelection(
            range: PlaybackRange(start: .seconds(60), end: .seconds(120)),
            audioStream: AudioStreamSelection(
                streamID: AudioStreamID("vlc-media-id:9"),
                fallbackSignature: AudioStreamSignature(
                    language: "jpn",
                    title: "Original Mix",
                    codec: "flac",
                    channelCount: 2,
                    indexHint: 1
                )
            )
        ),
        title: "Part Two",
        trackNumber: 2,
        trackTotal: 2,
        duration: .seconds(60),
        technicalInfo: MediaTechnicalInfo(
            container: "matroska",
            duration: .seconds(120),
            audioStreams: [
                AudioStreamInfo(
                    streamID: AudioStreamID("vlc-media-id:9"),
                    indexHint: 1,
                    language: "jpn",
                    title: "Original Mix",
                    isDefault: true,
                    codec: "flac",
                    sampleRate: 96_000,
                    bitDepth: 24,
                    channels: 2
                )
            ]
        )
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "cue-shared-graph",
        mutations: [.upsert(.track(first)), .upsert(.track(second))]
    ))

    #expect(try await library.logicalTrack(id: first.logicalTrackID) == first.logicalTrackProjection)
    #expect(try await library.trackVariant(id: secondID) == second.trackVariantProjection)
    #expect(try await library.mediaAsset(id: assetID) != nil)

    try await library.remove([firstID])
    #expect(try await library.logicalTrack(id: first.logicalTrackID) == nil)
    #expect(try await library.mediaAsset(id: assetID) != nil)
    #expect(try await library.track(id: secondID) == second)

    try await library.remove([secondID])
    #expect(try await library.mediaAsset(id: assetID) == nil)
    await store.close()
}

@Test("track-only updates preserve explicit source metadata snapshots")
func trackOnlyUpdatesPreserveSourceMetadataSnapshots() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "cue-source-snapshot-f1-t1")
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-source-snapshot")
    let sourceTrack = Track(
        id: itemID,
        logicalTrackID: LogicalTrackID("local:cue-source-snapshot-f1-t1"),
        assetID: assetID,
        title: "Source Title"
    )
    let sourceVariant = TrackVariant(
        id: itemID,
        logicalTrackID: sourceTrack.logicalTrackID,
        assetID: assetID,
        sourceIdentityHint: "cue-identity-hint-one",
        sourceMetadataRevision: "cue-revision-one",
        sourceMetadata: TrackSourceMetadataSnapshot(track: sourceTrack)
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "install-source-metadata-snapshot",
        mutations: [
            .upsert(.track(sourceTrack)),
            .upsert(.trackVariant(sourceVariant))
        ]
    ))

    let editedTrack = Track(
        id: sourceTrack.id,
        logicalTrackID: sourceTrack.logicalTrackID,
        assetID: sourceTrack.assetID,
        playbackSelection: sourceTrack.playbackSelection,
        title: "Manual Title"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "edit-track-without-variant",
        mutations: [.upsert(.track(editedTrack))]
    ))

    let persistedVariant = try #require(try await library.trackVariant(id: itemID))
    #expect(persistedVariant.sourceIdentityHint == "cue-identity-hint-one")
    #expect(persistedVariant.sourceMetadataRevision == "cue-revision-one")
    #expect(persistedVariant.sourceMetadata?.title == "Source Title")
    #expect(try await library.track(id: itemID)?.title == "Manual Title")
    await store.close()
}

@Test("explicit local graph mutations persist release, disc, and collection atomically")
func explicitLocalGraphTransactionRoundTripsCollectionStructure() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let releaseID = AlbumReleaseID("local-release-box-disc-one")
    let disc = Disc(
        id: DiscID(releaseID: releaseID, number: 1),
        releaseID: releaseID,
        number: 1,
        title: "Main Album",
        trackCount: 1
    )
    let asset = MediaAsset(
        id: MediaAssetID(sourceID: .local, externalID: "sha256-explicit-asset"),
        contentRevision: "sha256-explicit-asset",
        fileName: "album.flac"
    )
    let logical = LogicalTrack(
        id: LogicalTrackID("local-logical-box-track"),
        releaseID: releaseID,
        discID: disc.id,
        title: "Opening",
        trackNumber: 1,
        trackTotal: 1,
        discNumber: 1,
        discTotal: 1,
        duration: .seconds(90)
    )
    let variant = TrackVariant(
        id: MediaItemID(sourceID: .local, externalID: "local-variant-box-track"),
        logicalTrackID: logical.id,
        assetID: asset.id
    )
    let release = AlbumRelease(id: releaseID, title: "Disc One")
    let collection = LibraryCollection(
        id: LibraryCollectionID("local-box-set"),
        kind: .boxSet,
        title: "The Box"
    )
    let member = LibraryCollectionMember(
        collectionID: collection.id,
        releaseID: releaseID,
        position: 0
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "explicit-local-graph",
        mutations: [
            .upsert(.collectionMember(member)),
            .upsert(.trackVariant(variant)),
            .upsert(.logicalTrack(logical)),
            .upsert(.mediaAsset(asset)),
            .upsert(.disc(disc)),
            .upsert(.albumRelease(release)),
            .upsert(.collection(collection)),
        ]
    ))

    #expect(try await library.release(id: releaseID) == release)
    #expect(try await library.discs(for: releaseID) == [disc])
    #expect(try await library.logicalTrack(id: logical.id) == logical)
    #expect(try await library.trackVariant(id: variant.id) == variant)
    #expect(try await library.mediaAsset(id: asset.id) == asset)
    #expect(try await library.collections() == [collection])
    #expect(try await library.members(in: collection.id) == [member])
    await store.close()
}

@Test("local graph validation rejects a disc belonging to another release")
func localGraphValidationRejectsMismatchedDiscRelease() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let releaseID = AlbumReleaseID("graph-release")
    let otherReleaseID = AlbumReleaseID("graph-other-release")
    let discID = DiscID(releaseID: otherReleaseID, number: 1)
    let logical = LogicalTrack(
        id: LogicalTrackID("graph-mismatched-logical"),
        releaseID: releaseID,
        discID: discID,
        title: "Mismatched",
        discNumber: 1
    )

    await #expect(throws: LibraryError.constraint(.danglingReference)) {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "graph-mismatched-disc-release",
            mutations: [
                .upsert(.albumRelease(AlbumRelease(id: releaseID, title: "Release"))),
                .upsert(.albumRelease(AlbumRelease(id: otherReleaseID, title: "Other"))),
                .upsert(.disc(Disc(
                    id: discID,
                    releaseID: otherReleaseID,
                    number: 1
                ))),
                .upsert(.logicalTrack(logical))
            ]
        ))
    }
    await store.close()
}

@Test("local graph validation rejects missing artist and genre references")
func localGraphValidationRejectsMissingArtistAndGenreReferences() async throws {
    let artistStore = try LibraryPersistenceStore(configuration: .inMemory)
    let artistLibrary = SwiftDataLibraryRepository(store: artistStore)
    let artistID = ArtistID("missing-swiftdata-artist")
    let artistLogicalID = LogicalTrackID("missing-swiftdata-artist-logical")
    let artistAssetID = MediaAssetID(sourceID: .local, externalID: "missing-swiftdata-artist-asset")

    await #expect(throws: LibraryError.constraint(.danglingReference)) {
        try await artistLibrary.apply(try LibraryTransaction(
            idempotencyKey: "missing-swiftdata-artist",
            mutations: [
                .upsert(.logicalTrack(LogicalTrack(
                    id: artistLogicalID,
                    title: "Missing Artist",
                    artistIDs: [artistID]
                ))),
                .upsert(.mediaAsset(MediaAsset(id: artistAssetID))),
                .upsert(.trackVariant(TrackVariant(
                    id: MediaItemID(sourceID: .local, externalID: "missing-swiftdata-artist-variant"),
                    logicalTrackID: artistLogicalID,
                    assetID: artistAssetID
                )))
            ]
        ))
    }
    #expect(try await artistLibrary.logicalTrack(id: artistLogicalID) == nil)
    await artistStore.close()

    let genreStore = try LibraryPersistenceStore(configuration: .inMemory)
    let genreLibrary = SwiftDataLibraryRepository(store: genreStore)
    let genreID = GenreID("missing-swiftdata-genre")
    let genreLogicalID = LogicalTrackID("missing-swiftdata-genre-logical")
    let genreAssetID = MediaAssetID(sourceID: .local, externalID: "missing-swiftdata-genre-asset")

    await #expect(throws: LibraryError.constraint(.danglingReference)) {
        try await genreLibrary.apply(try LibraryTransaction(
            idempotencyKey: "missing-swiftdata-genre",
            mutations: [
                .upsert(.logicalTrack(LogicalTrack(
                    id: genreLogicalID,
                    title: "Missing Genre",
                    genreIDs: [genreID]
                ))),
                .upsert(.mediaAsset(MediaAsset(id: genreAssetID))),
                .upsert(.trackVariant(TrackVariant(
                    id: MediaItemID(sourceID: .local, externalID: "missing-swiftdata-genre-variant"),
                    logicalTrackID: genreLogicalID,
                    assetID: genreAssetID
                )))
            ]
        ))
    }
    #expect(try await genreLibrary.logicalTrack(id: genreLogicalID) == nil)
    await genreStore.close()
}

@Test("clearing a legacy album artist updates its release projection before pruning")
func clearingLegacyAlbumArtistUpdatesReleaseProjection() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let albumID = AlbumID("clear-album-artist")
    let releaseID = AlbumReleaseID(legacyAlbumID: albumID)
    let albumArtistID = ArtistID("clear-album-artist-album-artist")
    let trackArtistID = ArtistID("clear-album-artist-track-artist")
    let trackID = MediaItemID(sourceID: .local, externalID: "clear-album-artist-track")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "clear-album-artist-initial",
        mutations: [
            .upsert(.artist(Artist(id: albumArtistID, name: "Album Artist"))),
            .upsert(.artist(Artist(id: trackArtistID, name: "Track Artist"))),
            .upsert(.album(Album(
                id: albumID,
                title: "Album",
                artistIDs: [albumArtistID],
                trackCount: 1
            ))),
            .upsert(.albumRelease(AlbumRelease(
                id: releaseID,
                legacyAlbumID: albumID,
                title: "Album",
                artistIDs: [albumArtistID]
            ))),
            .upsert(.track(Track(
                id: trackID,
                title: "Track",
                albumID: albumID,
                artistIDs: [trackArtistID]
            )))
        ]
    ))

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "clear-album-artist-update",
        mutations: [
            .upsert(.album(Album(
                id: albumID,
                title: "Album",
                artistIDs: [],
                trackCount: 1
            )))
        ]
    ))

    #expect(try await library.album(id: albumID)?.artistIDs.isEmpty == true)
    #expect(try await library.release(id: releaseID)?.artistIDs.isEmpty == true)
    #expect(try await library.artist(id: albumArtistID) == nil)
    #expect(try await library.artist(id: trackArtistID)?.name == "Track Artist")
    await store.close()
}

@Test("removing the last graph-only variant prunes its release, disc, and box set")
func removingLastGraphOnlyVariantPrunesLocalStructure() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let albumID = AlbumID("graph-only-album")
    let releaseID = AlbumReleaseID(legacyAlbumID: albumID)
    let discID = DiscID(releaseID: releaseID, number: 1)
    let itemID = MediaItemID(sourceID: .local, externalID: "graph-only-variant")
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-graph-only")
    let logicalID = LogicalTrackID("local:graph-only-logical")
    let collectionID = LibraryCollectionID("graph-only-box-set")
    let artistID = ArtistID("graph-only-artist")
    let genreID = GenreID("graph-only-genre")
    let artworkID = ArtworkID("graph-only-artwork")
    let artwork = ArtworkReference(id: artworkID)
    let album = Album(
        id: albumID,
        title: "Graph Only Album",
        artistIDs: [artistID],
        artwork: artwork
    )
    let logical = LogicalTrack(
        id: logicalID,
        releaseID: releaseID,
        discID: discID,
        title: "Graph Only",
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 1,
        trackTotal: 1,
        discNumber: 1,
        discTotal: 1,
        duration: .seconds(10),
        artwork: artwork
    )
    let variant = TrackVariant(
        id: itemID,
        logicalTrackID: logicalID,
        assetID: assetID,
        selection: .wholeFile
    )
    let release = AlbumRelease(
        id: releaseID,
        legacyAlbumID: albumID,
        title: "Graph Only Album",
        artistIDs: [artistID],
        artwork: artwork
    )
    let disc = Disc(id: discID, releaseID: releaseID, number: 1, trackCount: 1)
    let collection = LibraryCollection(id: collectionID, kind: .boxSet, title: "Graph Only Box")
    let member = LibraryCollectionMember(collectionID: collectionID, releaseID: releaseID, position: 0)

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "graph-only-removal",
        mutations: [
            .upsert(.artist(Artist(id: artistID, name: "Graph Only Artist"))),
            .upsert(.genre(Genre(id: genreID, name: "Graph Only Genre"))),
            .upsert(.artwork(artwork)),
            .upsert(.album(album)),
            .upsert(.albumRelease(release)),
            .upsert(.disc(disc)),
            .upsert(.collection(collection)),
            .upsert(.collectionMember(member)),
            .upsert(.logicalTrack(logical)),
            .upsert(.mediaAsset(MediaAsset(
                id: assetID,
                contentRevision: assetID.externalID,
                fileName: "graph-only.flac"
            ))),
            .upsert(.trackVariant(variant)),
        ]
    ))

    try await library.remove([itemID])

    #expect(try await library.track(id: itemID) == nil)
    #expect(try await library.logicalTrack(id: logicalID) == nil)
    #expect(try await library.mediaAsset(id: assetID) == nil)
    #expect(try await library.album(id: albumID) == nil)
    #expect(try await library.artist(id: artistID) == nil)
    #expect(try await library.genre(id: genreID) == nil)
    #expect(try await library.artwork(id: artworkID) == nil)
    #expect(try await library.release(id: releaseID) == nil)
    #expect(try await library.discs(for: releaseID).isEmpty)
    #expect(try await library.collections().isEmpty)
    #expect(try await library.members(in: collectionID).isEmpty)
    await store.close()
}

@Test("graph-only shared assets remain until their last variant is removed")
func graphOnlySharedAssetReferenceCounting() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let assetID = MediaAssetID(sourceID: .local, externalID: "sha256-graph-shared")
    let firstID = MediaItemID(sourceID: .local, externalID: "graph-shared-first")
    let secondID = MediaItemID(sourceID: .local, externalID: "graph-shared-second")
    let firstLogicalID = LogicalTrackID("graph-shared-first-logical")
    let secondLogicalID = LogicalTrackID("graph-shared-second-logical")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "graph-shared-assets",
        mutations: [
            .upsert(.mediaAsset(MediaAsset(
                id: assetID,
                contentRevision: assetID.externalID,
                fileName: "shared.flac"
            ))),
            .upsert(.logicalTrack(LogicalTrack(id: firstLogicalID, title: "First"))),
            .upsert(.logicalTrack(LogicalTrack(id: secondLogicalID, title: "Second"))),
            .upsert(.trackVariant(TrackVariant(
                id: firstID,
                logicalTrackID: firstLogicalID,
                assetID: assetID
            ))),
            .upsert(.trackVariant(TrackVariant(
                id: secondID,
                logicalTrackID: secondLogicalID,
                assetID: assetID
            )))
        ]
    ))

    #expect(try await library.isMediaAssetReferenced(assetID, excluding: [firstID]))
    #expect(!(try await library.isMediaAssetReferenced(assetID, excluding: [firstID, secondID])))
    try await library.remove([firstID])
    #expect(try await library.mediaAsset(id: assetID) != nil)
    #expect(try await library.trackVariant(id: firstID) == nil)

    try await library.remove([secondID])
    #expect(try await library.mediaAsset(id: assetID) == nil)
    await store.close()
}

@Test("Removing a non-local variant also removes its graph records")
func removingNonLocalVariantPrunesItsMediaGraph() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let sourceID = MediaSourceID("remote-test")
    let itemID = MediaItemID(sourceID: sourceID, externalID: "remote-variant")
    let assetID = MediaAssetID(sourceID: sourceID, externalID: "remote-asset")
    let logicalID = LogicalTrackID("remote-logical-track")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "remove-remote-variant",
        mutations: [
            .upsert(.logicalTrack(LogicalTrack(id: logicalID, title: "Remote Track"))),
            .upsert(.mediaAsset(MediaAsset(id: assetID, fileName: "remote.m4a"))),
            .upsert(.trackVariant(TrackVariant(
                id: itemID,
                logicalTrackID: logicalID,
                assetID: assetID
            )))
        ]
    ))

    #expect(try await library.trackVariant(id: itemID) != nil)
    #expect(try await library.logicalTrack(id: logicalID) != nil)
    #expect(try await library.mediaAsset(id: assetID) != nil)

    try await library.remove([itemID])

    #expect(try await library.trackVariant(id: itemID) == nil)
    #expect(try await library.logicalTrack(id: logicalID) == nil)
    #expect(try await library.mediaAsset(id: assetID) == nil)
    await store.close()
}

@Test("replacing a graph-only variant prunes its old release member and group")
func replacingGraphOnlyVariantPrunesOldCollectionReferences() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "graph-replacement-variant")
    let oldAssetID = MediaAssetID(sourceID: .local, externalID: "sha256-graph-replacement-old")
    let newAssetID = MediaAssetID(sourceID: .local, externalID: "sha256-graph-replacement-new")
    let oldLogicalID = LogicalTrackID("graph-replacement-old-logical")
    let newLogicalID = LogicalTrackID("graph-replacement-new-logical")
    let oldReleaseID = AlbumReleaseID("graph-replacement-old-release")
    let newReleaseID = AlbumReleaseID("graph-replacement-new-release")
    let oldDiscID = DiscID(releaseID: oldReleaseID, number: 1)
    let newDiscID = DiscID(releaseID: newReleaseID, number: 1)
    let oldGroupID = AlbumGroupID("graph-replacement-old-group")
    let collectionID = LibraryCollectionID("graph-replacement-box-set")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "graph-replacement-initial",
        mutations: [
            .upsert(.albumGroup(AlbumGroup(id: oldGroupID, title: "Old Group"))),
            .upsert(.albumRelease(AlbumRelease(
                id: oldReleaseID,
                groupID: oldGroupID,
                title: "Old Release"
            ))),
            .upsert(.disc(Disc(id: oldDiscID, releaseID: oldReleaseID, number: 1))),
            .upsert(.collection(LibraryCollection(
                id: collectionID,
                kind: .boxSet,
                title: "Old Box Set"
            ))),
            .upsert(.collectionMember(LibraryCollectionMember(
                collectionID: collectionID,
                releaseID: oldReleaseID,
                position: 0
            ))),
            .upsert(.logicalTrack(LogicalTrack(
                id: oldLogicalID,
                releaseID: oldReleaseID,
                discID: oldDiscID,
                title: "Old Track"
            ))),
            .upsert(.mediaAsset(MediaAsset(
                id: oldAssetID,
                contentRevision: oldAssetID.externalID,
                fileName: "old.flac"
            ))),
            .upsert(.trackVariant(TrackVariant(
                id: itemID,
                logicalTrackID: oldLogicalID,
                assetID: oldAssetID
            )))
        ]
    ))

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "graph-replacement-update",
        mutations: [
            .upsert(.albumRelease(AlbumRelease(id: newReleaseID, title: "New Release"))),
            .upsert(.disc(Disc(id: newDiscID, releaseID: newReleaseID, number: 1))),
            .upsert(.logicalTrack(LogicalTrack(
                id: newLogicalID,
                releaseID: newReleaseID,
                discID: newDiscID,
                title: "New Track"
            ))),
            .upsert(.mediaAsset(MediaAsset(
                id: newAssetID,
                contentRevision: newAssetID.externalID,
                fileName: "new.flac"
            ))),
            .upsert(.trackVariant(TrackVariant(
                id: itemID,
                logicalTrackID: newLogicalID,
                assetID: newAssetID
            )))
        ]
    ))

    #expect(try await library.logicalTrack(id: oldLogicalID) == nil)
    #expect(try await library.mediaAsset(id: oldAssetID) == nil)
    #expect(try await library.release(id: oldReleaseID) == nil)
    #expect(try await library.discs(for: oldReleaseID).isEmpty)
    #expect(try await library.members(in: collectionID).isEmpty)
    #expect(try await library.collections().isEmpty)
    #expect(try await library.release(id: newReleaseID) != nil)
    #expect(try await library.logicalTrack(id: newLogicalID) != nil)
    #expect(try await library.mediaAsset(id: newAssetID) != nil)
    await store.close()
}

@Test("version one store migrates and deterministically backfills local graph records")
func versionOneStoreMigratesAndBackfillsLocalGraph() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("legacy-v1.store")
    try makeVersionOneStore(at: storeURL)

    let store = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "legacy-v1-track")
    let track = try #require(try await library.track(id: itemID))

    #expect(track.title == "Legacy V1")
    #expect(track.logicalTrackID == LogicalTrackID(legacyVariantID: itemID))
    #expect(track.assetID == MediaAssetID(legacyVariantID: itemID))
    #expect(try await library.logicalTrack(id: track.logicalTrackID) == track.logicalTrackProjection)
    #expect(try await library.trackVariant(id: itemID) == track.trackVariantProjection)
    #expect(try await library.mediaAsset(id: track.assetID) == track.mediaAssetProjection)

    // Once the v1 -> v2 graph backfill succeeds, later graph-only user state
    // must survive a full store reopen. Re-running the legacy backfill here
    // would overwrite this value from the unchanged v1 TrackRecord.
    let migratedLogical = track.logicalTrackProjection
    let editedLogical = LogicalTrack(
        id: migratedLogical.id,
        releaseID: migratedLogical.releaseID,
        discID: migratedLogical.discID,
        title: "Edited After Migration",
        artistIDs: migratedLogical.artistIDs,
        genreIDs: migratedLogical.genreIDs,
        trackNumber: migratedLogical.trackNumber,
        trackTotal: migratedLogical.trackTotal,
        discNumber: migratedLogical.discNumber,
        discTotal: migratedLogical.discTotal,
        duration: migratedLogical.duration,
        artwork: migratedLogical.artwork,
        isFavorite: true,
        statistics: migratedLogical.statistics
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "edit-logical-track-after-v1-backfill",
        mutations: [.upsert(.logicalTrack(editedLogical))]
    ))
    await store.close()

    let reopened = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let reopenedLibrary = SwiftDataLibraryRepository(store: reopened)
    #expect(try await reopenedLibrary.trackVariant(id: itemID) == track.trackVariantProjection)
    #expect(try await reopenedLibrary.logicalTrack(id: track.logicalTrackID) == editedLogical)
    await reopened.close()
}

@Test("markerless v2 backfill preserves existing graph user state")
func markerlessV2BackfillPreservesExistingGraphState() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("markerless-v2.store")

    let schema = Schema(versionedSchema: MusicFreeSchema.self)
    let configuration = ModelConfiguration(
        "MusicFreeLibrary",
        schema: schema,
        url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "markerless-v2-track"),
        title: "Legacy Projection",
        fileName: "markerless.flac"
    )
    let editedLogical = LogicalTrack(
        id: track.logicalTrackID,
        title: "User Graph Edit"
    )

    context.insert(try LibraryRecordMapper.makeTrack(track))
    context.insert(try LocalMediaGraphRecordMapper.makeLogicalTrack(editedLogical))
    context.insert(try LocalMediaGraphRecordMapper.makeAsset(track.mediaAssetProjection))
    context.insert(try LocalMediaGraphRecordMapper.makeVariant(track.trackVariantProjection))
    context.insert(StoreMetadataRecord(
        storageKey: "state",
        revision: 1,
        appliedTransactionKeys: try PersistenceCodec.encode(Set<String>())
    ))
    try context.save()

    let store = try LibraryPersistenceStore(
        configuration: try LibraryPersistenceConfiguration(storeURL: storeURL)
    )
    let library = SwiftDataLibraryRepository(store: store)

    // Opening a pre-marker v2 store still runs the compatibility backfill,
    // but it must not copy the stale legacy title over the graph edit.
    #expect(try await library.logicalTrack(id: track.logicalTrackID) == editedLogical)
    #expect(try await library.trackVariant(id: track.id) == track.trackVariantProjection)
    await store.close()
}

@Test("artwork reference checks include tracks, collections, and playlists")
func artworkReferenceChecksIncludeAllLibraryOwners() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let playlistRepository = SwiftDataPlaylistRepository(store: store)
    let trackArtworkID = ArtworkID("artwork-track-owner")
    let albumArtworkID = ArtworkID("artwork-album-owner")
    let artistArtworkID = ArtworkID("artwork-artist-owner")
    let playlistArtworkID = ArtworkID("artwork-playlist-owner")
    let orphanArtworkID = ArtworkID("artwork-no-owner")
    let playlistArtworkOwnerID = MediaItemID(
        sourceID: .local,
        externalID: "playlist-artwork-owner"
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "artwork-owner-references",
        mutations: [
            .upsert(.artwork(ArtworkReference(id: trackArtworkID))),
            .upsert(.artwork(ArtworkReference(id: albumArtworkID))),
            .upsert(.artwork(ArtworkReference(id: artistArtworkID))),
            .upsert(.artwork(ArtworkReference(id: playlistArtworkID))),
            .upsert(.artwork(ArtworkReference(id: orphanArtworkID))),
            .upsert(.album(Album(
                id: AlbumID("artwork-owner-album"),
                title: "Album",
                artwork: ArtworkReference(id: albumArtworkID)
            ))),
            .upsert(.artist(Artist(
                id: ArtistID("artwork-owner-artist"),
                name: "Artist",
                artwork: ArtworkReference(id: artistArtworkID)
            ))),
            .upsert(.track(Track(
                id: MediaItemID(sourceID: .local, externalID: "artwork-owner-track"),
                title: "Track",
                albumID: AlbumID("artwork-owner-album"),
                artistIDs: [ArtistID("artwork-owner-artist")],
                artwork: ArtworkReference(id: trackArtworkID)
            ))),
            // Keep the playlist artwork record alive until the playlist is
            // created; the transaction prunes unreferenced artwork records.
            .upsert(.track(Track(
                id: playlistArtworkOwnerID,
                title: "Playlist artwork owner",
                artwork: ArtworkReference(id: playlistArtworkID)
            )))
        ]
    ))
    _ = try await playlistRepository.create(PlaylistDraft(
        name: "Playlist",
        artworkID: playlistArtworkID
    ))
    try await library.remove([playlistArtworkOwnerID])

    #expect(try await library.isArtworkReferenced(trackArtworkID))
    #expect(try await library.isArtworkReferenced(albumArtworkID))
    #expect(try await library.isArtworkReferenced(artistArtworkID))
    #expect(try await library.isArtworkReferenced(playlistArtworkID))
    #expect(!(try await library.isArtworkReferenced(orphanArtworkID)))
    await store.close()
}

@Test("library persistence round trips and paginates with stable ordering")
func libraryPersistenceRoundTripAndPagination() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("library.store")
    let configuration = try LibraryPersistenceConfiguration(storeURL: storeURL)

    let firstStore = try LibraryPersistenceStore(configuration: configuration)
    let schemaVersion = await firstStore.schemaVersion
    #expect(schemaVersion == 2)
    let firstLibrary = SwiftDataLibraryRepository(store: firstStore)
    let values = makeLibraryValues()
    try await firstLibrary.apply(try LibraryTransaction(
        idempotencyKey: "initial-library",
        mutations: values.mutations
    ))
    await firstStore.close()

    let reopenedStore = try LibraryPersistenceStore(configuration: configuration)
    let library = SwiftDataLibraryRepository(store: reopenedStore)
    let firstPage = try await library.tracks(
        matching: TrackQuery(),
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(firstPage.elements.map(\.title) == ["Alpha", "Beta"])
    #expect(firstPage.hasNextPage)

    guard let nextPage = try firstPage.nextPage(limit: 2) else {
        Issue.record("The first page should provide a continuation")
        return
    }
    let secondPage = try await library.tracks(
        matching: TrackQuery(),
        page: nextPage
    )
    #expect(secondPage.elements.map(\.title) == ["Gamma"])
    #expect(!secondPage.hasNextPage)
    let persistedTrack = try await library.track(id: values.tracks[0].id)
    #expect(persistedTrack == values.tracks[0])
    #expect(try await library.album(id: AlbumID("album-1"))?.title == "Album")
    #expect(try await library.artist(id: ArtistID("artist-1"))?.name == "Artist")
    await reopenedStore.close()
}

@Test("library-wide search uses one bounded relationship-aware snapshot")
func libraryWideSearchUsesOneBoundedSnapshot() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let album = Album(
        id: AlbumID("search-album"),
        title: "Needle Album"
    )
    let artist = Artist(
        id: ArtistID("search-artist"),
        name: "Needle Artist"
    )
    let genre = Genre(
        id: GenreID("search-genre"),
        name: "Needle Genre"
    )
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "search-album-relation"),
            title: "Album relation",
            albumID: album.id
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "search-artist-relation"),
            title: "Artist relation",
            artistIDs: [artist.id]
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "search-genre-relation"),
            title: "Genre relation",
            genreIDs: [genre.id]
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "search-title"),
            title: "Needle title"
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "search-over-limit"),
            title: "Needle zzz"
        ),
    ]
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "library-wide-search",
        mutations: [
            .upsert(.album(album)),
            .upsert(.artist(artist)),
            .upsert(.genre(genre)),
        ] + tracks.map { .upsert(.track($0)) }
    ))

    let results = try await library.searchLibrary(try LibrarySearchRequest(
        searchText: "needle",
        sourceID: .local,
        limit: 4
    ))

    #expect(results.tracks.map(\.title) == [
        "Album relation",
        "Artist relation",
        "Genre relation",
        "Needle title",
    ])
    #expect(results.albums.map(\.title) == ["Needle Album"])
    #expect(results.artists.map(\.name) == ["Needle Artist"])
    #expect(await store.searchSnapshotBuildCount() == 1)
    await store.close()
}

@Test("relation mutations preserve track numbering and metadata overrides")
func relationMutationsPreserveTrackMetadata() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "relation-metadata-track")
    let albumID = AlbumID("relation-metadata-album")
    let artistID = ArtistID("relation-metadata-artist")
    let genreID = GenreID("relation-metadata-genre")
    let artworkID = ArtworkID("relation-metadata-artwork")
    let track = Track(
        id: itemID,
        title: "Relation Metadata",
        trackNumber: 7,
        discNumber: 3,
        fileName: "relation.mp3",
        technicalInfo: nil,
        year: 2024,
        comment: "kept",
        lyrics: TrackLyrics(rawText: "line"),
        artwork: ArtworkReference(id: artworkID)
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "relation-metadata",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album"))),
            .upsert(.artist(Artist(id: artistID, name: "Artist"))),
            .upsert(.genre(Genre(id: genreID, name: "Genre"))),
            .upsert(.artwork(ArtworkReference(id: artworkID))),
            .upsert(.track(track)),
            .relation(.setAlbum(trackID: itemID, albumID: albumID)),
            .relation(.setArtists(trackID: itemID, artistIDs: [artistID])),
            .relation(.setGenres(trackID: itemID, genreIDs: [genreID])),
            .relation(.setArtwork(trackID: itemID, artworkID: artworkID)),
        ]
    ))

    #expect(try await library.track(id: itemID) == Track(
        id: itemID,
        title: "Relation Metadata",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 7,
        discNumber: 3,
        fileName: "relation.mp3",
        year: 2024,
        comment: "kept",
        lyrics: TrackLyrics(rawText: "line"),
        artwork: ArtworkReference(id: artworkID)
    ))
    await store.close()
}

@Test("source-aware artist browsing includes album artists")
func sourceAwareArtistBrowsingIncludesAlbumArtists() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "album-artist-source")
    let albumID = AlbumID("album-artist-source-album")
    let trackArtistID = ArtistID("album-artist-source-track-artist")
    let albumArtistID = ArtistID("album-artist-source-album-artist")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "album-artist-source",
        mutations: [
            .upsert(.album(Album(
                id: albumID,
                title: "Album",
                artistIDs: [albumArtistID]
            ))),
            .upsert(.artist(Artist(id: trackArtistID, name: "Track Artist"))),
            .upsert(.artist(Artist(id: albumArtistID, name: "Album Artist"))),
            .upsert(.track(Track(
                id: itemID,
                title: "Track",
                albumID: albumID,
                artistIDs: [trackArtistID]
            )))
        ]
    ))

    let localArtists = try await library.artists(
        matching: ArtistQuery(sourceID: .local),
        page: try LibraryPageRequest(limit: 10)
    )
    let remoteArtists = try await library.artists(
        matching: ArtistQuery(sourceID: MediaSourceID(rawValue: "remote")),
        page: try LibraryPageRequest(limit: 10)
    )

    #expect(Set(localArtists.elements.map(\.id)) == Set([trackArtistID, albumArtistID]))
    #expect(remoteArtists.elements.isEmpty)
    await store.close()
}

@Test("album reassignment hides the orphaned legacy album")
func albumReassignmentHidesOrphanedLegacyAlbum() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "compilation-track")
    let legacyAlbumID = AlbumID("legacy-artist-scoped-album")
    let compilationAlbumID = AlbumID("merged-compilation-album")

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "install-legacy-compilation-album",
        mutations: [
            .upsert(.album(Album(id: legacyAlbumID, title: "Shared Compilation"))),
            .upsert(.track(Track(
                id: itemID,
                title: "Track",
                albumID: legacyAlbumID
            ))),
        ]
    ))
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "merge-compilation-album",
        mutations: [
            .upsert(.album(Album(
                id: compilationAlbumID,
                title: "Shared Compilation",
                trackCount: 1,
                albumType: .compilation
            ))),
            .upsert(.track(Track(
                id: itemID,
                title: "Track",
                albumID: compilationAlbumID
            ))),
        ]
    ))

    let albums = try await library.albums(
        matching: AlbumQuery(sourceID: .local),
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(albums.elements.map(\.id) == [compilationAlbumID])
    #expect(try await library.album(id: legacyAlbumID) == nil)
    await store.close()
}

@Test("metadata replacement removes no-longer-referenced records atomically")
func metadataReplacementPrunesOrphanedRecords() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-prune-update")
    let albumID = AlbumID("metadata-prune-album")
    let artistID = ArtistID("metadata-prune-artist")
    let genreID = GenreID("metadata-prune-genre")
    let artworkID = ArtworkID("metadata-prune-artwork")
    let initialTrack = Track(
        id: itemID,
        title: "Initial",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        artwork: ArtworkReference(id: artworkID)
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-initial",
        mutations: [
            .upsert(.album(Album(id: albumID, title: "Album", artistIDs: [artistID]))),
            .upsert(.artist(Artist(id: artistID, name: "Artist"))),
            .upsert(.genre(Genre(id: genreID, name: "Genre"))),
            .upsert(.artwork(ArtworkReference(id: artworkID))),
            .upsert(.track(initialTrack)),
        ]
    ))

    let changes = library.changes()
    var iterator = changes.makeAsyncIterator()
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-update",
        mutations: [.upsert(.track(Track(id: itemID, title: "Updated")))]
    ))

    #expect(try await library.album(id: albumID) == nil)
    #expect(try await library.artist(id: artistID) == nil)
    #expect(try await library.genres(
        matching: GenreQuery(),
        page: try LibraryPageRequest(limit: 10)
    ).elements.isEmpty)
    do {
        _ = try await SwiftDataPlaylistRepository(store: store).create(
            PlaylistDraft(name: "Artwork probe", artworkID: artworkID)
        )
        Issue.record("An unreferenced artwork record must be removed")
    } catch let error as LibraryError {
        #expect(error == .constraint(.danglingReference))
    }

    let change = try #require(await iterator.next())
    #expect(change.categories.contains(.deletions))
    #expect(change.affectedIDs.albumIDs == [albumID])
    #expect(change.affectedIDs.artistIDs == [artistID])
    #expect(change.affectedIDs.genreIDs == [genreID])
    #expect(change.affectedIDs.artworkIDs == [artworkID])
    await store.close()
}

@Test("removing the last track prunes its metadata records")
func removeLastTrackPrunesMetadataRecords() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let values = makeLibraryValues()
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "metadata-prune-remove-initial",
        mutations: values.mutations
    ))

    try await library.remove(Set(values.tracks.map(\.id)))

    #expect(try await library.album(id: AlbumID("album-1")) == nil)
    #expect(try await library.artist(id: ArtistID("artist-1")) == nil)
    #expect(try await library.genres(
        matching: GenreQuery(),
        page: try LibraryPageRequest(limit: 10)
    ).elements.isEmpty)
    await store.close()
}

@Test("playlist metadata and ordered entries survive store recreation")
func playlistPersistenceSurvivesStoreRecreation() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    )
    let values = makeLibraryValues()
    let expectedOrder = [values.tracks[2].id, values.tracks[0].id, values.tracks[1].id]

    let firstStore = try LibraryPersistenceStore(configuration: configuration)
    let firstLibrary = SwiftDataLibraryRepository(store: firstStore)
    let firstPlaylists = SwiftDataPlaylistRepository(store: firstStore)
    try await firstLibrary.apply(try LibraryTransaction(
        idempotencyKey: "playlist-reopen-library",
        mutations: values.mutations
    ))
    let removablePlaylist = try await firstPlaylists.create(PlaylistDraft(name: "Temporary"))
    let createdPlaylist = try await firstPlaylists.create(PlaylistDraft(name: "Road Trip"))
    let revisionBeforeRename = try await firstStore.currentRevision()
    let renamedPlaylist = try await firstPlaylists.update(PlaylistMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeRename,
        change: .rename("Road Trip Favorites")
    ))
    let revisionBeforeInsert = try await firstStore.currentRevision()
    try await firstPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeInsert,
        operation: .insert(expectedOrder.enumerated().map {
            PlaylistEntryInsertion(itemID: $0.element, position: $0.offset)
        })
    ))
    let persistedRevision = try await firstStore.currentRevision()
    await firstStore.close()

    let secondStore = try LibraryPersistenceStore(configuration: configuration)
    let secondPlaylists = SwiftDataPlaylistRepository(store: secondStore)
    #expect(try await secondStore.currentRevision() == persistedRevision)
    let restoredPage = try await secondPlaylists.playlists(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(restoredPage.elements.contains(renamedPlaylist))
    #expect(restoredPage.elements.contains(removablePlaylist))
    #expect(
        try await secondPlaylists.entries(in: createdPlaylist.id).map(\.trackID)
            == expectedOrder
    )

    do {
        _ = try await secondPlaylists.update(PlaylistMutation(
            playlistID: createdPlaylist.id,
            expectedRevision: .initial,
            change: .rename("Stale Rename")
        ))
        Issue.record("A stale playlist mutation must remain stale after reopening the store")
    } catch let error as LibraryError {
        #expect(error == .conflict(.revisionMismatch(
            expected: .initial,
            actual: persistedRevision
        )))
    }

    let reordered = [expectedOrder[1], expectedOrder[2], expectedOrder[0]]
    try await secondPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: persistedRevision,
        operation: .reorder(reordered)
    ))
    let revisionBeforeRemove = try await secondStore.currentRevision()
    try await secondPlaylists.apply(PlaylistEntriesMutation(
        playlistID: createdPlaylist.id,
        expectedRevision: revisionBeforeRemove,
        operation: .remove([reordered[1]])
    ))
    try await secondPlaylists.delete(removablePlaylist.id)
    let finalRevision = try await secondStore.currentRevision()
    await secondStore.close()

    let thirdStore = try LibraryPersistenceStore(configuration: configuration)
    let thirdPlaylists = SwiftDataPlaylistRepository(store: thirdStore)
    #expect(try await thirdStore.currentRevision() == finalRevision)
    #expect(
        try await thirdPlaylists.entries(in: createdPlaylist.id).map(\.trackID)
            == [reordered[0], reordered[2]]
    )
    let finalPage = try await thirdPlaylists.playlists(
        page: try LibraryPageRequest(limit: 10)
    )
    #expect(finalPage.elements == [renamedPlaylist])
    await thirdStore.close()
}

@Test("library transactions validate before save and enforce idempotency")
func libraryTransactionErrorsAndRollback() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LibraryPersistenceStore(configuration: try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    ))
    let library = SwiftDataLibraryRepository(store: store)

    let missingAlbumTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "missing-album-track"),
        title: "Invalid",
        albumID: AlbumID("missing-album")
    )
    do {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "invalid-transaction",
            mutations: [.upsert(.track(missingAlbumTrack))]
        ))
        Issue.record("A dangling relation should reject the complete transaction")
    } catch let error as LibraryError {
        #expect(error == .constraint(.danglingReference))
    }
    let missingTrack = try await library.track(id: missingAlbumTrack.id)
    #expect(missingTrack == nil)

    let validTrack = Track(
        id: MediaItemID(sourceID: .local, externalID: "valid-track"),
        title: "Valid"
    )
    let transaction = try LibraryTransaction(
        idempotencyKey: "valid-transaction",
        expectedRevision: .initial,
        mutations: [.upsert(.track(validTrack))]
    )
    try await library.apply(transaction)

    do {
        try await library.apply(transaction)
        Issue.record("The same idempotency key should not be applied twice")
    } catch let error as LibraryError {
        #expect(error == .conflict(.transactionAlreadyApplied))
    }

    do {
        try await library.apply(try LibraryTransaction(
            idempotencyKey: "stale-transaction",
            expectedRevision: .initial,
            mutations: [.upsert(.track(Track(
                id: MediaItemID(sourceID: .local, externalID: "stale-track"),
                title: "Stale"
            )))]
        ))
        Issue.record("An old revision should reject the transaction")
    } catch let error as LibraryError {
        #expect(error == .conflict(.revisionMismatch(expected: .initial, actual: LibraryRevision(1))))
    }

    let enrichedTrack = Track(
        id: validTrack.id,
        title: "Enriched",
        fileName: "enriched.flac",
        folderPath: "Albums/Live",
        technicalInfo: MediaTechnicalInfo(fileSizeBytes: 1234),
        year: 2024,
        comment: "Comment",
        lyrics: TrackLyrics(rawText: "[00:01.00]Line")
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "enriched-transaction",
        mutations: [.upsert(.track(enrichedTrack))]
    ))
    let restoredEnrichedTrack = try #require(await library.track(id: validTrack.id))
    #expect(restoredEnrichedTrack == enrichedTrack)
    await store.close()
}

@Test("library change streams register synchronously and buffer the next commit")
func libraryChangeStreamDoesNotMissImmediateCommit() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let stream = library.changes()
    #expect(store.changeSubscriberCount == 1)

    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "stream-track"),
        title: "Stream Track"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "stream-immediate-commit",
        mutations: [.upsert(.track(track))]
    ))

    var iterator = stream.makeAsyncIterator()
    let change = await iterator.next()
    #expect(change?.revision == LibraryRevision(1))
    #expect(change?.categories.contains(.tracks) == true)
    #expect(change?.affectedIDs.trackIDs == [track.id])

    await store.close()
    #expect(store.changeSubscriberCount == 0)
}

@Test("cancelling library change iteration removes the subscription")
func libraryChangeStreamCancellationUnregistersSynchronously() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let stream = library.changes()
    #expect(store.changeSubscriberCount == 1)

    let waiter = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
    await Task.yield()
    waiter.cancel()
    _ = await waiter.value

    #expect(store.changeSubscriberCount == 0)
    await store.close()
}

@Test("scalar-sort browsing fetches only one bounded SwiftData page")
func scalarSortBrowseUsesBoundedFetch() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let tracks = (0..<12).map { index in
        Track(
            id: MediaItemID(sourceID: .local, externalID: "bounded-\(index)"),
            title: "Bounded \(index)",
            sortTitle: "Bounded \(index)",
            isFavorite: index.isMultiple(of: 2)
        )
    }
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "bounded-track-page",
        mutations: tracks.map { .upsert(.track($0)) }
    ))

    let query = TrackQuery(
        sourceID: .local,
        sort: TrackSortDescriptor(key: .dateAdded)
    )
    let firstPage = try await library.tracks(
        matching: query,
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(firstPage.elements.count == 2)
    #expect(firstPage.hasNextPage)
    #expect(await store.lastBrowseRecordFetchCount() == 3)

    let pendingNextRequest = try firstPage.nextPage(limit: 2)
    let nextRequest = try #require(pendingNextRequest)
    let secondPage = try await library.tracks(matching: query, page: nextRequest)
    #expect(secondPage.elements.count == 2)
    #expect(await store.lastBrowseRecordFetchCount() == 3)

    let favoriteQuery = TrackQuery(
        sourceID: .local,
        favorite: .favorite,
        sort: TrackSortDescriptor(key: .dateAdded)
    )
    let favoritePage = try await library.tracks(
        matching: favoriteQuery,
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(favoritePage.elements.count == 2)
    #expect(favoritePage.hasNextPage)
    #expect(await store.lastBrowseRecordFetchCount() == 3)
    let favoriteNextPageRequest = try favoritePage.nextPage(limit: 2)
    let favoriteNextRequest = try #require(favoriteNextPageRequest)
    let favoriteSecondPage = try await library.tracks(
        matching: favoriteQuery,
        page: favoriteNextRequest
    )
    #expect(favoriteSecondPage.elements.count == 2)
    #expect(await store.lastBrowseRecordFetchCount() == 3)

    _ = try await library.tracks(
        matching: TrackQuery(),
        page: try LibraryPageRequest(limit: 2)
    )
    #expect(await store.lastBrowseRecordFetchCount() == nil)
    await store.close()
}

@Test("playlist history queue and deletion use one stable persistence boundary")
func playlistHistoryQueueAndDeletion() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try LibraryPersistenceStore(configuration: try LibraryPersistenceConfiguration(
        storeURL: directory.appendingPathComponent("library.store")
    ))
    let library = SwiftDataLibraryRepository(store: store)
    let playlists = SwiftDataPlaylistRepository(store: store)
    let history = SwiftDataPlaybackHistoryRepository(store: store)
    let queue = SwiftDataPlaybackQueueRepository(store: store)
    let values = makeLibraryValues()
    let track = values.tracks[0]
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "playlist-library",
        mutations: values.mutations
    ))

    let playlist = try await playlists.create(PlaylistDraft(name: "Favorites"))
    try await playlists.apply(PlaylistEntriesMutation(
        playlistID: playlist.id,
        operation: .insert([
            PlaylistEntryInsertion(itemID: track.id, position: 0)
        ])
    ))
    let playlistTrackIDs = try await playlists.entries(in: playlist.id).map(\.trackID)
    #expect(playlistTrackIDs == [track.id])

    let sessionID = UUID()
    let startedAt = Date(timeIntervalSince1970: 100)
    try await history.recordPlaybackStarted(PlaybackStart(
        sessionID: sessionID,
        itemID: track.id,
        startedAt: startedAt
    ))
    try await history.recordValidPlayback(ValidPlayback(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(30),
        playedDuration: .seconds(30)
    ))
    try await history.recordCompleted(PlaybackCompletion(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(31),
        reason: .ended
    ))
    let recent = try await history.recentHistory(page: try LibraryPageRequest(limit: 10))
    #expect(recent.elements.count == 1)
    #expect(recent.elements[0].totalPlayedDuration == .seconds(30))
    #expect(recent.elements[0].lastCompletionReason == .ended)

    let entry = PlaybackQueueEntry(id: UUID(), itemID: track.id)
    let snapshot = PlaybackQueueSnapshot(
        entries: [entry],
        currentEntryID: entry.id,
        resumePosition: .seconds(5)
    )
    try await queue.save(snapshot)
    let restoredQueue = try await queue.load()
    #expect(restoredQueue == snapshot)

    try await library.remove([track.id])
    let remainingPlaylistEntries = try await playlists.entries(in: playlist.id)
    #expect(remainingPlaylistEntries.isEmpty)
    let remainingHistory = try await history.recentHistory(page: try LibraryPageRequest(limit: 10))
    #expect(remainingHistory.elements.isEmpty)
    let clearedQueue = try await queue.load()
    #expect(clearedQueue == .empty)
    await store.close()
}

@Test("clearing persisted history keeps track statistics and publishes a history-only change")
func playbackHistoryClearKeepsStatistics() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let history = SwiftDataPlaybackHistoryRepository(store: store)
    let track = Track(
        id: MediaItemID(sourceID: .local, externalID: "history-clear"),
        title: "History Clear"
    )
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "history-clear-track",
        mutations: [.upsert(.track(track))]
    ))

    let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000501")!
    let startedAt = Date(timeIntervalSince1970: 100)
    try await history.recordPlaybackStarted(PlaybackStart(
        sessionID: sessionID,
        itemID: track.id,
        startedAt: startedAt
    ))
    try await history.recordValidPlayback(ValidPlayback(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(20),
        playedDuration: .seconds(20)
    ))
    try await history.recordCompleted(PlaybackCompletion(
        sessionID: sessionID,
        itemID: track.id,
        occurredAt: startedAt.addingTimeInterval(21),
        reason: .ended
    ))
    let statisticsBeforeClear = try #require(
        try await library.track(id: track.id)
    ).statistics

    let changes = library.changes()
    var iterator = changes.makeAsyncIterator()
    try await history.clearHistory()
    let clearChange = try #require(await iterator.next())

    #expect(clearChange.categories == [.playbackHistory])
    #expect(clearChange.affectedIDs.trackIDs == [track.id])
    #expect(
        try await history.recentHistory(page: try LibraryPageRequest(limit: 10)).elements.isEmpty
    )
    #expect(try await library.track(id: track.id)?.statistics == statisticsBeforeClear)

    await store.close()
}

private struct LibraryValues {
    let tracks: [Track]
    let mutations: [LibraryMutation]
}

private struct DatePayload: Codable, Equatable {
    let date: Date
}

private struct PersistedMojibakeFixture {
    let track: Track
    let album: Album
    let artist: Artist
    let genre: Genre
    let playlist: Playlist
    let logicalTrack: LogicalTrack
    let asset: MediaAsset
    let variant: TrackVariant
    let release: AlbumRelease
    let disc: Disc
    let collection: LibraryCollection
}

private func makePersistedMojibakeFixture(
    at storeURL: URL
) throws -> PersistedMojibakeFixture {
    let itemID = MediaItemID(sourceID: .local, externalID: "metadata-repair-track")
    let logicalTrackID = LogicalTrackID("metadata-repair-logical")
    let assetID = MediaAssetID(sourceID: .local, externalID: "metadata-repair-asset")
    let albumID = AlbumID("metadata-repair-album")
    let artistID = ArtistID("metadata-repair-artist")
    let genreID = GenreID("metadata-repair-genre")
    let playlistID = PlaylistID("metadata-repair-playlist")
    let groupID = AlbumGroupID("metadata-repair-group")
    let releaseID = AlbumReleaseID("metadata-repair-release")
    let discID = DiscID(releaseID: releaseID, number: 1)
    let collectionID = LibraryCollectionID("metadata-repair-collection")
    let lastPlayedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_200)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_300)
    let statistics = PlaybackStatistics(
        playCount: 9,
        completionCount: 4,
        skipCount: 1,
        lastPlayedAt: lastPlayedAt,
        lastCompletionReason: .ended,
        totalListeningDuration: .seconds(321)
    )
    let technicalInfo = MediaTechnicalInfo(
        container: "flac",
        codec: "flac",
        audioStreams: [AudioStreamInfo(
            indexHint: 0,
            title: "中文",
            isDefault: true,
            sampleRate: 44_100,
            bitDepth: 16,
            channels: 2,
            channelLayout: .stereo
        )],
        bitRate: 900_000,
        fileSizeBytes: 4_096
    )
    let album = Album(
        id: albumID,
        title: "离不开-陈百强 纪念歌集 80-93 D",
        sortTitle: "离不开",
        artistIDs: [artistID],
        releaseYear: 1993,
        trackCount: 1,
        albumType: .compilation
    )
    let track = Track(
        id: itemID,
        logicalTrackID: logicalTrackID,
        assetID: assetID,
        title: "几分钟的约会",
        sortTitle: "中文",
        albumID: albumID,
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 1,
        trackTotal: 1,
        discNumber: 1,
        discTotal: 1,
        fileName: "几分钟的约会.flac",
        folderPath: "离不开/陈百强",
        duration: .seconds(180),
        technicalInfo: technicalInfo,
        year: 1993,
        comment: "纪念歌集",
        lyrics: TrackLyrics(rawText: """
        [ar:陈百强]
        [offset:-250]
        [00:01.00]中文
        """),
        isFavorite: true,
        statistics: statistics
    )
    let artist = Artist(id: artistID, name: "陈百强", sortName: "陈百强")
    let genre = Genre(id: genreID, name: "中文", sortName: "中文")
    let playlist = Playlist(
        id: playlistID,
        name: "纪念歌集",
        sortName: "中文",
        createdAt: createdAt,
        updatedAt: updatedAt
    )
    let logicalTrack = LogicalTrack(
        id: logicalTrackID,
        releaseID: releaseID,
        discID: discID,
        title: "几分钟的约会",
        artistIDs: [artistID],
        genreIDs: [genreID],
        trackNumber: 1,
        trackTotal: 1,
        discNumber: 1,
        discTotal: 1,
        duration: .seconds(180),
        isFavorite: true,
        statistics: statistics
    )
    let asset = MediaAsset(
        id: assetID,
        contentRevision: "sha256-metadata-repair",
        fileName: "几分钟的约会.flac",
        folderPath: "离不开/陈百强",
        byteCount: 4_096,
        technicalInfo: technicalInfo
    )
    let variant = TrackVariant(
        id: itemID,
        logicalTrackID: logicalTrackID,
        assetID: assetID,
        sourceIdentityHint: "stable-source-identity",
        sourceMetadataRevision: "source-revision-1",
        sourceMetadata: TrackSourceMetadataSnapshot(track: track, album: album)
    )
    let group = AlbumGroup(id: groupID, title: "离不开", artistIDs: [artistID])
    let release = AlbumRelease(
        id: releaseID,
        legacyAlbumID: albumID,
        groupID: groupID,
        title: album.title,
        artistIDs: [artistID],
        releaseYear: 1993,
        editionTitle: "纪念歌集",
        albumType: .compilation
    )
    let disc = Disc(
        id: discID,
        releaseID: releaseID,
        number: 1,
        title: "中文",
        trackCount: 1
    )
    let collection = LibraryCollection(
        id: collectionID,
        kind: .boxSet,
        title: "离不开"
    )

    let replacements = [
        ("离不开-陈百强 纪念歌集 80-93 D", "Àë²»¿ª-³Â°ÙÇ¿ ¼ÍÄî¸è¼¯ 80-93 D"),
        ("几分钟的约会", "¼¸·ÖÖÓµÄÔ¼»á"),
        ("纪念歌集", "¼ÍÄî¸è¼¯"),
        ("离不开", "Àë²»¿ª"),
        ("陈百强", "³Â°ÙÇ¿"),
        ("中文", "ä¸­æ–‡"),
    ]
    let schema = Schema(versionedSchema: MusicFreeSchema.self)
    let configuration = ModelConfiguration("MusicFreeLibrary", schema: schema, url: storeURL)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)

    let trackRecord = try LibraryRecordMapper.makeTrack(
        track,
        dateAddedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    trackRecord.title = replacements[1].1
    trackRecord.sortTitle = replacements[5].1
    trackRecord.payload = replacingMetadataText(in: trackRecord.payload, replacements: replacements)

    let albumRecord = try LibraryRecordMapper.makeAlbum(album)
    albumRecord.title = replacements[0].1
    albumRecord.sortTitle = replacements[3].1
    albumRecord.payload = replacingMetadataText(in: albumRecord.payload, replacements: replacements)

    let artistRecord = try LibraryRecordMapper.makeArtist(artist)
    artistRecord.name = replacements[4].1
    artistRecord.sortName = replacements[4].1
    artistRecord.payload = replacingMetadataText(in: artistRecord.payload, replacements: replacements)

    let genreRecord = try LibraryRecordMapper.makeGenre(genre)
    genreRecord.name = replacements[5].1
    genreRecord.sortName = replacements[5].1
    genreRecord.payload = replacingMetadataText(in: genreRecord.payload, replacements: replacements)

    let playlistRecord = try LibraryRecordMapper.makePlaylist(playlist)
    playlistRecord.name = replacements[2].1
    playlistRecord.sortName = replacements[5].1
    playlistRecord.payload = replacingMetadataText(
        in: playlistRecord.payload,
        replacements: replacements
    )

    let logicalTrackRecord = try LocalMediaGraphRecordMapper.makeLogicalTrack(logicalTrack)
    logicalTrackRecord.payload = replacingMetadataText(
        in: logicalTrackRecord.payload,
        replacements: replacements
    )
    let assetRecord = try LocalMediaGraphRecordMapper.makeAsset(asset)
    assetRecord.payload = replacingMetadataText(in: assetRecord.payload, replacements: replacements)
    let variantRecord = try LocalMediaGraphRecordMapper.makeVariant(variant)
    variantRecord.payload = replacingMetadataText(
        in: variantRecord.payload,
        replacements: replacements
    )
    let groupRecord = try LocalMediaGraphRecordMapper.makeAlbumGroup(group)
    groupRecord.payload = replacingMetadataText(in: groupRecord.payload, replacements: replacements)
    let releaseRecord = try LocalMediaGraphRecordMapper.makeRelease(release)
    releaseRecord.payload = replacingMetadataText(
        in: releaseRecord.payload,
        replacements: replacements
    )
    let discRecord = try LocalMediaGraphRecordMapper.makeDisc(disc)
    discRecord.payload = replacingMetadataText(in: discRecord.payload, replacements: replacements)
    let collectionRecord = try LocalMediaGraphRecordMapper.makeCollection(collection)
    collectionRecord.payload = replacingMetadataText(
        in: collectionRecord.payload,
        replacements: replacements
    )

    context.insert(trackRecord)
    context.insert(albumRecord)
    context.insert(artistRecord)
    context.insert(genreRecord)
    context.insert(playlistRecord)
    context.insert(logicalTrackRecord)
    context.insert(assetRecord)
    context.insert(variantRecord)
    context.insert(groupRecord)
    context.insert(releaseRecord)
    context.insert(discRecord)
    context.insert(collectionRecord)
    context.insert(StoreMetadataRecord(
        storageKey: "state",
        revision: 7,
        appliedTransactionKeys: try PersistenceCodec.encode(
            Set(["__musicfree_internal_migration_local_media_graph_v2__"])
        )
    ))
    try context.save()

    return PersistedMojibakeFixture(
        track: track,
        album: album,
        artist: artist,
        genre: genre,
        playlist: playlist,
        logicalTrack: logicalTrack,
        asset: asset,
        variant: variant,
        release: release,
        disc: disc,
        collection: collection
    )
}

private func replacingMetadataText(
    in payload: Data,
    replacements: [(String, String)]
) -> Data {
    var text = String(decoding: payload, as: UTF8.self)
    for (decoded, mojibake) in replacements where text.contains(decoded) {
        text = text.replacingOccurrences(of: decoded, with: mojibake)
    }
    return Data(text.utf8)
}

private func makeLibraryValues() -> LibraryValues {
    let album = Album(id: AlbumID("album-1"), title: "Album")
    let artist = Artist(id: ArtistID("artist-1"), name: "Artist")
    let genre = Genre(id: GenreID("genre-1"), name: "Genre")
    let artwork = ArtworkReference(id: ArtworkID("artwork-1"))
    let tracks = [
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-1"),
            title: "Gamma",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-2"),
            title: "Alpha",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        ),
        Track(
            id: MediaItemID(sourceID: .local, externalID: "track-3"),
            title: "Beta",
            albumID: album.id,
            artistIDs: [artist.id],
            genreIDs: [genre.id],
            artwork: artwork
        )
    ]
    return LibraryValues(
        tracks: tracks,
        mutations: [
            .upsert(.album(album)),
            .upsert(.artist(artist)),
            .upsert(.genre(genre)),
            .upsert(.artwork(artwork)),
            .upsert(.track(tracks[0])),
            .upsert(.track(tracks[1])),
            .upsert(.track(tracks[2]))
        ]
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MusicFreeLibraryPersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeVersionOneStore(at storeURL: URL) throws {
    let schema = Schema(versionedSchema: MusicFreeSchemaV1.self)
    let configuration = ModelConfiguration(
        "MusicFreeLibrary",
        schema: schema,
        url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    let itemID = MediaItemID(sourceID: .local, externalID: "legacy-v1-track")
    let payload = #"{"id":{"sourceID":"local","externalID":"legacy-v1-track"},"title":"Legacy V1","fileName":"legacy.flac"}"#.data(using: .utf8)!
    context.insert(TrackRecord(
        storageKey: PersistenceKey.item(itemID),
        sourceID: itemID.sourceID.rawValue,
        externalID: itemID.externalID,
        title: "Legacy V1",
        sortTitle: nil,
        albumID: nil,
        artistIDs: try PersistenceCodec.encode([ArtistID]()),
        genreIDs: try PersistenceCodec.encode([GenreID]()),
        trackNumber: nil,
        discNumber: nil,
        artworkID: nil,
        isFavorite: false,
        playCount: 0,
        lastPlayedAt: nil,
        dateAddedAt: Date(timeIntervalSince1970: 1_700_000_000),
        payload: payload
    ))
    context.insert(StoreMetadataRecord(
        storageKey: "state",
        revision: 1,
        appliedTransactionKeys: try PersistenceCodec.encode(Set<String>())
    ))
    try context.save()
}

private func makeCurrentStoreWithLegacyCollectionMember(
    at storeURL: URL,
    member: LibraryCollectionMember
) throws {
    let schema = Schema(versionedSchema: MusicFreeSchema.self)
    let configuration = ModelConfiguration(
        "MusicFreeLibrary",
        schema: schema,
        url: storeURL
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)
    let record = try LocalMediaGraphRecordMapper.makeMember(member)
    record.storageKey = PersistenceKey.legacyCollectionMember(member)
    context.insert(record)
    try context.save()
}
