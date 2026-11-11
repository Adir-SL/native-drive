import Foundation

public enum DriveFields {
    public static let file = "id,name,mimeType,modifiedTime,viewedByMeTime,size,starred,trashed,parents,webViewLink,iconLink,thumbnailLink,owners(displayName,emailAddress,me,photoLink,permissionId),md5Checksum,driveId,shortcutDetails(targetId,targetMimeType)"
    public static let fileList = "files(\(file)),nextPageToken"
    public static let changeList = "changes(fileId,removed,file(\(file))),nextPageToken,newStartPageToken"
}

public struct FilePage: Equatable, Sendable {
    public var files: [DriveFile]
    public var nextPageToken: String?

    public init(files: [DriveFile], nextPageToken: String?) {
        self.files = files
        self.nextPageToken = nextPageToken
    }
}

public struct DriveChange: Codable, Equatable, Sendable {
    public var fileId: String
    public var removed: Bool
    public var file: DriveFile?

    public init(fileId: String, removed: Bool, file: DriveFile?) {
        self.fileId = fileId
        self.removed = removed
        self.file = file
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try container.decode(String.self, forKey: .fileId)
        removed = try container.decodeIfPresent(Bool.self, forKey: .removed) ?? false
        file = try container.decodeIfPresent(DriveFile.self, forKey: .file)
    }
}

public struct ChangePage: Equatable, Sendable {
    public var changes: [DriveChange]
    public var nextPageToken: String?
    public var newStartPageToken: String?

    public init(changes: [DriveChange], nextPageToken: String?, newStartPageToken: String?) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

public struct CollectedChanges: Equatable, Sendable {
    public var changes: [DriveChange]
    public var nextStartToken: String
    public var incomplete: Bool

    public init(changes: [DriveChange], nextStartToken: String, incomplete: Bool) {
        self.changes = changes
        self.nextStartToken = nextStartToken
        self.incomplete = incomplete
    }
}

public struct DriveClient: Sendable {
    private let http: any HTTPClient
    private let auth: any AccessTokenProviding
    private let baseURL: URL
    private let uploadBaseURL: URL
    private let uploadLimits: UploadLimits
    private let retry: RetryPolicy

    public init(
        http: any HTTPClient,
        auth: any AccessTokenProviding,
        baseURL: URL = URL(string: "https://www.googleapis.com")!,
        uploadBaseURL: URL = URL(string: "https://www.googleapis.com")!,
        uploadLimits: UploadLimits = .default,
        retry: RetryPolicy = RetryPolicy()
    ) {
        self.http = http
        self.auth = auth
        self.baseURL = baseURL
        self.uploadBaseURL = uploadBaseURL
        self.uploadLimits = uploadLimits
        self.retry = retry
    }

    public func listFiles(location: DriveLocation, pageToken: String?) async throws -> FilePage {
        let query = DriveQueryBuilder.filesList(for: location, pageToken: pageToken)
        let items = Self.fileListQueryItems(query)
        let response = try await perform { token in
            HTTPRequest(method: "GET", url: try self.endpoint("/drive/v3/files", query: items), headers: self.bearer(token))
        }
        return try decode(FilePagePayload.self, from: response.body).page
    }

    public func getFile(id: String) async throws -> DriveFile {
        let items = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: DriveFields.file)
        ]
        let response = try await perform { token in
            HTTPRequest(
                method: "GET",
                url: try self.endpoint("/drive/v3/files/\(self.pathComponent(id))", query: items),
                headers: self.bearer(token)
            )
        }
        return try decode(DriveFile.self, from: response.body)
    }

    public func updateFile(id: String, name: String?, starred: Bool?, trashed: Bool?) async throws -> DriveFile {
        let body = try PatchBody(name: name, starred: starred, trashed: trashed).encoded()
        let items = [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: DriveFields.file)
        ]
        let response = try await perform { token in
            var headers = self.bearer(token)
            headers["Content-Type"] = "application/json"
            return HTTPRequest(
                method: "PATCH",
                url: try self.endpoint("/drive/v3/files/\(self.pathComponent(id))", query: items),
                headers: headers,
                body: body
            )
        }
        return try decode(DriveFile.self, from: response.body)
    }

    public func listDrives() async throws -> [SharedDrive] {
        var drives: [SharedDrive] = []
        var pageToken: String?
        for _ in 0..<20 {
            let items = Self.driveListQueryItems(pageToken: pageToken)
            let response = try await perform { token in
                HTTPRequest(method: "GET", url: try self.endpoint("/drive/v3/drives", query: items), headers: self.bearer(token))
            }
            let page = try decode(DriveListPayload.self, from: response.body)
            drives.append(contentsOf: page.drives)
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        return drives
    }

    public func aboutUser() async throws -> DriveUser {
        let items = [URLQueryItem(name: "fields", value: "user(displayName,emailAddress,photoLink,permissionId)")]
        let response = try await perform { token in
            HTTPRequest(method: "GET", url: try self.endpoint("/drive/v3/about", query: items), headers: self.bearer(token))
        }
        return try decode(AboutPayload.self, from: response.body).user
    }

    public func startPageToken() async throws -> String {
        let items = [URLQueryItem(name: "supportsAllDrives", value: "true")]
        let response = try await perform { token in
            HTTPRequest(method: "GET", url: try self.endpoint("/drive/v3/changes/startPageToken", query: items), headers: self.bearer(token))
        }
        let payload = try decode(StartTokenPayload.self, from: response.body)
        guard !payload.startPageToken.isEmpty else {
            throw DriveAPIError.decoding("Missing start page token.")
        }
        return payload.startPageToken
    }

    public func listChanges(pageToken: String) async throws -> ChangePage {
        let items = [
            URLQueryItem(name: "pageToken", value: pageToken),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeRemoved", value: "true"),
            URLQueryItem(name: "fields", value: DriveFields.changeList)
        ]
        let response = try await perform { token in
            HTTPRequest(method: "GET", url: try self.endpoint("/drive/v3/changes", query: items), headers: self.bearer(token))
        }
        return try decode(ChangeListPayload.self, from: response.body).page
    }

    public func collectChanges(from pageToken: String, pageLimit: Int = 20) async throws -> CollectedChanges {
        var token = pageToken
        var all: [DriveChange] = []
        var pages = 0
        while pages < pageLimit {
            let page = try await listChanges(pageToken: token)
            all.append(contentsOf: page.changes)
            pages += 1
            if let next = page.nextPageToken, !next.isEmpty, next != token {
                token = next
                continue
            }
            let newStart = page.newStartPageToken ?? token
            return CollectedChanges(changes: all, nextStartToken: newStart, incomplete: false)
        }
        return CollectedChanges(changes: all, nextStartToken: token, incomplete: true)
    }

    public func mediaURL(fileID: String) throws -> URL {
        try endpoint("/drive/v3/files/\(pathComponent(fileID))", query: [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ])
    }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        try await auth.accessToken(forceRefresh: forceRefresh)
    }

    public func download(
        fileID: String,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        let url = try mediaURL(fileID: fileID)
        try await downloadAuthenticated(from: url, to: destination, onProgress: onProgress)
    }

    public func downloadAuthenticated(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws {
        try await retry.execute {
            let response = try await self.authorizedDownload(url: url, to: destination, forceRefresh: false, onProgress: onProgress)
            if response.status == 401 {
                let again = try await self.authorizedDownload(url: url, to: destination, forceRefresh: true, onProgress: onProgress)
                try self.discardUnlessSuccess(again, at: destination)
                return
            }
            try self.discardUnlessSuccess(response, at: destination)
        }
    }

    public func uploadFile(
        at fileURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DriveFile {
        let size = try fileSize(fileURL)
        if size >= uploadLimits.resumableThreshold {
            return try await resumableUpload(fileURL: fileURL, name: name, mimeType: mimeType, parentID: parentID, size: size, onProgress: onProgress)
        }
        return try await multipartUpload(fileURL: fileURL, name: name, mimeType: mimeType, parentID: parentID, onProgress: onProgress)
    }

    private func multipartUpload(
        fileURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DriveFile {
        let fileData = try Data(contentsOf: fileURL)
        let metadata = try UploadRequests.metadata(name: name, parentID: parentID, mimeType: mimeType)
        let boundary = "nativedrive-\(UUID().uuidString)"
        let body = UploadRequests.multipartBody(metadata: metadata, file: fileData, mimeType: mimeType, boundary: boundary)
        let total = Int64(fileData.count)
        onProgress(0, total)
        let response = try await perform { token in
            var headers = self.bearer(token)
            headers["Content-Type"] = "multipart/related; boundary=\(boundary)"
            return HTTPRequest(
                method: "POST",
                url: try self.uploadEndpoint("/upload/drive/v3/files", query: [
                    URLQueryItem(name: "uploadType", value: "multipart"),
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                    URLQueryItem(name: "fields", value: DriveFields.file)
                ]),
                headers: headers,
                body: body,
                timeout: 60 * 30
            )
        }
        onProgress(total, total)
        return try decode(DriveFile.self, from: response.body)
    }

    private func resumableUpload(
        fileURL: URL,
        name: String,
        mimeType: String,
        parentID: String,
        size: Int64,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DriveFile {
        let metadata = try UploadRequests.metadata(name: name, parentID: parentID, mimeType: mimeType)
        let initiation = try await perform { token in
            var headers = self.bearer(token)
            headers["Content-Type"] = "application/json; charset=UTF-8"
            headers["X-Upload-Content-Type"] = mimeType
            headers["X-Upload-Content-Length"] = String(size)
            return HTTPRequest(
                method: "POST",
                url: try self.uploadEndpoint("/upload/drive/v3/files", query: [
                    URLQueryItem(name: "uploadType", value: "resumable"),
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                    URLQueryItem(name: "fields", value: DriveFields.file)
                ]),
                headers: headers,
                body: metadata,
                timeout: 60
            )
        }
        if let file = try? decode(DriveFile.self, from: initiation.body), !file.id.isEmpty, initiation.header("location") == nil, size == 0 {
            onProgress(size, size)
            return file
        }
        guard let location = initiation.header("location"), let sessionURL = URL(string: location) else {
            throw DriveAPIError.missingUploadLocation
        }

        if size == 0 {
            let response = try await perform(allowing: []) { token in
                var headers = self.bearer(token)
                headers["Content-Range"] = "bytes */0"
                headers["Content-Type"] = mimeType
                return HTTPRequest(method: "PUT", url: sessionURL, headers: headers, body: Data(), timeout: 60 * 30)
            }
            onProgress(0, 0)
            return try decode(DriveFile.self, from: response.body)
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        onProgress(0, size)
        while offset < size {
            let length = min(Int64(max(uploadLimits.chunkSize, 1)), size - offset)
            try handle.seek(toOffset: UInt64(offset))
            let chunk = handle.readData(ofLength: Int(length))
            if chunk.isEmpty {
                throw DriveAPIError.transport("The file ended before the upload finished.")
            }
            let end = offset + Int64(chunk.count) - 1
            let chunkStart = offset
            let response = try await sendAllowing([200, 201, 308]) { token in
                var headers = self.bearer(token)
                headers["Content-Type"] = mimeType
                headers["Content-Range"] = "bytes \(chunkStart)-\(end)/\(size)"
                return HTTPRequest(method: "PUT", url: sessionURL, headers: headers, body: chunk, timeout: 60 * 30)
            }
            if (200..<300).contains(response.status) {
                onProgress(size, size)
                return try decode(DriveFile.self, from: response.body)
            }
            if response.status == 308 {
                let fallback = offset + Int64(chunk.count)
                offset = UploadRequests.nextOffset(rangeHeader: response.header("range"), fallback: fallback)
                onProgress(min(offset, size), size)
                continue
            }
            _ = try check(response)
        }
        throw DriveAPIError.transport("The upload finished without a file resource.")
    }

    private func authorizedDownload(
        url: URL,
        to destination: URL,
        forceRefresh: Bool,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse {
        let token = try await auth.accessToken(forceRefresh: forceRefresh)
        let request = HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "*/*"
            ],
            timeout: 60 * 60
        )
        do {
            return try await http.download(request, to: destination, onProgress: onProgress)
        } catch is CancellationError {
            throw DriveAPIError.cancelled
        } catch let error as DriveAPIError {
            throw error
        } catch {
            if DriveAPIError.isOffline(error) { throw DriveAPIError.offline }
            throw DriveAPIError.transport(error.localizedDescription)
        }
    }

    private func discardUnlessSuccess(_ response: HTTPResponse, at destination: URL) throws {
        if !(200..<300).contains(response.status) {
            try? FileManager.default.removeItem(at: destination)
        }
        _ = try check(response)
    }

    private func perform(_ build: @Sendable (String) throws -> HTTPRequest) async throws -> HTTPResponse {
        try await perform(allowing: [], build)
    }

    private func perform(allowing: Set<Int>, _ build: @Sendable (String) throws -> HTTPRequest) async throws -> HTTPResponse {
        try await retry.execute {
            let response = try await self.sendOnce(build, forceRefresh: false)
            if response.status == 401 {
                let again = try await self.sendOnce(build, forceRefresh: true)
                return try self.check(again, allowing: allowing)
            }
            return try self.check(response, allowing: allowing)
        }
    }

    private func sendAllowing(_ allowing: Set<Int>, _ build: @Sendable (String) throws -> HTTPRequest) async throws -> HTTPResponse {
        try await perform(allowing: allowing, build)
    }

    private func sendOnce(_ build: @Sendable (String) throws -> HTTPRequest, forceRefresh: Bool) async throws -> HTTPResponse {
        let token = try await auth.accessToken(forceRefresh: forceRefresh)
        let request: HTTPRequest
        do {
            request = try build(token)
        } catch let error as DriveAPIError {
            throw error
        } catch {
            throw DriveAPIError.transport(error.localizedDescription)
        }
        do {
            return try await http.send(request)
        } catch is CancellationError {
            throw DriveAPIError.cancelled
        } catch let error as DriveAPIError {
            throw error
        } catch {
            if DriveAPIError.isOffline(error) { throw DriveAPIError.offline }
            throw DriveAPIError.transport(error.localizedDescription)
        }
    }

    private func check(_ response: HTTPResponse, allowing: Set<Int> = []) throws -> HTTPResponse {
        if allowing.contains(response.status) || (200..<300).contains(response.status) {
            return response
        }
        let parsed = Self.googleError(from: response.body)
        switch response.status {
        case 401:
            throw DriveAPIError.unauthorized
        case 403:
            if parsed.reason == "rateLimitExceeded" || parsed.reason == "userRateLimitExceeded" {
                throw DriveAPIError.rateLimited(retryAfter: Self.retryAfter(response))
            }
            throw DriveAPIError.forbidden(parsed.message)
        case 404:
            throw DriveAPIError.notFound
        case 410:
            throw DriveAPIError.gone
        case 429:
            throw DriveAPIError.rateLimited(retryAfter: Self.retryAfter(response))
        case 500...599:
            throw DriveAPIError.server(status: response.status, message: parsed.message)
        default:
            throw DriveAPIError.badStatus(response.status, parsed.message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DriveAPIError.decoding(error.localizedDescription)
        }
    }

    private func endpoint(_ path: String, query: [URLQueryItem]) throws -> URL {
        try makeURL(base: baseURL, path: path, query: query)
    }

    private func uploadEndpoint(_ path: String, query: [URLQueryItem]) throws -> URL {
        try makeURL(base: uploadBaseURL, path: path, query: query)
    }

    private func makeURL(base: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw DriveAPIError.transport("Invalid API URL.")
        }
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw DriveAPIError.transport("Invalid API URL.")
        }
        return url
    }

    private static func fileListQueryItems(_ query: FilesListQuery) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "pageSize", value: String(query.pageSize)),
            URLQueryItem(name: "fields", value: DriveFields.fileList),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: query.includeItemsFromAllDrives ? "true" : "false"),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(name: "orderBy", value: query.orderBy)
        ]
        if let q = query.q {
            items.append(URLQueryItem(name: "q", value: q))
        }
        if let pageToken = query.pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        if let corpora = query.corpora {
            items.append(URLQueryItem(name: "corpora", value: corpora))
        }
        if let driveId = query.driveId {
            items.append(URLQueryItem(name: "driveId", value: driveId))
        }
        return items
    }

    private static func driveListQueryItems(pageToken: String?) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "fields", value: "drives(id,name),nextPageToken")
        ]
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return items
    }

    private func bearer(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json"
        ]
    }

    private func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/+")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
            return Int64(size)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let number = attributes[.size] as? NSNumber {
            return number.int64Value
        }
        if let size = attributes[.size] as? Int {
            return Int64(size)
        }
        if let size = attributes[.size] as? UInt64 {
            return Int64(size)
        }
        return 0
    }

    private static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        guard let value = response.header("retry-after") else { return nil }
        return TimeInterval(value)
    }

    static func googleError(from data: Data) -> (message: String, reason: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", nil)
        }
        if let error = json["error"] as? [String: Any] {
            let message = error["message"] as? String ?? ""
            let reason = (error["errors"] as? [[String: Any]])?.first?["reason"] as? String
            return (message, reason)
        }
        if let message = json["error_description"] as? String {
            return (message, json["error"] as? String)
        }
        return ("", nil)
    }
}

private struct FilePagePayload: Decodable {
    var files: [DriveFile]
    var nextPageToken: String?

    var page: FilePage { FilePage(files: files, nextPageToken: nextPageToken) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decodeIfPresent([DriveFile].self, forKey: .files) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case files, nextPageToken
    }
}

private struct DriveListPayload: Decodable {
    var drives: [SharedDrive]
    var nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        drives = try container.decodeIfPresent([SharedDrive].self, forKey: .drives) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case drives, nextPageToken
    }
}

public struct SharedDrive: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

private struct AboutPayload: Decodable {
    var user: DriveUser
}

private struct StartTokenPayload: Decodable {
    var startPageToken: String
}

private struct ChangeListPayload: Decodable {
    var changes: [DriveChange]
    var nextPageToken: String?
    var newStartPageToken: String?

    var page: ChangePage {
        ChangePage(changes: changes, nextPageToken: nextPageToken, newStartPageToken: newStartPageToken)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changes = try container.decodeIfPresent([DriveChange].self, forKey: .changes) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
        newStartPageToken = try container.decodeIfPresent(String.self, forKey: .newStartPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case changes, nextPageToken, newStartPageToken
    }
}

private struct PatchBody: Encodable {
    var name: String?
    var starred: Bool?
    var trashed: Bool?

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(starred, forKey: .starred)
        try container.encodeIfPresent(trashed, forKey: .trashed)
    }

    private enum CodingKeys: String, CodingKey {
        case name, starred, trashed
    }
}
