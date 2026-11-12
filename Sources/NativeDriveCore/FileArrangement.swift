import Foundation

public enum FolderColor {
    /// `#RGB`, `#RRGGBB`, or the same without a hash. Invalid strings are ignored.
    public static func components(_ raw: String?) -> (red: Double, green: Double, blue: Double)? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        let hex = text
        let expanded: String
        switch hex.count {
        case 3:
            expanded = hex.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = hex
        default:
            return nil
        }
        guard expanded.allSatisfy(\.isHexDigit),
              let value = Int(expanded, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        return (red, green, blue)
    }
}

public enum FileKind {
    public static func label(mimeType: String, fileName: String) -> String {
        if mimeType == DriveMime.folder { return "Folder" }
        if mimeType == DriveMime.shortcut { return "Shortcut" }
        if mimeType == DriveMime.document { return "Google Doc" }
        if mimeType == DriveMime.spreadsheet { return "Google Sheet" }
        if mimeType == DriveMime.presentation { return "Google Slides" }
        if mimeType == DriveMime.form { return "Google Form" }
        if mimeType == DriveMime.drawing { return "Google Drawing" }
        switch MediaClassifier.kind(mimeType: mimeType, fileName: fileName) {
        case .image: return "Image"
        case .playableVideo, .unsupportedVideo: return "Video"
        case .playableAudio: return "Audio"
        case .other:
            break
        }
        let ext = URL(fileURLWithPath: fileName).pathExtension
        if ext.isEmpty { return "Document" }
        return ext.uppercased()
    }
}

public enum FileSortKey: String, Codable, CaseIterable, Sendable, Identifiable {
    case name
    case modified
    case size
    case kind
    case owner

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .kind: return "Kind"
        case .owner: return "Owner"
        }
    }
}

public struct FileSort: Equatable, Sendable, Codable {
    public var key: FileSortKey
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(key: FileSortKey = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    public func sorted(_ files: [DriveFile]) -> [DriveFile] {
        files.sorted { lhs, rhs in
            if foldersFirst, lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }
            if key != .name {
                let leftMissing = Self.isMissing(lhs, key: key)
                let rightMissing = Self.isMissing(rhs, key: key)
                if leftMissing != rightMissing { return !leftMissing }
            }
            let compared = Self.compare(lhs, rhs, key: key)
            if compared == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return ascending ? compared == .orderedAscending : compared == .orderedDescending
        }
    }

    public func toggled(_ key: FileSortKey) -> FileSort {
        var next = self
        if next.key == key {
            next.ascending.toggle()
        } else {
            next.key = key
            next.ascending = key == .modified ? false : true
        }
        return next
    }

    private static func isMissing(_ file: DriveFile, key: FileSortKey) -> Bool {
        switch key {
        case .name: return false
        case .modified: return file.modifiedTime == nil
        case .size: return file.size == nil
        case .kind: return false
        case .owner: return file.ownerLabel == "—"
        }
    }

    private static func compare(_ lhs: DriveFile, _ rhs: DriveFile, key: FileSortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .modified:
            return compareOptional(lhs.modifiedTime, rhs.modifiedTime)
        case .size:
            return compareOptional(lhs.size, rhs.size)
        case .kind:
            return FileKind.label(mimeType: lhs.mimeType, fileName: lhs.name)
                .localizedCaseInsensitiveCompare(FileKind.label(mimeType: rhs.mimeType, fileName: rhs.name))
        case .owner:
            return lhs.ownerLabel.localizedCaseInsensitiveCompare(rhs.ownerLabel)
        }
    }

    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        case (nil, nil):
            return .orderedSame
        case (nil, _?):
            return .orderedDescending
        case (_?, nil):
            return .orderedAscending
        }
    }
}

public enum FileGroup: String, CaseIterable, Sendable, Identifiable {
    case folders
    case images
    case videos
    case audio
    case documents
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .folders: return "Folders"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .documents: return "Documents"
        case .other: return "Other"
        }
    }
}

public enum FileGrouping {
    public static func group(of file: DriveFile) -> FileGroup {
        if file.isFolder { return .folders }
        switch MediaClassifier.kind(of: file) {
        case .image: return .images
        case .playableVideo, .unsupportedVideo: return .videos
        case .playableAudio: return .audio
        case .other:
            if file.isGoogleNative { return .documents }
            return .other
        }
    }

    /// Sections follow the already chosen sort, with folders kept first when asked.
    public static func sections(_ files: [DriveFile], foldersFirst: Bool) -> [(FileGroup, [DriveFile])] {
        var buckets: [FileGroup: [DriveFile]] = [:]
        var order: [FileGroup] = []
        for file in files {
            let group = group(of: file)
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(file)
        }
        if foldersFirst, let index = order.firstIndex(of: .folders), index != 0 {
            order.remove(at: index)
            order.insert(.folders, at: 0)
        }
        return order.compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return (group, rows)
        }
    }
}
