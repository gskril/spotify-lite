import CryptoKit
import Foundation
import Security

enum PKCE {
    static func verifier() throws -> String {
        try randomURLSafeString(byteCount: 64)
    }

    static func state() throws -> String {
        try randomURLSafeString(byteCount: 32)
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func randomURLSafeString(byteCount: Int) throws -> String {
        var data = Data(count: byteCount)
        let result = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard result == errSecSuccess else {
            throw KeychainError.unexpectedStatus(result)
        }
        return data.base64URLEncodedString()
    }
}

extension Data {
    fileprivate func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
