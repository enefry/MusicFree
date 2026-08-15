import Foundation
import MusicDomain

public enum ArtworkDataLimits {
    public static let maximumByteCount = 20 * 1024 * 1024
}

/// A content-addressed artwork write that remains reserved until its owning
/// library transaction reports success or failure.
public struct ArtworkWriteReceipt: Sendable {
    public let wasCreated: Bool

    private let completionState: CompletionState?

    public init(
        wasCreated: Bool,
        completion: (@Sendable (Bool) async -> Void)? = nil
    ) {
        self.wasCreated = wasCreated
        self.completionState = completion.map(CompletionState.init)
    }

    public func finish(committed: Bool) async {
        guard let completion = completionState?.take() else { return }
        await completion(committed)
    }
}

private final class CompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Bool) async -> Void)?

    init(_ completion: @escaping @Sendable (Bool) async -> Void) {
        self.completion = completion
    }

    func take() -> (@Sendable (Bool) async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let completion = self.completion
        self.completion = nil
        return completion
    }
}
