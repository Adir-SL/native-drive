import Foundation

public enum NewItemKind: String, Equatable, Sendable, CaseIterable {
    case folder
    case document
    case spreadsheet
    case presentation
    case form
    case drawing

    public var mimeType: String {
        switch self {
        case .folder: return DriveMime.folder
        case .document: return DriveMime.document
        case .spreadsheet: return DriveMime.spreadsheet
        case .presentation: return DriveMime.presentation
        case .form: return DriveMime.form
        case .drawing: return DriveMime.drawing
        }
    }

    public var defaultName: String {
        switch self {
        case .folder: return "Untitled folder"
        case .document: return "Untitled document"
        case .spreadsheet: return "Untitled spreadsheet"
        case .presentation: return "Untitled presentation"
        case .form: return "Untitled form"
        case .drawing: return "Untitled drawing"
        }
    }

    public var opensInBrowser: Bool { self != .folder }
}

public enum NewItem {
    public static func localID() -> String {
        "local:\(UUID().uuidString)"
    }

    public static func isLocalID(_ id: String) -> Bool {
        id.hasPrefix("local:")
    }

    public static func queryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "fields", value: DriveFields.file)
        ]
    }

    public static func requestBody(name: String, mimeType: String, parentID: String) throws -> Data {
        try JSONEncoder().encode(CreateFileBody(name: name, mimeType: mimeType, parents: [parentID]))
    }

    /// Editor URL for a Google file. Prefers the link Drive returned.
    public static func editorURL(for file: DriveFile) -> URL? {
        if let webViewLink = file.webViewLink, let url = URL(string: webViewLink) {
            return url
        }
        let path: String
        switch file.mimeType {
        case DriveMime.document: path = "document"
        case DriveMime.spreadsheet: path = "spreadsheets"
        case DriveMime.presentation: path = "presentation"
        case DriveMime.form: path = "forms"
        case DriveMime.drawing: path = "drawings"
        default: return file.browserURL
        }
        return URL(string: "https://docs.google.com/\(path)/d/\(file.id)/edit")
    }
}

public struct CreateFileBody: Codable, Equatable, Sendable {
    public var name: String
    public var mimeType: String
    public var parents: [String]

    public init(name: String, mimeType: String, parents: [String]) {
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
    }
}

public enum CreationAccess: Equatable, Sendable {
    case allowed(parentID: String)
    case denied(String)
}

public enum CreationPolicy {
    public static func access(location: DriveLocation, canAddChildren: Bool?) -> CreationAccess {
        guard let parentID = location.uploadParentID else {
            return .denied("You can't add items in this view.")
        }
        if canAddChildren == false {
            return .denied("You don't have permission to add items to this folder.")
        }
        return .allowed(parentID: parentID)
    }
}

public struct UploadChunk: Equatable, Sendable {
    public var start: Int64
    public var end: Int64
    public var total: Int64

    public init(start: Int64, end: Int64, total: Int64) {
        self.start = start
        self.end = end
        self.total = total
    }

    public var contentRange: String {
        "bytes \(start)-\(end)/\(total)"
    }
}

public enum UploadChunker {
    /// Inclusive byte ranges covering `fileSize`, each at most `chunkSize` bytes.
    public static func chunks(fileSize: Int64, chunkSize: Int) -> [UploadChunk] {
        guard fileSize > 0 else { return [] }
        var start: Int64 = 0
        var result: [UploadChunk] = []
        while start < fileSize {
            guard let chunk = chunk(from: start, fileSize: fileSize, chunkSize: chunkSize) else { break }
            result.append(chunk)
            start = chunk.end + 1
        }
        return result
    }

    public static func chunk(from start: Int64, fileSize: Int64, chunkSize: Int) -> UploadChunk? {
        guard start >= 0, start < fileSize else { return nil }
        let length = min(Int64(max(chunkSize, 1)), fileSize - start)
        return UploadChunk(start: start, end: start + length - 1, total: fileSize)
    }
}

public enum UploadStrategy: Equatable, Sendable {
    /// Multipart below the threshold, resumable at or above it.
    case automatic
    case resumable
}

public enum FolderUploadPlan {
    public struct Entry: Equatable, Sendable {
        public var relativePath: String
        public var isDirectory: Bool

        public init(relativePath: String, isDirectory: Bool) {
            self.relativePath = relativePath
            self.isDirectory = isDirectory
        }

        public var name: String {
            relativePath.split(separator: "/").last.map(String.init) ?? relativePath
        }
    }

    /// Directory that contains this entry, relative to the same root. Nil for the top folder.
    public static func parentRelativePath(_ relativePath: String) -> String? {
        guard let slash = relativePath.lastIndex(of: "/") else { return nil }
        let parent = relativePath[..<slash]
        return parent.isEmpty ? nil : String(parent)
    }

    /// Parents before children, directories before files at the same depth.
    public static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            let left = lhs.relativePath.split(separator: "/").count
            let right = rhs.relativePath.split(separator: "/").count
            if left != right { return left < right }
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.relativePath < rhs.relativePath
        }
    }

    /// Entries for `root` and everything inside it. `relativePath` starts with the folder's name.
    public static func scan(root: URL) -> [Entry] {
        let folderName = root.lastPathComponent
        var entries = [Entry(relativePath: folderName, isDirectory: true)]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return entries
        }
        let rootPath = root.path
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let suffix: String
            if item.path.hasPrefix(rootPath + "/") {
                suffix = String(item.path.dropFirst(rootPath.count + 1))
            } else {
                suffix = item.lastPathComponent
            }
            entries.append(Entry(relativePath: folderName + "/" + suffix, isDirectory: values?.isDirectory == true))
        }
        return ordered(entries)
    }
}
