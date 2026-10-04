import Foundation
import SettingsAPI
import MusicFreePluginAPI

/// Host façade. Core knows only the generic API, never Runtime/HostBridge.
public protocol PluginServing: Sendable {
    func apply(_ settings: AppSettings) async
    func snapshots() async -> [PluginSnapshot]
    func stop() async
    func audioAnalysis() async -> AsyncStream<PluginPCMAnalysisSnapshot>
    func saveCredential(_ data: Data, pluginID: PluginID, instanceID: String) async throws -> String
    func deleteCredential(recordID: String, pluginID: PluginID, instanceID: String) async throws
}
public extension PluginServing {
    func audioAnalysis() async -> AsyncStream<PluginPCMAnalysisSnapshot> { AsyncStream { $0.finish() } }
    func saveCredential(_ data: Data, pluginID: PluginID, instanceID: String) async throws -> String { throw PluginError.unavailable }
    func deleteCredential(recordID: String, pluginID: PluginID, instanceID: String) async throws { throw PluginError.unavailable }
}
