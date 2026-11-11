import Foundation

public protocol TokenStore: Sendable {
    func save(_ tokens: OAuthTokens, for accountID: String) async throws
    func load(for accountID: String) async throws -> OAuthTokens?
    func delete(for accountID: String) async throws
    func deleteAll() async throws
}

public actor InMemoryTokenStore: TokenStore {
    private var values: [String: OAuthTokens] = [:]

    public init() {}

    public func save(_ tokens: OAuthTokens, for accountID: String) async {
        values[accountID] = tokens
    }

    public func load(for accountID: String) async -> OAuthTokens? {
        values[accountID]
    }

    public func delete(for accountID: String) async {
        values[accountID] = nil
    }

    public func deleteAll() async {
        values.removeAll()
    }
}

public protocol AccessTokenProviding: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public struct LiteralTokenProvider: AccessTokenProviding {
    public var token: String

    public init(token: String) {
        self.token = token
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        token
    }
}

public actor RefreshingTokenProvider: AccessTokenProviding {
    private let accountID: String
    private let config: OAuthClientConfig
    private let store: any TokenStore
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private var cached: OAuthTokens?
    private var inflight: Task<OAuthTokens, Error>?

    public init(
        accountID: String,
        config: OAuthClientConfig,
        store: any TokenStore,
        http: any HTTPClient,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.accountID = accountID
        self.config = config
        self.store = store
        self.http = http
        self.now = now
    }

    public func accessToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh {
            let tokens = try await currentTokens()
            if !tokens.needsRefresh(at: now()) {
                return tokens.accessToken
            }
        }
        return try await refreshCoalesced().accessToken
    }

    private func currentTokens() async throws -> OAuthTokens {
        if let cached {
            return cached
        }
        guard let stored = try await store.load(for: accountID) else {
            throw DriveAPIError.unauthorized
        }
        cached = stored
        return stored
    }

    private func refreshCoalesced() async throws -> OAuthTokens {
        if let inflight {
            return try await inflight.value
        }
        let task = Task { try await self.refresh() }
        inflight = task
        do {
            let tokens = try await task.value
            inflight = nil
            return tokens
        } catch {
            inflight = nil
            throw error
        }
    }

    private func refresh() async throws -> OAuthTokens {
        let existing = try await currentTokens()
        let request = OAuthFlow.refreshRequest(config: config, refreshToken: existing.refreshToken)
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw DriveAPIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.status) else {
            throw DriveAPIError.unauthorized
        }
        let tokens = try OAuthFlow.parseTokenResponse(data: response.body, existingRefreshToken: existing.refreshToken, now: now())
        cached = tokens
        try await store.save(tokens, for: accountID)
        return tokens
    }
}
