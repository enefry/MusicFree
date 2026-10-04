import Foundation

/// Persist unknown positions so newer settings remain recoverable on older hosts.
public struct PluginDSPPlacement: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let perTrack = Self(rawValue: "perTrack")
    public static let postMix = Self(rawValue: "postMix")
    public static let known: [Self] = [.perTrack, .postMix]
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

public struct PluginDSPPlacementOptions: Codable, Hashable, Sendable {
    public let supported: Set<PluginDSPPlacement>
    public let defaultPlacement: PluginDSPPlacement
    public init(supported: Set<PluginDSPPlacement>, defaultPlacement: PluginDSPPlacement) {
        self.supported = supported; self.defaultPlacement = defaultPlacement
    }
    public var isValid: Bool {
        !supported.isEmpty && supported.isSubset(of: Set(PluginDSPPlacement.known)) && supported.contains(defaultPlacement)
    }
}

extension PluginDescriptor {
    /// A missing declaration keeps legacy host routing. Explicit selections must
    /// be declared; an unknown selection is retained but cannot execute.
    public func resolvedDSPPlacement(_ selection: PluginDSPPlacement?) throws -> PluginDSPPlacement? {
        guard let options = dspPlacements else {
            guard selection == nil else { throw PluginError.unsupportedCapability }
            return nil
        }
        let selected = selection ?? options.defaultPlacement
        guard options.isValid, options.supported.contains(selected) else { throw PluginError.unsupportedCapability }
        return selected
    }
}
