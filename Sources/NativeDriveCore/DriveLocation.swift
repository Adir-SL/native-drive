import Foundation

public enum DriveRoot: Hashable, Codable, Sendable {
    case myDrive
    case sharedWithMe
    case recent
    case starred
    case trash
    case sharedDrive(id: String, name: String)

    public static let sidebarBuiltins: [DriveRoot] = [.myDrive, .sharedWithMe, .recent, .starred, .trash]

    public var sharedDriveID: String? {
        if case .sharedDrive(let id, _) = self {
            return id
        }
        return nil
    }

    public var title: String {
        switch self {
        case .myDrive: return "My Drive"
        case .sharedWithMe: return "Shared with me"
        case .recent: return "Recent"
        case .starred: return "Starred"
        case .trash: return "Trash"
        case .sharedDrive(_, let name): return name
        }
    }
}

public struct PathFolder: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var canAddChildren: Bool?

    public init(id: String, name: String, canAddChildren: Bool? = nil) {
        self.id = id
        self.name = name
        self.canAddChildren = canAddChildren
    }
}

public struct BrowsePath: Hashable, Codable, Sendable {
    public var root: DriveRoot
    public var folders: [PathFolder]

    public init(root: DriveRoot, folders: [PathFolder] = []) {
        self.root = root
        self.folders = folders
    }

    public var location: DriveLocation {
        if let folder = folders.last {
            return .folder(id: folder.id, name: folder.name, sharedDriveID: root.sharedDriveID)
        }
        switch root {
        case .myDrive: return .myDrive
        case .sharedWithMe: return .sharedWithMe
        case .recent: return .recent
        case .starred: return .starred
        case .trash: return .trash
        case .sharedDrive(let id, let name): return .sharedDrive(id: id, name: name)
        }
    }

    public var uploadParentID: String? {
        location.uploadParentID
    }
}

public enum DriveLocation: Hashable, Codable, Sendable {
    case myDrive
    case sharedWithMe
    case recent
    case starred
    case trash
    case sharedDrive(id: String, name: String)
    case folder(id: String, name: String, sharedDriveID: String?)
    case search(query: String)

    public var cacheKey: String {
        switch self {
        case .myDrive: return "myDrive"
        case .sharedWithMe: return "sharedWithMe"
        case .recent: return "recent"
        case .starred: return "starred"
        case .trash: return "trash"
        case .sharedDrive(let id, _): return "sharedDrive:\(id)"
        case .folder(let id, _, _): return "folder:\(id)"
        case .search(let query): return "search:\(query)"
        }
    }

    public var supportsIncrementalRefresh: Bool {
        if case .search = self { return false }
        return true
    }

    public var uploadParentID: String? {
        switch self {
        case .myDrive:
            return "root"
        case .folder(let id, _, _):
            return id
        case .sharedDrive(let id, _):
            return id
        case .sharedWithMe, .recent, .starred, .trash, .search:
            return nil
        }
    }
}

public enum SearchQuery {
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
