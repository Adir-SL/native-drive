import AppKit
import Foundation
import NativeDriveCore
import Network

/// Tracks expensive or constrained paths so prefetch can stay quiet on those networks.
final class NetworkConditions: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var constrained = false
    private var started = false

    var isConstrained: Bool {
        lock.lock()
        defer { lock.unlock() }
        return constrained
    }

    func start() {
        lock.lock()
        let already = started
        started = true
        lock.unlock()
        guard !already else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.store(path.isConstrained || path.isExpensive)
        }
        monitor.start(queue: DispatchQueue(label: "app.nativedrive.path"))
    }

    private func store(_ value: Bool) {
        lock.lock()
        constrained = value
        lock.unlock()
    }
}

/// Memory and disk cache for Drive thumbnail proxies. Decoding happens off the main thread.
@MainActor
final class ThumbnailFetcher {
    private let client: DriveClient
    private let accountID: String
    private let root: URL
    private let decoded: NSCache<NSString, NSImage>
    private var inflight: [String: Task<DecodedStill?, Never>] = [:]

    init(client: DriveClient, accountID: String, root: URL) {
        self.client = client
        self.accountID = accountID
        self.root = root
        decoded = NSCache<NSString, NSImage>()
        decoded.countLimit = ThumbnailPlan.memoryCountLimit
    }

    func cached(fileID: String, edge: Int) -> NSImage? {
        decoded.object(forKey: ThumbnailPlan.cacheKey(fileID: fileID, edge: edge) as NSString)
    }

    func image(for file: DriveFile, edge: Int) async -> NSImage? {
        let key = ThumbnailPlan.cacheKey(fileID: file.id, edge: edge)
        if let cached = decoded.object(forKey: key as NSString) {
            return cached
        }
        guard let still = await still(for: file, edge: edge, key: key) else { return nil }
        let image = NSImage(
            cgImage: still.image,
            size: NSSize(width: CGFloat(still.image.width), height: CGFloat(still.image.height))
        )
        decoded.setObject(image, forKey: key as NSString)
        return image
    }

    private func still(for file: DriveFile, edge: Int, key: String) async -> DecodedStill? {
        if let task = inflight[key] {
            return await task.value
        }
        while inflight.count >= 3 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        if Task.isCancelled { return nil }
        if let task = inflight[key] {
            return await task.value
        }
        let task = Task { @MainActor in
            await self.loadStill(file: file, edge: edge)
        }
        inflight[key] = task
        let value = await task.value
        inflight[key] = nil
        return value
    }

    private func loadStill(file: DriveFile, edge: Int) async -> DecodedStill? {
        let destination = root.appendingPathComponent(
            ThumbnailCacheKey.relativePath(accountID: accountID, fileID: file.id, edge: edge)
        )
        if !isNonEmpty(destination) {
            guard let link = file.thumbnailLink, let remote = URL(string: DriveThumbnailURL.enlarged(link, edge: edge)) else {
                return nil
            }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    try await client.downloadAuthenticated(from: remote, to: destination) { _, _ in }
                } catch {
                    let request = URLRequest(url: remote)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                        return nil
                    }
                    try data.write(to: destination, options: .atomic)
                }
            } catch {
                return nil
            }
            let account = accountID
            let root = root
            Task.detached(priority: .utility) {
                Self.evict(accountID: account, root: root)
            }
        }
        let maxPixel = CGFloat(edge)
        return await Task.detached(priority: .utility) {
            StillImageDecoder.decode(url: destination, maxPixel: maxPixel)
        }.value
    }

    private func isNonEmpty(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return size > 0
    }

    private nonisolated static func evict(accountID: String, root: URL) {
        let accountRoot = root
            .appendingPathComponent("thumbs", isDirectory: true)
            .appendingPathComponent(AccountID.sanitize(accountID), isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: accountRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [MediaCacheEntry] = []
        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            entries.append(MediaCacheEntry(
                key: directory.lastPathComponent,
                byteCount: byteCount(of: directory),
                lastAccessed: values?.contentModificationDate ?? .distantPast
            ))
        }
        let remove = MediaCacheEviction.keysToRemove(entries: entries, budget: ThumbnailPlan.diskBudget)
        for key in remove {
            try? FileManager.default.removeItem(at: accountRoot.appendingPathComponent(key, isDirectory: true))
        }
    }

    private nonisolated static func byteCount(of directory: URL) -> Int64 {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
        ) else { return 0 }
        var total: Int64 = 0
        for child in children {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                total += byteCount(of: child)
            } else {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }
}
