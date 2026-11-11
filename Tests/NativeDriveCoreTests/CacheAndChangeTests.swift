import XCTest
@testable import NativeDriveCore

final class CacheAndChangeTests: XCTestCase {
    func testChangeApplierUpdatesMovesStarsAndTrash() {
        let now = Date(timeIntervalSince1970: 50)
        var listings = [
            DriveLocation.myDrive.cacheKey: listing(DriveLocation.myDrive.cacheKey, [
                sampleFile(id: "folder", name: "Notes", mimeType: DriveMime.folder),
                sampleFile(id: "a", name: "Alpha")
            ]),
            "folder:notes": listing("folder:notes", [sampleFile(id: "a", name: "Alpha", parents: ["notes"])]),
            "folder:other": listing("folder:other", []),
            DriveLocation.starred.cacheKey: listing(DriveLocation.starred.cacheKey, [sampleFile(id: "a", name: "Alpha", starred: true)]),
            DriveLocation.trash.cacheKey: listing(DriveLocation.trash.cacheKey, []),
            DriveLocation.search(query: "alpha").cacheKey: listing(DriveLocation.search(query: "alpha").cacheKey, [sampleFile(id: "a", name: "Alpha")])
        ]

        let renamed = sampleFile(id: "a", name: "Beta", parents: ["other"])
        let touched = ChangeApplier.apply([
            DriveChange(fileId: "a", removed: false, file: renamed)
        ], to: &listings, now: now)

        XCTAssertTrue(touched.contains("folder:notes"))
        XCTAssertTrue(touched.contains("folder:other"))
        XCTAssertEqual(listings["folder:notes"]?.files.map(\.id), [])
        XCTAssertEqual(listings["folder:other"]?.files.map(\.name), ["Beta"])
        XCTAssertFalse(listings[DriveLocation.myDrive.cacheKey]?.files.contains(where: { $0.id == "a" }) == true)
        XCTAssertEqual(listings[DriveLocation.starred.cacheKey]?.files.map(\.id), [])
        XCTAssertEqual(listings[DriveLocation.search(query: "alpha").cacheKey]?.files.map(\.name), ["Beta"])

        var starred = sampleFile(id: "b", name: "Star", parents: ["root"], starred: true)
        _ = ChangeApplier.apply([DriveChange(fileId: "b", removed: false, file: starred)], to: &listings, now: now)
        XCTAssertEqual(listings[DriveLocation.myDrive.cacheKey]?.files.map(\.id), ["folder", "b"])
        XCTAssertEqual(listings[DriveLocation.starred.cacheKey]?.files.map(\.id), ["b"])

        starred.trashed = true
        _ = ChangeApplier.apply([DriveChange(fileId: "b", removed: false, file: starred)], to: &listings, now: now)
        XCTAssertFalse(listings[DriveLocation.myDrive.cacheKey]?.files.contains(where: { $0.id == "b" }) == true)
        XCTAssertEqual(listings[DriveLocation.trash.cacheKey]?.files.map(\.id), ["b"])

        _ = ChangeApplier.apply([DriveChange(fileId: "folder", removed: true, file: nil)], to: &listings, now: now)
        XCTAssertFalse(listings[DriveLocation.myDrive.cacheKey]?.files.contains(where: { $0.id == "folder" }) == true)
    }

    func testEmptyParentsDoNotEvictCachedFile() {
        var listings = [
            "folder:notes": listing("folder:notes", [sampleFile(id: "a", name: "Alpha", parents: ["notes"])])
        ]
        let partial = sampleFile(id: "a", name: "Renamed", parents: [])
        _ = ChangeApplier.apply([DriveChange(fileId: "a", removed: false, file: partial)], to: &listings)
        XCTAssertEqual(listings["folder:notes"]?.files.map(\.name), ["Renamed"])
    }

    func testCacheIsIsolatedPerAccount() async throws {
        let root = try temporaryDirectory()
        let cache = try DriveCache(rootDirectory: root)
        let ada = listing(DriveLocation.myDrive.cacheKey, [sampleFile(id: "1", name: "Ada file")])
        let grace = listing(DriveLocation.myDrive.cacheKey, [sampleFile(id: "2", name: "Grace file")])
        try await cache.saveListing(accountID: "ada@example.com", listing: ada)
        try await cache.saveListing(accountID: "grace@example.com", listing: grace)
        let loadedAda = try await cache.listing(accountID: "ada@example.com", key: DriveLocation.myDrive.cacheKey)
        let loadedGrace = try await cache.listing(accountID: "grace@example.com", key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(loadedAda?.files.map(\.name), ["Ada file"])
        XCTAssertEqual(loadedGrace?.files.map(\.name), ["Grace file"])

        try await cache.setStartPageToken(for: "ada@example.com", token: "cursor-ada")
        try await cache.saveDrives([SharedDrive(id: "d", name: "Team")], accountID: "ada@example.com")
        let adaToken = try await cache.startPageToken(for: "ada@example.com")
        let graceToken = try await cache.startPageToken(for: "grace@example.com")
        let adaDrives = try await cache.drives(for: "ada@example.com")
        XCTAssertEqual(adaToken, "cursor-ada")
        XCTAssertNil(graceToken)
        XCTAssertEqual(adaDrives.map(\.name), ["Team"])

        let moved = sampleFile(id: "1", name: "Moved", parents: ["other"])
        _ = try await cache.applyChanges(accountID: "ada@example.com", changes: [
            DriveChange(fileId: "1", removed: false, file: moved)
        ])
        let after = try await cache.listing(accountID: "ada@example.com", key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(after?.files, [])
        let graceAfter = try await cache.listing(accountID: "grace@example.com", key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(graceAfter?.files.map(\.name), ["Grace file"])

        try await cache.clear(accountID: "ada@example.com")
        let adaCleared = try await cache.listing(accountID: "ada@example.com", key: DriveLocation.myDrive.cacheKey)
        let graceKept = try await cache.listing(accountID: "grace@example.com", key: DriveLocation.myDrive.cacheKey)
        XCTAssertNil(adaCleared)
        XCTAssertEqual(graceKept?.files.map(\.id), ["2"])
    }

    func testAccountStorePersistsSeparatelyFromTokens() async throws {
        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("accounts.json")
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try AccountStore(fileURL: fileURL)
        try await store.upsert(DriveAccount(id: "ada@example.com", email: "ada@example.com", displayName: "Ada", pictureURL: nil, addedAt: added))
        try await store.upsert(DriveAccount(id: "grace@example.com", email: "grace@example.com", displayName: "Grace", pictureURL: nil, addedAt: added.addingTimeInterval(10)))
        try await store.upsert(DriveAccount(id: "ada@example.com", email: "ada@example.com", displayName: "Ada Lovelace", pictureURL: "https://example.com/a.png", addedAt: added.addingTimeInterval(100)))

        let reloaded = try AccountStore(fileURL: fileURL)
        let accounts = await reloaded.list()
        XCTAssertEqual(accounts.map(\.id), ["ada@example.com", "grace@example.com"])
        XCTAssertEqual(accounts[0].displayName, "Ada Lovelace")
        XCTAssertEqual(accounts[0].addedAt.timeIntervalSince1970, added.timeIntervalSince1970, accuracy: 0.001)

        let tokens = InMemoryTokenStore()
        await tokens.save(OAuthTokens(accessToken: "a", refreshToken: "ra", expiresAt: added), for: "ada@example.com")
        await tokens.save(OAuthTokens(accessToken: "g", refreshToken: "rg", expiresAt: added), for: "grace@example.com")
        await tokens.delete(for: "ada@example.com")
        let adaTokens = try await tokens.load(for: "ada@example.com")
        let graceTokens = try await tokens.load(for: "grace@example.com")
        XCTAssertNil(adaTokens)
        XCTAssertEqual(graceTokens?.refreshToken, "rg")
        try await reloaded.remove(id: "grace@example.com")
        let remaining = await reloaded.list()
        XCTAssertEqual(remaining.map(\.id), ["ada@example.com"])
    }
}
