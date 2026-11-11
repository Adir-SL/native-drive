import Foundation

public enum PKCE {
    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Base64URL.encode(bytes)
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(Data(verifier.utf8))
        return Base64URL.encode(digest)
    }
}
