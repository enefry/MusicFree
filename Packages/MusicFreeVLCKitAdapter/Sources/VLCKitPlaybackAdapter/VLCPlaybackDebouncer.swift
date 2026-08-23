import Foundation

/// Delays a one-shot state transition without rearming it for every callback.
///
/// libVLC can report several transient buffering regressions while one media
/// item is starting. The playback engine uses this helper only for entering
/// `.buffering`; recovery to `.playing` cancels the pending transition.
@MainActor
internal final class VLCPlaybackDebouncer {
    typealias Commit = @MainActor @Sendable () -> Void

    private let delayNanoseconds: UInt64
    private var task: Task<Void, Never>?

    init(delayNanoseconds: UInt64 = 250_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    var isPending: Bool {
        task != nil
    }

    func schedule(_ commit: @escaping Commit) {
        guard task == nil else { return }

        let delayNanoseconds = self.delayNanoseconds
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }

            guard let self else { return }
            self.task = nil
            commit()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
