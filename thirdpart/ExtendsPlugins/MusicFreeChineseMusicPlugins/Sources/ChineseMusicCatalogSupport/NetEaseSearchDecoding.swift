// Swift adaptation of NetEaseMusicSearchUtils.cs in jitwxs/163MusicLyrics (Apache-2.0).
import Foundation
import MusicFreePluginAPI

/// Some regions return search results as 64-byte obfuscated blocks.
enum NetEaseSearchDecoding {
    private static let substitution: [UInt8] = [
        82, 9, 106, 213, 48, 54, 165, 56, 191, 64, 163, 158, 129, 243, 215, 251,
        124, 227, 57, 130, 155, 47, 255, 135, 52, 142, 67, 68, 196, 222, 233, 203,
        84, 123, 148, 50, 166, 194, 35, 61, 238, 76, 149, 11, 66, 250, 195, 78,
        8, 46, 161, 102, 40, 217, 36, 178, 118, 91, 162, 73, 109, 139, 209, 37,
        114, 248, 246, 100, 134, 104, 152, 22, 212, 164, 92, 204, 93, 101, 182, 146,
        108, 112, 72, 80, 253, 237, 185, 218, 94, 21, 70, 87, 167, 141, 157, 132,
        144, 216, 171, 0, 140, 188, 211, 10, 247, 228, 88, 5, 184, 179, 69, 6,
        208, 44, 30, 143, 202, 63, 15, 2, 193, 175, 189, 3, 1, 19, 138, 107,
        58, 145, 17, 65, 79, 103, 220, 234, 151, 242, 207, 206, 240, 180, 230, 115,
        150, 172, 116, 34, 231, 173, 53, 133, 226, 249, 55, 232, 28, 117, 223, 110,
        71, 241, 26, 113, 29, 41, 197, 137, 111, 183, 98, 14, 170, 24, 190, 27,
        252, 86, 62, 75, 198, 210, 121, 32, 154, 219, 192, 254, 120, 205, 90, 244,
        31, 221, 168, 51, 136, 7, 199, 49, 177, 18, 16, 89, 39, 128, 236, 95,
        96, 81, 127, 169, 25, 181, 74, 13, 45, 229, 122, 159, 147, 201, 156, 239,
        160, 224, 59, 77, 174, 42, 245, 176, 200, 235, 187, 60, 131, 83, 153, 97,
        23, 43, 4, 126, 186, 119, 214, 38, 225, 105, 20, 99, 85, 33, 12, 125,
    ]
    private static let key = Array("fuck~#$%^&*(458".utf8)

    static func decode(_ hex: String) throws -> Data {
        let text = Array(hex.utf8)
        guard !text.isEmpty, text.count <= 2 * 1_024 * 1_024, text.count % 128 == 0 else {
            throw PluginDataError.invalidResponse
        }
        var input: [UInt8] = []
        input.reserveCapacity(text.count / 2)
        for index in stride(from: 0, to: text.count, by: 2) {
            guard let high = nibble(text[index]), let low = nibble(text[index + 1]) else {
                throw PluginDataError.invalidResponse
            }
            input.append(high << 4 | low)
        }
        let expandedKey = (0..<64).map { key[$0 % key.count] }
        var previous = expandedKey
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        for start in stride(from: 0, to: input.count, by: 64) {
            let block = Array(input[start..<start + 64])
            for index in 0..<64 {
                let substituted = substitution[Int(substitution[Int(block[index])])]
                output.append(((substituted ^ previous[index]) &- previous[index]) ^ expandedKey[index])
            }
            previous = block
        }
        let size = output.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard size <= output.count - 4 else { throw PluginDataError.invalidResponse }
        return Data(output.prefix(Int(size)))
    }

    private static func nibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 65 + 10
        case 97...102: value - 97 + 10
        default: nil
        }
    }
}
