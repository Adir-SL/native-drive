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
    private let transfers: TransferCenter
    private let accountID: String
    private let downloadRoot: URL
    private var playlist: [DriveFile]
    private var generation = 0
    private var loader: DriveMediaLoader?
    private var statusObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?

    @Published private(set) var index: Int
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var fullImage: NSImage?
    @Published private(set) var message: String?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playbackFailed = false
    weak var playerView: AVPlayerView?

    var onDismiss: (@MainActor () -> Void)?

    init(
        kind: Kind,
        playlistKind: MediaKind,
        playlist: [DriveFile],
        startingFileID: String,
        client: DriveClient,
        transfers: TransferCenter,
        accountID: String,
        downloadRoot: URL
    ) {
        self.kind = kind
        self.playlistKind = playlistKind
        self.playlist = playlist.isEmpty ? [] : playlist
        self.client = client
        self.transfers = transfers
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
        statusObserver?.invalidate()
        statusObserver = nil
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
        loader = nil
    }

    func dismiss() {
        stop()
        onDismiss?()
    }

    func step(_ delta: Int) {
        guard kind == .images, let next = MediaNavigator.neighborIndex(current: index, count: count, delta: delta) else { return }
        index = next
        showCurrentImage()
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
                let url = try await self.ensureDownloaded(file, reveal: true)
                NSWorkspace.shared.open(url)
            } catch is CancellationError {
                return
            } catch let error as DriveAPIError where error == .cancelled {
                return
            } catch {
                self.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func showCurrentImage() {
        generation += 1
        let token = generation
        let file = current
        fullImage = nil
        message = nil
        thumbnail = cachedThumbnail(for: file)
        let destination = fileURL(for: file)
        if isComplete(file, at: destination) {
            touch(destination)
            Task { @MainActor [weak self] in
                await self?.applyFullImage(at: destination, file: file, generation: token)
            }
        } else {
            Task { @MainActor [weak self] in
                await self?.downloadFullImage(file, generation: token)
            }
        }
        if thumbnail == nil {
            Task { @MainActor [weak self] in
                await self?.downloadThumbnail(file, generation: token)
            }
        }
        prefetchNeighbors()
    }

    private func downloadThumbnail(_ file: DriveFile, generation: Int) async {
        guard let link = file.thumbnailLink else { return }
        let remoteString = DriveThumbnailURL.enlarged(link)
        guard let remote = URL(string: remoteString) else { return }
        let destination = thumbnailURL(for: file)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try await client.downloadAuthenticated(from: remote, to: destination) { _, _ in }
            } catch {
                let request = URLRequest(url: remote)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                try data.write(to: destination, options: .atomic)
            }
            guard generation == self.generation, fullImage == nil else { return }
            thumbnail = NSImage(contentsOf: destination)
        } catch {
            return
        }
    }

    private func downloadFullImage(_ file: DriveFile, generation: Int) async {
        let destination = fileURL(for: file)
        do {
            _ = try await ensureDownloaded(file, reveal: false)
            guard generation == self.generation else { return }
            await applyFullImage(at: destination, file: file, generation: generation)
            evictUnneededMedia()
        } catch is CancellationError {
            return
        } catch let error as DriveAPIError where error == .cancelled {
            return
        } catch {
            guard generation == self.generation else { return }
            if fullImage == nil && thumbnail == nil {
                message = "Couldn't download this image."
            }
        }
    }

    private func applyFullImage(at url: URL, file: DriveFile, generation: Int) async {
        let animated = file.mimeType.lowercased().contains("gif") || file.name.lowercased().hasSuffix(".gif")
        if animated, let image = NSImage(contentsOf: url), image.size.width > 0 {
            guard generation == self.generation else { return }
            fullImage = image
            message = nil
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
            return
        }
        if let fallback = NSImage(contentsOf: url), fallback.size.width > 0 {
            fullImage = fallback
            message = nil
            return
        }
        message = thumbnail == nil
            ? "Couldn't decode this image."
            : "Couldn't decode this image. Showing Google's preview instead."
    }

    private func prefetchNeighbors() {
        for delta in [-1, 1] {
            guard let next = MediaNavigator.neighborIndex(current: index, count: count, delta: delta) else { continue }
            let file = playlist[next]
            let destination = fileURL(for: file)
            guard !isComplete(file, at: destination) else { continue }
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = try? await self.ensureDownloaded(file, reveal: false)
            }
        }
    }

    private func startPlayer() async {
        let file = current
        playbackFailed = false
        message = nil
        do {
            let remote = try client.mediaURL(fileID: file.id)
            let mediaLoader = DriveMediaLoader(
                remoteURL: remote,
                mimeType: file.mimeType,
                fileName: file.name,
                totalBytes: file.size,
                tokenProvider: { [client] forceRefresh in
                    try await client.accessToken(forceRefresh: forceRefresh)
                }
            )
            guard let playbackURL = mediaLoader.playbackURL(fileID: file.id) else {
                failPlayback("Couldn't open this file.")
                return
            }
            loader = mediaLoader
            let asset = AVURLAsset(url: playbackURL)
            asset.resourceLoader.setDelegate(mediaLoader, queue: mediaLoader.queue)
            let item = AVPlayerItem(asset: asset)
            watch(item)
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
        } catch {
            failPlayback((error as? LocalizedError)?.errorDescription ?? "Couldn't open this file.")
        }
    }

    private func watch(_ item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                self?.failPlayback("This file can't be played in Native Drive.")
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failPlayback("Playback stopped before the end of the file.")
            }
        }
    }

    private func failPlayback(_ text: String) {
        playbackFailed = true
        message = text
        player?.pause()
        player = nil
    }

    private func togglePlayback() {
        guard let player else { return }
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

    private func ensureDownloaded(_ file: DriveFile, reveal: Bool) async throws -> URL {
        let destination = fileURL(for: file)
        if isComplete(file, at: destination) {
            touch(destination)
            return destination
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await transfers.download(file: file, accountID: accountID, destination: destination, client: client, reveal: reveal)
        touch(destination)
        evictUnneededMedia()
        return destination
    }

    private func cachedThumbnail(for file: DriveFile) -> NSImage? {
        let url = thumbnailURL(for: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    private func fileURL(for file: DriveFile) -> URL {
        downloadRoot.appendingPathComponent(MediaCacheKey.relativePath(accountID: accountID, fileID: file.id, fileName: file.name))
    }

    private func thumbnailURL(for file: DriveFile) -> URL {
        fileURL(for: file).deletingLastPathComponent().appendingPathComponent("thumbnail")
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
                lastAccessed: values?.contentModificationDate ?? .distantPast
            ))
        }
        let remove = MediaCacheEviction.keysToRemove(entries: entries, protectedKeys: protectedIDs())
        for key in remove {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(key, isDirectory: true))
        }
    }

    private func protectedIDs() -> Set<String> {
        var ids: Set<String> = [current.id]
        if let previous = MediaNavigator.neighborIndex(current: index, count: count, delta: -1) {
            ids.insert(playlist[previous].id)
        }
        if let next = MediaNavigator.neighborIndex(current: index, count: count, delta: 1) {
            ids.insert(playlist[next].id)
        }
        return ids
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
