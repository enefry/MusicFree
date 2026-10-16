import Foundation
import PlaybackAPI

enum FFmpegEqualizerPresets {
    static func make(bands: [EqualizerBandDescriptor]) -> [EqualizerPresetDescriptor] {
        // Keep the existing profiles and identifiers unchanged.
        let current: [(UInt32, String, [Float])] = [
            (0, "Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
            (1, "Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
            (2, "Treble Boost", [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
            (3, "Vocal", [-2, -1, 0, 1, 2, 3, 3, 2, 0, -1])
        ]
        let existing = current.map { descriptor(id: $0.0, name: $0.1, gains: $0.2, bands: bands) }
        let restored = legacyProfiles.enumerated().map { index, profile in
            // The old engine used different center frequencies. Preserve the
            // curve on a logarithmic frequency axis, within the current bounds.
            let gains = bands.map { band in
                let interpolated = interpolate(profile.1, at: band.centerFrequencyHz)
                return min(band.maximumGainDecibels, max(band.minimumGainDecibels, (interpolated * 2).rounded() / 2))
            }
            // Leave headroom for boosted bands instead of carrying over VLC's
            // positive global preamp into the current output graph.
            return descriptor(id: UInt32(100 + index), name: profile.0, gains: gains,
                preamp: -max(0, gains.max() ?? 0), bands: bands)
        }
        return existing + restored
    }

    private static func descriptor(id: UInt32, name: String, gains: [Float], preamp: Float = 0,
                                   bands: [EqualizerBandDescriptor]) -> EqualizerPresetDescriptor {
        EqualizerPresetDescriptor(id: id, name: name, configuration: EqualizerConfiguration(
            preampDecibels: preamp,
            bandGains: zip(bands, gains).map {
                EqualizerBandGain(centerFrequencyHz: $0.0.centerFrequencyHz, gainDecibels: $0.1)
            }))
    }

    private static func interpolate(_ gains: [Float], at frequency: Double) -> Float {
        let frequencies = [60.0, 170, 310, 600, 1_000, 3_000, 6_000, 12_000, 14_000, 16_000]
        guard frequency > frequencies[0] else { return gains[0] }
        guard let upper = frequencies.firstIndex(where: { $0 >= frequency }) else { return gains[gains.count - 1] }
        let lower = upper - 1
        let fraction = Float(log(frequency / frequencies[lower]) / log(frequencies[upper] / frequencies[lower]))
        return gains[lower] + (gains[upper] - gains[lower]) * fraction
    }

    // Numerical curve data adapted from VideoLAN's equalizer_presets.h,
    // Copyright (C) 2004 VLC authors and VideoLAN, Laurent Aimar.
    // LGPL-2.1-or-later; see ThirdPartyNotices/VLCEqualizerPresets.txt.
    // Flat is supplied by the existing zero-gain profile above.
    private static let legacyProfiles: [(String, [Float])] = [
        ("Classical", [0, 0, 0, 0, 0, 0, -7.2, -7.2, -7.2, -9.6]),
        ("Club", [0, 0, 8, 5.6, 5.6, 5.6, 3.2, 0, 0, 0]),
        ("Dance", [9.6, 7.2, 2.4, 0, 0, -5.6, -7.2, -7.2, 0, 0]),
        ("Full bass", [-8, 9.6, 9.6, 5.6, 1.6, -4, -8, -10.4, -11.2, -11.2]),
        ("Full bass and treble", [7.2, 5.6, 0, -7.2, -4.8, 1.6, 8, 11.2, 12, 12]),
        ("Full treble", [-9.6, -9.6, -9.6, -4, 2.4, 11.2, 16, 16, 16, 16.8]),
        ("Headphones", [4.8, 11.2, 5.6, -3.2, -2.4, 1.6, 4.8, 9.6, 12.8, 14.4]),
        ("Large Hall", [10.4, 10.4, 5.6, 5.6, 0, -4.8, -4.8, -4.8, 0, 0]),
        ("Live", [-4.8, 0, 4, 5.6, 5.6, 5.6, 4, 2.4, 2.4, 2.4]),
        ("Party", [7.2, 7.2, 0, 0, 0, 0, 0, 0, 7.2, 7.2]),
        ("Pop", [-1.6, 4.8, 7.2, 8, 5.6, 0, -2.4, -2.4, -1.6, -1.6]),
        ("Reggae", [0, 0, 0, -5.6, 0, 6.4, 6.4, 0, 0, 0]),
        ("Rock", [8, 4.8, -5.6, -8, -3.2, 4, 8.8, 11.2, 11.2, 11.2]),
        ("Ska", [-2.4, -4.8, -4, 0, 4, 5.6, 8.8, 9.6, 11.2, 9.6]),
        ("Soft", [4.8, 1.6, 0, -2.4, 0, 4, 8, 9.6, 11.2, 12]),
        ("Soft rock", [4, 4, 2.4, 0, -4, -5.6, -3.2, 0, 2.4, 8.8]),
        ("Techno", [8, 5.6, 0, -5.6, -4.8, 0, 8, 9.6, 9.6, 8.8])
    ]
}
