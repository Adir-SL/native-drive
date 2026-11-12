import XCTest
@testable import NativeDriveCore

final class SharedItemTests: XCTestCase {
    func testSharedDetection() throws {
        XCTAssertTrue(SharedItem.isShared(shared: true, ownedByMe: true))
        XCTAssertTrue(SharedItem.isShared(shared: true, ownedByMe: nil))
        XCTAssertTrue(SharedItem.isShared(shared: false, ownedByMe: false))
        XCTAssertTrue(SharedItem.isShared(shared: nil, ownedByMe: false))
        XCTAssertFalse(SharedItem.isShared(shared: false, ownedByMe: true))
        XCTAssertFalse(SharedItem.isShared(shared: nil, ownedByMe: nil))
        XCTAssertFalse(SharedItem.isShared(shared: nil, ownedByMe: true))

        let page = try DriveFilePage.decode(Data(#"""
        {"files":[
          {"id":"mine","name":"Notes","mimeType":"text/plain","shared":false,"ownedByMe":true},
          {"id":"ours","name":"Plans","mimeType":"application/vnd.google-apps.folder","shared":true,"ownedByMe":true},
          {"id":"theirs","name":"Budget","mimeType":"application/vnd.google-apps.spreadsheet","ownedByMe":false}
        ]}
        """#.utf8))
        let byID = Dictionary(uniqueKeysWithValues: page.files.map { ($0.id, $0) })
        XCTAssertEqual(byID["mine"]?.showsAsShared, false)
        XCTAssertEqual(byID["ours"]?.showsAsShared, true)
        XCTAssertEqual(byID["theirs"]?.showsAsShared, true)
        XCTAssertEqual(byID["ours"]?.isFolder, true)

        XCTAssertTrue(DriveFields.fileList.contains("shared"))
        XCTAssertTrue(DriveFields.fileList.contains("ownedByMe"))
        XCTAssertFalse(DriveFields.fileList.contains("permissions"))
        XCTAssertFalse(DriveFields.fileList.contains("writersCanShare"))

        let stale = CachedListing(key: "myDrive", files: [], nextPageToken: nil, fetchedAt: Date(), version: 3)
        XCTAssertFalse(stale.isCurrent)
        XCTAssertEqual(ListingCacheVersion.current, 4)
        XCTAssertTrue(CachedListing(key: "myDrive", files: [], nextPageToken: nil, fetchedAt: Date()).isCurrent)
    }
}
