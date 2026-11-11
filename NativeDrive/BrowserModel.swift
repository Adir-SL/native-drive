import AppKit
import Combine
import Foundation
import NativeDriveCore
import UniformTypeIdentifiers

@MainActor
final class BrowserModel: ObservableObject {
    let accountID: String
    private let client: DriveClient
    private let cache: DriveCache
    private let transfers: TransferCenter
    private let downloadRoot: URL
    private let quickLook = QuickLookController()

    @Published private(set) var navigation: BrowserNavigation
    @Published private(set) var searchText = ""
    @Published private(set) var activeSearch: String?
    @Published private(set) var files: [DriveFile] = []
    @Published var selection = Set<String>()
    @Published private(set) var sharedDrives: [SharedDrive] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isOffline = false
    @Published var errorMessage: String?
    @Published var renameTarget: DriveFile?
    @Published private(set) var nextPageToken: String?
    @Published var mediaSession: MediaSession?

    private var searchTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var prefetchedKey: String?
    private var isLoadingMore = false
    private var suppressSearch = false
    private var pendingDrop: PendingDrop?
    private var dropTask: Task<Void, Never>?
    private var lastAction: (name: String, at: Date)?

    init(accountID: String, client: DriveClient, cache: DriveCache, transfers: TransferCenter, downloadRoot: URL) {
        self.accountID = accountID
        self.client = client
        self.cache = cache
        self.transfers = transfers
        self.downloadRoot = downloadRoot
        navigation = BrowserNavigation(path: BrowsePath(root: .myDrive))
    }

    var path: BrowsePath { navigation.path }
    var canGoBack: Bool { navigation.canGoBack }
    var canGoForward: Bool { navigation.canGoForward }

    var title: String {
        if activeSearch != nil { return "Search" }
        if let folder = path.folders.last { return folder.name }
        return path.root.title
    }

    var currentLocation: DriveLocation {
        if let activeSearch { return .search(query: activeSearch) }
        return path.location
    }

    func restore() async {
        sharedDrives = (try? await cache.drives(for: accountID)) ?? []
        await reload(forceFull: false)
        await refreshDrives()
    }

    func refresh() {
        Task { await reload(forceFull: true) }
    }

    func selectRoot(_ root: DriveRoot) {
        clearSearchSilently()
        navigation.selectRoot(root)
        Task { await reload(forceFull: false) }
    }

    func goBack() {
        guard navigation.canGoBack else { return }
        clearSearchSilently()
        navigation.goBack()
        Task { await reload(forceFull: false) }
    }

    func goForward() {
        guard navigation.canGoForward else { return }
        clearSearchSilently()
        navigation.goForward()
        Task { await reload(forceFull: false) }
    }

    func goUp() {
        guard navigation.goUp() else { return }
        clearSearchSilently()
        Task { await reload(forceFull: false) }
    }

    func jumpToCrumb(_ index: Int?) {
        clearSearchSilently()
        navigation.jumpToCrumb(index)
        Task { await reload(forceFull: false) }
    }

    func updateSearchText(_ text: String) {
        guard text != searchText else { return }
        searchText = text
        guard !suppressSearch else { return }
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.commitSearch(text)
        }
    }

    func openSelection() {
        guard let file = singleSelection() ?? selectedFiles().first else { return }
        coalesce("open") {
            Task { await self.open(file) }
        }
    }

    func quickLookSelection() {
        guard let file = singleSelection() ?? selectedFiles().first else { return }
        coalesce("quicklook") {
            Task { await self.quickLook(file) }
        }
    }

    func downloadSelection() {
        let chosen = selectedFiles()
        guard !chosen.isEmpty else { return }
        if chosen.count == 1, let file = chosen.first {
            saveOne(file)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Choose where to save the selected files."
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for file in chosen {
                    await self.download(file, to: directory.appendingPathComponent(FileName.sanitize(file.name)), reveal: true)
                }
            }
        }
    }

    func beginRename() {
        renameTarget = singleSelection()
    }

    func toggleStarSelection() {
        guard let file = singleSelection() else { return }
        Task { await toggleStar(file) }
    }

    func trashSelection() {
        let chosen = selectedFiles()
        guard !chosen.isEmpty else { return }
        Task { await trash(chosen) }
    }

    func copyLinkSelection() {
        guard let file = singleSelection() ?? selectedFiles().first else { return }
        copyLink(file)
    }

    func open(_ file: DriveFile) async {
        if file.isFolder || (file.isShortcut && file.shortcutDetails?.targetMimeType == DriveMime.folder) {
            let id = file.isShortcut ? (file.shortcutDetails?.targetId ?? file.id) : file.id
            navigateToFolder(id: id, name: file.name, driveID: file.driveId)
            return
        }
        if file.isGoogleNative || file.isShortcut {
            if let url = file.browserURL {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let kind = MediaClassifier.kind(of: file)
        switch kind {
        case .image:
            presentMedia(kind: .images, playlistKind: .image, file: file)
        case .playableVideo:
            presentMedia(kind: .player, playlistKind: .playableVideo, file: file)
        case .playableAudio:
            presentMedia(kind: .player, playlistKind: .playableAudio, file: file)
        case .unsupportedVideo:
            presentMedia(kind: .unsupported, playlistKind: .unsupportedVideo, file: file)
        case .other:
            do {
                let url = try await ensureLocalFile(file)
                NSWorkspace.shared.open(url)
            } catch is CancellationError {
                return
            } catch let error as DriveAPIError where error == .cancelled {
                return
            } catch {
                present(error)
            }
        }
    }

    func quickLook(_ file: DriveFile) async {
        if file.isFolder {
            await open(file)
            return
        }
        let kind = MediaClassifier.kind(of: file)
        if kind == .image || kind == .playableVideo || kind == .playableAudio || kind == .unsupportedVideo {
            if kind == .image, mediaSession?.fileID == file.id, mediaSession?.kind == .images {
                dismissMedia()
                return
            }
            await open(file)
            return
        }
        if file.isGoogleNative {
            if let url = file.browserURL { NSWorkspace.shared.open(url) }
            return
        }
        do {
            let url = try await ensureLocalFile(file)
            quickLook.show(url: url)
        } catch is CancellationError {
            return
        } catch let error as DriveAPIError where error == .cancelled {
            return
        } catch {
            present(error)
        }
    }

    func closeQuickLook() {
        quickLook.close()
        dismissMedia()
    }

    func dismissMedia() {
        mediaSession?.stop()
        mediaSession = nil
    }

    private func presentMedia(kind: MediaSession.Kind, playlistKind: MediaKind, file: DriveFile) {
        let playlist = MediaNavigator.playlist(in: files, kind: playlistKind)
        let items = playlist.isEmpty ? [file] : playlist
        mediaSession?.stop()
        let session = MediaSession(
            kind: kind,
            playlistKind: playlistKind,
            playlist: items,
            startingFileID: file.id,
            client: client,
            accountID: accountID,
            downloadRoot: downloadRoot
        )
        session.onDismiss = { [weak self, weak session] in
            guard let self, let session, self.mediaSession === session else { return }
            self.mediaSession = nil
        }
        mediaSession = session
        session.start()
    }

    func copyLink(_ file: DriveFile) {
        guard let url = file.browserURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func toggleStar(_ file: DriveFile) async {
        do {
            let updated = try await client.updateFile(id: file.id, name: nil, starred: !file.starred, trashed: nil)
            applyLocalUpdate(updated, removeFromCurrent: currentLocation == .starred && !updated.starred)
        } catch {
            present(error)
        }
    }

    func rename(_ file: DriveFile, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        do {
            let updated = try await client.updateFile(id: file.id, name: trimmed, starred: nil, trashed: nil)
            applyLocalUpdate(updated, removeFromCurrent: false)
        } catch {
            present(error)
        }
    }

    func trash(_ filesToTrash: [DriveFile]) async {
        for file in filesToTrash {
            do {
                let updated = try await client.updateFile(id: file.id, name: nil, starred: nil, trashed: true)
                files.removeAll { $0.id == file.id }
                selection.remove(file.id)
                try? await cache.removeFile(accountID: accountID, fileID: file.id, trashCopy: updated)
            } catch {
                present(error)
            }
        }
    }

    func upload(urls: [URL], parentID: String?) {
        guard let parentID else {
            errorMessage = "Open a folder in My Drive or a shared drive before uploading."
            return
        }
        let paths = urls.map(\.path).sorted()
        let targetsFolder = parentID != currentLocation.uploadParentID
        if var pending = pendingDrop, pending.paths == paths {
            if targetsFolder {
                pending.parentID = parentID
                pendingDrop = pending
            }
            return
        }
        pendingDrop = PendingDrop(paths: paths, urls: urls, parentID: parentID)
        dropTask?.cancel()
        dropTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let pending = self.pendingDrop else { return }
            self.pendingDrop = nil
            self.startUploads(urls: pending.urls, parentID: pending.parentID)
        }
    }

    private func startUploads(urls: [URL], parentID: String) {
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                errorMessage = "Drop files to upload. Folders from Finder aren't uploaded in this version."
                continue
            }
            let accessing = url.startAccessingSecurityScopedResource()
            Task { @MainActor in
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let uploaded = try await self.transfers.upload(
                        fileURL: url,
                        name: url.lastPathComponent,
                        mimeType: MimeType.guess(fileName: url.lastPathComponent),
                        parentID: parentID,
                        accountID: self.accountID,
                        client: self.client
                    )
                    self.insertUploaded(uploaded, parentID: parentID)
                } catch is CancellationError {
                    return
                } catch let error as DriveAPIError where error == .cancelled {
                    return
                } catch {
                    self.present(error)
                }
            }
        }
    }

    func dragProvider(for file: DriveFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = FileName.sanitize(file.name)
        if file.isFolder || file.isGoogleNative {
            let type = UTType(filenameExtension: "webloc")?.identifier ?? UTType.data.identifier
            let name = FileName.sanitize(file.name)
            let link = file.browserURL
            provider.suggestedName = name + ".webloc"
            provider.registerFileRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
                let url = Self.writeWebloc(name: name, link: link)
                completion(url, true, url == nil ? DriveAPIError.notFound : nil)
                return nil
            }
            return provider
        }
        let ext = URL(fileURLWithPath: file.name).pathExtension
        let type = UTType(filenameExtension: ext)?.identifier ?? UTType.data.identifier
        provider.registerFileRepresentation(forTypeIdentifier: type, visibility: .all) { [weak self] completion in
            let progress = Progress(totalUnitCount: max(file.size ?? 1, 1))
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, DriveAPIError.cancelled)
                    return
                }
                do {
                    let url = try await self.ensureLocalFile(file)
                    progress.completedUnitCount = progress.totalUnitCount
                    completion(url, true, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return progress
        }
        return provider
    }

    func selectedFiles() -> [DriveFile] {
        files.filter { selection.contains($0.id) }
    }

    func singleSelection() -> DriveFile? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return files.first { $0.id == id }
    }

    func targets(for file: DriveFile) -> [DriveFile] {
        if selection.contains(file.id), selection.count > 1 {
            return selectedFiles()
        }
        return [file]
    }

    func loadMoreIfNeeded(currentID: String) {
        guard files.last?.id == currentID else { return }
        Task { await loadMore() }
    }

    private func reload(forceFull: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let location = currentLocation
        prefetchedKey = nil
        if let cached = try? await cache.listing(accountID: accountID, key: location.cacheKey) {
            guard generation == loadGeneration else { return }
            apply(cached)
        }
        isRefreshing = true
        defer { if generation == loadGeneration { isRefreshing = false } }

        do {
            let cachedListing = try await cache.listing(accountID: accountID, key: location.cacheKey)
            let token = try await cache.startPageToken(for: accountID)
            let plan = RevalidatePlanner.plan(
                forceFull: forceFull,
                hasCachedListing: cachedListing != nil,
                startToken: token,
                location: location
            )
            if case .incremental(let start) = plan {
                do {
                    let collected = try await client.collectChanges(from: start)
                    guard generation == loadGeneration else { return }
                    _ = try await cache.applyChanges(accountID: accountID, changes: collected.changes)
                    try await cache.setStartPageToken(for: accountID, token: collected.nextStartToken)
                    if let updated = try await cache.listing(accountID: accountID, key: location.cacheKey) {
                        apply(updated)
                    }
                    isOffline = false
                    await prefetchIfNeeded(generation: generation)
                    return
                } catch let error as DriveAPIError where error == .gone {
                    try? await cache.clearListings(accountID: accountID)
                    try? await cache.setStartPageToken(for: accountID, token: nil)
                }
            }

            if try await cache.startPageToken(for: accountID) == nil {
                if let start = try? await client.startPageToken() {
                    try? await cache.setStartPageToken(for: accountID, token: start)
                }
            }
            let page = try await client.listFiles(location: location, pageToken: nil)
            guard generation == loadGeneration else { return }
            let sorted = ListingSorter.sort(page.files, key: location.cacheKey)
            let listing = CachedListing(key: location.cacheKey, files: sorted, nextPageToken: page.nextPageToken, fetchedAt: Date())
            try await cache.saveListing(accountID: accountID, listing: listing)
            apply(listing)
            isOffline = false
            await prefetchIfNeeded(generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            if !files.isEmpty, DriveAPIError.isOffline(error) {
                isOffline = true
            } else if DriveAPIError.isOffline(error) {
                isOffline = true
                errorMessage = "You're offline, and this folder hasn't been saved on this Mac yet."
            } else {
                present(error)
            }
        }
    }

    private func prefetchIfNeeded(generation: Int) async {
        let key = currentLocation.cacheKey
        guard prefetchedKey != key else { return }
        prefetchedKey = key
        guard nextPageToken != nil else { return }
        await loadMore(generation: generation)
    }

    private func loadMore() async {
        await loadMore(generation: loadGeneration)
    }

    private func loadMore(generation: Int) async {
        guard !isLoadingMore, let token = nextPageToken else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let location = currentLocation
        do {
            let page = try await client.listFiles(location: location, pageToken: token)
            guard generation == loadGeneration else { return }
            let merged = ListingSorter.sort(PageMerger.merge(existing: files, page: page.files), key: location.cacheKey)
            let listing = CachedListing(key: location.cacheKey, files: merged, nextPageToken: page.nextPageToken, fetchedAt: Date())
            try await cache.saveListing(accountID: accountID, listing: listing)
            apply(listing)
            isOffline = false
        } catch {
            guard generation == loadGeneration else { return }
            if DriveAPIError.isOffline(error) {
                isOffline = true
            } else {
                present(error)
            }
        }
    }

    private func refreshDrives() async {
        do {
            let drives = try await client.listDrives()
            try? await cache.saveDrives(drives, accountID: accountID)
            sharedDrives = drives
        } catch {
            if DriveAPIError.isOffline(error) { isOffline = true }
        }
    }

    private func navigateToFolder(id: String, name: String, driveID: String?) {
        clearSearchSilently()
        if let driveID, path.root.sharedDriveID != driveID {
            let driveName = sharedDrives.first(where: { $0.id == driveID })?.name ?? "Shared drive"
            navigation.replace(path: BrowsePath(root: .sharedDrive(id: driveID, name: driveName), folders: [PathFolder(id: id, name: name)]))
        } else {
            navigation.openFolder(id: id, name: name)
        }
        Task { await reload(forceFull: false) }
    }

    private func ensureLocalFile(_ file: DriveFile) async throws -> URL {
        let url = localURL(for: file)
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if size > 0, file.size == nil || file.size == size {
                return url
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await transfers.download(file: file, accountID: accountID, destination: url, client: client)
        return url
    }

    private func download(_ file: DriveFile, to destination: URL, reveal: Bool) async {
        if file.isGoogleNative {
            if let url = file.browserURL { NSWorkspace.shared.open(url) }
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await transfers.download(file: file, accountID: accountID, destination: destination, client: client)
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch is CancellationError {
            return
        } catch let error as DriveAPIError where error == .cancelled {
            return
        } catch {
            present(error)
        }
    }

    private func saveOne(_ file: DriveFile) {
        if file.isGoogleNative {
            if let url = file.browserURL { NSWorkspace.shared.open(url) }
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileName.sanitize(file.name)
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.download(file, to: url, reveal: true)
            }
        }
    }

    private func apply(_ listing: CachedListing) {
        files = listing.files
        nextPageToken = listing.nextPageToken
        selection = selection.filter { id in files.contains { $0.id == id } }
        if let mediaSession {
            mediaSession.replacePlaylist(files)
        }
    }

    private func applyLocalUpdate(_ file: DriveFile, removeFromCurrent: Bool) {
        if removeFromCurrent {
            files.removeAll { $0.id == file.id }
            selection.remove(file.id)
        } else if let index = files.firstIndex(where: { $0.id == file.id }) {
            files[index] = file
            files = ListingSorter.sort(files, key: currentLocation.cacheKey)
        }
        Task {
            guard var listing = try? await cache.listing(accountID: accountID, key: currentLocation.cacheKey) else { return }
            if removeFromCurrent {
                listing.files.removeAll { $0.id == file.id }
            } else if let index = listing.files.firstIndex(where: { $0.id == file.id }) {
                listing.files[index] = file
                listing.files = ListingSorter.sort(listing.files, key: listing.key)
            }
            try? await cache.saveListing(accountID: accountID, listing: listing)
        }
    }

    private func insertUploaded(_ file: DriveFile, parentID: String) {
        guard currentLocation.uploadParentID == parentID else { return }
        guard !files.contains(where: { $0.id == file.id }) else { return }
        files.append(file)
        files = ListingSorter.sort(files, key: currentLocation.cacheKey)
        Task {
            var listing = (try? await cache.listing(accountID: accountID, key: currentLocation.cacheKey))
                ?? CachedListing(key: currentLocation.cacheKey, files: [], nextPageToken: nil, fetchedAt: Date())
            if !listing.files.contains(where: { $0.id == file.id }) {
                listing.files.append(file)
                listing.files = ListingSorter.sort(listing.files, key: listing.key)
                listing.fetchedAt = Date()
                try? await cache.saveListing(accountID: accountID, listing: listing)
            }
        }
    }

    private func commitSearch(_ text: String) async {
        activeSearch = SearchQuery.normalized(text)
        await reload(forceFull: true)
    }

    private func clearSearchSilently() {
        suppressSearch = true
        searchText = ""
        activeSearch = nil
        suppressSearch = false
        searchTask?.cancel()
    }

    private func localURL(for file: DriveFile) -> URL {
        downloadRoot
            .appendingPathComponent(AccountID.sanitize(accountID), isDirectory: true)
            .appendingPathComponent(file.id, isDirectory: true)
            .appendingPathComponent(FileName.sanitize(file.name))
    }

    private nonisolated static func writeWebloc(name: String, link: URL?) -> URL? {
        guard let link else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDrive-links", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".webloc")
        let escaped = link.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>URL</key><string>\(escaped)</string></dict></plist>
        """
        do {
            try plist.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func present(_ error: Error) {
        if DriveAPIError.isOffline(error) {
            isOffline = true
            return
        }
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private struct PendingDrop {
        var paths: [String]
        var urls: [URL]
        var parentID: String
    }

    private func coalesce(_ name: String, _ body: () -> Void) {
        if let lastAction, lastAction.name == name, Date().timeIntervalSince(lastAction.at) < 0.3 {
            return
        }
        lastAction = (name, Date())
        body()
    }
}
