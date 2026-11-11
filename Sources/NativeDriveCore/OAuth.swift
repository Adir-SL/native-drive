import Foundation

public struct OAuthClientConfig: Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: String
    public var scopes: [String]

    public static let defaultScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/drive"
    ]

    public init(clientID: String, clientSecret: String?, redirectURI: String, scopes: [String] = OAuthClientConfig.defaultScopes) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

public struct OAuthTokens: Codable, Equatable, Sendable, CustomStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String?
    public var idToken: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String? = nil, idToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.idToken = idToken
    }

    public func needsRefresh(at now: Date, skew: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(now) <= skew
    }

    public var description: String {
        "OAuthTokens(expiresAt: \(expiresAt), scope: \(scope ?? ""))"
    }
}

public enum OAuthFlowError: Error, Equatable, LocalizedError {
    case missingClientID
    case cancelled
    case stateMismatch
    case missingCode
    case provider(String)
    case loopback(String)
    case presentationFailed

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Add a Google OAuth client ID in Config.local.xcconfig, then rebuild."
        case .cancelled:
            return "Sign-in was cancelled."
        case .stateMismatch:
            return "The sign-in response didn't match this request. Try again."
        case .missingCode:
            return "Google didn't return an authorization code."
        case .provider(let message):
            return message
        case .loopback(let message):
            return message
        case .presentationFailed:
            return "The sign-in window couldn't be opened."
        }
    }
}

public enum OAuthFlow {
    public static func authorizationURL(config: OAuthClientConfig, codeChallenge: String, state: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "accounts.google.com"
        components.path = "/o/oauth2/v2/auth"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent select_account"),
            URLQueryItem(name: "include_granted_scopes", value: "true")
        ]
        guard let url = components.url else {
            preconditionFailure("Failed to build the Google authorization URL.")
        }
        return url
    }

    public static func parseCallback(url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthFlowError.missingCode
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        if let error = value("error") {
            if error == "access_denied" {
                throw OAuthFlowError.cancelled
            }
            throw OAuthFlowError.provider(value("error_description") ?? error)
        }
        guard let state = value("state"), state == expectedState else {
            throw OAuthFlowError.stateMismatch
        }
        guard let code = value("code"), !code.isEmpty else {
            throw OAuthFlowError.missingCode
        }
        return code
    }

    public static func authorizationCodeRequest(config: OAuthClientConfig, code: String, verifier: String) -> HTTPRequest {
        tokenRequest(config: config, fields: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": config.redirectURI
        ])
    }

    public static func refreshRequest(config: OAuthClientConfig, refreshToken: String) -> HTTPRequest {
        tokenRequest(config: config, fields: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    public static func exchange(
        code: String,
        verifier: String,
        config: OAuthClientConfig,
        http: any HTTPClient,
        now: Date = Date()
    ) async throws -> OAuthTokens {
        let request = authorizationCodeRequest(config: config, code: code, verifier: verifier)
        let response = try await send(request, http: http)
        return try parseTokenResponse(data: response.body, existingRefreshToken: nil, now: now)
    }

    public static func parseTokenResponse(data: Data, existingRefreshToken: String?, now: Date = Date()) throws -> OAuthTokens {
        if let message = providerMessage(data), !data.containsAccessToken {
            throw OAuthFlowError.provider(message)
        }
        let payload: TokenPayload
        do {
            payload = try JSONDecoder().decode(TokenPayload.self, from: data)
        } catch {
            throw OAuthFlowError.provider("Google returned an unreadable token response.")
        }
        guard !payload.accessToken.isEmpty else {
            throw OAuthFlowError.provider("Google did not return an access token.")
        }
        guard let refresh = payload.refreshToken ?? existingRefreshToken, !refresh.isEmpty else {
            throw OAuthFlowError.provider("Google did not return a refresh token. Remove Native Drive's access in your Google Account permissions, then sign in again.")
        }
        let lifetime = TimeInterval(payload.expiresIn ?? 3600)
        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: refresh,
            expiresAt: now.addingTimeInterval(lifetime),
            scope: payload.scope,
            idToken: payload.idToken
        )
    }

    public static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func tokenRequest(config: OAuthClientConfig, fields: [String: String]) -> HTTPRequest {
        var pairs = ["client_id=\(formEncode(config.clientID))"]
        if let secret = config.clientSecret, !secret.isEmpty {
            pairs.append("client_secret=\(formEncode(secret))")
        }
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            pairs.append("\(formEncode(key))=\(formEncode(value))")
        }
        let body = pairs.joined(separator: "&")
        return HTTPRequest(
            method: "POST",
            url: URL(string: "https://oauth2.googleapis.com/token")!,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 30
        )
    }

    private static func send(_ request: HTTPRequest, http: any HTTPClient) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch let error as OAuthFlowError {
            throw error
        } catch {
            throw OAuthFlowError.provider(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            if let message = providerMessage(response.body) {
                throw OAuthFlowError.provider(message)
            }
            throw OAuthFlowError.provider("Token request failed (\(response.status)).")
        }
        return response
    }

    private static func providerMessage(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let description = json["error_description"] as? String, !description.isEmpty {
            return description
        }
        if let error = json["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }
}

public enum IDTokenClaims {
    public static func string(_ name: String, jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let data = Base64URL.decode(String(parts[1])) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[name] as? String
    }
}

private struct TokenPayload: Decodable {
    var accessToken: String
    var expiresIn: Int?
    var refreshToken: String?
    var scope: String?
    var idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
        case idToken = "id_token"
    }
}

private extension Data {
    var containsAccessToken: Bool {
        guard let json = try? JSONSerialization.jsonObject(with: self) as? [String: Any] else { return false }
        if let token = json["access_token"] as? String {
            return !token.isEmpty
        }
        return false
    }
}
