import AppServices
import Combine
import Foundation
import PlaybackAPI

enum QueueEditCommitResult: Equatable {
  case success
  case failure(PlaybackError)
}

@MainActor
final class QueueEditor: ObservableObject {
  enum Phase: Equatable {
    case inactive
    case editing
    case saving
  }

  @Published private(set) var phase: Phase = .inactive
  @Published private(set) var entries: [PlaybackQueueEntry] = []
  @Published private(set) var failureMessage: String?

  private var baseline: PlaybackQueueSummary?
  private var fixedPrefixIDs: [UUID] = []
  private var originalEditableIDs: [UUID] = []

  var isActive: Bool {
    phase != .inactive
  }

  var isSaving: Bool {
    phase == .saving
  }

  var hasChanges: Bool {
    entries.map(\.id) != originalEditableIDs
  }

  func begin(queue: PlaybackQueueSummary) {
    configure(with: queue, phase: .editing)
    failureMessage = nil
  }

  func move(from source: IndexSet, to destination: Int) {
    guard phase == .editing, !source.isEmpty else { return }

    let validSource = source.filter { entries.indices.contains($0) }
    guard !validSource.isEmpty else { return }

    let moving = validSource.sorted().map { entries[$0] }
    var remaining = entries.enumerated()
      .filter { !validSource.contains($0.offset) }
      .map(\.element)
    let removedBeforeDestination = validSource.filter { $0 < destination }.count
    let insertionIndex = min(
      max(0, destination - removedBeforeDestination),
      remaining.count
    )
    remaining.insert(contentsOf: moving, at: insertionIndex)
    entries = remaining
  }

  func remove(at offsets: IndexSet) {
    guard phase == .editing else { return }
    entries = entries.enumerated()
      .filter { !offsets.contains($0.offset) }
      .map(\.element)
  }

  func cancel() {
    reset()
  }

  func commit(using viewModel: PlayerViewModel) async {
    guard phase == .editing else { return }

    let edits = plannedEdits
    guard !edits.isEmpty else {
      reset()
      return
    }

    phase = .saving
    failureMessage = nil
    let result = await viewModel.commitQueueEdits(edits)

    switch result {
    case .success:
      reset()
    case .failure(let error):
      configure(with: viewModel.snapshot.queue, phase: .editing)
      failureMessage = Self.failureMessage(for: error)
    }
  }

  func synchronize(with queue: PlaybackQueueSummary) {
    guard phase == .editing, let baseline else { return }
    guard Self.hasStructuralChanges(from: baseline, to: queue) else { return }
    configure(with: queue, phase: .editing)
    failureMessage = "播放队列已更新，请重新调整顺序。"
  }

  func dismissFailure() {
    failureMessage = nil
  }

  private static func hasStructuralChanges(
    from baseline: PlaybackQueueSummary,
    to queue: PlaybackQueueSummary
  ) -> Bool {
    baseline.entries != queue.entries
      || baseline.currentEntryID != queue.currentEntryID
      || baseline.repeatMode != queue.repeatMode
      || baseline.shuffleMode != queue.shuffleMode
      || baseline.shuffleSeed != queue.shuffleSeed
      || baseline.shuffleOrder != queue.shuffleOrder
  }

  var plannedEdits: [PlaybackQueueEdit] {
    guard let baseline else { return [] }

    let draftIDs = entries.map(\.id)
    let draftIDSet = Set(draftIDs)
    let removedIDs = originalEditableIDs.filter { !draftIDSet.contains($0) }
    let removedIDSet = Set(removedIDs)
    var edits = removedIDs.map(PlaybackQueueEdit.remove)
    let desiredOrder = fixedPrefixIDs + draftIDs

    if baseline.shuffleMode == .on {
      let survivingOrder = Self.orderedEntries(in: baseline)
        .map(\.id)
        .filter { !removedIDSet.contains($0) }
      if desiredOrder != survivingOrder {
        edits.append(
          .setShuffle(
            mode: .on,
            seed: baseline.shuffleSeed,
            order: desiredOrder
          )
        )
      }
      return edits
    }

    let workingOrder = baseline.entries
      .map(\.id)
      .filter { !removedIDSet.contains($0) }
    let forwardMoves = Self.moveEdits(
      from: workingOrder,
      to: desiredOrder,
      traversing: desiredOrder.indices
    )
    let reverseMoves = Self.moveEdits(
      from: workingOrder,
      to: desiredOrder,
      traversing: desiredOrder.indices.reversed()
    )
    edits.append(contentsOf: reverseMoves.count < forwardMoves.count ? reverseMoves : forwardMoves)
    return edits
  }

  private func configure(with queue: PlaybackQueueSummary, phase: Phase) {
    let orderedEntries = Self.orderedEntries(in: queue)
    let editableStartIndex: Int
    if let currentEntryID = queue.currentEntryID,
       let currentIndex = orderedEntries.firstIndex(where: { $0.id == currentEntryID }) {
      fixedPrefixIDs = Array(orderedEntries[...currentIndex]).map(\.id)
      editableStartIndex = orderedEntries.index(after: currentIndex)
    } else {
      fixedPrefixIDs = []
      editableStartIndex = orderedEntries.startIndex
    }

    let editableEntries = editableStartIndex < orderedEntries.endIndex
      ? Array(orderedEntries[editableStartIndex...])
      : []
    baseline = queue
    entries = editableEntries
    originalEditableIDs = editableEntries.map(\.id)
    self.phase = phase
  }

  private func reset() {
    phase = .inactive
    entries = []
    failureMessage = nil
    baseline = nil
    fixedPrefixIDs = []
    originalEditableIDs = []
  }

  private static func orderedEntries(
    in queue: PlaybackQueueSummary
  ) -> [PlaybackQueueEntry] {
    guard queue.shuffleMode == .on, !queue.shuffleOrder.isEmpty else {
      return queue.entries
    }
    let entriesByID = Dictionary(uniqueKeysWithValues: queue.entries.map { ($0.id, $0) })
    return queue.shuffleOrder.compactMap { entriesByID[$0] }
  }

  /// A small local SplitMix64 shuffle keeps the persisted order reproducible
  /// for a given seed without importing test-support or UI code into Core.
  private static func moveEdits<S: Sequence>(
    from source: [UUID],
    to desired: [UUID],
    traversing indices: S
  ) -> [PlaybackQueueEdit] where S.Element == Int {
    guard source.count == desired.count, Set(source) == Set(desired) else {
      return []
    }

    var working = source
    var edits: [PlaybackQueueEdit] = []
    for targetIndex in indices {
      let entryID = desired[targetIndex]
      guard working[targetIndex] != entryID,
            let sourceIndex = working.firstIndex(of: entryID)
      else {
        continue
      }
      working.remove(at: sourceIndex)
      working.insert(entryID, at: targetIndex)
      edits.append(.move(entryID, to: targetIndex))
    }
    return edits
  }

  private static func failureMessage(for error: PlaybackError) -> String {
    switch error {
    case .cancelled:
      return "队列编辑已取消，未完成的更改没有保存。"
    case .resourceUnavailable:
      return "播放服务暂时不可用，请稍后重试。"
    default:
      return "无法保存播放顺序，已恢复为播放器中的实际队列。"
    }
  }
}
