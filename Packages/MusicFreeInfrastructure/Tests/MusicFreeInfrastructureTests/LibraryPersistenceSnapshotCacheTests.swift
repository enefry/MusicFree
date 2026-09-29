import LibraryAPI
import MusicDomain
import Testing

@testable import LibraryPersistenceAdapter

@Test("successful applies retain current snapshots and other writes invalidate them")
func successfulAppliesRetainCurrentSnapshotsAndOtherWritesInvalidateThem() async throws {
    let store = try LibraryPersistenceStore(configuration: .inMemory)
    let library = SwiftDataLibraryRepository(store: store)
    let first = Track(
        id: MediaItemID(sourceID: .local, externalID: "snapshot-cache-first"),
        title: "First"
    )
    let second = Track(
        id: MediaItemID(sourceID: .local, externalID: "snapshot-cache-second"),
        title: "Second"
    )
    let third = Track(
        id: MediaItemID(sourceID: .local, externalID: "snapshot-cache-third"),
        title: "Third"
    )

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "snapshot-cache-first",
        mutations: [.upsert(.track(first))]
    ))
    let initialBuildCounts = await store.applySnapshotBuildCounts()
    #expect(initialBuildCounts.library == 1)
    #expect(initialBuildCounts.localMediaGraph == 1)

    try await library.apply(try LibraryTransaction(
        idempotencyKey: "snapshot-cache-second",
        mutations: [.upsert(.track(second))]
    ))
    let retainedBuildCounts = await store.applySnapshotBuildCounts()
    #expect(retainedBuildCounts.library == 1)
    #expect(retainedBuildCounts.localMediaGraph == 1)
    #expect(try await library.track(id: second.id) == second)
    #expect(try await library.logicalTrack(id: second.logicalTrackID) == second.logicalTrackProjection)
    #expect(try await library.mediaAsset(id: second.assetID) == second.mediaAssetProjection)
    #expect(try await library.trackVariant(id: second.id) == second.trackVariantProjection)

    try await library.remove([first.id])
    let removalBuildCounts = await store.applySnapshotBuildCounts()
    #expect(removalBuildCounts.library == 1)
    #expect(removalBuildCounts.localMediaGraph == 2)
    try await library.apply(try LibraryTransaction(
        idempotencyKey: "snapshot-cache-third",
        mutations: [.upsert(.track(third))]
    ))
    let rebuiltCounts = await store.applySnapshotBuildCounts()
    #expect(rebuiltCounts.library == 2)
    #expect(rebuiltCounts.localMediaGraph == 3)
    #expect(try await library.track(id: first.id) == nil)
    #expect(try await library.track(id: third.id) == third)
    #expect(try await library.logicalTrack(id: third.logicalTrackID) == third.logicalTrackProjection)

    await store.close()
}
