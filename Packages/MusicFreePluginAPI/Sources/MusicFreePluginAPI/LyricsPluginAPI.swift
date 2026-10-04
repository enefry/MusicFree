import Foundation

public struct PluginLyricWord: Hashable, Sendable {
    public let startMilliseconds: Int64
    public let durationMilliseconds: Int64
    public let text: String
    public init(startMilliseconds: Int64, durationMilliseconds: Int64, text: String) {
        self.startMilliseconds = startMilliseconds; self.durationMilliseconds = durationMilliseconds; self.text = text
    }
}
public struct PluginLyricLine: Hashable, Sendable {
    public let startMilliseconds: Int64
    public let text: String
    public let translation: String?
    public let words: [PluginLyricWord]
    public init(startMilliseconds: Int64, text: String, translation: String? = nil, words: [PluginLyricWord] = []) {
        self.startMilliseconds = startMilliseconds; self.text = text; self.translation = translation; self.words = words
    }
}
public struct PluginLyricsCandidate: Sendable {
    public let id: String
    public let track: PluginTrackQuery
    public let rawText: String
    public let lines: [PluginLyricLine]
    public init(id: String, track: PluginTrackQuery, rawText: String, lines: [PluginLyricLine] = []) {
        self.id = id; self.track = track; self.rawText = rawText; self.lines = lines
    }
}
public protocol LyricsPlugin: PluginInstance {
    func candidates(for query: PluginTrackQuery, context: PluginOperationContext) async throws -> [PluginLyricsCandidate]
}
public typealias LyricsPluginFactory = @Sendable (PluginLoadContext) async throws -> any LyricsPlugin
