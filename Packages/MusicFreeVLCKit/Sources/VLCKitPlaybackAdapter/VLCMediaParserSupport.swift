import Foundation

#if canImport(VLCKit)
import VLCKit

internal final class VLCMediaParserBridge: NSObject, VLCMediaParserDelegate {
  private let completion: @Sendable (Int) -> Void

  init(completion: @escaping @Sendable (Int) -> Void) {
    self.completion = completion
    super.init()
  }

  func mediaFinishedParsing(_ media: VLCMedia, with status: VLCMediaParsedStatus) {
    completion(Int(status.rawValue))
  }
}

/// Keeps the parser, media, and weak Objective-C delegate alive for one
/// cancellable parse transaction. A lock protects the single-resume gate
/// shared by the delegate, timeout task, and cancellation handler.
internal final class VLCMediaParseWaiter: @unchecked Sendable {
  private let parser: VLCMediaParser
  private let media: VLCMedia
  private lazy var bridge = VLCMediaParserBridge { [weak self] status in
    self?.finish(status: status)
  }
  private let timeoutMilliseconds: UInt64
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Int, Error>?
  private var timeoutTask: Task<Void, Never>?
  private var didFinish = false

  init(parser: VLCMediaParser, media: VLCMedia, timeoutMilliseconds: UInt64) {
    self.parser = parser
    self.media = media
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  func wait() async throws -> Int {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        parser.delegate = bridge
        let result = parser.queue(media, options: VLCMediaParsingOptions(rawValue: 1))
        guard result == 0 else {
          finish(error: VLCKitAdapterError.parserFailed)
          return
        }

        let timeoutMilliseconds = self.timeoutMilliseconds
        timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(nanoseconds: timeoutMilliseconds * 1_000_000)
            self?.finish(error: VLCKitAdapterError.parserTimedOut)
          } catch {
            // Cancellation is the normal cleanup path after a parse finishes.
          }
        }
      }
    }, onCancel: { [weak self] in
      self?.cancel()
    })
  }

  private func cancel() {
    parser.cancelParsing(for: media)
    finish(error: VLCKitAdapterError.cancelled)
  }

  private func finish(status: Int) {
    switch status {
    case 6:
      finish(result: status)
    case 4:
      finish(error: VLCKitAdapterError.parserTimedOut)
    case 5:
      finish(error: VLCKitAdapterError.cancelled)
    default:
      finish(error: VLCKitAdapterError.parserFailed)
    }
  }

  private func finish(result: Int) {
    complete(.success(result))
  }

  private func finish(error: Error) {
    complete(.failure(error))
  }

  private func complete(_ result: Result<Int, Error>) {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return
    }
    didFinish = true
    let continuation = self.continuation
    self.continuation = nil
    let timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()

    parser.delegate = nil
    timeoutTask?.cancel()
    continuation?.resume(with: result)
  }
}
#endif
