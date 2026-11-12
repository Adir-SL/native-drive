import XCTest
@testable import NativeDriveCore

final class ListingPaginationTests: XCTestCase {
    func testWalkKeepsAFolderThatArrivesAfterTheFirstThousand() {
        let firstPage = (0..<1000).map { sampleFile(id: "file-\($0)", name: String(format: "file-%04d", $0)) }
        let lateFolder = sampleFile(id: "late-folder", name: "Zebra", mimeType: DriveMime.folder)
        let listing = ListingWalk.accumulate(
            pages: [
                FilePage(files: firstPage, nextPageToken: "page-2"),
                FilePage(files: [lateFolder], nextPageToken: nil)
            ],
            key: DriveLocation.myDrive.cacheKey,
            now: Date(timeIntervalSince1970: 50)
        )
        XCTAssertTrue(listing.files.contains { $0.id == "late-folder" })
        XCTAssertEqual(listing.files.count, 1001)
        XCTAssertNil(listing.nextPageToken)
        XCTAssertTrue(listing.isComplete)
        XCTAssertEqual(listing.files.first?.id, "late-folder")
    }

    func testPartialPageCannotReplaceACompleteListing() {
        var files = (0..<1000).map { sampleFile(id: "file-\($0)", name: String(format: "file-%04d", $0)) }
        let lateFolder = sampleFile(id: "late-folder", name: "Zebra", mimeType: DriveMime.folder)
        files.append(lateFolder)
        let complete = CachedListing(
            key: DriveLocation.myDrive.cacheKey,
            files: files,
            nextPageToken: nil,
            fetchedAt: Date(timeIntervalSince1970: 10)
        )
        let partial = CachedListing(
            key: complete.key,
            files: Array(files.prefix(1000)),
            nextPageToken: "page-2",
            fetchedAt: Date(timeIntervalSince1970: 90)
        )
        let resolved = ListingCacheWrite.resolve(existing: complete, incoming: partial)
        XCTAssertTrue(resolved.files.contains { $0.id == "late-folder" })
        XCTAssertEqual(resolved.files.count, 1001)
        XCTAssertNil(resolved.nextPageToken)
        XCTAssertTrue(resolved.isComplete)
        XCTAssertEqual(resolved.fetchedAt, complete.fetchedAt)
    }

    func testUnfinishedOrFailedWalkDoesNotDropLaterFolders() {
        let files = [
            sampleFile(id: "page-1", name: "A"),
            sampleFile(id: "late-folder", name: "Zebra", mimeType: DriveMime.folder)
        ]
        XCTAssertNil(ListingWalk.finalize(
            files: files,
            seen: ["page-1"],
            key: DriveLocation.myDrive.cacheKey,
            nextPageToken: "page-2",
            failed: false
        ))
        XCTAssertNil(ListingWalk.finalize(
            files: files,
            seen: ["page-1"],
            key: DriveLocation.myDrive.cacheKey,
            nextPageToken: nil,
            failed: true
        ))
        let finished = ListingWalk.finalize(
            files: files,
            seen: ["page-1", "late-folder"],
            key: DriveLocation.myDrive.cacheKey,
            nextPageToken: "   ",
            failed: false
        )
        XCTAssertEqual(finished?.files.map(\.id).sorted(), ["late-folder", "page-1"])
        XCTAssertNil(finished?.nextPageToken)
    }

    func testLegacyCacheEntriesAreIgnoredUntilRefetched() async throws {
        let root = try temporaryDirectory()
        let cache = try DriveCache(rootDirectory: root)
        let current = CachedListing(
            key: DriveLocation.myDrive.cacheKey,
            files: [sampleFile(id: "1", name: "Notes", mimeType: DriveMime.folder)],
            nextPageToken: nil,
            fetchedAt: Date(timeIntervalSince1970: 20)
        )
        try await cache.saveListing(accountID: "ada@example.com", listing: current)
        let loaded = try await cache.listing(accountID: "ada@example.com", key: current.key)
        XCTAssertEqual(loaded?.files.map(\.id), ["1"])

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var listingURL: URL?
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "json", url.lastPathComponent != "meta.json" {
                listingURL = url
                break
            }
        }
        let url = try XCTUnwrap(listingURL)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        var legacy = try XCTUnwrap(object)
        legacy.removeValue(forKey: "version")
        try JSONSerialization.data(withJSONObject: legacy).write(to: url)
        let ignored = try await cache.listing(accountID: "ada@example.com", key: current.key)
        XCTAssertNil(ignored)
    }

    func testListRequestKeepsTheNextPageTokenAndDoesNotHideShortcuts() throws {
        let query = DriveQueryBuilder.filesList(for: .folder(id: "parent", name: "Parent", sharedDriveID: nil), pageToken: "page-2")
        XCTAssertEqual(query.q, "'parent' in parents and trashed = false")
        XCTAssertEqual(query.pageToken, "page-2")
        XCTAssertEqual(query.pageSize, 1000)
        XCTAssertTrue(query.includeItemsFromAllDrives)
        XCTAssertTrue(DriveFields.fileList.hasPrefix("files("))
        XCTAssertTrue(DriveFields.fileList.contains("nextPageToken"))
        XCTAssertEqual(
            MediaClassifier.kind(mimeType: DriveMime.shortcut, fileName: "Shared folder"),
            .other
        )
    }
}
