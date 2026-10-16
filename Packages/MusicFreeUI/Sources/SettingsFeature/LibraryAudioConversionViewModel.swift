import Foundation
import AppServices
import DesignSystem
import MediaSourceAPI
import Observation

@MainActor
@Observable
final class LibraryAudioConversionViewModel {
    let service: any LibraryConversionServing
    let scope: LibraryConversionScope

    var target: AudioConversionTarget
    private(set) var preflight: LibraryConversionPreflight?
    private(set) var batches: [LibraryConversionBatchSnapshot] = []
    private(set) var isPreflighting = false
    private(set) var isStarting = false
    private(set) var failureMessage: String?
    var isStartConfirmationPresented = false

    init(
        service: any LibraryConversionServing,
        scope: LibraryConversionScope,
        initialTarget: AudioConversionTarget
    ) {
        self.service = service
        self.scope = scope
        target = initialTarget
    }

    func setTarget(_ value: AudioConversionTarget) {
        guard target != value else { return }
        target = value
        preflight = nil
        failureMessage = nil
    }

    func observe() async {
        batches = await service.snapshots()
        let stream = await service.makeEventStream()
        for await event in stream {
            guard !Task.isCancelled else { return }
            switch event {
            case .updated(let snapshot):
                upsert(snapshot)
            }
        }
    }

    func runPreflight() async {
        guard !isPreflighting, !isStarting else { return }
        isPreflighting = true
        failureMessage = nil
        defer { isPreflighting = false }
        do {
            preflight = try await service.preflight(scope: scope, target: target)
        } catch is CancellationError {
            return
        } catch {
            failureMessage = L(error.localizedDescription)
        }
    }

    func requestStart() {
        guard preflight?.eligibleAssetCount ?? 0 > 0 else { return }
        isStartConfirmationPresented = true
    }

    func startConversion() async {
        guard !isStarting, preflight?.eligibleAssetCount ?? 0 > 0 else { return }
        isStarting = true
        failureMessage = nil
        defer { isStarting = false }
        do {
            let id = try await service.start(scope: scope, target: target)
            if let snapshot = await service.snapshot(id: id) {
                upsert(snapshot)
            }
            preflight = nil
        } catch is CancellationError {
            return
        } catch {
            failureMessage = L(error.localizedDescription)
        }
    }

    func pause(_ id: UUID) async {
        await service.pause(id: id)
        await refresh(id)
    }

    func resume(_ id: UUID) async {
        await service.resume(id: id)
        await refresh(id)
    }

    func cancel(_ id: UUID) async {
        await service.cancel(id: id)
        await refresh(id)
    }

    func retryFailures(_ id: UUID) async {
        failureMessage = nil
        do {
            let retryID = try await service.retryFailures(id: id)
            if let snapshot = await service.snapshot(id: retryID) {
                upsert(snapshot)
            }
        } catch is CancellationError {
            return
        } catch {
            failureMessage = L(error.localizedDescription)
        }
    }

    private func refresh(_ id: UUID) async {
        if let snapshot = await service.snapshot(id: id) {
            upsert(snapshot)
        }
    }

    private func upsert(_ snapshot: LibraryConversionBatchSnapshot) {
        if let index = batches.firstIndex(where: { $0.id == snapshot.id }) {
            batches[index] = snapshot
        } else {
            batches.append(snapshot)
        }
        batches.sort { $0.createdAt > $1.createdAt }
    }
}
