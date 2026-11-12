import XCTest
@testable import NativeDriveCore

final class NewItemTests: XCTestCase {
    func testCreateFolderRequestUsesRootParentAndAllDrives() throws {
        let body = try NewItem.requestBody(name: "Untitled folder", mimeType: DriveMime.folder, parentID: "root")
        let decoded = try JSONDecoder().decode(CreateFileBody.self, from: body)
        XCTAssertEqual(decoded, CreateFileBody(name: "Untitled folder", mimeType: DriveMime.folder, parents: ["root"]))
        let items = NewItem.queryItems()
        XCTAssertEqual(items.first { $0.name == "supportsAllDrives" }?.value, "true")
        XCTAssertTrue(items.contains { $0.name == "fields" && ($0.value?.contains("webViewLink") == true) })
        XCTAssertEqual(NewItemKind.folder.defaultName, "Untitled folder")
        XCTAssertFalse(NewItemKind.folder.opensInBrowser)
    }

    func testCreateGoogleFileNamesAndEditorURL() throws {
        XCTAssertEqual(NewItemKind.document.defaultName, "Untitled document")
        XCTAssertEqual(NewItemKind.spreadsheet.mimeType, DriveMime.spreadsheet)
        XCTAssertEqual(NewItemKind.presentation.defaultName, "Untitled presentation")
        XCTAssertEqual(NewItemKind.form.mimeType, DriveMime.form)
        XCTAssertEqual(NewItemKind.drawing.defaultName, "Untitled drawing")
        let body = try NewItem.requestBody(name: NewItemKind.document.defaultName, mimeType: NewItemKind.document.mimeType, parentID: "folder-1")
        let decoded = try JSONDecoder().decode(CreateFileBody.self, from: body)
        XCTAssertEqual(decoded.parents, ["folder-1"])
        XCTAssertEqual(decoded.mimeType, "application/vnd.google-apps.document")

        let fromLink = DriveFile(id: "abc", name: "Doc", mimeType: DriveMime.document, webViewLink: "https://docs.google.com/document/d/abc/edit")
        XCTAssertEqual(NewItem.editorURL(for: fromLink)?.absoluteString, "https://docs.google.com/document/d/abc/edit")
        let fallback = DriveFile(id: "abc", name: "Sheet", mimeType: DriveMime.spreadsheet)
        XCTAssertEqual(NewItem.editorURL(for: fallback)?.absoluteString, "https://docs.google.com/spreadsheets/d/abc/edit")
        XCTAssertTrue(NewItem.isLocalID(NewItem.localID()))
    }

    func testCreateFilePostsMetadata() async throws {
        let http = MockHTTPClient(responses: [
            httpJSON(200, #"{"id":"new","name":"Untitled folder","mimeType":"application/vnd.google-apps.folder","parents":["root"],"capabilities":{"canAddChildren":true}}"#)
        ])
        let client = makeClient(http: http)
        let created = try await client.createFile(name: "Untitled folder", mimeType: DriveMime.folder, parentID: "root")
        XCTAssertEqual(created.id, "new")
        XCTAssertEqual(created.capabilities?.canAddChildren, true)
        let recorded = await http.recorded()
        let request = try XCTUnwrap(recorded.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(request.url.absoluteString.contains("/drive/v3/files"))
        XCTAssertTrue(request.url.absoluteString.contains("supportsAllDrives=true"))
        let body = try JSONDecoder().decode(CreateFileBody.self, from: request.body ?? Data())
        XCTAssertEqual(body.parents, ["root"])
        XCTAssertEqual(body.mimeType, DriveMime.folder)
    }

    func testResumableChunkRangesAndForcedStrategy() async throws {
        XCTAssertEqual(
            UploadChunker.chunks(fileSize: 10, chunkSize: 4).map(\.contentRange),
            ["bytes 0-3/10", "bytes 4-7/10", "bytes 8-9/10"]
        )
        XCTAssertTrue(UploadChunker.chunks(fileSize: 0, chunkSize: 4).isEmpty)

        let directory = try temporaryDirectory()
        let fileURL = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: fileURL)
        let http = MockHTTPClient(responses: [
            httpJSON(200, "", headers: ["Location": "https://upload.example/session"]),
            httpJSON(200, #"{"id":"up","name":"note.txt","mimeType":"text/plain"}"#)
        ])
        let client = makeClient(http: http)
        let uploaded = try await client.uploadFile(
            at: fileURL,
            name: "note.txt",
            mimeType: "text/plain",
            parentID: "root",
            strategy: .resumable
        ) { _, _ in }
        XCTAssertEqual(uploaded.id, "up")
        let requests = await http.recorded()
        XCTAssertTrue(requests[0].url.absoluteString.contains("uploadType=resumable"))
        XCTAssertEqual(requests[0].headers["X-Upload-Content-Length"], "5")
        XCTAssertEqual(requests[1].headers["Content-Range"], "bytes 0-4/5")
    }

    func testMIMEDetection() {
        XCTAssertEqual(MimeType.guess(fileName: "Photo.JPEG"), "image/jpeg")
        XCTAssertEqual(MimeType.guess(fileName: "Deck.pptx"), "application/vnd.openxmlformats-officedocument.presentationml.presentation")
        XCTAssertEqual(MimeType.guess(fileName: "Sheet.xlsx"), "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        XCTAssertEqual(MimeType.guess(fileName: "Notes.docx"), "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertEqual(MimeType.guess(fileName: "clip.WEBP"), "image/webp")
        XCTAssertEqual(MimeType.guess(fileName: "no-extension"), "application/octet-stream")
    }

    func testCreationPolicyAndPinnedCacheMerge() {
        XCTAssertEqual(
            CreationPolicy.access(location: .myDrive, canAddChildren: nil),
            .allowed(parentID: "root")
        )
        XCTAssertEqual(
            CreationPolicy.access(location: .folder(id: "f", name: "F", sharedDriveID: nil), canAddChildren: false).deniedReason,
            "You don't have permission to add items to this folder."
        )
        XCTAssertEqual(
            CreationPolicy.access(location: .sharedWithMe, canAddChildren: true).deniedReason,
            "You can't add items in this view."
        )
        XCTAssertEqual(
            CreationPolicy.access(location: .sharedDrive(id: "d", name: "Team"), canAddChildren: nil),
            .allowed(parentID: "d")
        )

        let existing = [
            sampleFile(id: "1", name: "B"),
            sampleFile(id: "local:1", name: "Untitled folder", mimeType: DriveMime.folder)
        ]
        let page = [sampleFile(id: "1", name: "B")]
        let merged = ListingRefresh.mergePage(existing: existing, page: page, key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(merged.map(\.id), ["local:1", "1"])
        let closed = ListingRefresh.droppingUnseen(files: merged, seen: ["1"], pinned: ["local:1"], key: DriveLocation.myDrive.cacheKey)
        XCTAssertEqual(closed.map(\.id), ["local:1", "1"])
        let replaced = ListingRefresh.mergePage(
            existing: closed,
            page: [sampleFile(id: "real", name: "Untitled folder", mimeType: DriveMime.folder)],
            key: DriveLocation.myDrive.cacheKey
        )
        XCTAssertEqual(replaced.filter { $0.name == "Untitled folder" }.map(\.id), ["local:1", "real"])
    }

    func testFolderUploadOrdersParentsBeforeChildren() throws {
        let root = try temporaryDirectory().appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent("Sub/b.txt"))
        let plan = FolderUploadPlan.scan(root: root)
        XCTAssertEqual(plan.map(\.relativePath), ["Photos", "Photos/Sub", "Photos/a.txt", "Photos/Sub/b.txt"])
        XCTAssertEqual(plan.map(\.isDirectory), [true, true, false, false])
        XCTAssertNil(FolderUploadPlan.parentRelativePath("Photos"))
        XCTAssertEqual(FolderUploadPlan.parentRelativePath("Photos/Sub/b.txt"), "Photos/Sub")
        XCTAssertEqual(plan[3].name, "b.txt")
    }
}

private extension CreationAccess {
    var deniedReason: String? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}
