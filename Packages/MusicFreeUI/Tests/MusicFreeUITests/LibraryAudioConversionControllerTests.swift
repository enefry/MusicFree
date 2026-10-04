@testable import SettingsFeature
import AppServices
import Foundation
import MediaSourceAPI
import MusicDomain
import Testing
import UIKit

private actor ConversionSceneService: LibraryConversionServing {
    var analyzed: LibraryConversionScope?
    var analyzedTarget: AudioConversionTarget?
    var starts = 0
    let batchID = UUID()
    var batchState: LibraryConversionBatchState = .running
    func preflight(scope: LibraryConversionScope, target: AudioConversionTarget) -> LibraryConversionPreflight {
        analyzed = scope; analyzedTarget = target
        return .init(scope: scope, target: target, candidates: [
            .init(assetID: .init(sourceID: .init("local"), externalID: "asset"), itemIDs: [.init(sourceID: .init("local"), externalID: "selected")], sourceByteCount: 1000)
        ])
    }
    func start(scope: LibraryConversionScope, target: AudioConversionTarget) -> UUID { starts += 1; return batchID }
    func snapshots() -> [LibraryConversionBatchSnapshot] { [] }
    func snapshot(id: UUID) -> LibraryConversionBatchSnapshot? {
        .init(id: id, scope: .allLocalMedia, target: .alac, state: batchState, totalAssetCount: 1)
    }
    func pause(id: UUID) { batchState = .paused }
    func resume(id: UUID) { batchState = .running }
    func cancel(id: UUID) { batchState = .cancelled }
    func retryFailures(id: UUID) -> UUID { batchID }
    func makeEventStream() -> AsyncStream<LibraryConversionEvent> { AsyncStream { $0.finish() } }
}

@Test @MainActor func nativeConversionAnalyzesSelectedScopeAndRequiresConfirmation() async throws {
    let service = ConversionSceneService()
    let scope = LibraryConversionScope.items([.init(sourceID: .init("local"), externalID: "selected")])
    let controller = LibraryAudioConversionViewController(service: service, scope: scope, initialTarget: .alac)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil }
    controller.loadViewIfNeeded()
    controller.tableView(controller.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
    for _ in 0..<100 {
        if controller.numberOfSections(in: controller.tableView) > 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await service.analyzed == scope)
    #expect(await service.analyzedTarget == .alac)
    try #require(controller.numberOfSections(in: controller.tableView) == 2)
    let start = IndexPath(row: controller.tableView(controller.tableView, numberOfRowsInSection: 1) - 1, section: 1)
    #expect(controller.tableView(controller.tableView, cellForRowAt: start).isUserInteractionEnabled)
    controller.tableView(controller.tableView, didSelectRowAt: start)
    #expect(controller.presentedViewController is UIAlertController)
    #expect(await service.starts == 0)
    controller.dismiss(animated: false)
}
