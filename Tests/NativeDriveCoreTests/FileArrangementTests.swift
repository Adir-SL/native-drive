import XCTest
@testable import NativeDriveCore

final class FileArrangementTests: XCTestCase {
    func testFolderColorParsing() throws {
        assertColor("#8f1d21", 143.0 / 255, 29.0 / 255, 33.0 / 255)
        assertColor("8f1d21", 143.0 / 255, 29.0 / 255, 33.0 / 255)
        assertColor("#abc", 170.0 / 255, 187.0 / 255, 204.0 / 255)
        XCTAssertNil(FolderColor.components(nil))
        XCTAssertNil(FolderColor.components(""))
        XCTAssertNil(FolderColor.components("#gghhii"))
        XCTAssertNil(FolderColor.components("12345"))
        let page = try? DriveFilePage.decode(Data(
            ##"{"files":[{"id":"f","name":"Reports","mimeType":"application/vnd.google-apps.folder","folderColorRgb":"#0f9d58"}]}"##.utf8
        ))
        XCTAssertEqual(page?.files.first?.folderColorRgb, "#0f9d58")
        XCTAssertTrue(DriveFields.fileList.contains("folderColorRgb"))
        XCTAssertFalse(DriveFields.fileList.contains("writersCanShare"))
        XCTAssertFalse(DriveFields.fileList.contains("imageMediaMetadata"))
        XCTAssertFalse(DriveFields.fileList.contains("videoMediaMetadata"))
        XCTAssertTrue(DriveFields.file.contains("imageMediaMetadata"))
        let clip = try JSONDecoder().decode(
            DriveFile.self,
            from: Data(#"{"id":"1","name":"clip","mimeType":"video/mp4","videoMediaMetadata":{"width":1920,"height":1080,"durationMillis":"1500"}}"#.utf8)
        )
        XCTAssertEqual(clip.pixelWidth, 1920)
        XCTAssertEqual(clip.pixelHeight, 1080)
        XCTAssertEqual(clip.durationMillis, 1500)
    }

    func testSortEachKeyInBothDirections() {
        let early = Date(timeIntervalSince1970: 10)
        let late = Date(timeIntervalSince1970: 50)
        let files = [
            DriveFile(id: "b", name: "Bravo", mimeType: "text/plain", modifiedTime: late, size: 20),
            DriveFile(id: "a", name: "alpha", mimeType: "image/jpeg", modifiedTime: early, size: 5),
            DriveFile(id: "blank", name: "Blank", mimeType: "application/pdf"),
            DriveFile(id: "folder", name: "Zoo", mimeType: DriveMime.folder, modifiedTime: early)
        ]
        var named = FileSort(key: .name, ascending: true, foldersFirst: false)
        XCTAssertEqual(named.sorted(files).map(\.id), ["a", "blank", "b", "folder"])
        named.ascending = false
        XCTAssertEqual(named.sorted(files).map(\.id), ["folder", "b", "blank", "a"])

        var modified = FileSort(key: .modified, ascending: true, foldersFirst: false)
        XCTAssertEqual(modified.sorted(files).map(\.id).prefix(3), ["a", "folder", "b"])
        XCTAssertEqual(modified.sorted(files).map(\.id).last, "blank")
        modified.ascending = false
        XCTAssertEqual(modified.sorted(files).map(\.id).first, "b")
        XCTAssertEqual(modified.sorted(files).map(\.id).last, "blank")

        var size = FileSort(key: .size, ascending: true, foldersFirst: false)
        XCTAssertEqual(size.sorted(files).filter { $0.size != nil }.map(\.id), ["a", "b"])
        XCTAssertEqual(size.sorted(files).suffix(2).map(\.id).sorted(), ["blank", "folder"])
        size.ascending = false
        XCTAssertEqual(size.sorted(files).filter { $0.size != nil }.map(\.id), ["b", "a"])

        var kind = FileSort(key: .kind, ascending: true, foldersFirst: false)
        XCTAssertEqual(kind.sorted(files).map { FileKind.label(mimeType: $0.mimeType, fileName: $0.name) }, ["Document", "Document", "Folder", "Image"])
        kind.ascending = false
        XCTAssertEqual(kind.sorted(files).map { FileKind.label(mimeType: $0.mimeType, fileName: $0.name) }.first, "Image")

        let owned = DriveFile(
            id: "owned",
            name: "Owned",
            mimeType: "text/plain",
            owners: [DriveUser(displayName: "Ada")]
        )
        let mine = DriveFile(
            id: "mine",
            name: "Mine",
            mimeType: "text/plain",
            owners: [DriveUser(displayName: "Bea")]
        )
        var owner = FileSort(key: .owner, ascending: true, foldersFirst: false)
        XCTAssertEqual(owner.sorted([mine, owned]).map(\.id), ["owned", "mine"])
        owner.ascending = false
        XCTAssertEqual(owner.sorted([owned, mine]).map(\.id), ["mine", "owned"])
    }

    func testFoldersFirstOverridesNameOrder() {
        let files = [
            sampleFile(id: "file", name: "Alpha", mimeType: "text/plain"),
            sampleFile(id: "folder", name: "Zoo", mimeType: DriveMime.folder)
        ]
        let first = FileSort(key: .name, ascending: true, foldersFirst: true)
        XCTAssertEqual(first.sorted(files).map(\.id), ["folder", "file"])
        let mixed = FileSort(key: .name, ascending: true, foldersFirst: false)
        XCTAssertEqual(mixed.sorted(files).map(\.id), ["file", "folder"])
        XCTAssertEqual(first.toggled(.name).ascending, false)
        XCTAssertEqual(first.toggled(.size).key, .size)
        XCTAssertEqual(FileGrouping.group(of: files[0]), .other)
        XCTAssertEqual(FileGrouping.group(of: files[1]), .folders)
    }

    func testFoldersFirstOnEveryKeyAndDirection() {
        let folder = DriveFile(
            id: "folder",
            name: "Zoo",
            mimeType: DriveMime.folder,
            modifiedTime: Date(timeIntervalSince1970: 1),
            size: 1,
            owners: [DriveUser(displayName: "Zoe")]
        )
        let file = DriveFile(
            id: "file",
            name: "Alpha",
            mimeType: "text/plain",
            modifiedTime: Date(timeIntervalSince1970: 100),
            size: 9,
            owners: [DriveUser(displayName: "Ada")]
        )
        for key in FileSortKey.allCases {
            for ascending in [true, false] {
                let sort = FileSort(key: key, ascending: ascending, foldersFirst: true)
                XCTAssertEqual(
                    sort.sorted([file, folder]).map(\.id),
                    ["folder", "file"],
                    "\(key.rawValue) ascending=\(ascending)"
                )
            }
        }
    }

    private func assertColor(_ raw: String, _ red: Double, _ green: Double, _ blue: Double, file: StaticString = #filePath, line: UInt = #line) {
        let color = FolderColor.components(raw)
        XCTAssertEqual(color?.red ?? -1, red, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color?.green ?? -1, green, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color?.blue ?? -1, blue, accuracy: 0.0001, file: file, line: line)
    }
}
