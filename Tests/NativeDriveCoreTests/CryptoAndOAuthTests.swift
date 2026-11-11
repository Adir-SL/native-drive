import XCTest
@testable import NativeDriveCore

final class CryptoAndOAuthTests: XCTestCase {
    func testSHA256KnownVectors() {
        XCTAssertEqual(hex(SHA256.hash(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(SHA256.hash(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testPKCEChallengeMatchesRFC7636() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsURLSafe() {
        let verifier = PKCE.generateVerifier()
        XCTAssertEqual(verifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertFalse(PKCE.challenge(for: verifier).contains("="))
    }

    func testAuthorizationURLCarriesPKCEAndDoesNotLeakVerifier() throws {
        let config = OAuthClientConfig(
            clientID: "client",
            clientSecret: "secret",
            redirectURI: "http://127.0.0.1:1234",
            scopes: OAuthClientConfig.defaultScopes
        )
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let url = OAuthFlow.authorizationURL(config: config, codeChallenge: PKCE.challenge(for: verifier), state: "state-1")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }

        XCTAssertEqual(value("client_id"), "client")
        XCTAssertEqual(value("redirect_uri"), "http://127.0.0.1:1234")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("code_challenge"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "state-1")
        XCTAssertEqual(value("access_type"), "offline")
        XCTAssertEqual(value("prompt"), "consent select_account")
        XCTAssertTrue(value("scope")?.contains("https://www.googleapis.com/auth/drive") == true)
        XCTAssertNil(value("code_verifier"))
        XCTAssertNil(value("client_secret"))
        XCTAssertFalse(url.absoluteString.contains(verifier))
    }

    func testParseCallbackChecksStateAndCode() throws {
        let ok = URL(string: "nativedrive://oauth?state=abc&code=xyz")!
        XCTAssertEqual(try OAuthFlow.parseCallback(url: ok, expectedState: "abc"), "xyz")

        let mismatch = URL(string: "http://127.0.0.1:9/?state=nope&code=xyz")!
        XCTAssertThrowsError(try OAuthFlow.parseCallback(url: mismatch, expectedState: "abc")) { error in
            XCTAssertEqual(error as? OAuthFlowError, .stateMismatch)
        }

        let denied = URL(string: "http://127.0.0.1:9/?error=access_denied&state=abc")!
        XCTAssertThrowsError(try OAuthFlow.parseCallback(url: denied, expectedState: "abc")) { error in
            XCTAssertEqual(error as? OAuthFlowError, .cancelled)
        }
    }

    func testTokenResponseKeepsExistingRefreshToken() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = #"{"access_token":"new","expires_in":120,"scope":"email"}"#
        let tokens = try OAuthFlow.parseTokenResponse(data: Data(json.utf8), existingRefreshToken: "keep-me", now: now)
        XCTAssertEqual(tokens.accessToken, "new")
        XCTAssertEqual(tokens.refreshToken, "keep-me")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(120))
    }

    func testTokenResponseRequiresRefreshTokenOnFirstExchange() {
        let json = #"{"access_token":"new","expires_in":120}"#
        XCTAssertThrowsError(try OAuthFlow.parseTokenResponse(data: Data(json.utf8), existingRefreshToken: nil))
    }

    func testProviderErrorIsSurfaced() {
        let json = #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#
        XCTAssertThrowsError(try OAuthFlow.parseTokenResponse(data: Data(json.utf8), existingRefreshToken: "x")) { error in
            XCTAssertEqual(error as? OAuthFlowError, .provider("Token has been expired or revoked."))
        }
    }

    func testCodeExchangeRequestIncludesVerifierAndOptionalSecret() throws {
        let withSecret = OAuthClientConfig(clientID: "id", clientSecret: "s3cret", redirectURI: "http://127.0.0.1:1")
        let request = OAuthFlow.authorizationCodeRequest(config: withSecret, code: "code", verifier: "verifier")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)
        XCTAssertTrue(body.contains("code_verifier=verifier"))
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("client_secret=s3cret"))
        XCTAssertEqual(request.url.host, "oauth2.googleapis.com")

        let without = OAuthClientConfig(clientID: "id", clientSecret: nil, redirectURI: "scheme:/oauth2callback")
        let refresh = OAuthFlow.refreshRequest(config: without, refreshToken: "refresh")
        let refreshBody = String(decoding: try XCTUnwrap(refresh.body), as: UTF8.self)
        XCTAssertFalse(refreshBody.contains("client_secret"))
        XCTAssertTrue(refreshBody.contains("refresh_token=refresh"))
    }

    func testIDTokenEmailClaim() throws {
        let payload = Base64URL.encode(Data(#"{"email":"ada@example.com","name":"Ada"}"#.utf8))
        let jwt = "eyJhbGciOiJub25lIn0.\(payload).sig"
        XCTAssertEqual(IDTokenClaims.string("email", jwt: jwt), "ada@example.com")
        XCTAssertEqual(IDTokenClaims.string("name", jwt: jwt), "Ada")
    }

    func testRefreshingProviderRefreshesWhenExpiredAndPersistsTokens() async throws {
        let store = InMemoryTokenStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let original = OAuthTokens(accessToken: "old", refreshToken: "refresh-1", expiresAt: now.addingTimeInterval(-10))
        await store.save(original, for: "ada@example.com")
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"access_token":"new","expires_in":3600}"#)
        ])
        let provider = RefreshingTokenProvider(
            accountID: "ada@example.com",
            config: OAuthClientConfig(clientID: "id", clientSecret: nil, redirectURI: "http://127.0.0.1"),
            store: store,
            http: http,
            now: { now }
        )
        let token = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(token, "new")
        let saved = try await store.load(for: "ada@example.com")
        XCTAssertEqual(saved?.accessToken, "new")
        XCTAssertEqual(saved?.refreshToken, "refresh-1")
        let request = try await http.recorded().first
        let body = String(decoding: try XCTUnwrap(request?.body), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=refresh-1"))
        XCTAssertFalse(body.contains("old"))

        let other = try await store.load(for: "other@example.com")
        XCTAssertNil(other)
    }

    func testFreshTokenSkipsNetworkUntilForced() async throws {
        let store = InMemoryTokenStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await store.save(OAuthTokens(accessToken: "alive", refreshToken: "r", expiresAt: now.addingTimeInterval(3600)), for: "a")
        let http = MockHTTPClient(responses: [httpJSON(200, #"{"access_token":"forced","expires_in":10}"#)])
        let provider = RefreshingTokenProvider(
            accountID: "a",
            config: OAuthClientConfig(clientID: "id", clientSecret: "secret", redirectURI: "http://127.0.0.1"),
            store: store,
            http: http,
            now: { now }
        )
        let first = try await provider.accessToken(forceRefresh: false)
        XCTAssertEqual(first, "alive")
        let beforeForce = await http.recorded()
        XCTAssertTrue(beforeForce.isEmpty)
        let forced = try await provider.accessToken(forceRefresh: true)
        XCTAssertEqual(forced, "forced")
        let afterForce = await http.recorded()
        XCTAssertEqual(afterForce.count, 1)
    }
}
