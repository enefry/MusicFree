import Foundation
import Testing
import MusicFreePluginAPI
@testable import MusicFreePluginRuntime

private let testID = PluginID(rawValue: "reference.test")
private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    var arrivalCount: Int { arrivals }
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func arrive() async {
        arrivals += 1
        for (_, observer) in observers.filter({ arrivals >= $0.0 }) { observer.resume() }
        observers.removeAll { arrivals >= $0.0 }
        if !open { await withCheckedContinuation { waiting.append($0) } }
    }
    func waitFor(_ count: Int) async {
        if arrivals < count { await withCheckedContinuation { observers.append((count, $0)) } }
    }
    func release() { open = true; waiting.forEach { $0.resume() }; waiting.removeAll() }
}
private actor TestLyrics: LyricsPlugin {
    let gate: Gate?
    var calls = 0
    var stops = 0
    init(gate: Gate? = nil) { self.gate = gate }
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate] {
        calls += 1
        await gate?.arrive()
        return [.init(id: "one", track: query, rawText: "fixture")]
    }
    func shutdown() { stops += 1 }
}
private actor Counter { var count = 0; func increment() { count += 1 } }
private func enabled(network: Bool = false) -> PluginPreference {
    PluginPreference(pluginID: testID, isEnabled: true, isLoadAllowed: true,
        grantedPermissions: network ? [.network] : [], acceptedPolicyVersion: network ? "1" : nil)
}
private func runtime(_ plugin: TestLyrics, network: Bool = false, counter: Counter? = nil, loadGate: Gate? = nil) -> PluginRuntime {
    PluginRuntime(registry: PluginRegistry([.init(descriptor: .init(id: testID, name: "Test", kinds: [.lyrics],
        permissions: network ? [.network] : []), lyrics: { _ in
        await counter?.increment(); await loadGate?.arrive(); return plugin
    })]))
}
private func query(_ runtime: PluginRuntime) async throws -> String {
    try await runtime.perform(pluginID: testID) { loaded, context in
        let lyrics = try #require(loaded.lyrics)
        return try await lyrics.candidates(for: .init(title: "Song", artist: "Artist"), context: context).first?.rawText ?? ""
    }
}

@Test func registrationIsLazyAndIsolatesBadEntries() async {
    let counter = Counter()
    let entry = BuiltInPluginRegistration(descriptor: .init(id: testID, name: "Test", kinds: [.lyrics]), lyrics: { _ in
        await counter.increment(); return TestLyrics()
    })
    let registry = PluginRegistry([entry, entry])
    #expect(registry.registrations.isEmpty)
    #expect(registry.unavailable[testID] == .invalidRegistration)
    #expect(await counter.count == 0)
    let incompatible = BuiltInPluginRegistration(descriptor: .init(id: testID, name: "Future", apiVersion: .init(major: 2), kinds: [.lyrics]), lyrics: entry.lyrics)
    #expect(PluginRegistry([incompatible]).unavailable[testID] == .incompatible)
    #expect(PluginRegistry([], compiledOut: [entry.descriptor]).unavailable[testID] == .compiledOut)
}
@Test func switchesAreIndependentAndHiddenCapabilityStillRuns() async throws {
    let plugin = TestLyrics(); let runtime = runtime(plugin)
    await #expect(throws: PluginError.disabled) { try await query(runtime) }
    var preference = enabled(); preference.isLoadAllowed = false
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    await #expect(throws: PluginError.loadBlocked) { try await query(runtime) }
    preference.isLoadAllowed = true; preference.isVisible = false
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await query(runtime) == "fixture")
    preference.isVisible = true
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    #expect(try await query(runtime) == "fixture")
    #expect(await plugin.stops == 0)
}
@Test func concurrentRequestsShareOneLoadAndKeepIndependentLeases() async throws {
    let counter = Counter(); let gate = Gate(); let runtime = runtime(TestLyrics(), counter: counter, loadGate: gate)
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    let first = Task { try await query(runtime) }
    await gate.waitFor(1)
    let second = Task { try await query(runtime) }
    await gate.release()
    #expect(try await first.value == "fixture")
    #expect(try await second.value == "fixture")
    #expect(await counter.count == 1)
}
@Test func privacyRevocationRejectsNonCooperativeLateResult() async throws {
    let gate = Gate(); let runtime = runtime(TestLyrics(gate: gate), network: true)
    await runtime.apply(preferences: [enabled(network: true)], applicationPrivacyAccepted: true)
    let request = Task { try await query(runtime) }
    await gate.waitFor(1)
    await runtime.apply(preferences: [enabled(network: true)], applicationPrivacyAccepted: false)
    await gate.release()
    await #expect(throws: (any Error).self) { try await request.value }
    await #expect(throws: PluginError.permissionRequired) { try await query(runtime) }
}
@Test func disablingDuringLoadDoesNotPublishInstance() async throws {
    let gate = Gate(); let runtime = runtime(TestLyrics(), loadGate: gate)
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    let request = Task { try await query(runtime) }
    await gate.waitFor(1)
    await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
    await gate.release()
    await #expect(throws: (any Error).self) { try await request.value }
    #expect(await runtime.snapshots().first?.state == .disabled)
}
@Test func callerCancellationRejectsLateResult() async throws {
    let gate = Gate(); let runtime = runtime(TestLyrics(gate: gate))
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    let request = Task { try await query(runtime) }
    await gate.waitFor(1); request.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await request.value }
}
@Test func schemaRejectsSecretsAndUnknownKeys() throws {
    let schema = PluginConfigurationSchema(fields: [.init(id: "password", title: "Password", kind: .secret, required: true)])
    #expect(throws: PluginError.invalidConfiguration) { try schema.validate(["password": .text("secret")], credentialRecordID: "ref") }
    #expect(throws: PluginError.invalidConfiguration) { try schema.validate([:], credentialRecordID: nil) }
    try schema.validate([:], credentialRecordID: "ref")
}
@Test func shutdownRejectsNewOperations() async throws {
    let runtime = runtime(TestLyrics())
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    #expect(try await query(runtime) == "fixture")
    await runtime.shutdown()
    await #expect(throws: PluginError.unavailable) { try await query(runtime) }
    #expect(await runtime.snapshots().first?.state == .unloaded)
}
@Test func missingPluginRemainsVisibleWithSavedConfiguration() async throws {
    let runtime = PluginRuntime(registry: PluginRegistry([]))
    let preference = PluginPreference(pluginID: testID, isEnabled: true, isLoadAllowed: true,
        configuration: ["saved": .text("value")])
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    let snapshot = try #require(await runtime.snapshots().first)
    #expect(snapshot.state == .compiledOut)
    #expect(snapshot.preference == preference)
    await #expect(throws: PluginError.unavailable) {
        try await runtime.perform(pluginID: testID, kind: .lyrics) { _, _ in true }
    }
}
private struct EmptyOnline: OnlineSourcePlugin {}
@Test func multiCapabilityLoadOnlyInstantiatesRequestedFactory() async throws {
    let sourceLoads = Counter()
    let runtime = PluginRuntime(registry: PluginRegistry([.init(descriptor: .init(id: testID, name: "Multiple", kinds: [.lyrics, .onlineSource],
        sourceConfiguration: .init(fields: [.init(id: "account", title: "Account", kind: .text, required: true)]), onlineProviderID: "multiple.source"),
        lyrics: { _ in TestLyrics() }, onlineSource: { _ in await sourceLoads.increment(); return EmptyOnline() })]))
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    await runtime.setAllowedSourceInstances([testID: []])
    let result = try await runtime.perform(pluginID: testID, kind: .lyrics) { loaded, _ in
        #expect(loaded.onlineSource == nil)
        return loaded.lyrics != nil
    }
    #expect(result); #expect(await sourceLoads.count == 0)
    await #expect(throws: PluginError.permissionRequired) {
        try await runtime.perform(pluginID: testID, configuration: .init(instanceID: "blocked"), kind: .onlineSource) { _, _ in true }
    }
}
@Test func differentCapabilitiesDoNotShareOneOperationGeneration() async throws {
    let runtime = runtime(TestLyrics())
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    let result = try await runtime.perform(pluginID: testID, kind: .lyrics) { _, context in context.generation }
    let second = try await runtime.perform(pluginID: testID, kind: .lyrics) { _, context in context.generation }
    #expect(result == second)
}
@Test func matchRequiresArtistDurationAndVersionEvidence() {
    let query = PluginTrackQuery(title: "Song (Live)", artist: "Artist", durationSeconds: 120)
    #expect(!query.matches(.init(title: "Song", artist: "Artist", durationSeconds: 120)))
    #expect(!query.matches(.init(title: "Song (Live)", artist: "Other", durationSeconds: 120)))
    #expect(!query.matches(.init(title: "Song (Live)", artist: "Artist", durationSeconds: 150)))
    #expect(query.matches(.init(title: "Song (Live)", artist: "Artist", durationSeconds: 120)))
}
private actor FixtureCredentials: PluginCredentialAccess {
    var reads = 0
    func read(recordID: String, pluginID: PluginID, instanceID: String) async throws -> Data? {
        reads += 1
        return Data("credential".utf8)
    }
}
@Test func credentialsAreScopedToDeclaredPermissionAccountAndRecord() async throws {
    let credentials = FixtureCredentials()
    let descriptor = PluginDescriptor(id: testID, name: "Credential Source", kinds: [.onlineSource],
        permissions: [.credentials], onlineProviderID: "credentials.source")
    let runtime = PluginRuntime(registry: PluginRegistry([.init(descriptor: descriptor, onlineSource: { context in
        let access = try #require(context.credentials)
        #expect(try await access.read(recordID: "record-a", pluginID: testID, instanceID: "account-a") == Data("credential".utf8))
        await #expect(throws: PluginError.permissionRequired) {
            try await access.read(recordID: "record-a", pluginID: testID, instanceID: "account-b")
        }
        await #expect(throws: PluginError.permissionRequired) {
            try await access.read(recordID: "record-b", pluginID: testID, instanceID: "account-a")
        }
        return EmptyOnline()
    })]), credentials: credentials)
    await runtime.apply(preferences: [.init(pluginID: testID, isEnabled: true, isLoadAllowed: true,
        grantedPermissions: [.credentials], acceptedPolicyVersion: "1")], applicationPrivacyAccepted: false)
    await runtime.setAllowedSourceInstances([testID: ["account-a"]])
    #expect(try await runtime.perform(pluginID: testID, configuration: .init(instanceID: "account-a", credentialRecordID: "record-a"),
        kind: .onlineSource) { loaded, _ in loaded.onlineSource != nil })
    #expect(await credentials.reads == 1)
}

@Test func futureConfigurationAndPermissionRoundTripWithoutLosingSettings() throws {
    let data = Data(#"{"pluginID":"future.plugin","isVisible":true,"isEnabled":false,"isLoadAllowed":false,"configuration":{"x":{"futureCase":{"_0":[1,"two",null]}}},"grantedPermissions":["futurePermission"],"schemaVersion":2,"instances":[]}"#.utf8)
    let preference = try JSONDecoder().decode(PluginPreference.self, from: data)
    #expect(preference.grantedPermissions.contains(.init(rawValue: "futurePermission")))
    let encoded = try JSONEncoder().encode(preference)
    #expect(try JSONDecoder().decode(PluginPreference.self, from: encoded) == preference)
    for value in [PluginConfigurationValue.text("a"), .number(2.5), .flag(true)] {
        #expect(try JSONDecoder().decode(PluginConfigurationValue.self, from: JSONEncoder().encode(value)) == value)
    }
}
@Test func numericLimitsRejectInvalidConfiguration() throws {
    let schema = PluginConfigurationSchema(fields: [.init(id: "gain", title: "Gain", kind: .number, minimumNumber: 0, maximumNumber: 4)])
    try schema.validate(["gain": .number(4)], credentialRecordID: nil)
    for value in [-0.1, 4.1, Double.infinity] {
        #expect(throws: PluginError.invalidConfiguration) { try schema.validate(["gain": .number(value)], credentialRecordID: nil) }
    }
}
@Test func invalidConfigurationHasDiagnosticInsteadOfPermissionPrompt() async {
    let descriptor = PluginDescriptor(id: testID, name: "Test", kinds: [.lyrics],
        configuration: .init(fields: [.init(id: "gain", title: "Gain", kind: .number, minimumNumber: 0, maximumNumber: 4)]))
    let runtime = PluginRuntime(registry: PluginRegistry([.init(descriptor: descriptor, lyrics: { _ in TestLyrics() })]))
    var preference = PluginPreference(pluginID: testID)
    preference.isEnabled = true; preference.isLoadAllowed = true; preference.configuration = ["gain": .number(99)]
    await runtime.apply(preferences: [preference], applicationPrivacyAccepted: false)
    let snapshots = await runtime.snapshots()
    #expect(snapshots.first?.state == .failed)
    #expect(snapshots.first?.diagnostic == "invalidConfiguration")
}

@Test func factoryFailureExposesSafeDiagnostic() async throws {
    struct PrivateFactoryError: Error {}
    let counter = Counter()
    let runtime = PluginRuntime(registry: PluginRegistry([.init(
        descriptor: .init(id: testID, name: "Test", kinds: [.lyrics]),
        lyrics: { _ in
            await counter.increment()
            if await counter.count == 1 { throw PrivateFactoryError() }
            return TestLyrics()
        })]))
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    await #expect(throws: PrivateFactoryError.self) { try await query(runtime) }
    let snapshot = await runtime.snapshots().first
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.diagnostic == "requestFailed(code: \"plugin_load_failed\")")
    #expect(try await query(runtime) == "fixture")
    let recovered = await runtime.snapshots().first
    #expect(recovered?.state == .ready)
    #expect(recovered?.diagnostic == nil)
}

@Test func combinedAuthorizationRevokesOnlyRemovedSourceAndRejectsItsLateResult() async throws {
    let gate = Gate()
    let runtime = PluginRuntime(registry: PluginRegistry([.init(
        descriptor: .init(id: testID, name: "Accounts", kinds: [.onlineSource], onlineProviderID: "test.accounts"), onlineSource: { _ in EmptyOnline() })]))
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false,
        allowedSourceInstances: [testID: ["a", "b"]])
    let pending = Task {
        try await runtime.perform(pluginID: testID, configuration: .init(instanceID: "a"), kind: .onlineSource) { _, _ in
            await gate.arrive(); return "late result"
        }
    }
    defer { pending.cancel(); Task { await gate.release() } }
    for _ in 0..<100 {
        if await gate.arrivalCount > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await gate.arrivalCount == 1)
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false,
        allowedSourceInstances: [testID: ["b"]])
    await gate.release()
    await #expect(throws: (any Error).self) { try await pending.value }
    await #expect(throws: PluginError.permissionRequired) {
        try await runtime.perform(pluginID: testID, configuration: .init(instanceID: "a"), kind: .onlineSource) { _, _ in true }
    }
    #expect(try await runtime.perform(pluginID: testID, configuration: .init(instanceID: "b"), kind: .onlineSource) { _, _ in true })
}

@Test func revokedOperationDiscardsOwnedLateResult() async throws {
    let gate = Gate(), discarded = Counter(), runtime = runtime(TestLyrics())
    await runtime.apply(preferences: [enabled()], applicationPrivacyAccepted: false)
    let request = Task {
        try await runtime.perform(pluginID: testID, discardResult: { (value: Int) in
            #expect(value == 42); await discarded.increment()
        }) { _, _ in await gate.arrive(); return 42 }
    }
    defer { request.cancel(); Task { await gate.release() } }
    await gate.waitFor(1)
    await runtime.apply(preferences: [], applicationPrivacyAccepted: false)
    await gate.release()
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(await discarded.count == 1)
}
