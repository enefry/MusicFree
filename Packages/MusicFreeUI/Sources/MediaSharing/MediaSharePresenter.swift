import AppServices
import DesignSystem
import LibraryAPI
import MediaSourceAPI
import MusicDomain
import UIKit

@MainActor
public final class MediaSharePresenter {
    private let resolver: MediaShareResolver
    private let library: (any LibraryServing)?
    private var task: Task<Void, Never>?

    public init(sourceResolver: any MediaSourceResolving, library: (any LibraryServing)? = nil) {
        resolver = MediaShareResolver(sourceResolver: sourceResolver)
        self.library = library
    }

    public func cancel() {
        task?.cancel()
    }

    public func present(
        itemID: MediaItemID,
        track: Track? = nil,
        from presenter: UIViewController,
        sourceView: UIView? = nil
    ) {
        guard task == nil, presenter.presentedViewController == nil else { return }
        let resolver = resolver
        let library = library
        task = Task { @MainActor [weak self, weak presenter] in
            defer { self?.task = nil }
            do {
                let resolvedTrack: Track
                if let track {
                    resolvedTrack = track
                } else if let library, let storedTrack = try await library.track(id: itemID) {
                    resolvedTrack = storedTrack
                } else {
                    throw MediaShareResolver.ShareError.emptySelection
                }
                let share = try await resolver.prepare(for: [resolvedTrack])
                try Task.checkCancellation()
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { return }
                let activity = MediaShareActivityViewController(share: share)
                if let popover = activity.popoverPresentationController {
                    let anchor = sourceView ?? presenter.view!
                    popover.sourceView = anchor
                    popover.sourceRect = CGRect(x: anchor.bounds.midX, y: anchor.bounds.midY, width: 1, height: 1)
                }
                presenter.present(activity, animated: true)
            } catch is CancellationError {
                return
            } catch {
                guard let presenter, presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil else { return }
                let alert = UIAlertController(title: L("无法分享"), message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L("好"), style: .default))
                presenter.present(alert, animated: true)
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
