import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum Hashing {
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Supernote login hash: SHA256(MD5(password) + randomCode), lowercase hex.
    static func password(_ password: String, randomCode: String) -> String {
        sha256Hex(md5Hex(Data(password.utf8)) + randomCode)
    }
}

public extension Data {
    var supernoteMD5: String { Hashing.md5Hex(self) }
}
