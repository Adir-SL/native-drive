import Foundation

public struct FilesListQuery: Equatable, Sendable {
    public var q: String?
    public var orderBy: String
    public var pageSize: Int
    public var pageToken: String?
    public var corpora: String?
    public var driveId: String?
    public var includeItemsFromAllDrives: Bool

    public init(
        q: String?,
        orderBy: String,
        pageSize: Int,
        pageToken: String?,
        corpora: String?,
        driveId: String?,
        includeItemsFromAllDrives: Bool
    ) {
        self.q = q
        self.orderBy = orderBy
        self.pageSize = pageSize
        self.pageToken = pageToken
        self.corpora = corpora
        self.driveId = driveId
        self.includeItemsFromAllDrives = includeItemsFromAllDrives
    }
}

public enum DriveQueryBuilder {
    public static let defaultPageSize = 1_000
    public static let maxPageSize = 1_000

    public static func clampedPageSize(_ value: Int) -> Int {
        if value < 1 { return 1 }
        if value > maxPageSize { return maxPageSize }
        return value
    }

    public static func escapeQueryLiteral(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "'" {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }

    public static func filesList(for location: DriveLocation, pageToken: String?, pageSize: Int = defaultPageSize) -> FilesListQuery {
        switch location {
        case .myDrive:
            return make(
                q: "'root' in parents and trashed = false",
                orderBy: "folder,name",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "user",
                driveId: nil
            )
        case .folder(let id, _, let sharedDriveID):
            let query = "'\(escapeQueryLiteral(id))' in parents and trashed = false"
            if let sharedDriveID {
                return make(q: query, orderBy: "folder,name", pageToken: pageToken, pageSize: pageSize, corpora: "drive", driveId: sharedDriveID)
            }
            return make(q: query, orderBy: "folder,name", pageToken: pageToken, pageSize: pageSize, corpora: "user", driveId: nil)
        case .sharedWithMe:
            return make(
                q: "sharedWithMe = true and trashed = false",
                orderBy: "folder,name",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "user",
                driveId: nil
            )
        case .recent:
            return make(
                q: "trashed = false",
                orderBy: "viewedByMeTime desc",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "allDrives",
                driveId: nil
            )
        case .starred:
            return make(
                q: "starred = true and trashed = false",
                orderBy: "folder,name",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "allDrives",
                driveId: nil
            )
        case .trash:
            return make(
                q: "trashed = true",
                orderBy: "modifiedTime desc",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "allDrives",
                driveId: nil
            )
        case .sharedDrive(let id, _):
            let query = "'\(escapeQueryLiteral(id))' in parents and trashed = false"
            return make(q: query, orderBy: "folder,name", pageToken: pageToken, pageSize: pageSize, corpora: "drive", driveId: id)
        case .search(let text):
            let escaped = escapeQueryLiteral(text)
            let query = "(name contains '\(escaped)' or fullText contains '\(escaped)') and trashed = false"
            return make(
                q: query,
                orderBy: "folder,modifiedTime desc",
                pageToken: pageToken,
                pageSize: clampedPageSize(pageSize),
                corpora: "allDrives",
                driveId: nil
            )
        }
    }

    private static func make(
        q: String,
        orderBy: String,
        pageToken: String?,
        pageSize: Int,
        corpora: String,
        driveId: String?
    ) -> FilesListQuery {
        FilesListQuery(
            q: q,
            orderBy: orderBy,
            pageSize: clampedPageSize(pageSize),
            pageToken: pageToken,
            corpora: corpora,
            driveId: driveId,
            includeItemsFromAllDrives: true
        )
    }
}
