import Foundation

/// Describes a known speaker layout and its channel count.
public struct ChannelLayout: Codable, Equatable, Hashable, Sendable {
    public let channelCount: Int
    public let name: String?

    /// Creates a layout. The name is descriptive metadata, not a decoder hint.
    public init(channelCount: Int, name: String? = nil) {
        self.channelCount = musicDomainPositive(channelCount, field: "channelCount")
        self.name = musicDomainOptionalText(name)
    }

    public static let mono = Self(channelCount: 1, name: "mono")
    public static let stereo = Self(channelCount: 2, name: "stereo")
    public static let fivePointOne = Self(channelCount: 6, name: "5.1")
    public static let sevenPointOne = Self(channelCount: 8, name: "7.1")

    private enum CodingKeys: String, CodingKey {
        case channelCount
        case name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let channelCount = try container.decode(Int.self, forKey: .channelCount)
        guard channelCount > 0 else {
            throw musicDomainDecodingFailure(decoder, field: "ChannelLayout.channelCount")
        }
        self.init(
            channelCount: channelCount,
            name: try container.decodeIfPresent(String.self, forKey: .name)
        )
    }
}

/// Technical information reported for one audio stream.
public struct AudioStreamInfo: Codable, Equatable, Hashable, Sendable {
    public let codec: String?
    /// Sample rate in hertz. `nil` means the source did not report it.
    public let sampleRate: Int?
    /// Sample depth in bits. `nil` means the source did not report it.
    public let bitDepth: Int?
    /// Number of channels. `nil` means the source did not report it.
    public let channels: Int?
    public let channelLayout: ChannelLayout?
    /// Bit rate in bits per second. `nil` means the source did not report it.
    public let bitRate: Int?

    /// Creates a stream description without inferring values from a file extension.
    public init(
        codec: String? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        channels: Int? = nil,
        channelLayout: ChannelLayout? = nil,
        bitRate: Int? = nil
    ) {
        if let sampleRate {
            _ = musicDomainPositive(sampleRate, field: "sampleRate")
        }
        if let bitDepth {
            _ = musicDomainPositive(bitDepth, field: "bitDepth")
        }
        if let channels {
            _ = musicDomainPositive(channels, field: "channels")
        }
        if let bitRate {
            _ = musicDomainPositive(bitRate, field: "bitRate")
        }
        if let channels, let channelLayout {
            precondition(
                channels == channelLayout.channelCount,
                "AudioStreamInfo channel count must match its layout"
            )
        }

        self.codec = musicDomainOptionalText(codec)
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.channelLayout = channelLayout
        self.bitRate = bitRate
    }

    public var sampleRateHz: Int? {
        sampleRate
    }

    public var channelCount: Int? {
        channels
    }

    public var bitRateBitsPerSecond: Int? {
        bitRate
    }

    private enum CodingKeys: String, CodingKey {
        case codec
        case sampleRate
        case bitDepth
        case channels
        case channelLayout
        case bitRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sampleRate = try container.decodeIfPresent(Int.self, forKey: .sampleRate)
        let bitDepth = try container.decodeIfPresent(Int.self, forKey: .bitDepth)
        let channels = try container.decodeIfPresent(Int.self, forKey: .channels)
        let channelLayout = try container.decodeIfPresent(ChannelLayout.self, forKey: .channelLayout)
        let bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate)

        guard sampleRate == nil || sampleRate! > 0,
              bitDepth == nil || bitDepth! > 0,
              channels == nil || channels! > 0,
              bitRate == nil || bitRate! > 0
        else {
            throw musicDomainDecodingFailure(decoder, field: "AudioStreamInfo")
        }
        if let channels, let channelLayout, channels != channelLayout.channelCount {
            throw musicDomainDecodingFailure(decoder, field: "AudioStreamInfo.channelLayout")
        }

        self.init(
            codec: try container.decodeIfPresent(String.self, forKey: .codec),
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            channels: channels,
            channelLayout: channelLayout,
            bitRate: bitRate
        )
    }
}

/// Technical information reported by a media probe.
@available(macOS 13.0, *)
public struct MediaTechnicalInfo: Codable, Equatable, Hashable, Sendable {
    public let container: String?
    /// The reported primary codec summary, if available.
    public let codec: String?
    /// Duration reported by the media source; unknown duration is `nil`.
    public let duration: Duration?
    public let audioStreams: [AudioStreamInfo]
    /// Aggregate bit rate in bits per second, if reported.
    public let bitRate: Int?
    /// File size in bytes, when the local source can report it.
    public let fileSizeBytes: Int64?

    /// Creates technical metadata. No value is derived from a filename extension.
    public init(
        container: String? = nil,
        codec: String? = nil,
        duration: Duration? = nil,
        audioStreams: [AudioStreamInfo] = [],
        bitRate: Int? = nil,
        fileSizeBytes: Int64? = nil
    ) {
        if let duration {
            _ = musicDomainNonNegativeDuration(duration, field: "duration")
        }
        if let bitRate {
            _ = musicDomainPositive(bitRate, field: "bitRate")
        }
        if let fileSizeBytes {
            precondition(fileSizeBytes >= 0, "MusicDomain fileSizeBytes cannot be negative")
        }

        self.container = musicDomainOptionalText(container)
        self.codec = musicDomainOptionalText(codec)
        self.duration = duration
        self.audioStreams = audioStreams
        self.bitRate = bitRate
        self.fileSizeBytes = fileSizeBytes
    }

    public var primaryAudioStream: AudioStreamInfo? {
        audioStreams.first
    }

    public var sampleRate: Int? {
        primaryAudioStream?.sampleRate
    }

    public var channels: Int? {
        primaryAudioStream?.channels
    }

    public var bitDepth: Int? {
        primaryAudioStream?.bitDepth
    }

    private enum CodingKeys: String, CodingKey {
        case container
        case codec
        case duration
        case audioStreams
        case bitRate
        case fileSizeBytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let duration = try container.decodeIfPresent(Duration.self, forKey: .duration)
        let bitRate = try container.decodeIfPresent(Int.self, forKey: .bitRate)
        let fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        guard duration == nil || duration! >= .zero,
              bitRate == nil || bitRate! > 0,
              fileSizeBytes == nil || fileSizeBytes! >= 0
        else {
            throw musicDomainDecodingFailure(decoder, field: "MediaTechnicalInfo")
        }
        self.init(
            container: try container.decodeIfPresent(String.self, forKey: .container),
            codec: try container.decodeIfPresent(String.self, forKey: .codec),
            duration: duration,
            audioStreams: try container.decodeIfPresent([AudioStreamInfo].self, forKey: .audioStreams) ?? [],
            bitRate: bitRate,
            fileSizeBytes: fileSizeBytes
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(codec, forKey: .codec)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(audioStreams, forKey: .audioStreams)
        try container.encodeIfPresent(bitRate, forKey: .bitRate)
        try container.encodeIfPresent(fileSizeBytes, forKey: .fileSizeBytes)
    }
}
