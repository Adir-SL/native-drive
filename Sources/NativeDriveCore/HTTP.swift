import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 60) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }

    public func urlRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        var normalized: [String: String] = [:]
        for (field, value) in headers {
            normalized[field.lowercased()] = value
        }
        self.status = status
        self.headers = normalized
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse
}
