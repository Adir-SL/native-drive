import Foundation
import XCTest
@testable import NativeDriveCore

actor MockHTTPClient: HTTPClient {
    struct Step {
        var response: HTTPResponse?
        var error: Error?
    }

    private var steps: [Step]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse] = []) {
        steps = responses.map { Step(response: $0, error: nil) }
    }

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else {
            throw DriveAPIError.transport("No scripted response.")
        }
        let step = steps.removeFirst()
        if let error = step.error {
            throw error
        }
        return step.response ?? HTTPResponse(status: 500, headers: [:], body: Data())
    }

    func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse {
        let response = try await send(request)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try response.body.write(to: destination, options: .atomic)
        let count = Int64(response.body.count)
        onProgress(count, count)
        return response
    }

    func recorded() -> [HTTPRequest] { requests }
}

extension MockHTTPClient.Step {
    static func response(_ response: HTTPResponse) -> MockHTTPClient.Step {
        MockHTTPClient.Step(response: response, error: nil)
    }

    static func failure(_ error: Error) -> MockHTTPClient.Step {
        MockHTTPClient.Step(response: nil, error: error)
    }
}

final class ScriptedTokens: AccessTokenProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    var stale = "stale-token"
    var refreshed = "fresh-token"

    func accessToken(forceRefresh: Bool) async throws -> String {
        lock.lock()
        calls.append(forceRefresh)
        lock.unlock()
        return forceRefresh ? refreshed : stale
    }

    func recordedCalls() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

func httpJSON(_ status: Int, _ json: String, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
}

func noSleepRetry() -> RetryPolicy {
    RetryPolicy(maxAttempts: 5, initialDelayNanoseconds: 0, maxDelayNanoseconds: 0, sleep: { _ in })
}

func makeClient(http: MockHTTPClient, auth: (any AccessTokenProviding)? = nil, limits: UploadLimits = .default) -> DriveClient {
    DriveClient(
        http: http,
        auth: auth ?? LiteralTokenProvider(token: "token"),
        uploadLimits: limits,
        retry: noSleepRetry()
    )
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nativedrive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sampleFile(
    id: String,
    name: String,
    mimeType: String = "text/plain",
    parents: [String] = ["root"],
    starred: Bool = false,
    trashed: Bool = false,
    modified: Date? = nil,
    viewed: Date? = nil,
    driveId: String? = nil
) -> DriveFile {
    DriveFile(
        id: id,
        name: name,
        mimeType: mimeType,
        modifiedTime: modified,
        viewedByMeTime: viewed,
        starred: starred,
        trashed: trashed,
        parents: parents,
        driveId: driveId
    )
}

func listing(_ key: String, _ files: [DriveFile]) -> CachedListing {
    CachedListing(key: key, files: files, nextPageToken: nil, fetchedAt: Date(timeIntervalSince1970: 10))
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
