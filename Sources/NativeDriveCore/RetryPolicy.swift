import Foundation

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var initialDelayNanoseconds: UInt64
    public var maxDelayNanoseconds: UInt64
    public var sleep: @Sendable (UInt64) async throws -> Void

    public init(
        maxAttempts: Int = 5,
        initialDelayNanoseconds: UInt64 = 500_000_000,
        maxDelayNanoseconds: UInt64 = 8_000_000_000,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        }
    ) {
        self.maxAttempts = maxAttempts
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.maxDelayNanoseconds = maxDelayNanoseconds
        self.sleep = sleep
    }

    public func execute<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        var delay = initialDelayNanoseconds
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DriveAPIError {
                let waitHint: UInt64?
                switch error {
                case .rateLimited(let retryAfter):
                    lastError = error
                    waitHint = retryAfter.map { UInt64(max(0, $0) * 1_000_000_000) }
                case .server:
                    lastError = error
                    waitHint = nil
                default:
                    throw error
                }
                if attempt == maxAttempts - 1 {
                    break
                }
                let wait = min(max(delay, waitHint ?? 0), maxDelayNanoseconds)
                try await sleep(wait)
                if delay > maxDelayNanoseconds / 2 {
                    delay = maxDelayNanoseconds
                } else {
                    delay *= 2
                }
            }
        }
        throw lastError ?? DriveAPIError.server(status: 500, message: "Request failed.")
    }
}
