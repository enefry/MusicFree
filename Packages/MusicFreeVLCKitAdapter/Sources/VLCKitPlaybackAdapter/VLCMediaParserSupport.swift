import Foundation

internal enum VLCMediaParseWaiterRegistration {
  case start
  case resume(Result<Int, Error>)
}

/// Serializes the continuation, parser-start, cancellation, and timeout races
/// that can happen before VLCKit's delegate callback is delivered.
internal final class VLCMediaParseWaiterState: @unchecked Sendable {
  typealias Completion = (
    continuation: CheckedContinuation<Int, Error>?,
    timeoutTask: Task<Void, Never>?
  )

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Int, Error>?
  private var pendingResult: Result<Int, Error>?
  private var timeoutTask: Task<Void, Never>?
  private var didFinish = false
  private var parserStartInProgress = false
  private var parserStarted = false
  private var cancellationRequested = false

  func register(
    _ continuation: CheckedContinuation<Int, Error>
  ) -> VLCMediaParseWaiterRegistration {
    lock.lock()
    if didFinish {
      let result = pendingResult ?? .failure(VLCKitAdapterError.cancelled)
      pendingResult = nil
      lock.unlock()
      return .resume(result)
    }
    self.continuation = continuation
    lock.unlock()
    return .start
  }

  func complete(_ result: Result<Int, Error>) -> Completion? {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return nil
    }
    didFinish = true
    let continuation = self.continuation
    self.continuation = nil
    if continuation == nil {
      pendingResult = result
    }
    let timeoutTask = self.timeoutTask
    self.timeoutTask = nil
    lock.unlock()
    return (continuation, timeoutTask)
  }

  func beginParserStart() -> Bool {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return false
    }
    parserStartInProgress = true
    lock.unlock()
    return true
  }

  func endParserStart(succeeded: Bool) -> Bool {
    lock.lock()
    parserStartInProgress = false
    if succeeded {
      parserStarted = true
    }
    let shouldCancel = succeeded && cancellationRequested
    lock.unlock()
    return shouldCancel
  }

  func requestCancellation() -> Bool {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return false
    }
    cancellationRequested = true
    let shouldCancelParser = parserStarted && !parserStartInProgress
    lock.unlock()
    return shouldCancelParser
  }

  func installTimeoutTask(_ task: Task<Void, Never>) -> Bool {
    lock.lock()
    guard !didFinish else {
      lock.unlock()
      return false
    }
    timeoutTask = task
    lock.unlock()
    return true
  }
}

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
/// cancellable parse transaction. The state object protects the single-resume
/// gate shared by the delegate, timeout task, and cancellation handler.
internal final class VLCMediaParseWaiter: @unchecked Sendable {
  private let parser: VLCMediaParser
  private let media: VLCMedia
  private lazy var bridge = VLCMediaParserBridge { [weak self] status in
    self?.finish(status: status)
  }
  private let timeoutMilliseconds: UInt64
  private let state = VLCMediaParseWaiterState()

  init(parser: VLCMediaParser, media: VLCMedia, timeoutMilliseconds: UInt64) {
    self.parser = parser
    self.media = media
    self.timeoutMilliseconds = timeoutMilliseconds
  }

  func wait() async throws -> Int {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
        switch state.register(continuation) {
        case .resume(let result):
          continuation.resume(with: result)
        case .start:
          startParsing()
        }
      }
    }, onCancel: { [weak self] in
      self?.cancel()
    })
  }

  private func startParsing() {
    guard state.beginParserStart() else { return }

    parser.delegate = bridge
    let result = parser.queue(media, options: VLCMediaParsingOptions(rawValue: 1))
    let shouldCancel = state.endParserStart(succeeded: result == 0)
    guard result == 0 else {
      finish(error: VLCKitAdapterError.parserFailed)
      return
    }

    if shouldCancel {
      parser.cancelParsing(for: media)
    }

    let timeoutMilliseconds = self.timeoutMilliseconds
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: timeoutMilliseconds * 1_000_000)
        self?.finish(error: VLCKitAdapterError.parserTimedOut)
      } catch {
        // Cancellation is the normal cleanup path after a parse finishes.
      }
    }
    if !state.installTimeoutTask(timeoutTask) {
      timeoutTask.cancel()
    }
  }

  private func cancel() {
    let shouldCancelParser = state.requestCancellation()
    finish(error: VLCKitAdapterError.cancelled)
    if shouldCancelParser {
      parser.cancelParsing(for: media)
    }
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
    guard let completion = state.complete(result) else { return }

    parser.delegate = nil
    completion.timeoutTask?.cancel()
    completion.continuation?.resume(with: result)
  }
}
#endif
