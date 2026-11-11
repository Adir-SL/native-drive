import AppKit
import AVFoundation
import AVKit
import Combine
import NativeDriveCore

@MainActor
final class MediaSession: ObservableObject {
    enum Kind: Equatable {
        case images
        case player
        case unsupported
    }

    let kind: Kind
    let playlistKind: MediaKind
    private let client: DriveClient
    private let thumbnails: ThumbnailFetcher
    private let accountID: String
    private let downloadRoot: URL
    private var playlist: [DriveFile]
    private var generation = 0
    private var statusObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?

    @Published private(set) var index: Int
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var fullImage: NSImage?
    @Published private(set) var message: String?
    @Published private(set) var detail: String?
    @Published private(set) var canRetry = false
    @Published private(set) var downloadFraction: Double?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playbackFailed = false
    weak var playerView: AVPlayerView?
    private var downloads: [String: Task<URL, Error>] = [:]
    private var shouldAutoplay = true
    private var travelDirection = 0
    private var loadingOriginal = false
    private var imageScheduler = PrefetchScheduler(limit: 2)
    private var imageTasks: [String: Task<Void, Never>] = [:]
    private var imageTokens: [String: UUID] = [:]
    var allowsPrefetch = true

    var onDismiss: (@MainActor () -> Void)?

    init(
        kind: Kind,
        playlistKind: MediaKind,
        playlist: [DriveFile],
        startingFileID: String,
        client: DriveClient,
        accountID: String,
        downloadRoot: URL,
        thumbnails: ThumbnailFetcher
    ) {
        self.kind = kind
        self.playlistKind = playlistKind
        self.playlist = playlist.isEmpty ? [] : playlist
        self.client = client
        self.thumbnails = thumbnails
        self.accountID = accountID
        self.downloadRoot = downloadRoot
        self.index = playlist.firstIndex { $0.id == startingFileID } ?? 0
    }

    var fileID: String { current.id }
    var fileName: String { current.name }
    var count: Int { playlist.count }
    var positionLabel: String { MediaNavigator.positionLabel(index: index, count: playlist.count) }
    var isAudio: Bool { MediaClassifier.kind(of: current) == .playableAudio }
    var canGoBack: Bool { MediaNavigator.neighborIndex(current: index, count: count, delta: -1) != nil }
    var canGoForward: Bool { MediaNavigator.neighborIndex(current: index, count: count, delta: 1) != nil }

    private var current: DriveFile {
        playlist[min(max(index, 0), max(playlist.count - 1, 0))]
    }

    func start() {
        guard !playlist.isEmpty else { return }
        switch kind {
        case .images:
            showCurrentImage()
        case .player:
            Task { await self.startPlayer() }
        case .unsupported:
            message = "Native Drive can't play this video in the app."
        }
    }

    func stop() {
        generation += 1
        player?.pause()
        player = nil
        detachPlaybackObservers()
    }

    func dismiss() {
        stop()
        onDismiss?()
    }

    func retry() {
        message = nil
        detail = nil
        canRetry = false
        playbackFailed = false
        switch kind {
        case .images:
            showCurrentImage()
        case .player:
            shouldAutoplay = true
            Task { await self.startPlayer() }
        case .unsupported:
            break
        }
    }

    func step(_ delta: Int) {
        guard kind == .images, let next = MediaNavigator.neighborIndex(current: index, count: count, delta: delta) else { return }
        travelDirection = delta < 0 ? -1 : 1
        index = next
        showCurrentImage()
    }

    func loadOriginalIfNeeded() {
        guard kind == .images, !loadingOriginal else { return }
        loadingOriginal = true
        let token = generation
        let file = current
        Task { @MainActor [weak self] in
            await self?.downloadFullImage(file, generation: token)
        }
    }

    func replacePlaylist(_ files: [DriveFile]) {
        let updated = MediaNavigator.playlist(in: files, kind: playlistKind)
        guard !updated.isEmpty else { return }
        let currentID = playlist.indices.contains(index) ? playlist[index].id : fileID
        playlist = updated
        index = MediaNavigator.index(of: currentID, in: updated) ?? min(index, updated.count - 1)
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags.isEmpty else { return false }
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        switch kind {
        case .images:
            if event.keyCode == 123 || event.keyCode == 126 {
                step(-1)
                return true
            }
            if event.keyCode == 124 || event.keyCode == 125 {
                step(1)
                return true
            }
            if event.keyCode == 49 {
                dismiss()
                return true
            }
            return false
        case .player:
            if event.keyCode == 49 {
                togglePlayback()
                return true
            }
            if event.keyCode == 123 {
                seek(by: -10)
                return true
            }
            if event.keyCode == 124 {
                seek(by: 10)
                return true
            }
            if event.keyCode == 3 {
                toggleFullScreen()
                return true
            }
            return false
        case .unsupported:
            if event.keyCode == 49 {
                dismiss()
                return true
            }
            return false
        }
    }

    func openInDefaultApp() {
        let file = current
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.ensureDownloaded(file)
                NSWorkspace.shared.open(url)
            } catch {
                guard !MediaFailure.isCancellation(error) else { return }
                self.message = "Couldn't download this file."
                self.detail = MediaFailure.detail(error)
                self.canRetry = true
                if self.player == nil {
                    self.playbackFailed = true
                }
            }
        }
    }

    private func showCurrentImage() {
        generation += 1
        let token = generation
        let file = current
        fullImage = nil
        message = nil
        detail = nil
        canRetry = false
        downloadFraction = nil
        loadingOriginal = false
        thumbnail = thumbnails.cached(fileID: file.id, edge: ThumbnailPlan.rowEdge)
        fullImage = thumbnails.cached(fileID: file.id, edge: ThumbnailPlan.proxyEdge)
        let destination = fileURL(for: file)
        if isComplete(file, at: destination) {
            touch(destination)
            Task { @MainActor [weak self] in
                await self?.applyFullImage(at: destination, file: file, generation: token)
            }
        } else if fullImage == nil {
            Task { @MainActor [weak self] in
                await self?.loadProxy(file, generation: token)
            }
        }
        prefetchImageNeighbors()
    }

    private func loadProxy(_ file: DriveFile, generation: Int) async {
        if let image = await thumbnails.image(for: file, edge: ThumbnailPlan.proxyEdge) {
            guard generation == self.generation else { return }
            fullImage = image
            message = nil
            detail = nil
            canRetry = false
            return
        }
        guard generation == self.generation else { return }
        await downloadFullImage(file, generation: generation)
    }

    private func downloadFullImage(_ file: DriveFile, generation: Int) async {
        let destination = fileURL(for: file)
        do {
            _ = try await ensureDownloaded(file)
            guard generation == self.generation else { return }
            await applyFullImage(at: destination, file: file, generation: generation)
            evictUnneededMedia()
        } catch {
            guard generation == self.generation else { return }
            guard !MediaFailure.isCancellation(error) else { return }
            message = "Couldn't download this image."
            detail = MediaFailure.detail(error)
            canRetry = true
        }
    }

    private func applyFullImage(at url: URL, file: DriveFile, generation: Int) async {
        let animated = file.mimeType.lowercased().contains("gif") || file.name.lowercased().hasSuffix(".gif")
        if animated, let image = NSImage(contentsOf: url), image.size.width > 0 {
            guard generation == self.generation else { return }
            fullImage = image
            message = nil
            detail = nil
            canRetry = false
            return
        }
        let decoded = await Task.detached(priority: .userInitiated) {
            StillImageDecoder.decode(url: url)
        }.value
        guard generation == self.generation else { return }
        if let decoded {
            let cgImage = decoded.image
            fullImage = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
            message = nil
            detail = nil
            canRetry = false
            return
        }
        if let fallback = NSImage(contentsOf: url), fallback.size.width > 0 {
            fullImage = fallback
            message = nil
            detail = nil
            canRetry = false
            return
        }
        message = thumbnail == nil
            ? "Couldn't decode this image."
            : "Couldn't decode this image. Showing Google's preview instead."
        detail = "ImageIO could not read \(file.name)."
        canRetry = true
    }

    private func prefetchImageNeighbors() {
        let ids = PrefetchPlanner.imageIDs(
            in: playlist,
            currentID: fileID,
            direction: travelDirection,
            isConstrained: !allowsPrefetch
        )
        let jobs = ids.enumerated().map { PrefetchJob(id: $0.element, priority: $0.offset) }
        let decision = imageScheduler.setRelevant(jobs)
        for job in decision.cancel {
            imageTokens[job.id] = UUID()
            imageTasks[job.id]?.cancel()
            imageTasks[job.id] = nil
        }
        for job in decision.start {
            startImagePrefetch(job)
        }
    }

    private func startImagePrefetch(_ job: PrefetchJob) {
        guard let file = playlist.first(where: { $0.id == job.id }) else {
            let more = imageScheduler.finished(job.id)
            for next in more { startImagePrefetch(next) }
            return
        }
        let token = UUID()
        imageTokens[job.id] = token
        imageTasks[job.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.thumbnails.image(for: file, edge: ThumbnailPlan.proxyEdge)
            guard self.imageTokens[job.id] == token else { return }
            self.imageTasks[job.id] = nil
            let more = self.imageScheduler.finished(job.id)
            for next in more {
                self.startImagePrefetch(next)
            }
        }
    }

    private func startPlayer() async {
        generation += 1
        let token = generation
        let file = current
        playbackFailed = false
        message = nil
        detail = nil
        canRetry = false
        downloadFraction = 0
        player?.pause()
        player = nil
        detachPlaybackObservers()
        shouldAutoplay = true
        do {
            let localURL = try await ensureDownloaded(file)
            guard token == generation else { return }
            downloadFraction = nil
            let item = AVPlayerItem(url: localURL)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            watch(item)
            if item.status == .readyToPlay {
                shouldAutoplay = false
                player.play()
            } else if item.status == .failed {
                noteItemFailure(item)
            }
        } catch {
            guard token == generation else { return }
            guard !MediaFailure.isCancellation(error) else { return }
            downloadFraction = nil
            failPlayback("Couldn't download this file.", detail: MediaFailure.detail(error))
        }
    }

    private func watch(_ item: AVPlayerItem) {
        detachPlaybackObservers()
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let rawStatus = item.status.rawValue
            let detail = Self.playbackDetail(for: item)
            Task { @MainActor [weak self] in
                self?.handleItemStatus(rawStatus: rawStatus, detail: detail)
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let underlying = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            let detail = underlying.map { MediaFailure.detail($0) }
            MainActor.assumeIsolated {
                self?.failPlayback("Playback stopped before the end of the file.", detail: detail)
            }
        }
    }

    private func detachPlaybackObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

    private nonisolated static func playbackDetail(for item: AVPlayerItem) -> String? {
        var lines: [String] = []
        if let error = item.error {
            lines.append(MediaFailure.detail(error))
        }
        if let events = item.errorLog()?.events.suffix(3) {
            for event in events {
                if let comment = event.errorComment, !comment.isEmpty {
                    lines.append(comment)
                } else {
                    lines.append("Error \(event.errorStatusCode)")
                }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func handleItemStatus(rawStatus: Int, detail: String?) {
        if rawStatus == AVPlayerItem.Status.readyToPlay.rawValue {
            guard shouldAutoplay, let player else { return }
            shouldAutoplay = false
            player.play()
        } else if rawStatus == AVPlayerItem.Status.failed.rawValue {
            failPlayback("This file can't be played in Native Drive.", detail: detail)
        }
    }

    private func noteItemFailure(_ item: AVPlayerItem) {
        failPlayback("This file can't be played in Native Drive.", detail: Self.playbackDetail(for: item))
    }

    private func failPlayback(_ text: String, detail: String? = nil) {
        playbackFailed = true
        message = text
        self.detail = detail
        canRetry = true
        downloadFraction = nil
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
        shouldAutoplay = false
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func seek(by seconds: Double) {
        guard let player else { return }
        let current = CMTimeGetSeconds(player.currentTime())
        let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .zero)
        var target = current + seconds
        if target < 0 { target = 0 }
        if duration.isFinite && target > duration { target = duration }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func toggleFullScreen() {
        playerView?.window?.toggleFullScreen(nil)
    }

    private func ensureDownloaded(_ file: DriveFile) async throws -> URL {
        let destination = fileURL(for: file)
        if isComplete(file, at: destination) {
            touch(destination)
            return destination
        }
        if let existing = downloads[file.id] {
            return try await existing.value
        }
        let task: Task<URL, Error> = Task { @MainActor in
            let downloaded = try await self.downloadFile(file, to: destination)
            return downloaded
        }
        downloads[file.id] = task
        defer { downloads[file.id] = nil }
        let url: URL = try await task.value
        evictUnneededMedia()
        return url
    }

    private func downloadFile(_ file: DriveFile, to destination: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("partial")
        var attempt = 0
        while true {
            if FileManager.default.fileExists(atPath: partial.path) {
                try? FileManager.default.removeItem(at: partial)
            }
            do {
                let knownSize = file.size
                let fileID = file.id
                try await client.download(fileID: fileID, to: partial) { [weak self] bytes, total in
                    let fraction = MediaDownloadProgress.fraction(bytes: bytes, total: total, known: knownSize)
                    Task { @MainActor [weak self] in
                        guard let self, self.fileID == fileID else { return }
                        self.downloadFraction = fraction
                    }
                }
                guard isComplete(file, at: partial) else {
                    throw DriveAPIError.transport("The download ended before the whole file arrived.")
                }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: partial, to: destination)
                touch(destination)
                return destination
            } catch {
                if MediaFailure.isCancellation(error) || Task.isCancelled {
                    throw CancellationError()
                }
                guard MediaRetry.shouldRetry(error, attempt: attempt) else { throw error }
                let delay = MediaRetry.delayNanoseconds(attempt: attempt, retryAfter: MediaFailure.retryAfter(error))
                attempt += 1
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func fileURL(for file: DriveFile) -> URL {
        downloadRoot.appendingPathComponent(MediaCacheKey.relativePath(accountID: accountID, fileID: file.id, fileName: file.name))
    }

    private func isComplete(_ file: DriveFile, at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return false }
        if let expected = file.size { return size == expected }
        return true
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func evictUnneededMedia() {
        let root = downloadRoot.appendingPathComponent(AccountID.sanitize(accountID), isDirectory: true)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
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
                lastAccessed: newestDate(in: directory) ?? values?.contentModificationDate ?? .distantPast
            ))
        }
        let remove = MediaCacheEviction.keysToRemove(entries: entries, protectedKeys: protectedIDs())
        for key in remove {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
        }
    }

    private func protectedIDs() -> Set<String> {
        var ids: Set<String> = [AccountID.sanitize(current.id)]
        if let previous = MediaNavigator.neighborIndex(current: index, count: count, delta: -1) {
            ids.insert(AccountID.sanitize(playlist[previous].id))
        }
        if let next = MediaNavigator.neighborIndex(current: index, count: count, delta: 1) {
            ids.insert(AccountID.sanitize(playlist[next].id))
        }
        return ids
    }

    private func newestDate(in directory: URL) -> Date? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return children.compactMap { url in
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max()
    }

    private func byteCount(of directory: URL) -> Int64 {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else {
            return 0
        }
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
