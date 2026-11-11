import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DriveAPIError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden(String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String)
    case notFound
    case gone
    case badStatus(Int, String)
    case transport(String)
    case decoding(String)
    case offline
    case cancelled
    case missingUploadLocation

    public static func isOffline(_ error: Error) -> Bool {
        if let error = error as? DriveAPIError {
            if case .offline = error { return true }
            if case .transport = error { return false }
        }
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension DriveAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Sign-in expired. Add the account again to continue."
        case .forbidden(let message):
            return message.isEmpty ? "You don't have permission to do that." : message
        case .rateLimited:
            return "Google Drive is rate limiting requests. Try again in a moment."
        case .server(let status, let message):
            return message.isEmpty ? "Google Drive returned an error (\(status))." : message
        case .notFound:
            return "That file is no longer available."
        case .gone:
            return "Saved Drive changes were too old, so this folder was reloaded."
        case .badStatus(let status, let message):
            return message.isEmpty ? "Unexpected response (\(status))." : message
        case .transport(let message):
            return message
        case .decoding:
            return "Couldn't read Google Drive's response."
        case .offline:
            return "Can't reach Google Drive."
        case .cancelled:
            return "Cancelled."
        case .missingUploadLocation:
            return "Google Drive did not return an upload session."
        }
    }
}
