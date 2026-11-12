import CommonCrypto
import CryptoKit
import Foundation
import Security

enum WeapiCrypto {
    static let presetKey = "0CoJUm6Qyw8W8jud"
    static let iv = "0102030405060708"

    struct Output {
        let params: String
        let encSecKey: String
    }

    static func encrypt(payload: [String: Any], secretKey: String = randomSecretKey()) -> Output? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encrypt(payloadJSON: json, secretKey: secretKey)
    }

    static func encrypt(payloadJSON: String, secretKey: String) -> Output? {
        guard secretKey.utf8.count == 16,
              let ivData = iv.data(using: .utf8),
              let presetKeyData = presetKey.data(using: .utf8),
              let secretKeyData = secretKey.data(using: .utf8),
              let first = aesCBC(Data(payloadJSON.utf8), key: presetKeyData, iv: ivData),
              let second = aesCBC(Data(first.base64EncodedString().utf8), key: secretKeyData, iv: ivData)
        else {
            return nil
        }

        let reversed = String(secretKey.reversed())
        guard let rsaPlain = rsaPlaintext(reversedKey: reversed),
              let encrypted = rsaRawEncrypt(rsaPlain)
        else {
            return nil
        }

        return Output(
            params: second.base64EncodedString(),
            encSecKey: encrypted.hexString
        )
    }

    static func randomSecretKey() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    static func rsaPlaintext(reversedKey: String) -> Data? {
        let bytes = Data(reversedKey.utf8)
        guard bytes.count <= 128 else { return nil }
        var padded = Data(repeating: 0, count: 128)
        padded.replaceSubrange((128 - bytes.count)..<128, with: bytes)
        return padded
    }

    static func rsaRawEncrypt(_ plaintext: Data) -> Data? {
        guard let der = rsaPublicKeyDER() else { return nil }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 1024
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            return nil
        }
        guard let encrypted = SecKeyCreateEncryptedData(
            key,
            .rsaEncryptionRaw,
            plaintext as CFData,
            &error
        ) else {
            return nil
        }
        return encrypted as Data
    }

    private static func rsaPublicKeyDER() -> Data? {
        let modulusHex = "e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
        guard let modulus = Data(hex: modulusHex) else { return nil }
        let exponent = Data([0x01, 0x00, 0x01])

        let modulusInteger = derInteger(modulus)
        let exponentInteger = derInteger(exponent)
        let content = modulusInteger + exponentInteger
        return Data([0x30]) + derLength(content.count) + content
    }

    private static func derInteger(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1, value.first == 0 {
            value.removeFirst()
        }
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0, at: 0)
        }
        return Data([0x02]) + derLength(value.count) + value
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        }
        if length <= 255 {
            return Data([0x81, UInt8(length)])
        }
        return Data([0x82, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
    }

    static func aesCBC(_ data: Data, key: Data, iv: Data) -> Data? {
        crypt(
            data,
            key: key,
            iv: iv,
            algorithm: CCAlgorithm(kCCAlgorithmAES),
            options: CCOptions(kCCOptionPKCS7Padding)
        )
    }

    private static func crypt(
        _ data: Data,
        key: Data,
        iv: Data?,
        algorithm: CCAlgorithm,
        options: CCOptions
    ) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    if let iv {
                        return iv.withUnsafeBytes { ivBytes in
                            CCCrypt(
                                CCOperation(kCCEncrypt),
                                algorithm,
                                options,
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                dataBytes.baseAddress,
                                data.count,
                                outputBytes.baseAddress,
                                outputBytes.count,
                                &written
                            )
                        }
                    }
                    return CCCrypt(
                        CCOperation(kCCEncrypt),
                        algorithm,
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        dataBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }
}

enum EapiCrypto {
    static let key = "e82ckenh8dichen8"
    static let separator = "-36cd479b6b5-"

    static func encrypt(apiPath: String, payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encrypt(apiPath: apiPath, payloadJSON: json)
    }

    static func encrypt(apiPath: String, payloadJSON: String) -> String? {
        let digest = digest(apiPath: apiPath, payloadJSON: payloadJSON)
        let plain = apiPath + separator + payloadJSON + separator + digest
        guard let encrypted = aesECB(Data(plain.utf8), key: Data(key.utf8)) else {
            return nil
        }
        return encrypted.hexString.uppercased()
    }

    static func digest(apiPath: String, payloadJSON: String) -> String {
        let text = "nobody" + apiPath + "use" + payloadJSON + "md5forencrypt"
        let hash = Insecure.MD5.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func aesECB(_ data: Data, key: Data) -> Data? {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        nil,
                        dataBytes.baseAddress,
                        data.count,
                        outputBytes.baseAddress,
                        outputBytes.count,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(written..<output.count)
        return output
    }
}

extension Data {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
