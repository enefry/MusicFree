#if DEBUG
import Foundation

/// Creates one deterministic local-audio input only for the explicit BVT launch.
/// The normal Debug and Release startup paths never write this fixture.
enum AppBVTFixtureSeeder {
    static let launchArgument = "--bvt-seed-audio"
    static let layoutLaunchArgument = "--bvt-seed-layout-library"
    static let trackTitle = "BVT Tone"
    static let longTrackTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"

    private struct Fixture {
        let title: String
        let artist: String
        let album: String
        let genre: String
        let year: String
        let folder: String
    }

    private static let layoutFixtures = (1...8).map { index in
        Fixture(
            title: String(format: "Layout Song %02d", index),
            artist: String(format: "Layout Artist %02d", index),
            album: String(format: "Layout Album %02d", index),
            genre: String(format: "Layout Genre %02d", index),
            year: "2026",
            folder: String(format: "Layout Folder %02d", index)
        )
    }

    static func seedIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains(launchArgument) || arguments.contains(layoutLaunchArgument),
              let documentsURL = try? fileManager.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
              )
        else {
            return
        }

        let fixtureDirectory = documentsURL.appendingPathComponent("Imported", isDirectory: true)
        try? fileManager.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        for title in [trackTitle, longTrackTitle] where arguments.contains(launchArgument) {
            let fixtureURL = fixtureDirectory.appendingPathComponent("\(title).wav")
            if !fileManager.fileExists(atPath: fixtureURL.path) {
                try? makeWaveData(title: title).write(to: fixtureURL, options: .atomic)
            }

            let lyricsURL = fixtureDirectory.appendingPathComponent("\(title).lrc")
            if !fileManager.fileExists(atPath: lyricsURL.path) {
                try? makeLyricsData(title: title).write(to: lyricsURL, options: .atomic)
            }
        }

        let layoutDirectory = fixtureDirectory.appendingPathComponent("LayoutFixtures", isDirectory: true)
        if arguments.contains(layoutLaunchArgument) {
            for fixture in layoutFixtures {
                let folderURL = layoutDirectory.appendingPathComponent(fixture.folder, isDirectory: true)
                try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
                let fixtureURL = folderURL.appendingPathComponent("\(fixture.title).wav")
                if !fileManager.fileExists(atPath: fixtureURL.path) {
                    try? makeWaveData(
                        title: fixture.title,
                        artist: fixture.artist,
                        album: fixture.album,
                        genre: fixture.genre,
                        year: fixture.year
                    ).write(to: fixtureURL, options: .atomic)
                }
            }
        } else {
            try? fileManager.removeItem(at: layoutDirectory)
        }
    }

    private static func makeLyricsData(title: String) -> Data {
        let lines = [
            "[00:00.00]Now the night is moving on",
            "[00:04.00]Every sound becomes a light",
            "[00:08.00]\(title)",
            "[00:12.00]Keep the moment close to me",
            "[00:16.00]Let the rhythm carry through",
            "[00:20.00]We will find the way back home",
            "[00:24.00]Stay with me until the end"
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func makeWaveData(
        title: String,
        artist: String = "BVT Artist",
        album: String = "BVT Album",
        genre: String = "BVT Genre",
        year: String = "2026"
    ) -> Data {
        let sampleRate: UInt32 = 8_000
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        // The UI flow intentionally spends more than a few seconds moving
        // between the library, mini player, and now-playing surfaces. Keep
        // the fixture alive long enough that the queue remains observable.
        let sampleCount = Int(sampleRate) * 30
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = UInt32(sampleCount * bytesPerSample)
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bytesPerSample)
        let blockAlign = channelCount * UInt16(bytesPerSample)
        let infoList = makeInfoList(
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            year: year
        )

        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(44 + infoList.count) + dataSize)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendASCII("LIST")
        data.appendLittleEndian(UInt32(infoList.count))
        data.append(infoList)
        data.appendASCII("data")
        data.appendLittleEndian(dataSize)

        for index in 0..<sampleCount {
            let phase = 2 * Double.pi * 440 * Double(index) / Double(sampleRate)
            let sample = Int16((sin(phase) * Double(Int16.max) * 0.08).rounded())
            data.appendLittleEndian(sample)
        }
        return data
    }

    private static func makeInfoList(
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: String
    ) -> Data {
        var info = Data()
        info.appendASCII("INFO")
        appendInfo("INAM", value: title, to: &info)
        appendInfo("IART", value: artist, to: &info)
        appendInfo("IPRD", value: album, to: &info)
        appendInfo("IGNR", value: genre, to: &info)
        appendInfo("ICRD", value: year, to: &info)
        return info
    }

    private static func appendInfo(_ key: String, value: String, to data: inout Data) {
        let valueData = Data((value + "\0").utf8)
        data.appendASCII(key)
        data.appendLittleEndian(UInt32(valueData.count))
        data.append(valueData)
        if !valueData.count.isMultiple(of: 2) {
            data.append(0)
        }
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
            append(contentsOf: bytes)
        }
    }
}
#endif
