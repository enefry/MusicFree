import AppServices
import Foundation
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import PlaybackAPI
@testable import PlayerFeature
import SwiftUI
import Testing
import UIKit

@MainActor
private final class RecordingPlaybackServing: PlaybackServing {
  private(set) var snapshot: PlaybackSessionSnapshot
  private(set) var commands: [PlaybackSessionCommand] = []
  var failure: PlaybackError?

  private var continuation: AsyncStream<PlaybackSessionSnapshot>.Continuation?

  init(snapshot: PlaybackSessionSnapshot) {
    self.snapshot = snapshot
  }

  func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
    AsyncStream { continuation in
      self.continuation = continuation
      continuation.yield(self.snapshot)
    }
  }

  func send(_ command: PlaybackSessionCommand) async {
    commands.append(command)

    guard let failure else { return }
    let state = PlaybackState(
      phase: .failed,
      generation: snapshot.generation,
      itemID: snapshot.currentItemID,
      position: snapshot.position,
      duration: snapshot.state.duration,
      error: failure
    )
    publish(
      PlaybackSessionSnapshot(
        state: state,
        currentItem: snapshot.currentItem,
        queue: snapshot.queue,
        capabilities: snapshot.capabilities,
        effectiveEffects: snapshot.effectiveEffects,
        systemCapabilities: snapshot.systemCapabilities
      )
    )
  }

  func publish(_ nextSnapshot: PlaybackSessionSnapshot) {
    snapshot = nextSnapshot
    continuation?.yield(nextSnapshot)
  }
}

@MainActor
private func makePlayerSnapshot(
  phase: PlaybackPhase = .paused,
  generation: PlaybackGeneration = PlaybackGeneration(1),
  position: Duration = .seconds(10),
  capabilities: PlaybackCapabilities = [.seeking]
) -> PlaybackSessionSnapshot {
  let itemID = MediaItemID(sourceID: .local, externalID: "track-1")
  let entry = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    itemID: itemID
  )
  let display = PlaybackDisplaySnapshot(
    title: "Track",
    artist: "Artist",
    album: "Album",
    duration: .seconds(120)
  )
  let state = PlaybackState(
    phase: phase,
    generation: generation,
    itemID: itemID,
    position: position,
    duration: .seconds(120)
  )
  return PlaybackSessionSnapshot(
    state: state,
    currentItem: display,
    queue: PlaybackQueueSummary(entries: [entry], currentEntryID: entry.id),
    capabilities: capabilities
  )
}

@MainActor
@Test("Player events map to state and position snapshots")
func playerFeatureMapsPlaybackEvents() {
  let serving = RecordingPlaybackServing(snapshot: makePlayerSnapshot())
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)
  let itemID = viewModel.snapshot.currentItemID!
  let generation = viewModel.snapshot.generation

  #expect(
    viewModel.receive(
      .phaseChanged(generation: generation, itemID: itemID, phase: .playing)
    )
  )
  #expect(viewModel.snapshot.phase == .playing)

  #expect(
    viewModel.receive(
      .positionChanged(
        generation: generation,
        itemID: itemID,
        position: .seconds(42),
        duration: .seconds(120)
      )
    )
  )
  #expect(viewModel.snapshot.position == .seconds(42))
}

@MainActor
@Test("Older generations cannot roll back the visible session")
func playerFeatureFiltersStaleGenerations() {
  let serving = RecordingPlaybackServing(
    snapshot: makePlayerSnapshot(position: .seconds(30))
  )
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)
  let itemID = viewModel.snapshot.currentItemID!

  #expect(
    !viewModel.receive(
      .positionChanged(
        generation: PlaybackGeneration(0),
        itemID: itemID,
        position: .seconds(2),
        duration: .seconds(120)
      )
    )
  )
  #expect(viewModel.snapshot.position == .seconds(30))

  #expect(
    !viewModel.apply(
      makePlayerSnapshot(
        generation: PlaybackGeneration(0),
        position: .seconds(1)
      )
    )
  )
  #expect(viewModel.snapshot.position == .seconds(30))
}

@Test("Now Playing omits stale relationship labels after a Track is loaded")
func nowPlayingMetadataDoesNotUseStaleRelationshipFallback() {
  let track = Track(
    id: MediaItemID(sourceID: .local, externalID: "loaded-track"),
    title: "Loaded Track",
    albumID: AlbumID("loaded-album"),
    artistIDs: [ArtistID("loaded-artist")]
  )

  #expect(
    NowPlayingHeaderMetadata.artistSubtitle(
      for: track,
      artistNames: [:],
      fallback: "Old Artist"
    ) == nil
  )
  #expect(
    NowPlayingHeaderMetadata.albumSubtitle(
      for: track,
      albumNames: [:],
      fallback: "Old Album"
    ) == nil
  )
  #expect(
    NowPlayingHeaderMetadata.artistSubtitle(
      for: nil,
      artistNames: [:],
      fallback: "Snapshot Artist"
    ) == "Snapshot Artist"
  )
  #expect(
    NowPlayingHeaderMetadata.albumSubtitle(
      for: nil,
      albumNames: [:],
      fallback: "Snapshot Album"
    ) == "Snapshot Album"
  )
}

@MainActor
@Test("A seek drag emits one merged command at the final position")
func playerFeatureMergesSeekUpdates() async {
  let serving = RecordingPlaybackServing(snapshot: makePlayerSnapshot())
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)

  viewModel.beginSeeking()
  viewModel.updateSeeking(to: .seconds(20))
  viewModel.updateSeeking(to: .seconds(70))
  viewModel.finishSeeking()
  await viewModel.waitForPendingWork()

  #expect(serving.commands == [.seek(to: .seconds(70))])
}

@MainActor
@Test("Seeking is rejected before a disabled capability reaches the service")
func playerFeatureDisablesUnsupportedSeek() {
  let serving = RecordingPlaybackServing(
    snapshot: makePlayerSnapshot(capabilities: [])
  )
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)

  viewModel.beginSeeking()
  viewModel.updateSeeking(to: .seconds(60))
  viewModel.finishSeeking()

  #expect(viewModel.lastCommandError == .unsupportedCapability(.seeking))
  #expect(serving.commands.isEmpty)
}

@MainActor
@Test("A failed service command becomes a visible playback failure")
func playerFeatureMapsCommandFailure() async {
  let serving = RecordingPlaybackServing(snapshot: makePlayerSnapshot())
  serving.failure = .resourceUnavailable
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)

  viewModel.play()
  await viewModel.waitForPendingWork()

  #expect(viewModel.lastCommandError == .resourceUnavailable)
  #expect(viewModel.presentationState == .failed(.resourceUnavailable))
  #expect(serving.commands == [.play(itemID: viewModel.snapshot.currentItemID!)])
}

@MainActor
@Test("Player previous and next availability follows queue boundaries and repeat all")
func playerFeatureQueueBoundaryAvailability() {
  let first = PlayerViewModel(
    serving: RecordingPlaybackServing(snapshot: makeQueuePlayerSnapshot(currentIndex: 0)),
    autoStart: false
  )
  #expect(!first.canGoPrevious)
  #expect(first.canGoNext)

  let last = PlayerViewModel(
    serving: RecordingPlaybackServing(snapshot: makeQueuePlayerSnapshot(currentIndex: 3)),
    autoStart: false
  )
  #expect(last.canGoPrevious)
  #expect(!last.canGoNext)

  let repeatingFirst = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: makeQueuePlayerSnapshot(currentIndex: 0, repeatMode: .all)
    ),
    autoStart: false
  )
  let repeatingLast = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: makeQueuePlayerSnapshot(currentIndex: 3, repeatMode: .all)
    ),
    autoStart: false
  )
  #expect(repeatingFirst.canGoPrevious)
  #expect(repeatingLast.canGoNext)
}

@MainActor
@Test("MiniPlayer hides without an active single-track session")
func miniPlayerVisibilityFollowsPlaybackPhase() {
  for phase in [PlaybackPhase.preparing, .buffering, .playing, .paused] {
    let viewModel = PlayerViewModel(
      serving: RecordingPlaybackServing(snapshot: makePlayerSnapshot(phase: phase)),
      autoStart: false
    )
    #expect(viewModel.isMiniPlayerVisible)
  }

  for phase in [PlaybackPhase.idle, .stopped, .failed] {
    let viewModel = PlayerViewModel(
      serving: RecordingPlaybackServing(snapshot: makePlayerSnapshot(phase: phase)),
      autoStart: false
    )
    #expect(!viewModel.isMiniPlayerVisible)
  }

  let noCurrentItem = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: PlaybackSessionSnapshot(
        state: PlaybackState(
          phase: .paused,
          generation: PlaybackGeneration(1)
        ),
        currentItem: nil,
        queue: PlaybackQueueSummary()
      )
    ),
    autoStart: false
  )
  #expect(!noCurrentItem.isMiniPlayerVisible)

  let clearedQueueSnapshot = makePlayerSnapshot(phase: .paused)
  let clearedQueue = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: PlaybackSessionSnapshot(
        state: clearedQueueSnapshot.state,
        currentItem: clearedQueueSnapshot.currentItem,
        queue: PlaybackQueueSummary()
      )
    ),
    autoStart: false
  )
  #expect(!clearedQueue.isMiniPlayerVisible)
}

@Test("MiniPlayer horizontal swipes map to previous and next")
func miniPlayerSwipeMapsHorizontalDirection() {
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: -60, height: 8),
      predictedEndTranslation: CGSize(width: -90, height: 10),
      canGoPrevious: true,
      canGoNext: true
    ) == .next
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: 60, height: -8),
      predictedEndTranslation: CGSize(width: 90, height: -10),
      canGoPrevious: true,
      canGoNext: true
    ) == .previous
  )
}

@Test("MiniPlayer ignores vertical, short, and unavailable swipes")
func miniPlayerSwipeRejectsInvalidNavigation() {
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: -40, height: -70),
      predictedEndTranslation: CGSize(width: -90, height: -110),
      canGoPrevious: true,
      canGoNext: true
    ) == nil
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: 24, height: 3),
      predictedEndTranslation: CGSize(width: 36, height: 4),
      canGoPrevious: true,
      canGoNext: true
    ) == nil
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: -32, height: 2),
      predictedEndTranslation: CGSize(width: -140, height: 2),
      canGoPrevious: true,
      canGoNext: true
    ) == nil
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: 70, height: 3),
      predictedEndTranslation: CGSize(width: 90, height: 4),
      canGoPrevious: false,
      canGoNext: true
    ) == nil
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: -70, height: 3),
      predictedEndTranslation: CGSize(width: -90, height: 4),
      canGoPrevious: true,
      canGoNext: false
    ) == nil
  )
}

@Test("MiniPlayer drag preview follows the finger and can retract before commit")
func miniPlayerSwipePreviewCanRetract() {
  #expect(
    MiniPlayerSwipePolicy.displayOffset(
      for: CGSize(width: -36, height: 2),
      canGoPrevious: true,
      canGoNext: true
    ) == -36
  )
  #expect(
    MiniPlayerSwipePolicy.action(
      for: CGSize(width: -36, height: 2),
      predictedEndTranslation: CGSize(width: -36, height: 2),
      canGoPrevious: true,
      canGoNext: true
    ) == nil
  )
  #expect(
    MiniPlayerSwipePolicy.commitOffset(
      for: .next,
      pageWidth: 240
    ) == -240
  )
  #expect(
    MiniPlayerSwipePolicy.commitOffset(
      for: .previous,
      pageWidth: 240
    ) == 240
  )
}

@MainActor
@Test("MiniPlayer previews follow the playback queue order")
func miniPlayerAdjacentQueueEntriesFollowPlaybackOrder() {
  let viewModel = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: makeQueuePlayerSnapshot(currentIndex: 1)
    ),
    autoStart: false
  )

  #expect(viewModel.adjacentQueueEntry(direction: -1)?.itemID.externalID == "queue-0")
  #expect(viewModel.adjacentQueueEntry(direction: 1)?.itemID.externalID == "queue-2")

  let repeatingFirst = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: makeQueuePlayerSnapshot(currentIndex: 0, repeatMode: .all)
    ),
    autoStart: false
  )
  #expect(repeatingFirst.adjacentQueueEntry(direction: -1)?.itemID.externalID == "queue-3")
}

@Test("Now Playing pins its queue only above the regular-height boundary")
func nowPlayingVerticalLayoutUsesExplicitHeightBoundary() {
  let minimumHeight = NowPlayingVerticalLayoutPolicy.minimumPinnedHeight

  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: 667,
      verticalSizeClass: .regular,
      dynamicTypeSize: .large
    ) == .pinnedQueue
  )
  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: minimumHeight,
      verticalSizeClass: .regular,
      dynamicTypeSize: .large
    ) == .pinnedQueue
  )
  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: minimumHeight - 1,
      verticalSizeClass: .regular,
      dynamicTypeSize: .large
    ) == .scrolling
  )
}

@Test("Now Playing scrolls for compact height and accessibility Dynamic Type")
func nowPlayingVerticalLayoutHonorsEnvironmentConstraints() {
  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: 844,
      verticalSizeClass: .compact,
      dynamicTypeSize: .large
    ) == .scrolling
  )
  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: 844,
      verticalSizeClass: .regular,
      dynamicTypeSize: .accessibility1
    ) == .scrolling
  )
  #expect(
    NowPlayingVerticalLayoutPolicy.mode(
      availableHeight: 844,
      verticalSizeClass: .regular,
      dynamicTypeSize: .accessibility5
    ) == .scrolling
  )
}

@Test("Now Playing only presents a real artist subtitle")
func nowPlayingArtistSubtitleRequiresArtistMetadata() {
  #expect(NowPlayingHeaderMetadata.artistSubtitle("BVT Artist") == "BVT Artist")
  #expect(NowPlayingHeaderMetadata.artistSubtitle(nil) == nil)
  #expect(NowPlayingHeaderMetadata.artistSubtitle(" \n ") == nil)
}

@MainActor
@Test("Now Playing history loads artist metadata and clears without losing rows on failure")
func nowPlayingHistoryLoaderLoadAndClear() async {
  let artistID = ArtistID("history-artist")
  let track = Track(
    id: MediaItemID(sourceID: .local, externalID: "history-player-track"),
    title: "History Player Track",
    artistIDs: [artistID]
  )
  let item = makePlayerHistoryItem(
    sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
    track: track,
    completionReason: .ended
  )
  let service = PlayerHistoryLibrary(
    historyItems: [item],
    artists: [Artist(id: artistID, name: "History Artist")]
  )
  let loader = NowPlayingHistoryLoader(library: service)

  await loader.load()
  #expect(loader.state == .loaded)
  #expect(loader.items == [item])
  #expect(loader.artistNames[artistID] == "History Artist")

  service.clearError = LibraryTestFailure.unsupported
  await loader.clear()
  #expect(loader.items == [item])
  #expect(loader.failureMessage != nil)

  service.clearError = nil
  loader.dismissFailure()
  await loader.clear()
  #expect(loader.state == .empty)
  #expect(loader.items.isEmpty)
  #expect(service.clearCallCount == 2)
}

@Test("Now Playing history hides only the current unfinished session")
func nowPlayingHistoryFiltersCurrentUnfinishedSession() {
  let currentID = MediaItemID(sourceID: .local, externalID: "history-current")
  let otherID = MediaItemID(sourceID: .local, externalID: "history-other")
  let currentTrack = Track(id: currentID, title: "Current")
  let items = [
    makePlayerHistoryItem(sessionID: UUID(), track: currentTrack),
    makePlayerHistoryItem(
      sessionID: UUID(),
      track: currentTrack,
      completionReason: .ended
    ),
    makePlayerHistoryItem(
      sessionID: UUID(),
      track: Track(id: otherID, title: "Other")
    ),
  ]

  let visible = NowPlayingHistoryPresentation.visibleItems(
    from: items,
    currentItemID: currentID
  )

  #expect(visible.count == 2)
  #expect(visible.contains(where: {
    $0.track.id == currentID && $0.lastCompletionReason == .ended
  }))
  #expect(visible.contains(where: { $0.track.id == otherID }))
}

@MainActor
@Test("Now Playing history reloads after a playback history change")
func nowPlayingHistoryObservesLibraryChanges() async {
  let service = PlayerHistoryLibrary()
  let loader = NowPlayingHistoryLoader(library: service)
  let observation = Task { await loader.observeChanges() }
  await service.waitForChangeSubscriber()

  let item = makePlayerHistoryItem(
    sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000702")!,
    track: Track(
      id: MediaItemID(sourceID: .local, externalID: "history-observed"),
      title: "Observed"
    ),
    completionReason: .ended
  )
  service.historyItems = [item]
  service.publishHistoryChange()

  for _ in 0..<20 where loader.items != [item] {
    await Task.yield()
  }
  #expect(loader.items == [item])
  #expect(service.historyLoadCount == 1)

  observation.cancel()
  service.finishChanges()
  await observation.value
}

@MainActor
@Test("Player navigation and Continue Playing follow shuffled successor order")
func playerFeatureUsesShuffledSuccessors() {
  let order = [4, 1, 8, 0, 2, 3, 5, 6, 7]
  let viewModel = PlayerViewModel(
    serving: RecordingPlaybackServing(
      snapshot: makeQueuePlayerSnapshot(
        count: 9,
        currentIndex: 1,
        shuffleOrder: order
      )
    ),
    autoStart: false
  )

  #expect(viewModel.canGoPrevious)
  #expect(viewModel.canGoNext)
  #expect(
    viewModel.upcomingQueueEntries().map(\.itemID.externalID)
      == ["queue-8", "queue-0", "queue-2", "queue-3", "queue-5", "queue-6", "queue-7"]
  )
}

@MainActor
@Test("Rapid player commands remain independently in flight")
func playerFeaturePreservesRapidCommands() async {
  let serving = SuspendedPlaybackServing(snapshot: makeQueuePlayerSnapshot(currentIndex: 0))
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)

  viewModel.next()
  await serving.waitUntilFirstCommandStarts()
  viewModel.next()
  while serving.commands.count < 2 {
    await Task.yield()
  }
  serving.releaseFirstCommand()
  await viewModel.waitForPendingWork()

  #expect(serving.commands == [.next, .next])
}

@MainActor
@Test("Player favorite toggles serialize and preserve the last intent")
func playerFavoritePreservesRapidIntent() async {
  let itemID = MediaItemID(sourceID: .local, externalID: "favorite-current")
  let service = ControlledFavoriteLibrary(
    tracks: [Track(id: itemID, title: "Favorite Current")]
  )
  let controller = PlayerFavoriteController(library: service)
  controller.load(itemID: itemID)
  await controller.waitForPendingWork()

  controller.toggle()
  await service.waitUntilFirstMutationStarts()
  for _ in 0..<4 {
    controller.toggle()
  }
  service.releaseFirstMutation()
  await controller.waitForPendingWork()

  #expect(controller.isFavorite)
  #expect(service.favoriteWrites == [true, true])
  #expect(service.tracks[itemID]?.isFavorite == true)
}

@MainActor
@Test("An old player favorite completion cannot overwrite the newly loaded item")
func playerFavoriteIgnoresOldItemCompletion() async {
  let firstID = MediaItemID(sourceID: .local, externalID: "favorite-old")
  let secondID = MediaItemID(sourceID: .local, externalID: "favorite-new")
  let service = ControlledFavoriteLibrary(tracks: [
    Track(id: firstID, title: "Favorite Old"),
    Track(id: secondID, title: "Favorite New"),
  ])
  let controller = PlayerFavoriteController(library: service)
  controller.load(itemID: firstID)
  await controller.waitForPendingWork()

  controller.toggle()
  await service.waitUntilFirstMutationStarts()
  controller.load(itemID: secondID)
  service.releaseFirstMutation()
  await controller.waitForPendingWork()

  #expect(!controller.isFavorite)
  #expect(service.tracks[firstID]?.isFavorite == true)
  #expect(service.tracks[secondID]?.isFavorite == false)
}

@MainActor
@Test("A newer player artwork request wins over an older failure")
func playerArtworkLoaderIgnoresOlderFailure() async {
  let service = PlayerArtworkRaceService()
  let loader = ArtworkImageLoader()
  let oldRequest = Task {
    await loader.load(
      artworkID: ArtworkID("old"),
      sourceID: .local,
      serving: service
    )
  }

  await service.waitForOldRequest()
  await loader.load(
    artworkID: ArtworkID("new"),
    sourceID: .local,
    serving: service
  )
  await oldRequest.value

  #expect(loader.image != nil)
}

@Test("Player artwork decoding rejects streams larger than 20 MiB")
func playerArtworkDecodingRejectsOversizedStreams() async {
  let oversizedResource = ArtworkResource.inMemory(
    Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1)
  )

  await #expect(throws: ArtworkImageLoaderError.self) {
    _ = try await ArtworkImageDecoding.image(from: oversizedResource)
  }
}

@Test("Player artwork decoding rejects local files larger than 20 MiB")
func playerArtworkDecodingRejectsOversizedLocalFiles() async throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("MusicFree-player-artwork-\(UUID().uuidString).bin")
  #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
  defer { try? FileManager.default.removeItem(at: url) }
  let handle = try FileHandle(forWritingTo: url)
  try handle.truncate(atOffset: UInt64(20 * 1_024 * 1_024 + 1))
  try handle.close()

  await #expect(throws: ArtworkImageLoaderError.self) {
    _ = try await ArtworkImageDecoding.image(from: .localFile(url))
  }
}

@MainActor
@Test("Player artwork decoding downsamples images to a 2048 pixel longest edge")
func playerArtworkDecodingBoundsPixelDimensions() async throws {
  let decoded = try #require(
    try await ArtworkImageDecoding.image(from: .inMemory(wideArtworkData()))
  )
  let cgImage = try #require(decoded.cgImage)

  #expect(max(cgImage.width, cgImage.height) <= 2_048)
  #expect(cgImage.width == 2_048)
}

@MainActor
@Test("Cancelling after player artwork decode starts prevents publication")
func playerArtworkLoaderChecksCancellationAfterDecode() async throws {
  let service = PlayerArtworkRaceService()
  let decoder = PlayerControlledArtworkDecoder()
  let loader = ArtworkImageLoader { resource in
    await decoder.decode(resource)
  }
  let request = Task {
    await loader.load(
      artworkID: ArtworkID("new"),
      sourceID: .local,
      serving: service
    )
  }

  await decoder.waitForDecode()
  request.cancel()
  await decoder.complete(with: UIImage(data: testArtworkData()))
  await request.value

  #expect(loader.image == nil)
}

@MainActor
@Test("Selecting a queue entry starts playback through the service command")
func playerFeaturePlaysSelectedQueueEntry() async {
  let first = MediaItemID(sourceID: .local, externalID: "first")
  let second = MediaItemID(sourceID: .local, externalID: "second")
  let firstEntry = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
    itemID: first
  )
  let secondEntry = PlaybackQueueEntry(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
    itemID: second
  )
  let serving = RecordingPlaybackServing(
    snapshot: PlaybackSessionSnapshot(
      state: PlaybackState(
        phase: .paused,
        generation: PlaybackGeneration(1),
        itemID: first,
        duration: .seconds(120)
      ),
      currentItem: PlaybackDisplaySnapshot(title: "First", duration: .seconds(120)),
      queue: PlaybackQueueSummary(
        entries: [firstEntry, secondEntry],
        currentEntryID: firstEntry.id
      ),
      capabilities: [.seeking]
    )
  )
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)

  viewModel.selectQueueEntry(secondEntry.id)
  await viewModel.waitForPendingWork()

  #expect(serving.commands == [.play(itemID: second)])
}

@MainActor
@Test("Queue editor stages move and delete commands until completion")
func queueEditorStagesMoveAndDeleteCommands() {
  let queue = makeQueuePlayerSnapshot(currentIndex: 0).queue
  let ids = queue.entries.map(\.id)
  let editor = QueueEditor()

  editor.begin(queue: queue)
  #expect(editor.entries.map(\.id) == [ids[1], ids[2], ids[3]])

  editor.move(from: IndexSet(integer: 0), to: 3)
  editor.remove(at: IndexSet(integer: 0))

  #expect(editor.entries.map(\.id) == [ids[3], ids[1]])
  #expect(
    editor.plannedEdits == [
      .remove(ids[2]),
      .move(ids[3], to: 1),
    ]
  )

  editor.cancel()
  #expect(editor.phase == .inactive)
  #expect(editor.entries.isEmpty)
  #expect(editor.plannedEdits.isEmpty)
}

@MainActor
@Test("Queue editor ignores playback progress updates while editing")
func queueEditorIgnoresResumePositionChanges() {
  let queue = makeQueuePlayerSnapshot(currentIndex: 0).queue
  let editor = QueueEditor()
  editor.begin(queue: queue)

  let progressedQueue = PlaybackQueueSummary(
    entries: queue.entries,
    currentEntryID: queue.currentEntryID,
    repeatMode: queue.repeatMode,
    shuffleMode: queue.shuffleMode,
    shuffleSeed: queue.shuffleSeed,
    shuffleOrder: queue.shuffleOrder,
    resumePosition: .seconds(18)
  )
  editor.synchronize(with: progressedQueue)

  #expect(editor.phase == .editing)
  #expect(editor.failureMessage == nil)
  #expect(editor.entries.map(\.id) == queue.entries.dropFirst().map(\.id))
}

@MainActor
@Test("Queue editor preserves the active shuffled playback order")
func queueEditorPlansShuffledOrder() {
  let queue = makeQueuePlayerSnapshot(
    count: 5,
    currentIndex: 1,
    shuffleOrder: [4, 1, 3, 0, 2]
  ).queue
  let ids = queue.entries.map(\.id)
  let editor = QueueEditor()

  editor.begin(queue: queue)
  editor.move(from: IndexSet(integer: 0), to: 3)

  #expect(
    editor.plannedEdits == [
      .setShuffle(
        mode: .on,
        seed: 7,
        order: [ids[4], ids[1], ids[0], ids[2], ids[3]]
      )
    ]
  )
}

@MainActor
@Test("Queue editor exits after a successful staged commit")
func queueEditorCompletesSuccessfulCommit() async {
  let initial = makeQueuePlayerSnapshot(currentIndex: 0)
  let ids = initial.queue.entries.map(\.id)
  let serving = QueueEditingPlaybackServing(snapshot: initial)
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)
  let editor = QueueEditor()

  editor.begin(queue: initial.queue)
  editor.move(from: IndexSet(integer: 0), to: 3)
  await editor.commit(using: viewModel)

  #expect(editor.phase == .inactive)
  #expect(editor.failureMessage == nil)
  #expect(serving.commands == [.editQueue(.move(ids[1], to: 3))])
  #expect(serving.snapshot.queue.entries.map(\.id) == [ids[0], ids[2], ids[3], ids[1]])
}

@MainActor
@Test("Queue editor stops on failure and reloads the authoritative partial result")
func queueEditorRecoversFromPartialCommitFailure() async {
  let initial = makeQueuePlayerSnapshot(currentIndex: 0)
  let ids = initial.queue.entries.map(\.id)
  let serving = QueueEditingPlaybackServing(
    snapshot: initial,
    failureAtCommandIndex: 1
  )
  let viewModel = PlayerViewModel(serving: serving, autoStart: false)
  let editor = QueueEditor()

  editor.begin(queue: initial.queue)
  editor.remove(at: IndexSet(integer: 0))
  editor.move(from: IndexSet(integer: 0), to: 2)
  await editor.commit(using: viewModel)

  #expect(
    serving.commands == [
      .editQueue(.remove(ids[1])),
      .editQueue(.move(ids[3], to: 1)),
    ]
  )
  #expect(serving.snapshot.queue.entries.map(\.id) == [ids[0], ids[2], ids[3]])
  #expect(viewModel.lastCommandError == .resourceUnavailable)
  #expect(editor.phase == .editing)
  #expect(editor.entries.map(\.id) == [ids[2], ids[3]])
  #expect(editor.failureMessage != nil)
}

private enum ArtworkLoaderTestError: Error, Sendable {
  case unavailable
}

@MainActor
private final class QueueEditingPlaybackServing: PlaybackServing {
  private(set) var snapshot: PlaybackSessionSnapshot
  private(set) var commands: [PlaybackSessionCommand] = []
  private let failureAtCommandIndex: Int?

  init(
    snapshot: PlaybackSessionSnapshot,
    failureAtCommandIndex: Int? = nil
  ) {
    self.snapshot = snapshot
    self.failureAtCommandIndex = failureAtCommandIndex
  }

  func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
    AsyncStream { $0.finish() }
  }

  func send(_ command: PlaybackSessionCommand) async {
    try? await execute(command)
  }

  func execute(_ command: PlaybackSessionCommand) async throws {
    let commandIndex = commands.count
    commands.append(command)
    if commandIndex == failureAtCommandIndex {
      throw PlaybackError.resourceUnavailable
    }

    guard case .editQueue(let edit) = command else { return }
    let updatedQueue = try snapshot.queue.snapshot.applying(edit)
    snapshot = PlaybackSessionSnapshot(
      state: snapshot.state,
      currentItem: snapshot.currentItem,
      queue: PlaybackQueueSummary(snapshot: updatedQueue),
      capabilities: snapshot.capabilities,
      effectiveEffects: snapshot.effectiveEffects,
      systemCapabilities: snapshot.systemCapabilities
    )
  }
}

@MainActor
private final class SuspendedPlaybackServing: PlaybackServing {
  private(set) var snapshot: PlaybackSessionSnapshot
  private(set) var commands: [PlaybackSessionCommand] = []
  private var firstCommandContinuation: CheckedContinuation<Void, Never>?
  private var firstCommandStarted = false
  private var firstCommandStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(snapshot: PlaybackSessionSnapshot) {
    self.snapshot = snapshot
  }

  func makeSnapshotStream() -> AsyncStream<PlaybackSessionSnapshot> {
    AsyncStream { $0.finish() }
  }

  func send(_ command: PlaybackSessionCommand) async {
    commands.append(command)
    guard commands.count == 1 else { return }
    firstCommandStarted = true
    let waiters = firstCommandStartWaiters
    firstCommandStartWaiters.removeAll()
    waiters.forEach { $0.resume() }
    await withCheckedContinuation { continuation in
      firstCommandContinuation = continuation
    }
  }

  func waitUntilFirstCommandStarts() async {
    guard !firstCommandStarted else { return }
    await withCheckedContinuation { continuation in
      firstCommandStartWaiters.append(continuation)
    }
  }

  func releaseFirstCommand() {
    firstCommandContinuation?.resume()
    firstCommandContinuation = nil
  }
}

@MainActor
private final class ControlledFavoriteLibrary: LibraryServing {
  private(set) var tracks: [MediaItemID: Track]
  private(set) var favoriteWrites: [Bool] = []
  private var firstMutationContinuation: CheckedContinuation<Void, Never>?
  private var firstMutationStarted = false
  private var firstMutationStartWaiters: [CheckedContinuation<Void, Never>] = []

  init(tracks: [Track]) {
    self.tracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
  }

  func track(id: MediaItemID) async throws -> Track? {
    tracks[id]
  }

  func browseTracks(
    matching _: TrackQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: Array(tracks.values))
  }

  func browseAlbums(
    matching _: AlbumQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Album> {
    LibraryPage(elements: [])
  }

  func browseArtists(
    matching _: ArtistQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    LibraryPage(elements: [])
  }

  func searchTracks(
    text _: String,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: [])
  }

  func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
    favoriteWrites.append(isFavorite)
    if favoriteWrites.count == 1 {
      firstMutationStarted = true
      let waiters = firstMutationStartWaiters
      firstMutationStartWaiters.removeAll()
      waiters.forEach { $0.resume() }
      await withCheckedContinuation { continuation in
        firstMutationContinuation = continuation
      }
    }
    let existing = tracks[itemID]!
    let updated = Track(
      id: existing.id,
      title: existing.title,
      sortTitle: existing.sortTitle,
      albumID: existing.albumID,
      artistIDs: existing.artistIDs,
      genreIDs: existing.genreIDs,
      folderPath: existing.folderPath,
      duration: existing.duration,
      technicalInfo: existing.technicalInfo,
      artwork: existing.artwork,
      isFavorite: isFavorite,
      statistics: existing.statistics
    )
    tracks[itemID] = updated
    return updated
  }

  func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
    throw LibraryTestFailure.unsupported
  }

  func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
    throw LibraryTestFailure.unsupported
  }

  func makeChangeStream() async -> AsyncStream<LibraryChange> {
    AsyncStream { $0.finish() }
  }

  func waitUntilFirstMutationStarts() async {
    guard !firstMutationStarted else { return }
    await withCheckedContinuation { continuation in
      firstMutationStartWaiters.append(continuation)
    }
  }

  func releaseFirstMutation() {
    firstMutationContinuation?.resume()
    firstMutationContinuation = nil
  }
}

@MainActor
private final class PlayerHistoryLibrary: LibraryServing {
  var historyItems: [PlaybackHistoryItem]
  var clearError: Error?
  private(set) var clearCallCount = 0
  private(set) var historyLoadCount = 0

  private let artists: [Artist]
  private var changeContinuation: AsyncStream<LibraryChange>.Continuation?
  private var changeSubscriberWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    historyItems: [PlaybackHistoryItem] = [],
    artists: [Artist] = []
  ) {
    self.historyItems = historyItems
    self.artists = artists
  }

  func track(id: MediaItemID) async throws -> Track? {
    historyItems.first(where: { $0.track.id == id })?.track
  }

  func browseTracks(
    matching _: TrackQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: historyItems.map(\.track))
  }

  func browseAlbums(
    matching _: AlbumQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Album> {
    LibraryPage(elements: [])
  }

  func browseArtists(
    matching _: ArtistQuery,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Artist> {
    LibraryPage(elements: artists)
  }

  func recentHistory(
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<PlaybackHistoryItem> {
    historyLoadCount += 1
    return LibraryPage(elements: historyItems)
  }

  func clearPlaybackHistory() async throws {
    clearCallCount += 1
    if let clearError { throw clearError }
    historyItems = []
  }

  func searchTracks(
    text _: String,
    page _: LibraryPageRequest
  ) async throws -> LibraryPage<Track> {
    LibraryPage(elements: [])
  }

  func setFavorite(_ isFavorite: Bool, for itemID: MediaItemID) async throws -> Track {
    _ = isFavorite
    _ = itemID
    throw LibraryTestFailure.unsupported
  }

  func delete(_ itemIDs: Set<MediaItemID>) async throws -> LibraryDeletionResult {
    _ = itemIDs
    throw LibraryTestFailure.unsupported
  }

  func recoverPendingRemovals() async throws -> LibraryRecoveryResult {
    throw LibraryTestFailure.unsupported
  }

  func makeChangeStream() async -> AsyncStream<LibraryChange> {
    AsyncStream { continuation in
      changeContinuation = continuation
      let waiters = changeSubscriberWaiters
      changeSubscriberWaiters.removeAll()
      waiters.forEach { $0.resume() }
    }
  }

  func waitForChangeSubscriber() async {
    guard changeContinuation == nil else { return }
    await withCheckedContinuation { continuation in
      changeSubscriberWaiters.append(continuation)
    }
  }

  func publishHistoryChange() {
    changeContinuation?.yield(LibraryChange(
      revision: LibraryRevision(1),
      categories: [.playbackHistory],
      affectedIDs: LibraryAffectedIDs()
    ))
  }

  func finishChanges() {
    changeContinuation?.finish()
    changeContinuation = nil
  }
}

private enum LibraryTestFailure: Error {
  case unsupported
}

private func makePlayerHistoryItem(
  sessionID: UUID,
  track: Track,
  completionReason: PlaybackCompletionReason? = nil
) -> PlaybackHistoryItem {
  PlaybackHistoryItem(
    sessionID: sessionID,
    track: track,
    lastStartedAt: Date(timeIntervalSince1970: 100),
    lastEventAt: Date(timeIntervalSince1970: 110),
    totalPlayedDuration: .seconds(10),
    lastPosition: .seconds(10),
    lastCompletionReason: completionReason
  )
}

@MainActor
private func makeQueuePlayerSnapshot(
  count: Int = 4,
  currentIndex: Int,
  repeatMode: PlaybackRepeatMode = .off,
  shuffleOrder: [Int] = []
) -> PlaybackSessionSnapshot {
  let entries = (0..<count).map { index in
    PlaybackQueueEntry(
      id: UUID(uuidString: String(
        format: "00000000-0000-0000-0001-%012d",
        index
      ))!,
      itemID: MediaItemID(sourceID: .local, externalID: "queue-\(index)")
    )
  }
  let orderedIDs = shuffleOrder.map { entries[$0].id }
  let currentEntry = entries[currentIndex]
  return PlaybackSessionSnapshot(
    state: PlaybackState(
      phase: .paused,
      generation: PlaybackGeneration(1),
      itemID: currentEntry.itemID,
      duration: .seconds(120)
    ),
    currentItem: PlaybackDisplaySnapshot(title: currentEntry.itemID.externalID),
    queue: PlaybackQueueSummary(
      entries: entries,
      currentEntryID: currentEntry.id,
      repeatMode: repeatMode,
      shuffleMode: shuffleOrder.isEmpty ? .off : .on,
      shuffleSeed: shuffleOrder.isEmpty ? nil : 7,
      shuffleOrder: orderedIDs
    )
  )
}

private actor PlayerArtworkRaceService: ArtworkServing {
  private var oldRequestStarted = false
  private var oldRequestContinuation: CheckedContinuation<Void, Never>?

  func artwork(
    for artworkID: ArtworkID,
    sourceID _: MediaSourceID
  ) async throws -> ArtworkResource? {
    if artworkID == ArtworkID("old") {
      oldRequestStarted = true
      oldRequestContinuation?.resume()
      oldRequestContinuation = nil
      try await Task.sleep(nanoseconds: 50_000_000)
      throw ArtworkLoaderTestError.unavailable
    }

    return .inMemory(testArtworkData())
  }

  func waitForOldRequest() async {
    guard !oldRequestStarted else { return }
    await withCheckedContinuation { continuation in
      oldRequestContinuation = continuation
    }
  }
}

private actor PlayerControlledArtworkDecoder {
  private var didStart = false
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var resultContinuation: CheckedContinuation<UIImage?, Never>?

  func decode(_ resource: ArtworkResource?) async -> UIImage? {
    _ = resource
    didStart = true
    startContinuation?.resume()
    startContinuation = nil
    return await withCheckedContinuation { continuation in
      resultContinuation = continuation
    }
  }

  func waitForDecode() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startContinuation = continuation
    }
  }

  func complete(with image: UIImage?) {
    resultContinuation?.resume(returning: image)
    resultContinuation = nil
  }
}

private func testArtworkData() -> Data {
  Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9JgV0AAAAASUVORK5CYII="
  )!
}

@MainActor
private func wideArtworkData() -> Data {
  let size = CGSize(width: 4_096, height: 16)
  return UIGraphicsImageRenderer(size: size).pngData { context in
    UIColor.systemBlue.setFill()
    context.fill(CGRect(origin: .zero, size: size))
  }
}
