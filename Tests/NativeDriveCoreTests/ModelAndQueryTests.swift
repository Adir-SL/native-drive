import XCTest
@testable import NativeDriveCore

final class ModelAndQueryTests: XCTestCase {
    func testDriveFileDecodesGoogleJSON() throws {
        let json = """
        {
          "id": "abc",
          "name": "Hello.pdf",
          "mimeType": "application/pdf",
          "modifiedTime": "2024-05-01T12:00:00.000Z",
          "size": "1024",
          "starred": true,
          "parents": ["root"],
          "webViewLink": "https://drive.google.com/file/d/abc/view",
          "owners": [{"displayName": "Ada", "emailAddress": "ada@example.com", "me": true}]
        }
        """
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.size, 1024)
        XCTAssertEqual(file.ownerLabel, "Ada")
        XCTAssertEqual(file.browserURL?.absoluteString, "https://drive.google.com/file/d/abc/view")
        XCTAssertEqual(file.modifiedTime, DriveDate.parse("2024-05-01T12:00:00.000Z"))
        XCTAssertFalse(file.isFolder)
        let roundTrip = try JSONDecoder().decode(DriveFile.self, from: try JSONEncoder().encode(file))
        XCTAssertEqual(roundTrip, file)
    }

    func testNumericSizeAndGoogleNativeTypes() throws {
        let json = #"{"id":"d","name":"Doc","mimeType":"application/vnd.google-apps.document","size":12}"#
        let file = try JSONDecoder().decode(DriveFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.size, 12)
        XCTAssertTrue(file.isGoogleNative)
        XCTAssertFalse(DriveFile(id: "f", name: "Folder", mimeType: DriveMime.folder).isGoogleNative)
        XCTAssertTrue(DriveFile(id: "f", name: "Folder", mimeType: DriveMime.folder).isFolder)
    }

    func testQueryEscapingAndLocations() {
        XCTAssertEqual(DriveQueryBuilder.escapeQueryLiteral(#"a'b\c"#), #"a\'b\\c"#)
        let mine = DriveQueryBuilder.filesList(for: .myDrive, pageToken: nil)
        XCTAssertEqual(mine.q, "'root' in parents and trashed = false")
        XCTAssertEqual(mine.corpora, "user")
        XCTAssertEqual(mine.orderBy, "name")

        let search = DriveQueryBuilder.filesList(for: .search(query: "tax report"), pageToken: "next")
        XCTAssertEqual(search.q, "(name contains 'tax report' or fullText contains 'tax report') and trashed = false")
        XCTAssertEqual(search.pageToken, "next")
        XCTAssertEqual(search.corpora, "allDrives")

        let quoted = DriveQueryBuilder.filesList(for: .search(query: "a'b"), pageToken: nil)
        XCTAssertEqual(quoted.q, #"(name contains 'a\'b' or fullText contains 'a\'b') and trashed = false"#)

        let drive = DriveQueryBuilder.filesList(for: .sharedDrive(id: "drive1", name: "Team"), pageToken: nil)
        XCTAssertEqual(drive.driveId, "drive1")
        XCTAssertEqual(drive.corpora, "drive")
        XCTAssertEqual(drive.q, "'drive1' in parents and trashed = false")

        let folder = DriveQueryBuilder.filesList(for: .folder(id: "fld", name: "Notes", sharedDriveID: "drive1"), pageToken: nil)
        XCTAssertEqual(folder.driveId, "drive1")
        XCTAssertEqual(folder.q, "'fld' in parents and trashed = false")

        XCTAssertEqual(DriveQueryBuilder.filesList(for: .recent, pageToken: nil).orderBy, "viewedByMeTime desc")
        XCTAssertEqual(DriveQueryBuilder.filesList(for: .starred, pageToken: nil).q, "starred = true and trashed = false")
        XCTAssertEqual(DriveQueryBuilder.filesList(for: .trash, pageToken: nil).q, "trashed = true")
        XCTAssertEqual(DriveQueryBuilder.filesList(for: .sharedWithMe, pageToken: nil).q, "sharedWithMe = true and trashed = false")
    }

    func testAccountIDAndFileNameSanitizing() {
        XCTAssertEqual(AccountID.make(email: " Ada@Example.com ", permissionID: "perm"), "ada@example.com")
        XCTAssertEqual(AccountID.sanitize("a/b c"), "a_b_c")
        XCTAssertEqual(AccountID.make(email: " ", permissionID: "perm"), "perm")
        XCTAssertEqual(FileName.sanitize("../Hello/World.txt"), "..-Hello-World.txt")
        XCTAssertEqual(FileName.sanitize("   "), "file")
        XCTAssertEqual(MimeType.guess(fileName: "photo.JPG"), "image/jpeg")
        XCTAssertEqual(SearchQuery.normalized("  taxes "), "taxes")
        XCTAssertNil(SearchQuery.normalized("   "))
    }

    func testNavigationHistoryAndBreadcrumbs() {
        var navigation = BrowserNavigation(path: BrowsePath(root: .myDrive))
        navigation.openFolder(id: "a", name: "A")
        navigation.openFolder(id: "b", name: "B")
        XCTAssertEqual(navigation.path.location, .folder(id: "b", name: "B", sharedDriveID: nil))
        XCTAssertTrue(navigation.goUp())
        XCTAssertEqual(navigation.path.folders.map(\.id), ["a"])
        navigation.goBack()
        XCTAssertEqual(navigation.path.folders.map(\.id), ["a", "b"])
        navigation.goBack()
        XCTAssertEqual(navigation.path.folders.map(\.id), ["a"])
        navigation.goForward()
        XCTAssertEqual(navigation.path.folders.map(\.name), ["A", "B"])
        navigation.selectRoot(.trash)
        XCTAssertEqual(navigation.path.root, .trash)
        XCTAssertFalse(navigation.canGoForward)
        XCTAssertTrue(navigation.canGoBack)
        navigation.jumpToCrumb(nil)
        XCTAssertTrue(navigation.path.folders.isEmpty)

        var deep = BrowserNavigation(path: BrowsePath(root: .myDrive, folders: [
            PathFolder(id: "a", name: "A"),
            PathFolder(id: "b", name: "B"),
            PathFolder(id: "c", name: "C")
        ]))
        deep.jumpToCrumb(0)
        XCTAssertEqual(deep.path.folders.map(\.id), ["a"])
        XCTAssertFalse(deep.goUp() == false)
        deep.goUp()
        XCTAssertTrue(deep.path.folders.isEmpty)
        XCTAssertFalse(deep.goUp())

        let shared = BrowsePath(root: .sharedDrive(id: "d", name: "Team"), folders: [PathFolder(id: "f", name: "F")])
        XCTAssertEqual(shared.location, .folder(id: "f", name: "F", sharedDriveID: "d"))
        XCTAssertEqual(shared.uploadParentID, "f")
        XCTAssertEqual(BrowsePath(root: .myDrive).uploadParentID, "root")
        XCTAssertNil(BrowsePath(root: .starred).uploadParentID)
        XCTAssertFalse(DriveLocation.search(query: "q").supportsIncrementalRefresh)
        XCTAssertEqual(DriveLocation.myDrive.cacheKey, "myDrive")
        XCTAssertEqual(DriveLocation.folder(id: "f", name: "F", sharedDriveID: nil).cacheKey, "folder:f")
    }

    func testPageMergeAndSort() {
        let existing = [sampleFile(id: "1", name: "B"), sampleFile(id: "2", name: "A", mimeType: DriveMime.folder)]
        let merged = PageMerger.merge(existing: existing, page: [sampleFile(id: "2", name: "A", mimeType: DriveMime.folder), sampleFile(id: "3", name: "C")])
        XCTAssertEqual(merged.map(\.id), ["1", "2", "3"])
        let sorted = ListingSorter.sort(merged, key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(sorted.map(\.name), ["A", "B", "C"])
        XCTAssertTrue(sorted[0].isFolder)
    }

    func testRevalidatePlanner() {
        XCTAssertEqual(RevalidatePlanner.plan(forceFull: true, hasCachedListing: true, startToken: "t", location: .myDrive), .full)
        XCTAssertEqual(RevalidatePlanner.plan(forceFull: false, hasCachedListing: true, startToken: "t", location: .myDrive), .incremental(token: "t"))
        XCTAssertEqual(RevalidatePlanner.plan(forceFull: false, hasCachedListing: false, startToken: "t", location: .myDrive), .full)
        XCTAssertEqual(RevalidatePlanner.plan(forceFull: false, hasCachedListing: true, startToken: nil, location: .myDrive), .full)
        XCTAssertEqual(RevalidatePlanner.plan(forceFull: false, hasCachedListing: true, startToken: "t", location: .search(query: "q")), .full)
    }
}
