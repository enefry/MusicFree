// Swift adaptation of NetEaseMusicNativeApi.cs in jitwxs/163MusicLyrics (Apache-2.0).
import CommonCrypto
import Foundation
import MusicFreePluginAPI

enum NetEaseRequestEncryption {
    // These are public protocol constants, not account credentials. RSA wraps
    // the reversed second AES key with the upstream exponent and modulus.
    private static let secondKey = "MusicFree1234567"
    private static let wrappedKey = "59092ace9f8046ed2bfa1fffc1eec9385ba32538e13ca35c05096a4f227555174f2dec95395bc8f25f9d2fbb563d0428d1d07ee38d6a9e2ae27fc23f6887d29bbeb7245c85e953184380d94ad3083934cad7d9c4258045e637f355d32f7c8134420705a36c6fc073fe9325b989a6631a12cf21966fe45d9ccd87bf9ea7e6f741"

    static func body(_ fields: [String: String]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        let first = try encrypt(json, key: "0CoJUm6Qyw8W8jud")
        let second = try encrypt(Data(first.base64EncodedString().utf8), key: secondKey)
        return formData(["params": second.base64EncodedString(), "encSecKey": wrappedKey])
    }

    private static func encrypt(_ input: Data, key: String) throws -> Data {
        let key = Data(key.utf8)
        let iv = Data("0102030405060708".utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress, source.baseAddress, input.count,
                            destination.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PluginDataError.invalidResponse }
        output.count = written
        return output
    }
}
