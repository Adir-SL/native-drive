import XCTest
@testable import NativeDriveCore

final class MediaTests: XCTestCase {
    func testHEICAndHEIFAreImages() {
        XCTAssertEqual(MediaClassifier.kind(mimeType: "image/heic", fileName: "IMG_1.HEIC"), .image)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "image/heif", fileName: "photo.heif"), .image)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "image/heic-sequence", fileName: "burst.heics"), .image)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "application/octet-stream", fileName: "scan.heic"), .image)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "", fileName: "scan.HEIF"), .image)
    }

    func testCommonStillFormatsAreImages() {
        let samples = [
            ("image/jpeg", "a.jpg"),
            ("image/png", "a.png"),
            ("image/gif", "a.gif"),
            ("image/webp", "a.webp"),
            ("image/tiff", "a.tif"),
            ("image/bmp", "a.bmp"),
            ("image/svg+xml", "a.svg"),
            ("image/x-adobe-dng", "a.dng"),
            ("application/octet-stream", "a.cr2"),
            ("application/octet-stream", "a.nef")
        ]
        for (mime, name) in samples {
            XCTAssertEqual(MediaClassifier.kind(mimeType: mime, fileName: name), .image, name)
        }
    }

    func testMIMEWinsOverAMisleadingExtension() {
        XCTAssertEqual(MediaClassifier.kind(mimeType: "image/heic", fileName: "clip.mp4"), .image)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "video/mp4", fileName: "clip.mkv"), .playableVideo)
    }

    func testPlayableVideoAudioAndUnsupportedVideo() {
        XCTAssertEqual(MediaClassifier.kind(mimeType: "video/mp4", fileName: "a.mp4"), .playableVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "video/quicktime", fileName: "a.mov"), .playableVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "application/octet-stream", fileName: "a.m4v"), .playableVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "video/x-matroska", fileName: "a.mkv"), .unsupportedVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "video/x-msvideo", fileName: "a.avi"), .unsupportedVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "application/octet-stream", fileName: "a.webm"), .unsupportedVideo)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "audio/mpeg", fileName: "a.mp3"), .playableAudio)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "audio/mp4", fileName: "a.m4a"), .playableAudio)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "audio/wav", fileName: "a.wav"), .playableAudio)
        XCTAssertEqual(MediaClassifier.kind(mimeType: "application/pdf", fileName: "a.pdf"), .other)
    }

    func testImageNavigationSkipsOtherFilesAndDoesNotWrap() {
        let files = [
            sampleFile(id: "pdf", name: "notes.pdf", mimeType: "application/pdf"),
            sampleFile(id: "a", name: "a.heic", mimeType: "image/heic"),
            sampleFile(id: "folder", name: "Album", mimeType: DriveMime.folder),
            sampleFile(id: "b", name: "b.jpg", mimeType: "image/jpeg"),
            sampleFile(id: "vid", name: "c.mp4", mimeType: "video/mp4"),
            sampleFile(id: "c", name: "c.png", mimeType: "image/png")
        ]
        let playlist = MediaNavigator.playlist(in: files, kind: .image)
        XCTAssertEqual(playlist.map(\.id), ["a", "b", "c"])
        let start = MediaNavigator.index(of: "b", in: playlist)
        XCTAssertEqual(start, 1)
        XCTAssertEqual(MediaNavigator.neighborIndex(current: 1, count: playlist.count, delta: -1), 0)
        XCTAssertEqual(MediaNavigator.neighborIndex(current: 1, count: playlist.count, delta: 1), 2)
        XCTAssertNil(MediaNavigator.neighborIndex(current: 0, count: playlist.count, delta: -1))
        XCTAssertNil(MediaNavigator.neighborIndex(current: 2, count: playlist.count, delta: 1))
        XCTAssertEqual(MediaNavigator.positionLabel(index: 1, count: 24), "2 of 24")
        XCTAssertEqual(MediaNavigator.positionLabel(index: 2, count: 24), "3 of 24")
        XCTAssertEqual(MediaNavigator.positionLabel(index: -1, count: 24), "")
    }

    func testCacheKeyIsStableAndSafe() {
        XCTAssertEqual(
            MediaCacheKey.relativePath(accountID: "Ada@Example.com", fileID: "file/1", fileName: "vacation.heic"),
            "Ada@Example.com/file_1/vacation.heic"
        )
        XCTAssertEqual(
            MediaCacheKey.relativePath(accountID: "a@b.c", fileID: "id", fileName: "../x.png"),
            "a@b.c/id/..-x.png"
        )
    }

    func testEvictionRemovesOldestUnprotectedFiles() {
        let older = Date(timeIntervalSince1970: 10)
        let newer = Date(timeIntervalSince1970: 20)
        let entries = [
            MediaCacheEntry(key: "old", byteCount: 80, lastAccessed: older),
            MediaCacheEntry(key: "keep", byteCount: 50, lastAccessed: older),
            MediaCacheEntry(key: "new", byteCount: 40, lastAccessed: newer)
        ]
        let removed = MediaCacheEviction.keysToRemove(entries: entries, budget: 100, protectedKeys: ["keep"])
        XCTAssertEqual(removed, ["old"])
        XCTAssertEqual(
            MediaCacheEviction.keysToRemove(entries: entries, budget: 200, protectedKeys: []),
            []
        )
        XCTAssertEqual(
            MediaCacheEviction.keysToRemove(entries: entries, budget: 40, protectedKeys: ["keep"]),
            ["old", "new"]
        )
    }

    func testThumbnailURLAndContentRange() {
        XCTAssertEqual(
            DriveThumbnailURL.enlarged("https://lh3.googleusercontent.com/d/abc=s220"),
            "https://lh3.googleusercontent.com/d/abc=s1600"
        )
        XCTAssertEqual(DriveThumbnailURL.enlarged("https://example.com/plain"), "https://example.com/plain")
        XCTAssertEqual(HTTPContentRange.totalLength("bytes 0-1023/4096"), 4096)
        XCTAssertEqual(HTTPContentRange.totalLength("bytes */8000"), 8000)
        XCTAssertNil(HTTPContentRange.totalLength("bytes 0-1/*"))
    }

    func testMediaURLRequestsFileBytes() throws {
        let client = makeClient(http: MockHTTPClient())
        let url = try client.mediaURL(fileID: "abc")
        XCTAssertTrue(url.absoluteString.contains("/files/abc"))
        XCTAssertTrue(url.absoluteString.contains("alt=media"))
        XCTAssertTrue(url.absoluteString.contains("supportsAllDrives=true"))
    }
}
