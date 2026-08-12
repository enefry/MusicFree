#if DEBUG
import Foundation

/// Creates one deterministic local-audio input only for the explicit BVT launch.
/// The normal Debug and Release startup paths never write this fixture.
enum AppBVTFixtureSeeder {
    static let launchArgument = "--bvt-seed-audio"
    static let trackTitle = "BVT Tone"
    static let longTrackTitle = "BVT Extremely Long Track Title That Must Stay Inside The Player Width"

    static func seedIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        fileManager: FileManager = .default
    ) {
        guard arguments.contains(launchArgument),
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
        for title in [trackTitle, longTrackTitle] {
            let fixtureURL = fixtureDirectory.appendingPathComponent("\(title).wav")
            guard !fileManager.fileExists(atPath: fixtureURL.path) else {
                continue
            }

            try? makeWaveData(title: title).write(to: fixtureURL, options: .atomic)
        }
    }

    private static func makeWaveData(title: String) -> Data {
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
        let infoList = makeInfoList(title: title)

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

    private static func makeInfoList(title: String) -> Data {
        var info = Data()
        info.appendASCII("INFO")
        appendInfo("INAM", value: title, to: &info)
        appendInfo("IART", value: "BVT Artist", to: &info)
        appendInfo("IPRD", value: "BVT Album", to: &info)
        appendInfo("IGNR", value: "BVT Genre", to: &info)
        appendInfo("ICRD", value: "2026", to: &info)
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
