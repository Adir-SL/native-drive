import XCTest
@testable import NativeDriveCore

final class AccountIdentityTests: XCTestCase {
    func testSameDisplayNameUsesDistinctEmails() {
        let added = Date(timeIntervalSince1970: 10)
        let first = DriveAccount(id: "ada@example.com", email: "ada@example.com", displayName: "Alex", pictureURL: nil, addedAt: added)
        let second = DriveAccount(id: "bea@example.com", email: "bea@example.com", displayName: "Alex", pictureURL: nil, addedAt: added)
        XCTAssertEqual(first.title, "ada@example.com")
        XCTAssertEqual(second.title, "bea@example.com")
        XCTAssertEqual(first.subtitle, "Alex")
        XCTAssertNotEqual(first.title, second.title)
        XCTAssertNil(DriveAccount(id: "ada@example.com", email: "ada@example.com", displayName: "ada@example.com", pictureURL: nil, addedAt: added).subtitle)
    }

    func testMigrationFillsAMissingEmailWithoutReplacingAStoredOne() throws {
        let added = Date(timeIntervalSince1970: 10)
        let stored = DriveAccount(id: "perm", email: "perm", displayName: "Alex", pictureURL: nil, addedAt: added)
        let fromAbout = AccountEmailMigration.resolve(
            stored: stored,
            aboutEmail: "Ada@Example.com",
            aboutName: "Alex",
            aboutPicture: "https://example.com/a.png",
            userInfoEmail: "other@example.com",
            userInfoName: nil,
            userInfoPicture: nil,
            idToken: nil
        )
        XCTAssertEqual(fromAbout?.email, "Ada@Example.com")
        XCTAssertEqual(fromAbout?.id, "perm")
        XCTAssertEqual(fromAbout?.pictureURL, "https://example.com/a.png")

        let payload = Base64URL.encode(Data(#"{"email":"ada@example.com"}"#.utf8))
        let fromToken = AccountEmailMigration.resolve(
            stored: stored,
            aboutEmail: nil,
            aboutName: nil,
            aboutPicture: nil,
            userInfoEmail: nil,
            userInfoName: "Alex Smith",
            userInfoPicture: nil,
            idToken: "header.\(payload).sig"
        )
        XCTAssertEqual(fromToken?.email, "ada@example.com")
        XCTAssertEqual(fromToken?.displayName, "Alex Smith")

        let fromUserInfo = AccountEmailMigration.resolve(
            stored: stored,
            aboutEmail: " ",
            aboutName: nil,
            aboutPicture: nil,
            userInfoEmail: "bea@example.com",
            userInfoName: nil,
            userInfoPicture: nil,
            idToken: nil
        )
        XCTAssertEqual(fromUserInfo?.email, "bea@example.com")
        XCTAssertNil(AccountEmailMigration.resolve(
            stored: DriveAccount(id: "ada@example.com", email: "ada@example.com", displayName: "Alex", pictureURL: nil, addedAt: added),
            aboutEmail: "other@example.com",
            aboutName: nil,
            aboutPicture: nil,
            userInfoEmail: nil,
            userInfoName: nil,
            userInfoPicture: nil,
            idToken: nil
        ))
        XCTAssertNil(AccountEmailMigration.resolve(
            stored: stored,
            aboutEmail: nil,
            aboutName: nil,
            aboutPicture: nil,
            userInfoEmail: nil,
            userInfoName: nil,
            userInfoPicture: nil,
            idToken: nil
        ))
    }

    func testStoredAccountWithoutAnEmailKeyStillDecodes() throws {
        let added = Date(timeIntervalSince1970: 10)
        let account = DriveAccount(id: "perm", email: "perm", displayName: "Alex", pictureURL: nil, addedAt: added, hostedDomain: "example.com")
        var object = try JSONSerialization.jsonObject(with: JSONCoders.makeEncoder().encode(account)) as? [String: Any]
        object?.removeValue(forKey: "email")
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object))
        let decoded = try JSONCoders.makeDecoder().decode(DriveAccount.self, from: data)
        XCTAssertEqual(decoded.email, "")
        XCTAssertEqual(decoded.displayName, "Alex")
        XCTAssertEqual(decoded.hostedDomain, "example.com")
        XCTAssertEqual(decoded.title, "Alex")
    }
}

final class UserInfoTests: XCTestCase {
    func testUserInfoReadsEmailFromTheOpenIDEndpoint() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"email":"ada@example.com","name":"Alex","picture":"https://example.com/a.png"}"#)
        ])
        let client = makeClient(http: http)
        let info = try await client.userInfo()
        XCTAssertEqual(info.email, "ada@example.com")
        XCTAssertEqual(info.name, "Alex")
        let recorded = await http.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.url.absoluteString, "https://www.googleapis.com/oauth2/v3/userinfo")
        XCTAssertEqual(request.headers["Authorization"], "Bearer token")
    }
}
