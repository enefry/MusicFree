import AppServices
import Combine
import Foundation
import PlaybackAPI

@MainActor
final class PlayerViewModel: ObservableObject {
  @Published private(set) var snapshot: PlaybackSessionSnapshot
  @Published private(set) var lastCommandError: PlaybackError?
  @Published private(set) var isSeeking = false
  @Published private(set) var seekPosition: Duration?
  @Published private(set) var volume: Float
  @Published private(set) var isMuted: Bool

  private let serving: any PlaybackServing
  private let audioServing: any PlayerAudioServing
  private var observationTask: Task<Void, Never>?
  private var commandTasks: [UUID: Task<Void, Never>] = [:]
  private var audioTask: Task<Void, Never>?
  private var pendingSeekPosition: Duration?
  private var pendingSeekGeneration: PlaybackGeneration?
  private var pendingVolume: Float?

  init(
    serving: any PlaybackServing,
    audioServing: (any PlayerAudioServing)? = nil,
    autoStart: Bool = true
  ) {
    self.serving = serving
    self.snapshot = serving.snapshot

    let resolvedAudioServing = audioServing
      ?? (serving as? any PlaybackAudioServing)
      ?? PlayerAudioStore()
    self.audioServing = resolvedAudioServing
    self.volume = resolvedAudioServing.volume
    self.isMuted = resolvedAudioServing.isMuted

    if autoStart {
      start()
    }
  }

  deinit {
    observationTask?.cancel()
    commandTasks.values.forEach { $0.cancel() }
    audioTask?.cancel()
  }

  var presentationState: PlayerPresentationState {
    if case .unsupportedCapability(let capabilities) = lastCommandError {
      return .unsupported(capabilities)
    }
    if case .unsupportedCapability(let capabilities) = snapshot.error {
      return .unsupported(capabilities)
    }

    switch snapshot.phase {
    case .idle:
      return .empty
    case .preparing:
      return .loading
    case .buffering:
      return .buffering
    case .playing:
      return .playing
    case .paused:
      return .paused
    case .stopped:
      return snapshot.currentItem == nil ? .empty : .stopped
    case .failed:
      return .failed(snapshot.error ?? .unknown(code: "playback_failed"))
    }
  }

  var currentTitle: String? {
    snapshot.currentItem?.title
  }

  var currentArtist: String? {
    snapshot.currentItem?.artist
  }

  /// The MiniPlayer represents an active single-track session. A stopped
  /// coordinator intentionally retains the current item for later resume, so
  /// checking only `currentItem` would leave the MiniPlayer visible after stop.
  var isMiniPlayerVisible: Bool {
    guard snapshot.currentItem != nil,
          snapshot.queue.currentEntryID != nil,
          snapshot.queue.currentItemID != nil else {
      return false
    }

    switch snapshot.phase {
    case .preparing, .buffering, .playing, .paused:
      return true
    case .idle, .stopped, .failed:
      return false
    }
  }

  var displayedPosition: Duration {
    if isSeeking, let seekPosition {
      return clamped(seekPosition)
    }
    if let pendingSeekPosition {
      return clamped(pendingSeekPosition)
    }
    return clamped(snapshot.position)
  }

  var displayedVolume: Float {
    pendingVolume ?? volume
  }

  var duration: Duration? {
    snapshot.duration
  }

  var canSeek: Bool {
    snapshot.capabilities.contains(.seeking) && duration != nil
  }

  var canGoPrevious: Bool {
    canAdvance(direction: -1)
  }

  var canGoNext: Bool {
    canAdvance(direction: 1)
  }

  var orderedQueueEntries: [PlaybackQueueEntry] {
    let queue = snapshot.queue
    guard queue.shuffleMode == .on, !queue.shuffleOrder.isEmpty else {
      return queue.entries
    }
    let entriesByID = Dictionary(uniqueKeysWithValues: queue.entries.map { ($0.id, $0) })
    return queue.shuffleOrder.compactMap { entriesByID[$0] }
  }

  func upcomingQueueEntries() -> [PlaybackQueueEntry] {
    guard let currentEntryID = snapshot.queue.currentEntryID,
          let currentIndex = orderedQueueEntries.firstIndex(where: { $0.id == currentEntryID })
    else {
      return []
    }
    let startIndex = orderedQueueEntries.index(after: currentIndex)
    guard startIndex < orderedQueueEntries.endIndex else { return [] }
    return Array(orderedQueueEntries[startIndex...])
  }

  func adjacentQueueEntry(direction: Int) -> PlaybackQueueEntry? {
    guard direction != 0 else { return nil }

    let entries = orderedQueueEntries
    guard let currentEntryID = snapshot.queue.currentEntryID,
          let currentIndex = entries.firstIndex(where: { $0.id == currentEntryID })
    else {
      return direction > 0 ? entries.first : entries.last
    }

    let adjacentIndex = currentIndex + (direction > 0 ? 1 : -1)
    if entries.indices.contains(adjacentIndex) {
      return entries[adjacentIndex]
    }

    guard snapshot.queue.repeatMode == .all else { return nil }
    return direction > 0 ? entries.first : entries.last
  }

  func start() {
    guard observationTask == nil else { return }

    let stream = serving.makeSnapshotStream()
    observationTask = Task { @MainActor [weak self] in
      for await nextSnapshot in stream {
        guard !Task.isCancelled else { return }
        self?.apply(nextSnapshot)
      }
      self?.observationTask = nil
    }
  }

  func stop() {
    observationTask?.cancel()
    observationTask = nil
    commandTasks.values.forEach { $0.cancel() }
    commandTasks.removeAll()
    audioTask?.cancel()
    audioTask = nil
  }

  /// Waits until the most recent injected work has returned. This keeps
  /// preview and test stores deterministic without exposing their internals.
  func waitForPendingWork() async {
    let tasks = Array(commandTasks.values)
    for task in tasks {
      await task.value
    }
    await audioTask?.value
  }

  @discardableResult
  func apply(_ nextSnapshot: PlaybackSessionSnapshot) -> Bool {
    guard nextSnapshot.generation >= snapshot.generation else {
      return false
    }

    if nextSnapshot.generation == snapshot.generation,
       let currentItemID = snapshot.currentItemID,
       let nextItemID = nextSnapshot.currentItemID,
       currentItemID != nextItemID,
       nextSnapshot.phase != .preparing,
       nextSnapshot.phase != .failed {
      return false
    }

    snapshot = nextSnapshot

    if nextSnapshot.generation != pendingSeekGeneration {
      pendingSeekPosition = nil
      pendingSeekGeneration = nil
    } else if let pendingSeekPosition,
              isClose(nextSnapshot.position, to: pendingSeekPosition) {
      self.pendingSeekPosition = nil
      pendingSeekGeneration = nil
    }

    if let error = nextSnapshot.error {
      lastCommandError = error
      pendingSeekPosition = nil
      pendingSeekGeneration = nil
    } else if nextSnapshot.phase != .failed {
      lastCommandError = nil
    }

    return true
  }

  /// Maps an engine event for tests and future coordinator bridges. The live
  /// feature observes AppServices snapshots, while this helper preserves the
  /// same stale-generation behavior for event-driven fakes.
  @discardableResult
  func receive(_ event: PlaybackEvent) -> Bool {
    guard event.generation >= snapshot.generation else {
      return false
    }

    let currentItemID = snapshot.currentItemID
    if event.generation == snapshot.generation,
       let eventItemID = event.itemID,
       let currentItemID,
       eventItemID != currentItemID {
      return false
    }

    let eventItemID = event.itemID ?? currentItemID
    let display = eventItemID == currentItemID ? snapshot.currentItem : nil
    let state: PlaybackState

    switch event {
    case .phaseChanged(_, _, let phase):
      state = PlaybackState(
        phase: phase,
        generation: event.generation,
        itemID: eventItemID,
        position: snapshot.position,
        duration: snapshot.state.duration,
        error: phase == .failed ? snapshot.error : nil
      )
    case .positionChanged(_, let itemID, let position, let duration):
      state = PlaybackState(
        phase: snapshot.phase,
        generation: event.generation,
        itemID: itemID,
        position: position,
        duration: duration,
        error: nil
      )
    case .ended(_, let itemID, _):
      state = PlaybackState(
        phase: .stopped,
        generation: event.generation,
        itemID: itemID,
        position: snapshot.state.duration ?? snapshot.position,
        duration: snapshot.state.duration,
        error: nil
      )
    case .failed(_, let itemID, let error):
      state = PlaybackState(
        phase: .failed,
        generation: event.generation,
        itemID: itemID,
        position: snapshot.position,
        duration: snapshot.state.duration,
        error: error
      )
    }

    return apply(
      PlaybackSessionSnapshot(
        state: state,
        currentItem: display,
        queue: snapshot.queue,
        capabilities: snapshot.capabilities,
        effectiveEffects: snapshot.effectiveEffects,
        systemCapabilities: snapshot.systemCapabilities
      )
    )
  }

  func play() {
    guard let itemID = snapshot.currentItemID else {
      lastCommandError = .noCurrentItem
      return
    }
    send(.play(itemID: itemID))
  }

  func pause() {
    send(.pause)
  }

  func togglePlayback() {
    send(.toggle)
  }

  func previous() {
    send(.previous)
  }

  func next() {
    send(.next)
  }

  func selectQueueEntry(_ entryID: UUID) {
    guard let entry = snapshot.queue.entries.first(where: { $0.id == entryID }) else {
      lastCommandError = .noCurrentItem
      return
    }

    // Selecting a queue row is a playback intent, not just a persisted cursor
    // edit. Going through `.play` keeps queue selection, resource resolution,
    // audio-session activation, and VLC preparation in one coordinator path.
    send(.play(itemID: entry.itemID))
  }

  func removeQueueEntry(_ entryID: UUID) {
    send(.editQueue(.remove(entryID)))
  }

  func clearQueue() {
    send(.editQueue(.clear))
  }

  func commitQueueEdits(
    _ edits: [PlaybackQueueEdit]
  ) async -> QueueEditCommitResult {
    lastCommandError = nil

    for edit in edits {
      guard !Task.isCancelled else {
        lastCommandError = .cancelled
        return .failure(.cancelled)
      }

      do {
        try await serving.execute(.editQueue(edit))
      } catch is CancellationError {
        _ = apply(serving.snapshot)
        lastCommandError = .cancelled
        return .failure(.cancelled)
      } catch let error as PlaybackError {
        _ = apply(serving.snapshot)
        lastCommandError = error
        return .failure(error)
      } catch {
        let playbackError = serving.snapshot.error
          ?? .unknown(code: "queue_edit_failed")
        _ = apply(serving.snapshot)
        lastCommandError = playbackError
        return .failure(playbackError)
      }

      _ = apply(serving.snapshot)
      if let error = serving.snapshot.error {
        lastCommandError = error
        return .failure(error)
      }
    }

    return .success
  }

  func setRepeatMode(_ mode: PlaybackRepeatMode) {
    send(.editQueue(.setRepeatMode(mode)))
  }

  func setShuffle(_ mode: PlaybackShuffleMode) {
    send(
      .editQueue(
        .setShuffle(
          mode: mode,
          seed: snapshot.queue.shuffleSeed,
          order: snapshot.queue.shuffleOrder
        )
      )
    )
  }

  func beginSeeking() {
    guard canSeek else {
      lastCommandError = .unsupportedCapability(.seeking)
      return
    }

    isSeeking = true
    seekPosition = displayedPosition
    lastCommandError = nil
  }

  func updateSeeking(to position: Duration) {
    guard isSeeking else { return }
    seekPosition = clamped(position)
  }

  func finishSeeking() {
    guard isSeeking, let seekPosition else { return }

    isSeeking = false
    self.seekPosition = nil
    pendingSeekPosition = clamped(seekPosition)
    pendingSeekGeneration = snapshot.generation
    send(.seek(to: clamped(seekPosition)))
  }

  func seek(to position: Duration) {
    beginSeeking()
    updateSeeking(to: position)
    finishSeeking()
  }

  func updateVolume(_ volume: Float) {
    pendingVolume = min(max(volume, 0), 1)
  }

  func finishVolumeChange() {
    guard let pendingVolume else { return }
    audioTask?.cancel()
    let audioServing = self.audioServing
    audioTask = Task { @MainActor [weak self] in
      await audioServing.setVolume(pendingVolume)
      guard !Task.isCancelled, let self else { return }
      self.volume = audioServing.volume
      self.pendingVolume = nil
    }
  }

  func setMuted(_ isMuted: Bool) {
    audioTask?.cancel()
    let audioServing = self.audioServing
    audioTask = Task { @MainActor [weak self] in
      await audioServing.setMuted(isMuted)
      guard !Task.isCancelled, let self else { return }
      self.isMuted = audioServing.isMuted
    }
  }

  func send(_ command: PlaybackSessionCommand) {
    if case .seek = command, !canSeek {
      lastCommandError = .unsupportedCapability(.seeking)
      pendingSeekPosition = nil
      pendingSeekGeneration = nil
      return
    }

    lastCommandError = nil
    let serving = self.serving
    let taskID = UUID()

    let task = Task { @MainActor [weak self] in
      await serving.send(command)
      guard let self else { return }
      defer { self.commandTasks[taskID] = nil }
      guard !Task.isCancelled else { return }

      let returnedSnapshot = serving.snapshot
      _ = self.apply(returnedSnapshot)
      if let error = returnedSnapshot.error {
        self.lastCommandError = error
      }
    }
    commandTasks[taskID] = task
  }

  private func canAdvance(direction: Int) -> Bool {
    let entries = orderedQueueEntries
    guard entries.count > 1,
          let currentEntryID = snapshot.queue.currentEntryID,
          let currentIndex = entries.firstIndex(where: { $0.id == currentEntryID })
    else {
      return false
    }
    if snapshot.queue.repeatMode == .all { return true }
    return entries.indices.contains(currentIndex + direction)
  }

  private func clamped(_ position: Duration) -> Duration {
    let nonNegative = max(position, .zero)
    guard let duration else { return nonNegative }
    return min(nonNegative, duration)
  }

  private func isClose(
    _ lhs: Duration,
    to rhs: Duration,
    tolerance: Duration = .seconds(0.75)
  ) -> Bool {
    let difference = abs(PlayerFormatting.seconds(lhs) - PlayerFormatting.seconds(rhs))
    return difference <= PlayerFormatting.seconds(tolerance)
  }
}
