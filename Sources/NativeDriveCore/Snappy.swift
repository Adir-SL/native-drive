import Foundation

/// In-memory folder listings. A hit is synchronous so navigation can paint before disk or the network.
public struct ListingMemoryCache: Equatable, Sendable {
    public private(set) var limit: Int
    private var order: [String] = []
    private var values: [String: CachedListing] = [:]

    public init(limit: Int = 32) {
        self.limit = max(1, limit)
    }

    public var count: Int { values.count }

    public mutating func listing(for key: String) -> CachedListing? {
        guard let listing = values[key] else { return nil }
        touch(key)
        return listing
    }

    public mutating func store(_ listing: CachedListing) {
        if values[listing.key] == nil {
            order.append(listing.key)
        }
        values[listing.key] = listing
        touch(listing.key)
        evict()
    }

    public mutating func removeAll() {
        order.removeAll()
        values.removeAll()
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private mutating func evict() {
        while order.count > limit {
            let oldest = order.removeFirst()
            values[oldest] = nil
        }
    }
}

public enum ListingFreshness {
    /// Cached folders younger than this skip a background refetch.
    public static let staleInterval: TimeInterval = 20

    public static func isStale(_ listing: CachedListing, now: Date, interval: TimeInterval = staleInterval) -> Bool {
        now.timeIntervalSince(listing.fetchedAt) >= interval
    }
}

public enum ListingReconciler {
    /// Keep the current array when ids and values already match, so SwiftUI does not rebuild the rows.
    public static func reconcile(current: [DriveFile], incoming: [DriveFile]) -> [DriveFile] {
        guard current.count == incoming.count else { return incoming }
        for pair in zip(current, incoming) where pair.0.id != pair.1.id {
            return incoming
        }
        var result = current
        var changed = false
        for index in current.indices where current[index] != incoming[index] {
            result[index] = incoming[index]
            changed = true
        }
        return changed ? result : current
    }
}

public enum ListingRefresh {
    /// Fold the latest page into the rows already on screen. The tail stays until the last page arrives.
    public static func mergePage(existing: [DriveFile], page: [DriveFile], key: String) -> [DriveFile] {
        var incoming: [String: DriveFile] = [:]
        incoming.reserveCapacity(page.count)
        for file in page {
            incoming[file.id] = file
        }
        var seen = Set<String>()
        var result: [DriveFile] = []
        result.reserveCapacity(existing.count + page.count)
        for file in existing {
            result.append(incoming[file.id] ?? file)
            seen.insert(file.id)
        }
        for file in page where seen.insert(file.id).inserted {
            result.append(file)
        }
        return ListingSorter.sort(result, key: key)
    }

    public static func droppingUnseen(files: [DriveFile], seen: Set<String>, key: String) -> [DriveFile] {
        ListingSorter.sort(files.filter { seen.contains($0.id) }, key: key)
    }
}

public struct FileMetadataIndex: Equatable, Sendable {
    public private(set) var limit: Int
    private var order: [String] = []
    private var files: [String: DriveFile] = [:]

    public init(limit: Int = 2_000) {
        self.limit = max(1, limit)
    }

    public var count: Int { files.count }

    public mutating func remember(_ batch: [DriveFile]) {
        for file in batch {
            remember(file)
        }
    }

    public mutating func remember(_ file: DriveFile) {
        if files[file.id] == nil {
            order.append(file.id)
        } else {
            order.removeAll { $0 == file.id }
            order.append(file.id)
        }
        files[file.id] = file
        while order.count > limit {
            let oldest = order.removeFirst()
            files[oldest] = nil
        }
    }

    public func file(id: String) -> DriveFile? {
        files[id]
    }
}

public struct PrefetchJob: Equatable, Sendable, Identifiable {
    public var id: String
    public var priority: Int

    public init(id: String, priority: Int) {
        self.id = id
        self.priority = priority
    }
}

public struct PrefetchScheduler: Equatable, Sendable {
    public var limit: Int
    public private(set) var running: [PrefetchJob] = []
    public private(set) var queued: [PrefetchJob] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public struct Decision: Equatable, Sendable {
        public var start: [PrefetchJob]
        public var cancel: [PrefetchJob]

        public init(start: [PrefetchJob], cancel: [PrefetchJob]) {
            self.start = start
            self.cancel = cancel
        }
    }

    /// Replace the desired set. Lower priority numbers run first. Running jobs that are no longer desired are cancelled.
    public mutating func setRelevant(_ jobs: [PrefetchJob]) -> Decision {
        var unique: [PrefetchJob] = []
        var seen = Set<String>()
        for job in jobs where seen.insert(job.id).inserted {
            unique.append(job)
        }
        let relevant = Set(unique.map(\.id))
        var cancel: [PrefetchJob] = []
        running.removeAll { job in
            guard !relevant.contains(job.id) else { return false }
            cancel.append(job)
            return true
        }
        queued.removeAll { !relevant.contains($0.id) }
        for job in unique {
            if let index = running.firstIndex(where: { $0.id == job.id }) {
                running[index] = job
                continue
            }
            if let index = queued.firstIndex(where: { $0.id == job.id }) {
                queued[index] = job
            } else {
                queued.append(job)
            }
        }
        return Decision(start: pump(), cancel: cancel)
    }

    public mutating func finished(_ id: String) -> [PrefetchJob] {
        running.removeAll { $0.id == id }
        queued.removeAll { $0.id == id }
        return pump()
    }

    private mutating func pump() -> [PrefetchJob] {
        queued.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
        var started: [PrefetchJob] = []
        while running.count < limit, !queued.isEmpty {
            let job = queued.removeFirst()
            running.append(job)
            started.append(job)
        }
        return started
    }
}

public enum PrefetchPlanner {
    public static let hoverDelayNanoseconds: UInt64 = 150_000_000
    public static let subfolderLimit = 4
    public static let imageLookahead = 2
    public static let maxPrefetchBytes: Int64 = 32 * 1024 * 1024

    public static func allowsNetworkPrefetch(isConstrained: Bool) -> Bool {
        !isConstrained
    }

    public static func subfolders(in files: [DriveFile], limit: Int = subfolderLimit) -> [DriveFile] {
        Array(files.filter(\.isFolder).prefix(max(0, limit)))
    }

    public static func imageIDs(
        in files: [DriveFile],
        currentID: String,
        direction: Int,
        lookahead: Int = imageLookahead,
        isConstrained: Bool,
        maxBytes: Int64 = maxPrefetchBytes
    ) -> [String] {
        guard allowsNetworkPrefetch(isConstrained: isConstrained) else { return [] }
        let images = files.filter { MediaClassifier.kind(of: $0) == .image }
        guard let index = images.firstIndex(where: { $0.id == currentID }) else { return [] }
        let steps = offsets(direction: direction, lookahead: max(1, lookahead))
        var ids: [String] = []
        for step in steps {
            let next = index + step
            guard images.indices.contains(next) else { continue }
            let file = images[next]
            if let size = file.size, size > maxBytes { continue }
            ids.append(file.id)
        }
        return ids
    }

    private static func offsets(direction: Int, lookahead: Int) -> [Int] {
        if direction > 0 {
            var values = [Int]()
            values.reserveCapacity(lookahead + 1)
            values.append(-1)
            for step in 1...lookahead {
                values.append(step)
            }
            return values
        }
        if direction < 0 {
            var values = [Int]()
            values.reserveCapacity(lookahead + 1)
            values.append(1)
            for step in 1...lookahead {
                values.append(-step)
            }
            return values
        }
        return [-1, 1]
    }
}

public enum ThumbnailPlan {
    public static let rowEdge = 128
    public static let proxyEdge = 1600
    public static let diskBudget: Int64 = 256 * 1024 * 1024
    public static let memoryCountLimit = 180

    public static func proxyEdge(forPixelLength pixels: Int) -> Int {
        let buckets = [256, 512, 1024, 1600, 2048]
        let target = min(max(pixels, buckets[0]), buckets[buckets.count - 1])
        return buckets.first(where: { $0 >= target }) ?? proxyEdge
    }

    public static func cacheKey(fileID: String, edge: Int) -> String {
        "\(fileID)#\(edge)"
    }
}

public enum ThumbnailCacheKey {
    public static func relativePath(accountID: String, fileID: String, edge: Int) -> String {
        let account = AccountID.sanitize(accountID)
        let file = AccountID.sanitize(fileID)
        return "thumbs/\(account)/\(file)/\(edge)"
    }
}
