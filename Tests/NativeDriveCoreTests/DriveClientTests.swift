import XCTest
@testable import NativeDriveCore

final class DriveClientTests: XCTestCase {
    func testListFilesSendsQueryAndBearerToken() async throws {
        let json = """
        {"files":[{"id":"1","name":"Notes","mimeType":"application/vnd.google-apps.folder"}],"nextPageToken":"page-2"}
        """
        let http = MockHTTPClient(responses: [httpJSON(200, json)])
        let auth = ScriptedTokens()
        let client = makeClient(http: http, auth: auth)
        let page = try await client.listFiles(location: .myDrive, pageToken: nil)
        XCTAssertEqual(page.files.map(\.name), ["Notes"])
        XCTAssertEqual(page.nextPageToken, "page-2")
        let recorded = await http.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer stale-token")
        let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "'root' in parents and trashed = false")
        XCTAssertEqual(items.first(where: { $0.name == "supportsAllDrives" })?.value, "true")
        XCTAssertEqual(items.first(where: { $0.name == "pageSize" })?.value, "1000")
        XCTAssertTrue(items.contains(where: { $0.name == "fields" && ($0.value?.contains("nextPageToken") == true) }))
        XCTAssertTrue(items.contains(where: { $0.name == "fields" && ($0.value?.contains("thumbnailLink") == true) }))
        XCTAssertFalse(items.contains(where: { $0.name == "fields" && ($0.value?.contains("photoLink") == true) }))
        let calls = await auth.recordedCalls()
        XCTAssertEqual(calls, [false])
    }

    func testUnauthorizedRefreshesOnce() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(401, #"{"error":{"code":401,"message":"expired"}}"#),
            httpJSON(200, #"{"files":[{"id":"1","name":"A","mimeType":"text/plain"}]}"#)
        ])
        let auth = ScriptedTokens()
        let client = makeClient(http: http, auth: auth)
        let page = try await client.listFiles(location: .starred, pageToken: nil)
        XCTAssertEqual(page.files.map(\.id), ["1"])
        let calls = await auth.recordedCalls()
        XCTAssertEqual(calls, [false, true])
        let requests = await http.recorded()
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer stale-token", "Bearer fresh-token"])
    }

    func testRateLimitRetriesThenSucceeds() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(429, #"{"error":{"message":"slow down"}}"#, headers: ["Retry-After": "1"]),
            httpJSON(500, #"{"error":{"message":"nope"}}"#),
            httpJSON(200, #"{"files":[]}"#)
        ])
        let client = makeClient(http: http)
        let page = try await client.listFiles(location: .trash, pageToken: "t")
        XCTAssertTrue(page.files.isEmpty)
        let attempts = await http.recorded()
        XCTAssertEqual(attempts.count, 3)
    }

    func testForbiddenDoesNotRetryUnlessRateLimited() async throws {
        let forbidden = MockHTTPClient(responses: [
            httpJSON(403, #"{"error":{"message":"no access","errors":[{"reason":"insufficientPermissions"}]}}"#)
        ])
        let client = makeClient(http: forbidden)
        do {
            _ = try await client.listFiles(location: .myDrive, pageToken: nil)
            XCTFail("Expected forbidden")
        } catch let error as DriveAPIError {
            XCTAssertEqual(error, .forbidden("no access"))
        }
        let forbiddenCalls = await forbidden.recorded()
        XCTAssertEqual(forbiddenCalls.count, 1)

        let limited = MockHTTPClient(responses: [
            httpJSON(403, #"{"error":{"message":"limit","errors":[{"reason":"userRateLimitExceeded"}]}}"#),
            httpJSON(200, #"{"files":[]}"#)
        ])
        let retrying = makeClient(http: limited)
        _ = try await retrying.listFiles(location: .myDrive, pageToken: nil)
        let limitedCalls = await limited.recorded()
        XCTAssertEqual(limitedCalls.count, 2)
    }

    func testGoneChangeToken() async throws {
        let http = MockHTTPClient(responses: [httpJSON(410, #"{"error":{"message":"page token expired"}}"#)])
        let client = makeClient(http: http)
        do {
            _ = try await client.listChanges(pageToken: "old")
            XCTFail("Expected gone")
        } catch let error as DriveAPIError {
            XCTAssertEqual(error, .gone)
        }
    }

    func testOfflineDoesNotRetry() async throws {
        let http = MockHTTPClient(steps: [.failure(URLError(.notConnectedToInternet))])
        let client = makeClient(http: http)
        do {
            _ = try await client.aboutUser()
            XCTFail("Expected offline")
        } catch let error as DriveAPIError {
            XCTAssertEqual(error, .offline)
        }
        let offlineCalls = await http.recorded()
        XCTAssertEqual(offlineCalls.count, 1)
    }

    func testCollectChangesFollowsPages() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"changes":[{"fileId":"1","removed":false,"file":{"id":"1","name":"A","mimeType":"text/plain"}}],"nextPageToken":"p2"}"#),
            httpJSON(200, #"{"changes":[{"fileId":"2","removed":true}],"newStartPageToken":"cursor"}"#)
        ])
        let client = makeClient(http: http)
        let collected = try await client.collectChanges(from: "start")
        XCTAssertEqual(collected.changes.map(\.fileId), ["1", "2"])
        XCTAssertEqual(collected.nextStartToken, "cursor")
        XCTAssertFalse(collected.incomplete)
    }

    func testDownloadWritesBytes() async throws {
        let http = MockHTTPClient(responses: [httpJSON(200, "hello-drive")])
        let client = makeClient(http: http)
        let destination = try temporaryDirectory().appendingPathComponent("hello.txt")
        try await client.download(fileID: "file 1", to: destination) { _, _ in }
        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertEqual(text, "hello-drive")
        let recorded = await http.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertTrue(request.url.absoluteString.contains("alt=media"))
        XCTAssertTrue(request.url.absoluteString.contains("file%201"))
    }

    func testMultipartUploadForSmallFiles() async throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: fileURL)
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"id":"up1","name":"note.txt","mimeType":"text/plain","parents":["root"]}"#)
        ])
        let client = makeClient(http: http)
        let uploaded = try await client.uploadFile(at: fileURL, name: "note.txt", mimeType: "text/plain", parentID: "root") { _, _ in }
        XCTAssertEqual(uploaded.id, "up1")
        let recorded = await http.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.url.absoluteString.contains("uploadType=multipart"))
        let body = try XCTUnwrap(request.body)
        XCTAssertTrue(body.range(of: Data("hello".utf8)) != nil)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"name\":\"note.txt\""))
        XCTAssertTrue(text.contains("\"parents\":[\"root\"]"))
    }

    func testResumableUploadChunksAndRange() async throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("blob.bin")
        try Data("0123456789".utf8).write(to: fileURL)
        let fileJSON = #"{"id":"big","name":"blob.bin","mimeType":"application/octet-stream"}"#
        let http = MockHTTPClient(responses: [
            httpJSON(200, "", headers: ["Location": "https://upload.example/session"]),
            httpJSON(308, "", headers: ["Range": "bytes=0-3"]),
            httpJSON(308, "", headers: ["Range": "bytes=0-7"]),
            httpJSON(200, fileJSON)
        ])
        let client = makeClient(http: http, limits: UploadLimits(resumableThreshold: 0, chunkSize: 4))
        let uploaded = try await client.uploadFile(at: fileURL, name: "blob.bin", mimeType: "application/octet-stream", parentID: "parent") { _, _ in }
        XCTAssertEqual(uploaded.id, "big")
        let requests = await http.recorded()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests[0].url.absoluteString.contains("uploadType=resumable"))
        XCTAssertEqual(requests[0].headers["X-Upload-Content-Length"], "10")
        XCTAssertEqual(requests[1].headers["Content-Range"], "bytes 0-3/10")
        XCTAssertEqual(requests[2].headers["Content-Range"], "bytes 4-7/10")
        XCTAssertEqual(requests[3].headers["Content-Range"], "bytes 8-9/10")
        XCTAssertEqual(requests[1].url.absoluteString, "https://upload.example/session")
        XCTAssertEqual(UploadRequests.nextOffset(rangeHeader: "bytes=0-42", fallback: 0), 43)
        XCTAssertEqual(UploadRequests.nextOffset(rangeHeader: nil, fallback: 8), 8)
    }

    func testListDrivesAndAbout() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"user":{"displayName":"Ada","emailAddress":"Ada@Example.com","permissionId":"perm"}}"#),
            httpJSON(200, #"{"drives":[{"id":"d1","name":"Team"}],"nextPageToken":"n"}"#),
            httpJSON(200, #"{"drives":[{"id":"d2","name":"Other"}]}"#)
        ])
        let client = makeClient(http: http)
        let user = try await client.aboutUser()
        XCTAssertEqual(user.emailAddress, "Ada@Example.com")
        let drives = try await client.listDrives()
        XCTAssertEqual(drives.map(\.name), ["Team", "Other"])
    }

    func testUpdateFileOmitsNilFields() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"id":"1","name":"Renamed","mimeType":"text/plain","starred":true}"#)
        ])
        let client = makeClient(http: http)
        let file = try await client.updateFile(id: "1", name: "Renamed", starred: true, trashed: nil)
        XCTAssertEqual(file.name, "Renamed")
        let recorded = await http.recorded()
        let body = String(decoding: try XCTUnwrap(recorded.first?.body), as: UTF8.self)
        XCTAssertTrue(body.contains("\"name\":\"Renamed\""))
        XCTAssertTrue(body.contains("\"starred\":true"))
        XCTAssertFalse(body.contains("trashed"))
    }
}
