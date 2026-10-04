import Foundation
import PlaybackAPI
import SettingsAPI
import Testing

// Kept in the isolated transition target to make this phase independently verifiable.
@Suite struct PlaybackTransitionPreferencesTests {
    @Test(arguments: [0, 1, 3, 6, 30])
    func migrateCrossfade(_ seconds: Int) throws {
        struct Old: Encodable { let gaplessPlaybackEnabled = false; let crossfadeDuration: Duration }
        let data = try JSONEncoder().encode(Old(crossfadeDuration: .seconds(seconds)))
        let value = try JSONDecoder().decode(TransitionPreferences.self, from: data)
        #expect(value.crossfadeDuration == .seconds(min(3, seconds)))
        #expect(!value.gaplessPlaybackEnabled)
        #expect(value.fadeInDuration == .zero)
        #expect(value.fadeOutDuration == .zero)
    }

    @Test func defaultsAndIndependentRoundTrip() throws {
        #expect(TransitionPreferences.defaults.fadeInDuration == .milliseconds(80))
        #expect(TransitionPreferences.defaults.fadeOutDuration == .milliseconds(120))
        #expect(!TransitionPreferences.defaults.isCrossfadeEnabled)
        let value = try TransitionPreferences(gaplessPlaybackEnabled: false, crossfadeDuration: .seconds(3),
            fadeInDuration: .zero, fadeOutDuration: .seconds(1))
        #expect(try JSONDecoder().decode(TransitionPreferences.self, from: JSONEncoder().encode(value)) == value)
        let old = try JSONDecoder().decode(PlaybackPreferences.self, from: Data("{}".utf8))
        #expect(old.transition.fadeInDuration == .zero)
        #expect(old.transition.fadeOutDuration == .zero)
    }

    @Test(arguments: [Duration.seconds(-1), .milliseconds(3001), .seconds(30)])
    func rejectLiveInput(_ duration: Duration) {
        #expect(throws: SettingsError.self) { try TransitionPreferences(crossfadeDuration: duration) }
        #expect(throws: SettingsError.self) { try TransitionPreferences(fadeInDuration: duration) }
        #expect(throws: SettingsError.self) { try TransitionPreferences(fadeOutDuration: duration) }
    }
}
