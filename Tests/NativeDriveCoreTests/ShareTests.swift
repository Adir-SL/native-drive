import XCTest
@testable import NativeDriveCore

final class ShareTests: XCTestCase {
    func testPermissionListParsesInheritedAndSortsOwnerFirst() throws {
        let json = """
        {"permissions":[
          {"id":"any","type":"anyone","role":"reader","allowFileDiscovery":false},
          {"id":"ada","type":"user","role":"writer","emailAddress":"Ada@Example.com","displayName":"Ada","permissionDetails":[{"inherited":true,"inheritedFrom":"parent","role":"writer"}]},
          {"id":"own","type":"user","role":"owner","emailAddress":"owner@example.com","displayName":"Owner"},
          {"id":"pending","type":"user","role":"writer","emailAddress":"new@example.com","displayName":"New","pendingOwner":true},
          {"id":"dom","type":"domain","role":"commenter","domain":"example.com","allowFileDiscovery":false}
        ]}
        """
        let page = try JSONDecoder().decode(PermissionListPayloadMirror.self, from: Data(json.utf8))
        let sorted = ShareList.sorted(page.permissions)
        XCTAssertEqual(sorted.map(\.id), ["own", "pending", "ada", "dom", "any"])
        XCTAssertTrue(page.permissions.first { $0.id == "ada" }?.isInherited == true)
        XCTAssertFalse(page.permissions.first { $0.id == "own" }?.isInherited == true)
        let people = ShareList.people(page.permissions)
        XCTAssertEqual(people.map(\.id), ["own", "pending", "ada"])
        XCTAssertEqual(ShareList.generalAccess(in: page.permissions), .anyone(role: .reader, discoverable: false))
        XCTAssertEqual(ShareRole.title(for: "writer"), "Editor")
        XCTAssertFalse(ShareRole.writer.allowsExpiration)
        XCTAssertTrue(ShareRole.reader.allowsExpiration)
    }

    func testGeneralAccessEditRemovesLinkGrantsWithoutDuplicates() {
        let start = [
            DrivePermission(id: "own", type: "user", role: "owner", emailAddress: "owner@example.com"),
            DrivePermission(id: "any", type: "anyone", role: "reader", allowFileDiscovery: false),
            DrivePermission(id: "dom", type: "domain", role: "reader", domain: "example.com")
        ]
        let restricted = ShareList.applying(.restricted, to: start)
        XCTAssertEqual(restricted.map(\.id), ["own"])
        let domain = ShareList.applying(.domain(domain: "example.com", role: .commenter, discoverable: false), to: start)
        XCTAssertEqual(domain.map(\.type), ["user", "domain"])
        XCTAssertEqual(domain.first { $0.type == "domain" }?.id, "dom")
        XCTAssertEqual(domain.first { $0.type == "domain" }?.role, "commenter")
        let added = ShareList.upsert(DrivePermission.optimistic(email: "ada@example.com", role: .writer, id: "local:1"), into: restricted)
        let confirmed = ShareList.upsert(
            DrivePermission(id: "real", type: "user", role: "writer", emailAddress: "ada@example.com", displayName: "Ada"),
            into: added
        )
        XCTAssertEqual(confirmed.filter { $0.emailAddress == "ada@example.com" }.map(\.id), ["real"])
    }

    func testPermissionRequestsAndGrantBody() throws {
        let list = PermissionRequests.listQuery(pageToken: nil)
        XCTAssertEqual(list.first { $0.name == "supportsAllDrives" }?.value, "true")
        let fields = list.first { $0.name == "fields" }?.value ?? ""
        XCTAssertTrue(fields.contains("emailAddress"))
        XCTAssertTrue(fields.contains("permissionDetails"))
        XCTAssertTrue(fields.contains("expirationTime"))
        let create = PermissionRequests.createQuery(sendNotification: true, message: "Hello", transferOwnership: false)
        XCTAssertEqual(create.first { $0.name == "sendNotificationEmail" }?.value, "true")
        XCTAssertEqual(create.first { $0.name == "emailMessage" }?.value, "Hello")
        XCTAssertFalse(create.contains { $0.name == "transferOwnership" })
        let transfer = PermissionRequests.updateQuery(transferOwnership: true)
        XCTAssertEqual(transfer.first { $0.name == "transferOwnership" }?.value, "true")
        XCTAssertEqual(PermissionRequests.deleteQuery().first?.name, "supportsAllDrives")

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let body = try PermissionWrite(
            type: "user",
            role: "reader",
            emailAddress: "ada@example.com",
            expirationTime: when
        ).encoded()
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(object?["emailAddress"] as? String, "ada@example.com")
        XCTAssertEqual(object?["role"] as? String, "reader")
        XCTAssertEqual(object?["expirationTime"] as? String, ShareDate.format(when))
        let cleared = try PermissionWrite(role: "writer", clearExpiration: true).encoded()
        let clearedObject = try JSONSerialization.jsonObject(with: cleared) as? [String: Any]
        XCTAssertTrue(clearedObject?["expirationTime"] is NSNull)
    }

    func testListAndCreatePermissionCalls() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"permissions":[{"id":"own","type":"user","role":"owner","emailAddress":"a@example.com"}],"nextPageToken":"p2"}"#),
            httpJSON(200, #"{"permissions":[{"id":"ada","type":"user","role":"reader","emailAddress":"ada@example.com"}]}"#),
            httpJSON(200, #"{"id":"ada","type":"user","role":"reader","emailAddress":"ada@example.com"}"#)
        ])
        let client = makeClient(http: http)
        let listed = try await client.listPermissions(fileID: "file 1")
        XCTAssertEqual(listed.map(\.id), ["own", "ada"])
        let created = try await client.createPermission(
            fileID: "file 1",
            permission: PermissionWrite(type: "user", role: "reader", emailAddress: "ada@example.com"),
            sendNotification: false,
            message: nil
        )
        XCTAssertEqual(created.emailAddress, "ada@example.com")
        let recorded = await http.recorded()
        XCTAssertTrue(recorded[0].url.absoluteString.contains("/files/file%201/permissions"))
        XCTAssertTrue(recorded[0].url.absoluteString.contains("supportsAllDrives=true"))
        XCTAssertEqual(recorded[2].method, "POST")
        XCTAssertEqual(recorded[2].url.absoluteString.contains("sendNotificationEmail=false"), true)
    }

    func testEmailsCollaboratorsOwnershipAndWorkspaceDomain() {
        XCTAssertTrue(ShareEmail.isValid("Ada@Example.com"))
        XCTAssertFalse(ShareEmail.isValid("not an email"))
        XCTAssertEqual(ShareEmail.tokens(in: "a@b.co, a@b.co; c@d.eo"), ["a@b.co", "c@d.eo"])
        var directory = CollaboratorDirectory(limit: 2)
        directory.remember([
            DrivePermission(id: "1", type: "user", role: "reader", emailAddress: "ada@example.com", displayName: "Ada"),
            DrivePermission(id: "2", type: "user", role: "reader", emailAddress: "bea@example.com", displayName: "Bea")
        ])
        directory.remember(Collaborator(email: "cy@example.com", name: "Cy"))
        XCTAssertEqual(directory.suggestions(matching: "ada").map(\.email), [])
        XCTAssertEqual(directory.suggestions(matching: "be").map(\.name), ["Bea"])
        XCTAssertEqual(OwnershipTransfer.kind(ownerEmail: "owner@example.com", recipientEmail: "new@example.com"), .immediate)
        XCTAssertEqual(OwnershipTransfer.kind(ownerEmail: "owner@gmail.com", recipientEmail: "new@gmail.com"), .pending)
        XCTAssertEqual(OwnershipTransfer.kind(ownerEmail: "owner@example.com", recipientEmail: "new@other.com"), .pending)
        let payload = Data(#"{"hd":"Example.com","email":"a@example.com"}"#.utf8)
        let token = "header.\(Base64URL.encode(payload)).sig"
        XCTAssertEqual(ShareAccount.workspaceDomain(email: "a@example.com", idToken: token), "example.com")
        XCTAssertNil(ShareAccount.workspaceDomain(email: "a@gmail.com", idToken: "header.\(Base64URL.encode(Data(#"{"email":"a@gmail.com"}"#.utf8))).sig"))
    }
}

private struct PermissionListPayloadMirror: Decodable {
    var permissions: [DrivePermission]
}
