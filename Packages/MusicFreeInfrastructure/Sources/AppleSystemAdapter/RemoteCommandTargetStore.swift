import SystemIntegrationAPI

@MainActor
final class AppleRemoteCommandTargetToken {
    private let removeAction: @MainActor () -> Void
    private(set) var isRemoved = false

    init(removeAction: @escaping @MainActor () -> Void) {
        self.removeAction = removeAction
    }

    func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        removeAction()
    }
}

@MainActor
final class RemoteCommandTargetStore {
    private var tokens: [RemoteCommandKind: AppleRemoteCommandTargetToken] = [:]

    var registeredCommands: Set<RemoteCommandKind> {
        Set(tokens.keys)
    }

    var count: Int {
        tokens.count
    }

    func token(for command: RemoteCommandKind) -> AppleRemoteCommandTargetToken? {
        tokens[command]
    }

    func insert(_ token: AppleRemoteCommandTargetToken, for command: RemoteCommandKind) {
        tokens[command]?.remove()
        tokens[command] = token
    }

    @discardableResult
    func remove(_ command: RemoteCommandKind) -> Bool {
        guard let token = tokens.removeValue(forKey: command) else { return false }
        token.remove()
        return true
    }

    func removeAll() {
        let currentTokens = Array(tokens.values)
        tokens.removeAll(keepingCapacity: false)
        currentTokens.forEach { $0.remove() }
    }
}
