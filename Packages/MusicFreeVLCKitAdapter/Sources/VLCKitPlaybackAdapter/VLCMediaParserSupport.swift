import Foundation
import MusicDomain

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

private final class VLCMediaParserDiagnostics: @unchecked Sendable {
  static let shared = VLCMediaParserDiagnostics()

  private let lock = NSLock()
  private var seenLibraries: Set<ObjectIdentifier> = []

  private init() {}

  func makeTransaction(for library: VLCLibrary) -> (id: UUID, isFirstRequest: Bool) {
    lock.lock()
    let isFirstRequest = seenLibraries.insert(ObjectIdentifier(library)).inserted
    lock.unlock()
    return (UUID(), isFirstRequest)
  }
}

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
  private static let logger = MusicLogger(
    subsystem: "com.musicfree.app",
    category: "vlc-media-parser"
  )

  private let parser: VLCMediaParser
  private let media: VLCMedia
  private lazy var bridge = VLCMediaParserBridge { [weak self] status in
    self?.finish(status: status)
  }
  private let timeoutMilliseconds: UInt64
  private let state = VLCMediaParseWaiterState()
  private let transactionID: UUID
  private let isFirstLibraryRequest: Bool
  private let startedAtNanoseconds: UInt64

  init(
    parser: VLCMediaParser,
    media: VLCMedia,
    library: VLCLibrary,
    timeoutMilliseconds: UInt64
  ) {
    self.parser = parser
    self.media = media
    self.timeoutMilliseconds = timeoutMilliseconds
    let transaction = VLCMediaParserDiagnostics.shared.makeTransaction(for: library)
    self.transactionID = transaction.id
    self.isFirstLibraryRequest = transaction.isFirstRequest
    self.startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds
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

    Self.logger.info(
      "parser queue starting transaction=\(self.transactionID.uuidString) firstLibraryRequest=\(self.isFirstLibraryRequest) timeoutMs=\(self.timeoutMilliseconds)"
    )
    parser.delegate = bridge
    let result = parser.queue(media, options: VLCMediaParsingOptions(rawValue: 1))
    Self.logger.info(
      "parser queue returned transaction=\(self.transactionID.uuidString) result=\(result) elapsedMs=\(self.elapsedMilliseconds)"
    )
    let shouldCancel = state.endParserStart(succeeded: result == 0)
    guard result == 0 else {
      Self.logger.error(
        "parser queue failed transaction=\(self.transactionID.uuidString) result=\(result) firstLibraryRequest=\(self.isFirstLibraryRequest)"
      )
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
    Self.logger.warning(
      "parser cancellation requested transaction=\(self.transactionID.uuidString) elapsedMs=\(self.elapsedMilliseconds)"
    )
    let shouldCancelParser = state.requestCancellation()
    finish(error: VLCKitAdapterError.cancelled)
    if shouldCancelParser {
      parser.cancelParsing(for: media)
    }
  }

  private func finish(status: Int) {
    Self.logger.info(
      "parser callback transaction=\(self.transactionID.uuidString) rawStatus=\(status) elapsedMs=\(self.elapsedMilliseconds) firstLibraryRequest=\(self.isFirstLibraryRequest)"
    )
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

    switch result {
    case .success(let status):
      Self.logger.info(
        "parser completed transaction=\(self.transactionID.uuidString) rawStatus=\(status) elapsedMs=\(self.elapsedMilliseconds)"
      )
    case .failure(let error):
      Self.logger.error(
        "parser completed transaction=\(self.transactionID.uuidString) error=\(String(describing: error)) elapsedMs=\(self.elapsedMilliseconds)"
      )
    }
    parser.delegate = nil
    completion.timeoutTask?.cancel()
    completion.continuation?.resume(with: result)
  }

  private var elapsedMilliseconds: UInt64 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now >= startedAtNanoseconds else { return 0 }
    return (now - startedAtNanoseconds) / 1_000_000
  }
}
#endif
