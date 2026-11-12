import Foundation

public enum DriveMime {
    public static let folder = "application/vnd.google-apps.folder"
    public static let shortcut = "application/vnd.google-apps.shortcut"
    public static let document = "application/vnd.google-apps.document"
    public static let spreadsheet = "application/vnd.google-apps.spreadsheet"
    public static let presentation = "application/vnd.google-apps.presentation"
    public static let drawing = "application/vnd.google-apps.drawing"
    public static let form = "application/vnd.google-apps.form"
}

public struct DriveUser: Codable, Equatable, Hashable, Sendable {
    public var displayName: String?
    public var emailAddress: String?
    public var photoLink: String?
    public var permissionId: String?
    public var me: Bool?

    public init(displayName: String? = nil, emailAddress: String? = nil, photoLink: String? = nil, permissionId: String? = nil, me: Bool? = nil) {
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.photoLink = photoLink
        self.permissionId = permissionId
        self.me = me
    }
}

public struct ShortcutDetails: Codable, Equatable, Hashable, Sendable {
    public var targetId: String?
    public var targetMimeType: String?

    public init(targetId: String? = nil, targetMimeType: String? = nil) {
        self.targetId = targetId
        self.targetMimeType = targetMimeType
    }
}

struct LossyDriveFile: Decodable {
    var file: DriveFile?

    init(from decoder: Decoder) throws {
        file = try? DriveFile(from: decoder)
    }
}

public enum DriveFilePage {
    /// Decodes a files.list body. One file that cannot be read is skipped so the rest of the page, including its folders, stays.
    public static func decode(_ data: Data) throws -> FilePage {
        let page = try JSONCoders.makeDecoder().decode(LossyFilePage.self, from: data)
        return FilePage(files: page.files, nextPageToken: ListingPageToken.normalized(page.nextPageToken))
    }
}

private struct LossyFilePage: Decodable {
    var files: [DriveFile]
    var nextPageToken: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decodeIfPresent([LossyDriveFile].self, forKey: .files) ?? []
        files = rows.compactMap(\.file)
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }

    private enum CodingKeys: String, CodingKey {
        case files, nextPageToken
    }
}

public struct FileCapabilities: Codable, Equatable, Hashable, Sendable {
    public var canAddChildren: Bool?
    public var canShare: Bool?
    public var canChangeCopyRequiresWriterPermission: Bool?
    public var canChangeViewersCanCopyContent: Bool?

    public init(
        canAddChildren: Bool? = nil,
        canShare: Bool? = nil,
        canChangeCopyRequiresWriterPermission: Bool? = nil,
        canChangeViewersCanCopyContent: Bool? = nil
    ) {
        self.canAddChildren = canAddChildren
        self.canShare = canShare
        self.canChangeCopyRequiresWriterPermission = canChangeCopyRequiresWriterPermission
        self.canChangeViewersCanCopyContent = canChangeViewersCanCopyContent
    }
}

public struct DriveFile: Identifiable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var modifiedTime: Date?
    public var viewedByMeTime: Date?
    public var size: Int64?
    public var starred: Bool
    public var trashed: Bool
    public var parents: [String]
    public var webViewLink: String?
    public var iconLink: String?
    public var thumbnailLink: String?
    public var owners: [DriveUser]
    public var md5Checksum: String?
    public var driveId: String?
    public var shortcutDetails: ShortcutDetails?
    public var capabilities: FileCapabilities?
    public var writersCanShare: Bool?
    public var copyRequiresWriterPermission: Bool?

    public init(
        id: String,
        name: String,
        mimeType: String,
        modifiedTime: Date? = nil,
        viewedByMeTime: Date? = nil,
        size: Int64? = nil,
        starred: Bool = false,
        trashed: Bool = false,
        parents: [String] = [],
        webViewLink: String? = nil,
        iconLink: String? = nil,
        thumbnailLink: String? = nil,
        owners: [DriveUser] = [],
        md5Checksum: String? = nil,
        driveId: String? = nil,
        shortcutDetails: ShortcutDetails? = nil,
        capabilities: FileCapabilities? = nil,
        writersCanShare: Bool? = nil,
        copyRequiresWriterPermission: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.modifiedTime = modifiedTime
        self.viewedByMeTime = viewedByMeTime
        self.size = size
        self.starred = starred
        self.trashed = trashed
        self.parents = parents
        self.webViewLink = webViewLink
        self.iconLink = iconLink
        self.thumbnailLink = thumbnailLink
        self.owners = owners
        self.md5Checksum = md5Checksum
        self.driveId = driveId
        self.shortcutDetails = shortcutDetails
        self.capabilities = capabilities
        self.writersCanShare = writersCanShare
        self.copyRequiresWriterPermission = copyRequiresWriterPermission
    }

    public var isFolder: Bool { mimeType == DriveMime.folder }

    public var isShortcut: Bool { mimeType == DriveMime.shortcut }

    public var isGoogleNative: Bool {
        mimeType.hasPrefix("application/vnd.google-apps.") && !isFolder && !isShortcut
    }

    public var ownerLabel: String {
        if let me = owners.first(where: { $0.me == true }) {
            return me.displayName ?? me.emailAddress ?? "me"
        }
        if let owner = owners.first {
            return owner.displayName ?? owner.emailAddress ?? "—"
        }
        return "—"
    }

    public var browserURL: URL? {
        if let webViewLink, let url = URL(string: webViewLink) {
            return url
        }
        if isFolder {
            return URL(string: "https://drive.google.com/drive/folders/\(id)")
        }
        return URL(string: "https://drive.google.com/file/d/\(id)/view")
    }
}

extension DriveFile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, mimeType, modifiedTime, viewedByMeTime, size, starred, trashed, parents
        case webViewLink, iconLink, thumbnailLink, owners, md5Checksum, driveId, shortcutDetails, capabilities
        case writersCanShare, copyRequiresWriterPermission
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        modifiedTime = try container.decodeFlexibleDate(forKey: .modifiedTime)
        viewedByMeTime = try container.decodeFlexibleDate(forKey: .viewedByMeTime)
        size = try container.decodeFlexibleInt64(forKey: .size)
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        trashed = try container.decodeIfPresent(Bool.self, forKey: .trashed) ?? false
        parents = try container.decodeIfPresent([String].self, forKey: .parents) ?? []
        webViewLink = try container.decodeIfPresent(String.self, forKey: .webViewLink)
        iconLink = try container.decodeIfPresent(String.self, forKey: .iconLink)
        thumbnailLink = try container.decodeIfPresent(String.self, forKey: .thumbnailLink)
        owners = try container.decodeIfPresent([DriveUser].self, forKey: .owners) ?? []
        md5Checksum = try container.decodeIfPresent(String.self, forKey: .md5Checksum)
        driveId = try container.decodeIfPresent(String.self, forKey: .driveId)
        shortcutDetails = try container.decodeIfPresent(ShortcutDetails.self, forKey: .shortcutDetails)
        capabilities = try container.decodeIfPresent(FileCapabilities.self, forKey: .capabilities)
        writersCanShare = try container.decodeIfPresent(Bool.self, forKey: .writersCanShare)
        copyRequiresWriterPermission = try container.decodeIfPresent(Bool.self, forKey: .copyRequiresWriterPermission)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(modifiedTime.map(DriveDate.format), forKey: .modifiedTime)
        try container.encodeIfPresent(viewedByMeTime.map(DriveDate.format), forKey: .viewedByMeTime)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encode(starred, forKey: .starred)
        try container.encode(trashed, forKey: .trashed)
        try container.encode(parents, forKey: .parents)
        try container.encodeIfPresent(webViewLink, forKey: .webViewLink)
        try container.encodeIfPresent(iconLink, forKey: .iconLink)
        try container.encodeIfPresent(thumbnailLink, forKey: .thumbnailLink)
        try container.encode(owners, forKey: .owners)
        try container.encodeIfPresent(md5Checksum, forKey: .md5Checksum)
        try container.encodeIfPresent(driveId, forKey: .driveId)
        try container.encodeIfPresent(shortcutDetails, forKey: .shortcutDetails)
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(writersCanShare, forKey: .writersCanShare)
        try container.encodeIfPresent(copyRequiresWriterPermission, forKey: .copyRequiresWriterPermission)
    }
}

extension KeyedDecodingContainer {
    func decodeFlexibleInt64(forKey key: Key) throws -> Int64? {
        if let number = try? decodeIfPresent(Int64.self, forKey: key) {
            return number
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(text)
        }
        return nil
    }

    func decodeFlexibleDate(forKey key: Key) throws -> Date? {
        guard let text = try decodeIfPresent(String.self, forKey: key), !text.isEmpty else {
            return nil
        }
        return DriveDate.parse(text)
    }
}

public enum FileName {
    public static func sanitize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaced = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let base = replaced.split(separator: "\\").last.map(String.init) ?? replaced
        if base.isEmpty || base == "." || base == ".." {
            return "file"
        }
        return base
    }
}

public enum MimeType {
    public static func guess(fileName: String) -> String {
        switch URL(fileURLWithPath: fileName).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "txt", "md": return "text/plain"
        case "json": return "application/json"
        case "zip": return "application/zip"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "heif": return "image/heif"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "rtf": return "application/rtf"
        case "gz": return "application/gzip"
        default: return "application/octet-stream"
        }
    }
}
