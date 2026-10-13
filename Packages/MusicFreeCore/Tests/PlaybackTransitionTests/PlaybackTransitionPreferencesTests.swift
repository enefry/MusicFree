import Foundation
import PlaybackAPI
import SettingsAPI
import Testing

// Kept in the isolated transition target to make this phase independently verifiable.
@Suite struct PlaybackTransitionPreferencesTests {
    @Test(arguments: [0, 1, 3, 6, 12, 30])
    func migrateCrossfade(_ seconds: Int) throws {
        struct Old: Encodable { let gaplessPlaybackEnabled = false; let crossfadeDuration: Duration }
        let data = try JSONEncoder().encode(Old(crossfadeDuration: .seconds(seconds)))
        let value = try JSONDecoder().decode(TransitionPreferences.self, from: data)
        #expect(value.crossfadeDuration == .seconds(min(12, seconds)))
        #expect(!value.gaplessPlaybackEnabled)
        #expect(!value.skipBoundarySilence)
        #expect(value.fadeInDuration == .zero)
        #expect(value.fadeOutDuration == .zero)
    }

    @Test func audioConfigurationRoundTripAndLegacyDefaults() throws {
        let value = AudioTransitionConfiguration(mode: .crossfade, crossfadeDuration: .seconds(12), skipBoundarySilence: true)
        #expect(try JSONDecoder().decode(AudioTransitionConfiguration.self, from: JSONEncoder().encode(value)) == value)
        #expect(try JSONDecoder().decode(AudioTransitionConfiguration.self, from: Data("{\"mode\":\"gapless\"}".utf8)).skipBoundarySilence == false)
    }

    @Test func defaultsAndIndependentRoundTrip() throws {
        #expect(TransitionPreferences.defaults.fadeInDuration == .milliseconds(80))
        #expect(TransitionPreferences.defaults.fadeOutDuration == .milliseconds(120))
        #expect(!TransitionPreferences.defaults.isCrossfadeEnabled)
        let value = try TransitionPreferences(gaplessPlaybackEnabled: false, crossfadeDuration: .seconds(12),
            fadeInDuration: .zero, fadeOutDuration: .seconds(1), skipBoundarySilence: true)
        #expect(try JSONDecoder().decode(TransitionPreferences.self, from: JSONEncoder().encode(value)) == value)
        let old = try JSONDecoder().decode(PlaybackPreferences.self, from: Data("{}".utf8))
        #expect(old.transition.fadeInDuration == .zero)
        #expect(old.transition.fadeOutDuration == .zero)
    }

    @Test(arguments: [Duration.seconds(-1), .milliseconds(3001), .milliseconds(12001), .seconds(30)])
    func rejectLiveInput(_ duration: Duration) {
        if duration < .zero || duration > .seconds(12) {
            #expect(throws: SettingsError.self) { try TransitionPreferences(crossfadeDuration: duration) }
        } else {
            #expect(throws: Never.self) { _ = try TransitionPreferences(crossfadeDuration: duration) }
        }
        #expect(throws: SettingsError.self) { try TransitionPreferences(fadeInDuration: duration) }
        #expect(throws: SettingsError.self) { try TransitionPreferences(fadeOutDuration: duration) }
    }
}
