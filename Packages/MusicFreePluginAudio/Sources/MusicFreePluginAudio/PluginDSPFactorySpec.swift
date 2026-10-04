import MusicFreePluginAPI
import MusicFreePluginDSPAPI
import PluginAnalysisRing

/// Main/control writes, decode/render reads. No locks or allocations per block.
public final class PluginDSPPermissionGate: @unchecked Sendable {
    private let gate: OpaquePointer?
    public init() { gate = mf_gate_create() }
    deinit { if let gate { mf_gate_destroy(gate) } }
    public var hasFailed: Bool { gate.map { mf_gate_failed($0) } ?? true }
    public func markFailed() { if let gate { mf_gate_fail(gate) } }
    public var isAllowed: Bool { gate.map { mf_gate_get($0) } ?? false }
    public func setAllowed(_ allowed: Bool) { if let gate { mf_gate_set(gate, allowed) } }
}
public struct PluginDSPFactorySpec: Sendable {
    public let pluginID: PluginID
    public let factory: DSPPluginFactory
    public let configuration: PluginInstanceConfiguration
    public let gate: PluginDSPPermissionGate
    public init(pluginID: PluginID, factory: @escaping DSPPluginFactory, configuration: PluginInstanceConfiguration, gate: PluginDSPPermissionGate) {
        self.pluginID = pluginID; self.factory = factory; self.configuration = configuration; self.gate = gate
    }
    public func makeProcessor() throws -> any PluginDSPProcessor {
        let processor = try factory(configuration)
        if let placement = configuration.dspPlacement {
            guard processor.behavior.scope.rawValue == placement.rawValue else { throw PluginError.unsupportedCapability }
        }
        return PermissionGatedProcessor(wrapped: processor, gate: gate)
    }
}
private struct PermissionGatedProcessor: PluginDSPProcessor {
    var wrapped: any PluginDSPProcessor
    let gate: PluginDSPPermissionGate
    var behavior: PluginDSPBehavior { wrapped.behavior }
    mutating func prepare(format: PluginPCMFormat) throws { try wrapped.prepare(format: format) }
    mutating func process(_ buffer: PluginPCMBufferView) throws { if gate.isAllowed { try wrapped.process(buffer) } }
    mutating func reset(_ reason: PluginDSPResetReason) { wrapped.reset(reason) }
}
