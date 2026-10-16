import Foundation
import UIKit

/// Owns the named files until the receiving activity finishes reading them.
public final class PreparedMediaShare: Sendable {
    public let urls: [URL]
    private let directory: URL

    init(urls: [URL], directory: URL) {
        self.urls = urls
        self.directory = directory
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
public final class MediaShareActivityViewController: UIActivityViewController {
    let share: PreparedMediaShare

    public init(share: PreparedMediaShare) {
        self.share = share
        super.init(activityItems: share.urls, applicationActivities: nil)
        completionWithItemsHandler = { [share] _, _, _, _ in
            share.cleanup()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
