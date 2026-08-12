import AppServices
import Combine
import MusicDomain

@MainActor
final class PlayerFavoriteController: ObservableObject {
  @Published private(set) var isFavorite = false

  private struct Request {
    let version: UInt64
    let value: Bool
  }

  private let library: (any LibraryServing)?
  private var currentItemID: MediaItemID?
  private var loadTask: Task<Void, Never>?
  private var mutationTasks: [MediaItemID: Task<Void, Never>] = [:]
  private var requests: [MediaItemID: Request] = [:]
  private var versions: [MediaItemID: UInt64] = [:]

  init(library: (any LibraryServing)?) {
    self.library = library
  }

  deinit {
    loadTask?.cancel()
    mutationTasks.values.forEach { $0.cancel() }
  }

  func load(itemID: MediaItemID?) {
    currentItemID = itemID
    loadTask?.cancel()
    guard let library, let itemID else {
      isFavorite = false
      return
    }
    if let request = requests[itemID] {
      isFavorite = request.value
      return
    }

    let expectedVersion = versions[itemID, default: 0]
    loadTask = Task { @MainActor [weak self] in
      let track = try? await library.track(id: itemID)
      guard !Task.isCancelled,
            let self,
            self.currentItemID == itemID,
            self.versions[itemID, default: 0] == expectedVersion,
            self.requests[itemID] == nil
      else { return }
      self.isFavorite = track?.isFavorite ?? false
    }
  }

  func toggle() {
    guard library != nil, let itemID = currentItemID else { return }
    let nextVersion = versions[itemID, default: 0] &+ 1
    versions[itemID] = nextVersion
    let request = Request(version: nextVersion, value: !isFavorite)
    requests[itemID] = request
    isFavorite = request.value

    guard mutationTasks[itemID] == nil else { return }
    mutationTasks[itemID] = Task { @MainActor [weak self] in
      await self?.runMutations(for: itemID)
    }
  }

  func waitForPendingWork() async {
    let tasks = Array(mutationTasks.values)
    for task in tasks {
      await task.value
    }
    await loadTask?.value
  }

  private func runMutations(for itemID: MediaItemID) async {
    guard let library else { return }
    defer { mutationTasks[itemID] = nil }

    while let request = requests[itemID] {
      do {
        let track = try await library.setFavorite(request.value, for: itemID)
        guard !Task.isCancelled else { return }
        guard requests[itemID]?.version == request.version else { continue }
        requests[itemID] = nil
        if currentItemID == itemID {
          isFavorite = track.isFavorite
        }
      } catch {
        guard requests[itemID]?.version == request.version else { continue }
        requests[itemID] = nil
        if currentItemID == itemID {
          isFavorite = (try? await library.track(id: itemID))?.isFavorite ?? !request.value
        }
      }
    }
  }
}
