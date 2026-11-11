import Foundation

enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var output = [UInt8]()
        output.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let value = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8) | UInt32(bytes[index + 2])
            output.append(alphabet[Int((value >> 18) & 63)])
            output.append(alphabet[Int((value >> 12) & 63)])
            output.append(alphabet[Int((value >> 6) & 63)])
            output.append(alphabet[Int(value & 63)])
            index += 3
        }
        let remaining = bytes.count - index
        if remaining == 1 {
            let value = UInt32(bytes[index]) << 16
            output.append(alphabet[Int((value >> 18) & 63)])
            output.append(alphabet[Int((value >> 12) & 63)])
        } else if remaining == 2 {
            let value = (UInt32(bytes[index]) << 16) | (UInt32(bytes[index + 1]) << 8)
            output.append(alphabet[Int((value >> 18) & 63)])
            output.append(alphabet[Int((value >> 12) & 63)])
            output.append(alphabet[Int((value >> 6) & 63)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func encode(_ data: Data) -> String {
        encode([UInt8](data))
    }

    static func decode(_ text: String) -> Data? {
        let cleaned = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - (cleaned.count % 4)) % 4
        let padded = cleaned + String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return data
    }
}
