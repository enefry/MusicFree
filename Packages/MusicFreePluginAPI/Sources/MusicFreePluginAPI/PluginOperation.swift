import Foundation

public struct PluginOperationContext: Sendable {
    public let pluginID: PluginID
    public let instanceID: String
    public let operationID: UUID
    public let generation: UInt64
    public let permissions: Set<PluginPermission>
    public let applicationPrivacyAccepted: Bool
    public init(pluginID: PluginID, instanceID: String, operationID: UUID = UUID(), generation: UInt64,
                permissions: Set<PluginPermission>, applicationPrivacyAccepted: Bool) {
        self.pluginID = pluginID; self.instanceID = instanceID; self.operationID = operationID
        self.generation = generation; self.permissions = permissions
        self.applicationPrivacyAccepted = applicationPrivacyAccepted
    }
}
public struct PluginLoadContext: Sendable {
    public let operation: PluginOperationContext
    public let configuration: PluginInstanceConfiguration
    public let credentials: (any PluginCredentialAccess)?
    public init(operation: PluginOperationContext, configuration: PluginInstanceConfiguration,
                credentials: (any PluginCredentialAccess)? = nil) {
        self.operation = operation; self.configuration = configuration; self.credentials = credentials
    }
}
public protocol PluginInstance: Sendable { func shutdown() async }
public extension PluginInstance { func shutdown() async {} }

public struct PluginPCMAnalysisSnapshot: Sendable {
    public let peak: Float
    public let rms: Float
    public let frameCount: Int
    public init(peak: Float, rms: Float, frameCount: Int) { self.peak = peak; self.rms = rms; self.frameCount = frameCount }
}

public struct PluginTrackQuery: Hashable, Sendable {
    public let title: String
    public let artist: String?
    public let album: String?
    public let durationSeconds: Double?
    public init(title: String, artist: String? = nil, album: String? = nil, durationSeconds: Double? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.durationSeconds = durationSeconds
    }
    public func matches(_ candidate: Self) -> Bool {
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        guard !title.isEmpty, normalize(title) == normalize(candidate.title),
              let artist, let otherArtist = candidate.artist, normalize(artist) == normalize(otherArtist) else { return false }
        if let album, let otherAlbum = candidate.album, normalize(album) != normalize(otherAlbum) { return false }
        if let durationSeconds {
            guard durationSeconds.isFinite, durationSeconds >= 0, let other = candidate.durationSeconds,
                  other.isFinite, abs(durationSeconds - other) <= 2 else { return false }
        }
        return true
    }
}
