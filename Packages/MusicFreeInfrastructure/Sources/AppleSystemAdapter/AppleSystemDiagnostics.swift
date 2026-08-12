import SystemIntegrationAPI

enum AppleSystemDiagnostics {
    static func commandSetDescription(_ commands: Set<RemoteCommandKind>) -> String {
        commands.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func capabilityDescription(_ capabilities: SystemIntegrationCapabilities) -> String {
        String(capabilities.rawValue)
    }
}
