import Foundation
import SystemIntegrationAPI

/// Owns one in-flight artwork request and rejects results belonging to an
/// older publication. Artwork loading remains outside the MediaPlayer wrapper.
@MainActor
final class NowPlayingArtworkProvider {
    typealias Delivery = @MainActor @Sendable (Data?) -> Void

    private var task: Task<Void, Never>?
    private var requestKey: String?
    private var requestSerial: UInt64 = 0

    func request(
        _ reference: NowPlayingArtworkReference,
        deliver: @escaping Delivery
    ) {
        let key = reference.artworkID?.rawValue
        if let key, key == requestKey, task != nil {
            return
        }

        cancel()
        guard let provider = reference.provider else { return }

        requestSerial &+= 1
        let serial = requestSerial
        requestKey = key
        task = Task { @MainActor [weak self, provider] in
            let data: Data?
            do {
                data = try await provider.artworkData()
            } catch {
                data = nil
            }

            guard !Task.isCancelled,
                  let self,
                  self.requestSerial == serial
            else {
                return
            }

            self.task = nil
            self.requestKey = nil
            deliver(data)
        }
    }

    func cancel() {
        requestSerial &+= 1
        task?.cancel()
        task = nil
        requestKey = nil
    }
}
