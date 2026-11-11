import Foundation

public struct UploadLimits: Equatable, Sendable {
    public var resumableThreshold: Int64
    public var chunkSize: Int

    public init(resumableThreshold: Int64 = 5 * 1024 * 1024, chunkSize: Int = 8 * 1024 * 1024) {
        self.resumableThreshold = resumableThreshold
        self.chunkSize = chunkSize
    }

    public static let `default` = UploadLimits()
}

public enum UploadRequests {
    public static func metadata(name: String, parentID: String, mimeType: String) throws -> Data {
        struct Metadata: Encodable {
            var name: String
            var parents: [String]
            var mimeType: String
        }
        return try JSONEncoder().encode(Metadata(name: name, parents: [parentID], mimeType: mimeType))
    }

    public static func multipartBody(metadata: Data, file: Data, mimeType: String, boundary: String) -> Data {
        var data = Data()
        func append(_ string: String) {
            data.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        data.append(metadata)
        append("\r\n--\(boundary)\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        data.append(file)
        append("\r\n--\(boundary)--\r\n")
        return data
    }

    public static func nextOffset(rangeHeader: String?, fallback: Int64) -> Int64 {
        guard var header = rangeHeader?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else {
            return fallback
        }
        if let separator = header.firstIndex(of: "=") {
            header = String(header[header.index(after: separator)...])
        }
        guard let last = header.split(separator: "-").last, let end = Int64(last) else {
            return fallback
        }
        return end &+ 1
    }
}
