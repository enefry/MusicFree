import Foundation

/// AAC-LC target bit rates supported by the application.
public enum AACLCBitRate: Int, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case kbps320 = 320_000
    case kbps256 = 256_000
    case kbps192 = 192_000
    case kbps160 = 160_000
    case kbps128 = 128_000

    public var kilobitsPerSecond: Int { rawValue / 1_000 }
}

/// Audio encoding selected for a conversion task.
public enum AudioConversionTarget: Codable, Equatable, Hashable, Sendable {
    case alac
    case aacLC(AACLCBitRate)

    public static let defaultAAC = Self.aacLC(.kbps256)

    private enum CodingKeys: String, CodingKey {
        case codec
        case bitRate
    }

    private enum Codec: String, Codable {
        case alac
        case aacLC
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Codec.self, forKey: .codec) {
        case .alac:
            self = .alac
        case .aacLC:
            self = .aacLC(try container.decode(AACLCBitRate.self, forKey: .bitRate))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .alac:
            try container.encode(Codec.alac, forKey: .codec)
        case .aacLC(let bitRate):
            try container.encode(Codec.aacLC, forKey: .codec)
            try container.encode(bitRate, forKey: .bitRate)
        }
    }
}

/// Valid global conversion worker limits exposed in Settings.
public enum MediaConversionConcurrency: Int, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4

    public static let `default` = Self.two
}

/// A fixed import-time conversion snapshot. A nil policy preserves the input.
public struct AudioImportConversionPolicy: Codable, Equatable, Hashable, Sendable {
    public let target: AudioConversionTarget

    public init(target: AudioConversionTarget) {
        self.target = target
    }
}

public enum MediaTranscodeStage: String, Codable, Equatable, Hashable, Sendable {
    case waiting
    case decoding
    case encoding
    case finalizing
    case validating
}

public struct MediaTranscodeProgress: Codable, Equatable, Sendable {
    public let stage: MediaTranscodeStage
    public let completedFrames: Int64
    public let totalFrames: Int64?

    public init(
        stage: MediaTranscodeStage,
        completedFrames: Int64 = 0,
        totalFrames: Int64? = nil
    ) {
        self.stage = stage
        self.completedFrames = max(0, completedFrames)
        self.totalFrames = totalFrames.flatMap { $0 > 0 ? $0 : nil }
    }

    public var fractionCompleted: Double? {
        guard let totalFrames else { return nil }
        return min(1, Double(completedFrames) / Double(totalFrames))
    }
}

public struct MediaTranscodeRequest: Sendable {
    public let inputURL: URL
    public let outputURL: URL
    public let target: AudioConversionTarget
    public let sourceTrack: ProbedAudioTrack
    public let sourceDuration: Duration?

    public init(
        inputURL: URL,
        outputURL: URL,
        target: AudioConversionTarget,
        sourceTrack: ProbedAudioTrack,
        sourceDuration: Duration? = nil
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.target = target
        self.sourceTrack = sourceTrack
        self.sourceDuration = sourceDuration
    }
}

public struct MediaTranscodeResult: Equatable, Sendable {
    public let outputURL: URL
    public let target: AudioConversionTarget
    public let processedFrames: Int64
    public let sampleRate: Double
    public let channelCount: Int
    public let bitDepth: Int?

    public init(
        outputURL: URL,
        target: AudioConversionTarget,
        processedFrames: Int64,
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int? = nil
    ) {
        self.outputURL = outputURL
        self.target = target
        self.processedFrames = max(0, processedFrames)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
    }
}

public enum MediaTranscodeError: String, Error, Codable, Equatable, Sendable {
    case unsupportedInput
    case unsupportedChannelCount
    case unsupportedBitDepth
    case invalidOutput
    case decoderFailed
    case encoderUnavailable
    case encoderFailed
    case validationFailed
}

public protocol MediaTranscoding: Sendable {
    func transcode(
        _ request: MediaTranscodeRequest,
        progress: @escaping @Sendable (MediaTranscodeProgress) -> Void
    ) async throws -> MediaTranscodeResult
}

/// Verifies that a lossless transcode decodes to the same integer PCM samples.
public protocol MediaLosslessValidating: Sendable {
    func validateLosslessPCM(inputURL: URL, outputURL: URL) async throws
}

/// One application-wide bounded queue shared by import and library conversion.
public protocol MediaConversionScheduling: Sendable {
    func updateMaximumConcurrency(_ maximum: MediaConversionConcurrency) async

    func updateApplicationInBackground(_ isInBackground: Bool) async

    func updatePlaybackIsPlaying(_ isPlaying: Bool) async

    func schedule(
        _ operation: @escaping @Sendable () async throws -> MediaTranscodeResult
    ) async throws -> MediaTranscodeResult
}

extension MediaConversionScheduling {
    public func updateApplicationInBackground(_ isInBackground: Bool) async {}

    public func updatePlaybackIsPlaying(_ isPlaying: Bool) async {}
}

public enum MediaConversionExecution {
    @TaskLocal public static var checkpoint: (@Sendable () async throws -> Void)?

    public static func waitUntilRunnable() async throws {
        try Task.checkCancellation()
        try await checkpoint?()
        try Task.checkCancellation()
    }
}
