import Foundation

public enum ListingCacheVersion {
    /// Bumped when stored listings lack fields the browser now shows, and earlier when a wide files.list mask truncated pages.
    public static let current = 4
}

public struct CachedListing: Equatable, Sendable {
    public var key: String
    public var files: [DriveFile]
    public var nextPageToken: String?
    public var fetchedAt: Date
    public var version: Int

    public init(key: String, files: [DriveFile], nextPageToken: String?, fetchedAt: Date, version: Int = ListingCacheVersion.current) {
        self.key = key
        self.files = files
        self.nextPageToken = ListingPageToken.normalized(nextPageToken)
        self.fetchedAt = fetchedAt
        self.version = version
    }

    /// A listing with no further page token. Older versions are not trusted; they may be truncated.
    public var isComplete: Bool {
        nextPageToken == nil && version >= ListingCacheVersion.current
    }

    public var isCurrent: Bool {
        version >= ListingCacheVersion.current
    }
}

extension CachedListing: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, files, nextPageToken, fetchedAt, version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        files = try container.decodeIfPresent([DriveFile].self, forKey: .files) ?? []
        nextPageToken = ListingPageToken.normalized(try container.decodeIfPresent(String.self, forKey: .nextPageToken))
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt) ?? .distantPast
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(files, forKey: .files)
        try container.encodeIfPresent(nextPageToken, forKey: .nextPageToken)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(version, forKey: .version)
    }
}

public enum ListingPageToken {
    public static func normalized(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ListingWalk {
    /// Merge every page. The listing is complete only when the last page has no token.
    public static func accumulate(pages: [FilePage], key: String, now: Date = Date()) -> CachedListing {
        var files: [DriveFile] = []
        var token: String?
        for page in pages {
            files = ListingRefresh.mergePage(existing: files, page: page.files, key: key)
            token = ListingPageToken.normalized(page.nextPageToken)
        }
        return CachedListing(key: key, files: files, nextPageToken: token, fetchedAt: now)
    }

    /// Drop rows the server did not return only after every page arrived.
    public static func finalize(
        files: [DriveFile],
        seen: Set<String>,
        pinned: Set<String> = [],
        key: String,
        nextPageToken: String?,
        failed: Bool,
        now: Date = Date()
    ) -> CachedListing? {
        guard !failed, ListingPageToken.normalized(nextPageToken) == nil else { return nil }
        let closed = ListingRefresh.droppingUnseen(files: files, seen: seen, pinned: pinned, key: key)
        return CachedListing(key: key, files: closed, nextPageToken: nil, fetchedAt: now)
    }
}

public enum ListingCacheWrite {
    /// A one-page prefetch must not discard rows already stored from later pages.
    public static func resolve(existing: CachedListing?, incoming: CachedListing) -> CachedListing {
        var incoming = incoming
        incoming.version = ListingCacheVersion.current
        incoming.nextPageToken = ListingPageToken.normalized(incoming.nextPageToken)
        guard let existing, existing.isCurrent, !incoming.isComplete, existing.files.count > incoming.files.count else {
            return incoming
        }
        let merged = ListingRefresh.mergePage(existing: existing.files, page: incoming.files, key: existing.key)
        return CachedListing(
            key: existing.key,
            files: merged,
            nextPageToken: existing.nextPageToken,
            fetchedAt: existing.fetchedAt,
            version: ListingCacheVersion.current
        )
    }
}

public enum ListingSorter {
    public static func sort(_ files: [DriveFile], key: String) -> [DriveFile] {
        if key == DriveLocation.recent.cacheKey {
            return files.sorted { lhs, rhs in
                let left = lhs.viewedByMeTime ?? lhs.modifiedTime ?? .distantPast
                let right = rhs.viewedByMeTime ?? rhs.modifiedTime ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        if key == DriveLocation.trash.cacheKey {
            return files.sorted { lhs, rhs in
                let left = lhs.modifiedTime ?? .distantPast
                let right = rhs.modifiedTime ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        if key.hasPrefix("search:") {
            return files.sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder && !rhs.isFolder }
                let left = lhs.modifiedTime ?? .distantPast
                let right = rhs.modifiedTime ?? .distantPast
                if left != right { return left > right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
        return files.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder && !rhs.isFolder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

public enum PageMerger {
    public static func merge(existing: [DriveFile], page: [DriveFile]) -> [DriveFile] {
        var seen = Set(existing.map(\.id))
        var result = existing
        for file in page where seen.insert(file.id).inserted {
            result.append(file)
        }
        return result
    }
}

public enum ChangeApplier {
    public static func apply(_ changes: [DriveChange], to listings: inout [String: CachedListing], now: Date = Date()) -> Set<String> {
        var touched = Set<String>()
        for change in changes {
            let trashed = change.file?.trashed == true
            if change.removed || trashed {
                for key in Array(listings.keys) where key != DriveLocation.trash.cacheKey {
                    if remove(change.fileId, from: key, listings: &listings) {
                        touched.insert(key)
                    }
                }
                if change.removed {
                    if remove(change.fileId, from: DriveLocation.trash.cacheKey, listings: &listings) {
                        touched.insert(DriveLocation.trash.cacheKey)
                    }
                } else if let file = change.file {
                    if upsert(file, into: DriveLocation.trash.cacheKey, listings: &listings) {
                        touched.insert(DriveLocation.trash.cacheKey)
                    }
                }
                continue
            }

            guard let file = change.file else { continue }
            for key in Array(listings.keys) {
                if key == DriveLocation.trash.cacheKey {
                    if remove(file.id, from: key, listings: &listings) {
                        touched.insert(key)
                    }
                    continue
                }
                if key == DriveLocation.starred.cacheKey && !file.starred {
                    if remove(file.id, from: key, listings: &listings) {
                        touched.insert(key)
                    }
                    continue
                }
                if let parent = parentID(for: key), !file.parents.isEmpty, !file.parents.contains(parent) {
                    if remove(file.id, from: key, listings: &listings) {
                        touched.insert(key)
                    }
                    continue
                }
                if replace(file, in: key, listings: &listings) {
                    touched.insert(key)
                }
            }

            if !file.trashed {
                for parent in file.parents {
                    for key in keys(forParent: parent, driveID: file.driveId) {
                        if insertIfMissing(file, into: key, listings: &listings) {
                            touched.insert(key)
                        }
                    }
                }
                if file.starred, insertIfMissing(file, into: DriveLocation.starred.cacheKey, listings: &listings) {
                    touched.insert(DriveLocation.starred.cacheKey)
                }
            }
        }

        for key in touched {
            guard var listing = listings[key] else { continue }
            listing.files = ListingSorter.sort(listing.files, key: key)
            listing.fetchedAt = now
            listings[key] = listing
        }
        return touched
    }

    private static func parentID(for key: String) -> String? {
        if key == DriveLocation.myDrive.cacheKey { return "root" }
        if key.hasPrefix("sharedDrive:") { return String(key.dropFirst("sharedDrive:".count)) }
        if key.hasPrefix("folder:") { return String(key.dropFirst("folder:".count)) }
        return nil
    }

    private static func keys(forParent parent: String, driveID: String?) -> [String] {
        var keys = ["folder:\(parent)"]
        if parent == "root" {
            keys.append(DriveLocation.myDrive.cacheKey)
        }
        if let driveID, parent == driveID {
            keys.append(DriveLocation.sharedDrive(id: driveID, name: "").cacheKey)
        }
        return keys
    }

    private static func remove(_ fileID: String, from key: String, listings: inout [String: CachedListing]) -> Bool {
        guard var listing = listings[key], let index = listing.files.firstIndex(where: { $0.id == fileID }) else {
            return false
        }
        listing.files.remove(at: index)
        listings[key] = listing
        return true
    }

    private static func replace(_ file: DriveFile, in key: String, listings: inout [String: CachedListing]) -> Bool {
        guard var listing = listings[key], let index = listing.files.firstIndex(where: { $0.id == file.id }) else {
            return false
        }
        listing.files[index] = file
        listings[key] = listing
        return true
    }

    private static func insertIfMissing(_ file: DriveFile, into key: String, listings: inout [String: CachedListing]) -> Bool {
        guard var listing = listings[key] else { return false }
        if listing.files.contains(where: { $0.id == file.id }) { return false }
        listing.files.append(file)
        listings[key] = listing
        return true
    }

    private static func upsert(_ file: DriveFile, into key: String, listings: inout [String: CachedListing]) -> Bool {
        guard listings[key] != nil else { return false }
        if replace(file, in: key, listings: &listings) { return true }
        return insertIfMissing(file, into: key, listings: &listings)
    }
}

public enum RevalidatePlan: Equatable, Sendable {
    case incremental(token: String)
    case full
}

public enum RevalidatePlanner {
    public static func plan(forceFull: Bool, hasCachedListing: Bool, startToken: String?, location: DriveLocation) -> RevalidatePlan {
        if forceFull { return .full }
        guard hasCachedListing, let startToken, !startToken.isEmpty, location.supportsIncrementalRefresh else {
            return .full
        }
        return .incremental(token: startToken)
    }
}
