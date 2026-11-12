import Foundation

public actor DriveCache {
    private let rootDirectory: URL

    public init(rootDirectory: URL) throws {
        self.rootDirectory = rootDirectory
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    public func listing(accountID: String, key: String) throws -> CachedListing? {
        let url = listingURL(accountID: accountID, key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let listing = try? JSONCoders.makeDecoder().decode(CachedListing.self, from: data), listing.isCurrent else {
            return nil
        }
        return listing
    }

    public func saveListing(accountID: String, listing: CachedListing) throws {
        let url = listingURL(accountID: accountID, key: listing.key)
        let data = try JSONCoders.makeEncoder().encode(listing)
        try writeAtomic(data, to: url)
    }

    public func applyChanges(accountID: String, changes: [DriveChange], now: Date = Date()) throws -> Set<String> {
        var listings = try loadAllListings(accountID: accountID)
        let touched = ChangeApplier.apply(changes, to: &listings, now: now)
        for key in touched {
            if let listing = listings[key] {
                try saveListing(accountID: accountID, listing: listing)
            }
        }
        return touched
    }

    public func removeFile(accountID: String, fileID: String, trashCopy: DriveFile?) throws {
        var listings = try loadAllListings(accountID: accountID)
        var file = trashCopy
        file?.trashed = true
        let change = DriveChange(fileId: fileID, removed: file == nil, file: file)
        let touched = ChangeApplier.apply([change], to: &listings)
        for key in touched {
            if let listing = listings[key] {
                try saveListing(accountID: accountID, listing: listing)
            }
        }
    }

    public func startPageToken(for accountID: String) throws -> String? {
        try loadMeta(accountID: accountID).startPageToken
    }

    public func setStartPageToken(for accountID: String, token: String?) throws {
        var meta = try loadMeta(accountID: accountID)
        meta.startPageToken = token
        try saveMeta(meta, accountID: accountID)
    }

    public func drives(for accountID: String) throws -> [SharedDrive] {
        try loadMeta(accountID: accountID).drives
    }

    public func saveDrives(_ drives: [SharedDrive], accountID: String) throws {
        var meta = try loadMeta(accountID: accountID)
        meta.drives = drives
        try saveMeta(meta, accountID: accountID)
    }

    public func clearListings(accountID: String) throws {
        let directory = accountDirectory(accountID).appendingPathComponent("listings", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public func clear(accountID: String) throws {
        let directory = accountDirectory(accountID)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func loadAllListings(accountID: String) throws -> [String: CachedListing] {
        let directory = accountDirectory(accountID).appendingPathComponent("listings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var listings: [String: CachedListing] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let listing = try? JSONCoders.makeDecoder().decode(CachedListing.self, from: data) else {
                continue
            }
            guard listing.isCurrent else { continue }
            listings[listing.key] = listing
        }
        return listings
    }

    private func listingURL(accountID: String, key: String) -> URL {
        accountDirectory(accountID)
            .appendingPathComponent("listings", isDirectory: true)
            .appendingPathComponent(fileName(for: key))
            .appendingPathExtension("json")
    }

    private func accountDirectory(_ accountID: String) -> URL {
        rootDirectory.appendingPathComponent(AccountID.sanitize(accountID), isDirectory: true)
    }

    private func metaURL(accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("meta.json")
    }

    private func loadMeta(accountID: String) throws -> AccountMeta {
        let url = metaURL(accountID: accountID)
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountMeta() }
        let data = try Data(contentsOf: url)
        return (try? JSONCoders.makeDecoder().decode(AccountMeta.self, from: data)) ?? AccountMeta()
    }

    private func saveMeta(_ meta: AccountMeta, accountID: String) throws {
        let data = try JSONCoders.makeEncoder().encode(meta)
        try writeAtomic(data, to: metaURL(accountID: accountID))
    }

    private func fileName(for key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "listing"
    }

    private func writeAtomic(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}

private struct AccountMeta: Codable {
    var startPageToken: String?
    var drives: [SharedDrive]

    init(startPageToken: String? = nil, drives: [SharedDrive] = []) {
        self.startPageToken = startPageToken
        self.drives = drives
    }
}
