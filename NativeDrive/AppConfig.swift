import Foundation
import NativeDriveCore

enum AppConfig {
    static var clientID: String { string("GOOGLE_CLIENT_ID") }

    static var clientSecret: String? {
        let value = string("GOOGLE_CLIENT_SECRET")
        return value.isEmpty ? nil : value
    }

    static var redirectScheme: String {
        let value = string("GOOGLE_OAUTH_REDIRECT_SCHEME")
        return value.isEmpty || value.contains("$") ? "nativedrive" : value
    }

    static var useLoopback: Bool {
        let value = string("GOOGLE_OAUTH_USE_LOOPBACK").uppercased()
        if value.isEmpty || value.contains("$") { return true }
        return value == "YES" || value == "TRUE" || value == "1"
    }

    static var isConfigured: Bool {
        let id = clientID
        return !id.isEmpty && !id.contains("$") && !id.hasPrefix("YOUR_")
    }

    static var configurationSummary: String {
        let secret = clientSecret == nil ? "not set" : "set"
        let mode = useLoopback ? "loopback on 127.0.0.1 (Desktop client)" : "custom scheme \(redirectScheme):/oauth2callback"
        return """
        Client ID: \(isConfigured ? clientID : "not set")
        Client secret: \(secret)
        Sign-in: \(mode)
        """
    }

    static func oauthConfig() -> OAuthClientConfig? {
        guard isConfigured else { return nil }
        let redirect = useLoopback ? "http://127.0.0.1" : "\(redirectScheme):/oauth2callback"
        return OAuthClientConfig(clientID: clientID, clientSecret: clientSecret, redirectURI: redirect)
    }

    private static func string(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppPaths {
    static func supportDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = root.appendingPathComponent("NativeDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func downloadCacheDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = root.appendingPathComponent("NativeDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
