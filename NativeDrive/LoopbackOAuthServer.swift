import Darwin
import Foundation
import NativeDriveCore

/// Listens on 127.0.0.1 for the OAuth redirect used by a Desktop OAuth client.
final class LoopbackOAuthServer: @unchecked Sendable {
    private var socketFD: Int32 = -1
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<URL, Error>?

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthFlowError.loopback("Could not open a local socket for sign-in.")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw OAuthFlowError.loopback("Could not bind 127.0.0.1 for sign-in.")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw OAuthFlowError.loopback("Could not listen on 127.0.0.1 for sign-in.")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                getsockname(fd, pointer, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw OAuthFlowError.loopback("Could not read the local sign-in port.")
        }
        lock.lock()
        socketFD = fd
        lock.unlock()
        return UInt16(bigEndian: actual.sin_port)
    }

    func waitForCallback() async throws -> URL {
        let fd = currentFD()
        guard fd >= 0 else { throw OAuthFlowError.cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.acceptLoop(fd)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180) { [weak self] in
                self?.finish(OAuthFlowError.loopback("Sign-in timed out."))
                self?.stop()
            }
        }
    }

    func stop() {
        lock.lock()
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
    }

    private func currentFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return socketFD
    }

    private func acceptLoop(_ fd: Int32) {
        while currentFD() >= 0 {
            var clientAddress = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    accept(fd, pointer, &clientLength)
                }
            }
            if client < 0 {
                finish(OAuthFlowError.cancelled)
                return
            }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            let request = readRequest(client)
            if let url = Self.callbackURL(from: request) {
                writeResponse(client, status: "200 OK", body: Self.successHTML)
                close(client)
                finish(url)
                return
            }
            writeResponse(client, status: "404 Not Found", body: "Not found")
            close(client)
        }
    }

    private func readRequest(_ client: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeResponse(_ client: Int32, status: String, body: String) {
        let payload = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var bytes = Data(header.utf8)
        bytes.append(payload)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(client, base, raw.count)
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func finish(_ url: URL) { finish(.success(url)) }
    private func finish(_ error: Error) { finish(.failure(error)) }

    private static func callbackURL(from request: String) -> URL? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard target.contains("code=") || target.contains("error=") else { return nil }
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            return URL(string: target)
        }
        return URL(string: "http://127.0.0.1" + (target.hasPrefix("/") ? target : "/" + target))
    }

    private static let successHTML = """
    <!DOCTYPE html><html><head><title>Native Drive</title></head>
    <body style="font-family:-apple-system,sans-serif;padding:2rem">
    <p>Signed in. You can close this window and return to Native Drive.</p>
    </body></html>
    """
}
