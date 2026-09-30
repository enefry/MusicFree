import Foundation
import MediaSourceAPI

public struct AudioConversionPreferences: Codable, Equatable, Hashable, Sendable {
    public let automaticallyConvertLosslessImports: Bool
    public let target: AudioConversionTarget
    public let maximumConcurrency: MediaConversionConcurrency

    public init(
        automaticallyConvertLosslessImports: Bool = false,
        target: AudioConversionTarget = .defaultAAC,
        maximumConcurrency: MediaConversionConcurrency = .default
    ) {
        self.automaticallyConvertLosslessImports = automaticallyConvertLosslessImports
        self.target = target
        self.maximumConcurrency = maximumConcurrency
    }

    public static let defaults = Self()

    public var importPolicy: AudioImportConversionPolicy? {
        guard automaticallyConvertLosslessImports else { return nil }
        return AudioImportConversionPolicy(target: target)
    }

    public func settingAutomaticConversion(_ enabled: Bool) -> Self {
        Self(
            automaticallyConvertLosslessImports: enabled,
            target: target,
            maximumConcurrency: maximumConcurrency
        )
    }

    public func settingTarget(_ target: AudioConversionTarget) -> Self {
        Self(
            automaticallyConvertLosslessImports: automaticallyConvertLosslessImports,
            target: target,
            maximumConcurrency: maximumConcurrency
        )
    }

    public func settingMaximumConcurrency(_ maximum: MediaConversionConcurrency) -> Self {
        Self(
            automaticallyConvertLosslessImports: automaticallyConvertLosslessImports,
            target: target,
            maximumConcurrency: maximum
        )
    }
}
