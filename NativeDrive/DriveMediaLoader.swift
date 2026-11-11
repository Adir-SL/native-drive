import AVFoundation
import Foundation
import NativeDriveCore
import UniformTypeIdentifiers

/// Serves Drive `alt=media` byte ranges to AVFoundation so playback can start and seek
/// before the whole file is on disk. The delegate is not retained by AVFoundation.
final class DriveMediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.nativedrive.media-loader")

    private let remoteURL: URL
    private let contentType: String
    private let knownTotal: Int64?
    private let tokenProvider: @Sendable (Bool) async throws -> String
    private let session: URLSession
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        remoteURL: URL,
        mimeType: String,
        fileName: String,
        totalBytes: Int64?,
        tokenProvider: @escaping @Sendable (Bool) async throws -> String
    ) {
        self.remoteURL = remoteURL
        self.knownTotal = totalBytes
        self.tokenProvider = tokenProvider
        if let type = UTType(mimeType: mimeType) {
            contentType = type.identifier
        } else if let type = UTType(filenameExtension: URL(fileURLWithPath: fileName).pathExtension) {
            contentType = type.identifier
        } else {
            contentType = UTType.data.identifier
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        session = URLSession(configuration: configuration)
        super.init()
    }

    func playbackURL(fileID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "nativedrive-media"
        components.host = "play"
        components.path = "/\(fileID)"
        return components.url
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let box = LoadingRequestBox(loadingRequest)
        let task = Task {
            await self.fulfill(box)
        }
        store(task, for: loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        cancelTask(for: loadingRequest)?.cancel()
    }

    private func fulfill(_ box: LoadingRequestBox) async {
        let request = box.request
        defer { _ = cancelTask(for: request) }
        do {
            if let dataRequest = request.dataRequest {
                try await sendBytes(for: dataRequest, request: request)
            } else {
                fillInformation(request, total: knownTotal)
            }
            request.finishLoading()
        } catch is CancellationError {
            request.finishLoading(with: CancellationError())
        } catch {
            request.finishLoading(with: error)
        }
    }

    private func sendBytes(for dataRequest: AVAssetResourceLoadingDataRequest, request: AVAssetResourceLoadingRequest) async throws {
        let start = dataRequest.requestedOffset
        var total = knownTotal
        if dataRequest.requestsAllDataToEndOfResource == false {
            let length = min(max(dataRequest.requestedLength, 1), 1_048_576)
            let (data, http) = try await fetch(offset: start, length: length)
            if total == nil {
                total = Self.totalLength(http)
            }
            fillInformation(request, total: total)
            dataRequest.respond(with: data)
            return
        }

        var offset = start
        while true {
            try Task.checkCancellation()
            let (data, http) = try await fetch(offset: offset, length: 1_048_576)
            if total == nil {
                total = Self.totalLength(http)
            }
            fillInformation(request, total: total)
            if data.isEmpty { return }
            if http.statusCode == 200 && data.count > 1_048_576 {
                var cursor = Int(offset)
                while cursor < data.count {
                    try Task.checkCancellation()
                    let next = min(cursor + 1_048_576, data.count)
                    dataRequest.respond(with: data.subdata(in: cursor..<next))
                    cursor = next
                }
                return
            }
            dataRequest.respond(with: data)
            offset += Int64(data.count)
            if let total, offset >= total { return }
            if data.count < 1_048_576 { return }
        }
    }

    private func fillInformation(_ request: AVAssetResourceLoadingRequest, total: Int64?) {
        guard let info = request.contentInformationRequest else { return }
        info.isByteRangeAccessSupported = true
        info.contentType = contentType
        if let total, total > 0 {
            info.contentLength = total
        }
    }

    private func fetch(offset: Int64, length: Int) async throws -> (Data, HTTPURLResponse) {
        func makeRequest(_ accessToken: String) -> URLRequest {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = 60
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let end = offset + Int64(max(length, 1)) - 1
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            return request
        }
        var accessToken = try await tokenProvider(false)
        var (data, response) = try await session.data(for: makeRequest(accessToken))
        var http = response as? HTTPURLResponse
        if http?.statusCode == 401 {
            accessToken = try await tokenProvider(true)
            (data, response) = try await session.data(for: makeRequest(accessToken))
            http = response as? HTTPURLResponse
        }
        guard let http, (200...299).contains(http.statusCode) else {
            throw DriveAPIError.badStatus(http?.statusCode ?? -1, "Drive didn't return this part of the file.")
        }
        return (data, http)
    }

    private static func totalLength(_ response: HTTPURLResponse) -> Int64? {
        if let header = response.value(forHTTPHeaderField: "Content-Range"), let total = HTTPContentRange.totalLength(header) {
            return total
        }
        if response.statusCode == 200, let header = response.value(forHTTPHeaderField: "Content-Length"), let total = Int64(header) {
            return total
        }
        return nil
    }

    private func store(_ task: Task<Void, Never>, for request: AVAssetResourceLoadingRequest) {
        lock.lock()
        tasks[ObjectIdentifier(request)] = task
        lock.unlock()
    }

    @discardableResult
    private func cancelTask(for request: AVAssetResourceLoadingRequest) -> Task<Void, Never>? {
        lock.lock()
        let task = tasks.removeValue(forKey: ObjectIdentifier(request))
        lock.unlock()
        return task
    }
}

private final class LoadingRequestBox: @unchecked Sendable {
    let request: AVAssetResourceLoadingRequest
    init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }
}
