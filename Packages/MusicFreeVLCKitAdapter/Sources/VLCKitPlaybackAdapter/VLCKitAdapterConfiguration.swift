import Foundation
import PlaybackAPI

/// Compatibility marker retained for the initial package graph test.
/// The old standalone Module.swift file is intentionally removed.
public enum VLCKitPlaybackAdapterModule {}

/// A constrained libVLC media option exposed to the composition root.
/// Feature code cannot inject arbitrary option strings.
public enum VLCKitMediaOption: Equatable, Hashable, Sendable {
  case networkCaching(milliseconds: Int)
  case reconnect
  case continuousHTTP
}

/// Capability bits that the composition root has verified for its fixed
/// binary and target device matrix.
public struct VLCKitCapabilityPolicy: Equatable, Sendable {
  public let enabledCapabilities: PlaybackCapabilities

  public init(enabledCapabilities: PlaybackCapabilities = []) {
    self.enabledCapabilities = enabledCapabilities.intersection(.all)
  }

  /// The default is intentionally conservative until a device spike has
  /// verified a capability for the exact VLCKit binary.
  public static let conservative = Self()
}

/// Controls whether the adapter may emit operational diagnostic records.
/// Diagnostic records are always redacted by the adapter.
public enum VLCKitDiagnosticsPolicy: String, CaseIterable, Sendable {
  case disabled
  case errorsOnly
}

/// Values needed to create and configure one VLCKit adapter instance.
public struct VLCKitAdapterConfiguration: Equatable, Sendable {
  public let applicationIdentifier: String
  public let applicationVersion: String
  public let applicationName: String
  public let mediaOptions: [VLCKitMediaOption]
  public let capabilityPolicy: VLCKitCapabilityPolicy
  public let diagnosticsPolicy: VLCKitDiagnosticsPolicy
  public let parserTimeout: Duration

  public init(
    applicationIdentifier: String,
    applicationVersion: String,
    applicationName: String,
    mediaOptions: [VLCKitMediaOption] = [],
    capabilityPolicy: VLCKitCapabilityPolicy = .conservative,
    diagnosticsPolicy: VLCKitDiagnosticsPolicy = .disabled,
    parserTimeout: Duration = .seconds(15)
  ) throws {
    let normalizedIdentifier = applicationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedVersion = applicationVersion.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedName = applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedIdentifier.isEmpty else {
      throw VLCKitAdapterError.invalidConfiguration(field: "applicationIdentifier")
    }
    guard !normalizedVersion.isEmpty else {
      throw VLCKitAdapterError.invalidConfiguration(field: "applicationVersion")
    }
    guard !normalizedName.isEmpty else {
      throw VLCKitAdapterError.invalidConfiguration(field: "applicationName")
    }
    guard parserTimeout > .zero, parserTimeout <= .seconds(120) else {
      throw VLCKitAdapterError.invalidConfiguration(field: "parserTimeout")
    }

    for option in mediaOptions {
      if case .networkCaching(let milliseconds) = option,
         !(0...600_000).contains(milliseconds)
      {
        throw VLCKitAdapterError.invalidOption(field: "networkCaching")
      }
    }

    self.applicationIdentifier = normalizedIdentifier
    self.applicationVersion = normalizedVersion
    self.applicationName = normalizedName
    self.mediaOptions = mediaOptions
    self.capabilityPolicy = capabilityPolicy
    self.diagnosticsPolicy = diagnosticsPolicy
    self.parserTimeout = parserTimeout
  }
}
