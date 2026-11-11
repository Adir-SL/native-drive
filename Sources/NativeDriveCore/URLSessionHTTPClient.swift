import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class URLSessionHTTPClient: NSObject, HTTPClient, URLSessionDataDelegate, @unchecked Sendable {
    private let session: URLSession
    private let lock = NSLock()
    /// One session for file bytes so HTTP/2 connections are reused. `taskIdentifier` is only unique inside a session, so state is keyed by object identity.
    private var downloadSession: URLSession!
    private var downloads: [ObjectIdentifier: DownloadState] = [:]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpMaximumConnectionsPerHost = 8
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60 * 60
            #if canImport(FoundationNetworking)
            configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024, diskPath: nil)
            #else
            configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 128 * 1024 * 1024)
            #endif
            configuration.requestCachePolicy = .reloadRevalidatingCacheData
            self.session = URLSession(configuration: configuration)
        }
        super.init()
        if session != nil {
            downloadSession = self.session
        } else {
            let downloads = URLSessionConfiguration.default
            downloads.urlCache = nil
            downloads.requestCachePolicy = .reloadIgnoringLocalCacheData
            downloads.httpMaximumConnectionsPerHost = 6
            downloads.timeoutIntervalForRequest = 60
            downloads.timeoutIntervalForResource = 60 * 60
            downloadSession = URLSession(configuration: downloads, delegate: self, delegateQueue: nil)
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request.urlRequest())
            guard let http = response as? HTTPURLResponse else {
                throw DriveAPIError.transport("The server did not return an HTTP response.")
            }
            return HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: data)
        } catch let error as DriveAPIError {
            throw error
        } catch is CancellationError {
            throw DriveAPIError.cancelled
        } catch {
            if DriveAPIError.isOffline(error) { throw DriveAPIError.offline }
            throw DriveAPIError.transport(error.localizedDescription)
        }
    }

    public func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> HTTPResponse {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        let state = DownloadState(destination: destination, handle: handle, onProgress: onProgress)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                state.continuation = continuation
                let task = downloadSession.dataTask(with: request.urlRequest())
                state.task = task
                lock.lock()
                downloads[ObjectIdentifier(task)] = state
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            state.task?.cancel()
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        let alreadySet = redirected.value(forHTTPHeaderField: "Authorization") != nil
        if !alreadySet,
           let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
           DriveAuthorizationRedirect.shouldForwardAuthorization(to: redirected.url?.host) {
            redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let state = state(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        let http = response as? HTTPURLResponse
        state.status = http?.statusCode ?? -1
        if let http {
            state.headers = Self.headers(from: http)
        }
        if let length = http?.expectedContentLength, length > 0 {
            state.expected = length
        }
        state.bufferErrorBody = state.status >= 400
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(for: dataTask) else { return }
        if state.bufferErrorBody {
            state.errorBody.append(data)
            return
        }
        do {
            try state.handle.write(contentsOf: data)
            state.received += Int64(data.count)
            state.onProgress(state.received, state.expected)
        } catch {
            state.writeError = error
            dataTask.cancel()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = takeState(for: task) else { return }
        try? state.handle.close()
        let continuation = state.continuation
        state.continuation = nil
        if let writeError = state.writeError {
            continuation?.resume(throwing: DriveAPIError.transport(writeError.localizedDescription))
            return
        }
        if let error {
            if DriveAPIError.isOffline(error) {
                continuation?.resume(throwing: DriveAPIError.offline)
            } else if (error as? URLError)?.code == .cancelled {
                continuation?.resume(throwing: DriveAPIError.cancelled)
            } else {
                continuation?.resume(throwing: DriveAPIError.transport(error.localizedDescription))
            }
            return
        }
        let response = HTTPResponse(status: state.status, headers: state.headers, body: state.errorBody)
        continuation?.resume(returning: response)
    }

    private func state(for task: URLSessionTask) -> DownloadState? {
        lock.lock()
        defer { lock.unlock() }
        return downloads[ObjectIdentifier(task)]
    }

    private func takeState(for task: URLSessionTask) -> DownloadState? {
        lock.lock()
        defer { lock.unlock() }
        return downloads.removeValue(forKey: ObjectIdentifier(task))
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key).lowercased()] = String(describing: value)
        }
        return result
    }
}

private final class DownloadState: @unchecked Sendable {
    let destination: URL
    let handle: FileHandle
    let onProgress: @Sendable (Int64, Int64?) -> Void
    var task: URLSessionTask?
    var continuation: CheckedContinuation<HTTPResponse, Error>?
    var status: Int = -1
    var headers: [String: String] = [:]
    var expected: Int64?
    var received: Int64 = 0
    var bufferErrorBody = false
    var errorBody = Data()
    var writeError: Error?

    init(destination: URL, handle: FileHandle, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.destination = destination
        self.handle = handle
        self.onProgress = onProgress
    }
}
