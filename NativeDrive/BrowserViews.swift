import AppKit
import AVFoundation
import AVKit
import SwiftUI
import NativeDriveCore

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case icon
    case list
    case column
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "as Icons"
        case .list: return "as List"
        case .column: return "as Columns"
        case .gallery: return "as Gallery"
        }
    }

    var name: String {
        switch self {
        case .icon: return "Icons"
        case .list: return "List"
        case .column: return "Columns"
        case .gallery: return "Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icon: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .column: return "rectangle.split.3x1"
        case .gallery: return "photo.on.rectangle"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .icon: return "1"
        case .list: return "2"
        case .column: return "3"
        case .gallery: return "4"
        }
    }
}

enum BrowserPreference {
    static let viewMode = "browser.viewMode"
    static let folderColors = "browser.folderColors"
    static let showPreview = "browser.showPreview"
    static let videoPreviews = "browser.videoPreviews"
    static let foldersFirst = "browser.foldersFirst"
    static let showPath = "browser.showPath"
    static let showStatus = "browser.showStatus"
    static let useGroups = "browser.useGroups"
    static let iconSize = "browser.iconSize"
    static let folderSorts = "browser.folderSorts"
}

final class FolderSortStore: ObservableObject {
    static let shared = FolderSortStore()

    @Published private var sorts: [String: FileSort] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: BrowserPreference.folderSorts),
           let decoded = try? JSONDecoder().decode([String: FileSort].self, from: data) {
            sorts = decoded
        }
    }

    func sort(for folderKey: String, foldersFirst: Bool) -> FileSort {
        var stored = sorts[folderKey] ?? FileSort()
        stored.foldersFirst = foldersFirst
        return stored
    }

    func update(_ sort: FileSort, for folderKey: String) {
        sorts[folderKey] = sort
        if let data = try? JSONEncoder().encode(sorts) {
            UserDefaults.standard.set(data, forKey: BrowserPreference.folderSorts)
        }
        objectWillChange.send()
    }
}

struct SettingsView: View {
    @AppStorage(BrowserPreference.viewMode) private var viewMode = BrowserViewMode.list.rawValue
    @AppStorage(BrowserPreference.folderColors) private var folderColors = true
    @AppStorage(BrowserPreference.showPreview) private var showPreview = true
    @AppStorage(BrowserPreference.videoPreviews) private var videoPreviews = true
    @AppStorage(BrowserPreference.foldersFirst) private var foldersFirst = true
    @AppStorage(BrowserPreference.showPath) private var showPath = true
    @AppStorage(BrowserPreference.showStatus) private var showStatus = true
    @AppStorage(BrowserPreference.useGroups) private var useGroups = false
    @AppStorage(BrowserPreference.iconSize) private var iconSize = 72.0

    var body: some View {
        Form {
            Picker("Default view", selection: $viewMode) {
                ForEach(BrowserViewMode.allCases) { mode in
                    Text(mode.name).tag(mode.rawValue)
                }
            }
            Slider(value: $iconSize, in: 48...160, step: 8) {
                Text("Icon size")
            }
            Toggle("Folder colors", isOn: $folderColors)
            Toggle("Show preview", isOn: $showPreview)
            Toggle("Video previews", isOn: $videoPreviews)
            Toggle("Show folders first", isOn: $foldersFirst)
            Toggle("Use groups", isOn: $useGroups)
            Toggle("Show path bar", isOn: $showPath)
            Toggle("Show status bar", isOn: $showStatus)
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 360)
    }
}

struct FinderToolbarViews: View {
    @Binding var mode: String

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(BrowserViewMode.allCases) { item in
                Image(systemName: item.symbol).tag(item.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .help("View")
    }
}

struct FileArrangementViews: View {
    @ObservedObject var browser: BrowserModel
    @ObservedObject private var sorts = FolderSortStore.shared
    @AppStorage(BrowserPreference.viewMode) private var viewMode = BrowserViewMode.list.rawValue
    @AppStorage(BrowserPreference.folderColors) private var folderColors = true
    @AppStorage(BrowserPreference.showPreview) private var showPreview = true
    @AppStorage(BrowserPreference.videoPreviews) private var videoPreviews = true
    @AppStorage(BrowserPreference.foldersFirst) private var foldersFirst = true
    @AppStorage(BrowserPreference.useGroups) private var useGroups = false
    @AppStorage(BrowserPreference.iconSize) private var iconSize = 72.0

    private var arrangement: FileSort {
        sorts.sort(for: browser.currentLocation.cacheKey, foldersFirst: foldersFirst)
    }

    private var arranged: [DriveFile] {
        arrangement.sorted(browser.files)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if browser.files.isEmpty && browser.isRefreshing {
                    skeleton
                } else if browser.files.isEmpty {
                    ContentUnavailableView(
                        browser.activeSearch == nil ? "Empty" : "No results",
                        systemImage: browser.activeSearch == nil ? "folder" : "magnifyingglass",
                        description: Text(browser.activeSearch == nil ? "This folder doesn't have any files." : "Try a different name or phrase.")
                    )
                } else {
                    switch BrowserViewMode(rawValue: viewMode) ?? .list {
                    case .icon:
                        iconGrid(size: iconSize)
                    case .list:
                        listView
                    case .column:
                        ColumnBrowser(browser: browser, showPreview: showPreview, videoPreviews: videoPreviews, folderColors: folderColors, foldersFirst: foldersFirst)
                    case .gallery:
                        iconGrid(size: min(iconSize * 1.6, 220))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsInspector, let file = browser.singleSelection() {
                Divider()
                PreviewPane(file: file, browser: browser, videoPreviews: videoPreviews)
                    .frame(width: 280)
            }
        }
        .transaction { $0.animation = nil }
    }

    private var showsInspector: Bool {
        showPreview && (BrowserViewMode(rawValue: viewMode) ?? .list) != .column
    }

    private var listView: some View {
        VStack(spacing: 0) {
            sortHeader
            Divider()
            List(selection: $browser.selection) {
                if useGroups {
                    ForEach(FileGrouping.sections(arranged, foldersFirst: foldersFirst), id: \.0.id) { section in
                        Section(section.0.title) {
                            ForEach(section.1) { file in
                                listRow(file).tag(file.id)
                            }
                        }
                    }
                } else {
                    ForEach(arranged) { file in
                        listRow(file).tag(file.id)
                    }
                }
            }
            .listStyle(.inset)
            .onChange(of: browser.selection) { _, _ in
                browser.prefetchSelection()
            }
        }
    }

    private var sortHeader: some View {
        HStack(spacing: 0) {
            sortButton(.name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton(.modified).frame(width: 160, alignment: .leading)
            sortButton(.size).frame(width: 80, alignment: .leading)
            sortButton(.kind).frame(width: 110, alignment: .leading)
            sortButton(.owner).frame(width: 140, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sortButton(_ key: FileSortKey) -> some View {
        Button {
            sorts.update(arrangement.toggled(key), for: browser.currentLocation.cacheKey)
        } label: {
            HStack(spacing: 4) {
                Text(key.title)
                if arrangement.key == key {
                    Image(systemName: arrangement.ascending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func listRow(_ file: DriveFile) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                FileGlyph(file: file, browser: browser, side: 18, folderColors: folderColors)
                if browser.renamingID == file.id {
                    InlineNameField(browser: browser)
                } else {
                    Text(file.name).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.modifiedTime?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            Text(file.size.map(ByteFormatting.string) ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(FileKind.label(mimeType: file.mimeType, fileName: file.name))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(file.ownerLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await browser.open(file) } }
        .onHover { browser.hover(file, inside: $0) }
        .contextMenu { FileContextMenu(browser: browser, file: file) }
        .onDrag { browser.dragProvider(for: file) }
        .dropDestination(for: URL.self) { urls, _ in
            guard file.isFolder, file.capabilities?.canAddChildren != false else { return false }
            browser.upload(urls: urls, parentID: file.id)
            return true
        }
        .onAppear { browser.loadMoreIfNeeded(currentID: file.id, isLastVisible: arranged.last?.id == file.id) }
    }

    private func iconGrid(size: Double) -> some View {
        ScrollView {
                if useGroups {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(FileGrouping.sections(arranged, foldersFirst: foldersFirst), id: \.0.id) { section in
                        Text(section.0.title).font(.headline).padding(.horizontal, 12)
                        grid(section.1, size: size)
                    }
                }
                .padding(.vertical, 12)
            } else {
                grid(arranged, size: size)
                    .padding(12)
            }
        }
        .onChange(of: browser.selection) { _, _ in
            browser.prefetchSelection()
        }
    }

    private func grid(_ files: [DriveFile], size: Double) -> some View {
        let columns = [GridItem(.adaptive(minimum: size + 28), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(files) { file in
                VStack(spacing: 6) {
                    FileGlyph(file: file, browser: browser, side: size, folderColors: folderColors)
                    Text(file.name)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .frame(width: size + 24)
                .padding(6)
                .background(browser.selection.contains(file.id) ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { browser.selection = [file.id] }
                .onTapGesture(count: 2) { Task { await browser.open(file) } }
                .contextMenu { FileContextMenu(browser: browser, file: file) }
                .onDrag { browser.dragProvider(for: file) }
                .onAppear { browser.loadMoreIfNeeded(currentID: file.id, isLastVisible: arranged.last?.id == file.id) }
                .help(file.name)
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 14)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ColumnBrowser: View {
    @ObservedObject var browser: BrowserModel
    var showPreview: Bool
    var videoPreviews: Bool
    var folderColors: Bool
    var foldersFirst: Bool
    @ObservedObject private var sorts = FolderSortStore.shared
    @State private var columns: [[DriveFile]] = []

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(locations.enumerated()), id: \.offset) { item in
                    column(index: item.offset, location: item.element)
                    Divider()
                }
                if showPreview, let file = browser.singleSelection() {
                    PreviewPane(file: file, browser: browser, videoPreviews: videoPreviews)
                        .frame(width: 280)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var locations: [DriveLocation] {
        var result = [BrowsePath(root: browser.path.root).location]
        for index in browser.path.folders.indices {
            result.append(BrowsePath(root: browser.path.root, folders: Array(browser.path.folders.prefix(index + 1))).location)
        }
        return result
    }

    private func column(index: Int, location: DriveLocation) -> some View {
        let files = index == locations.count - 1 ? browser.files : (index < columns.count ? columns[index] : [])
        let arranged = sorts.sort(for: location.cacheKey, foldersFirst: foldersFirst).sorted(files)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(arranged) { file in
                    HStack(spacing: 8) {
                        FileGlyph(file: file, browser: browser, side: 18, folderColors: folderColors)
                        Text(file.name).lineLimit(1)
                        Spacer(minLength: 0)
                        if file.isFolder {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected(file, column: index) ? Color.accentColor.opacity(0.25) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        if !file.isFolder { Task { await browser.open(file) } }
                    }
                    .onTapGesture { browser.openColumnFolder(file, columnIndex: index) }
                    .onAppear {
                        if index == locations.count - 1 {
                            browser.loadMoreIfNeeded(currentID: file.id, isLastVisible: arranged.last?.id == file.id)
                        }
                    }
                }
            }
        }
        .frame(width: 220)
        .task(id: location.cacheKey) {
            guard index != locations.count - 1 else { return }
            let loaded = await browser.listingForColumn(location)
            if columns.count <= index {
                columns.append(contentsOf: Array(repeating: [], count: index - columns.count + 1))
            }
            columns[index] = loaded
        }
    }

    private func isSelected(_ file: DriveFile, column: Int) -> Bool {
        if column < browser.path.folders.count {
            return browser.path.folders[column].id == file.id
        }
        return browser.selection.contains(file.id)
    }
}

struct PreviewPane: View {
    let file: DriveFile
    @ObservedObject var browser: BrowserModel
    var videoPreviews: Bool
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var duration: String?
    @State private var dimensions: String?

    private var kind: MediaKind { MediaClassifier.kind(of: file) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                Text(file.name).font(.headline).lineLimit(3)
                meta("Kind", FileKind.label(mimeType: file.mimeType, fileName: file.name))
                meta("Size", file.size.map(ByteFormatting.string) ?? "—")
                meta("Modified", file.modifiedTime?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                if let dimensions { meta("Dimensions", dimensions) }
                if let duration { meta("Duration", duration) }
            }
            .padding(12)
        }
        .background(.quaternary.opacity(0.35))
        .task(id: file.id) {
            player?.pause()
            player = nil
            duration = nil
            dimensions = nil
            async let details = browser.previewDetails(file)
            image = await browser.thumbnail(for: file, edge: 800)
            if let details = await details {
                if let width = details.pixelWidth, let height = details.pixelHeight {
                    dimensions = "\(width) × \(height)"
                }
                if let millis = details.durationMillis {
                    duration = Self.clock(Double(millis) / 1000)
                }
            }
            let playable = kind == .playableVideo || kind == .playableAudio
            guard videoPreviews, playable, let size = file.size, size <= 48 * 1024 * 1024 else { return }
            await loadPlayable()
        }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var preview: some View {
        if let player {
            VideoPlayer(player: player)
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            FileGlyph(file: file, browser: browser, side: 72, folderColors: true)
        }
    }

    private func meta(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func loadPlayable() async {
        do {
            let destination = try await browser.preparePreviewFile(file)
            guard !Task.isCancelled else { return }
            let asset = AVURLAsset(url: destination)
            if let time = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite {
                    duration = Self.clock(seconds)
                }
            }
            let next = AVPlayer(url: destination)
            player = next
            next.play()
        } catch {
            return
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct FileGlyph: View {
    let file: DriveFile
    @ObservedObject var browser: BrowserModel
    var side: CGFloat
    var folderColors: Bool
    @State private var image: NSImage?

    var body: some View {
        Group {
            if file.isFolder {
                Image(nsImage: FolderIconImage.make(hex: file.folderColorRgb, enabled: folderColors))
                    .resizable()
                    .scaledToFit()
            } else if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                FileTypeIcon(file: file)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side > 40 ? 6 : 2))
        .task(id: file.id) {
            guard !file.isFolder else { return }
            guard MediaClassifier.kind(of: file) == .image || side > 40 else { return }
            image = await browser.thumbnail(for: file, edge: max(Int(side * 2), ThumbnailPlan.rowEdge))
        }
    }
}

enum FolderIconImage {
    private static let cache = NSCache<NSString, NSImage>()

    static func make(hex: String?, enabled: Bool) -> NSImage {
        let base = NSWorkspace.shared.icon(for: .folder)
        guard enabled, let color = FolderColor.components(hex), let hex else { return base }
        if let cached = cache.object(forKey: hex as NSString) { return cached }
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        NSColor(calibratedRed: color.red, green: color.green, blue: color.blue, alpha: 0.45).set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        cache.setObject(tinted, forKey: hex as NSString)
        return tinted
    }
}

struct FileContextMenu: View {
    @ObservedObject var browser: BrowserModel
    let file: DriveFile

    var body: some View {
        Group {
            menu
        }
    }

    @ViewBuilder
    private var menu: some View {
        let targets = browser.targets(for: file)
        Button("Open") { Task { await browser.open(file) } }
        Button("Download…") {
            if targets.count == 1 { browser.selection = [file.id] }
            browser.downloadSelection()
        }
        .disabled(file.isGoogleNative && targets.count == 1)
        Divider()
        Button("Rename…") { browser.renameTarget = file }
            .disabled(targets.count != 1)
        Button(file.starred ? "Unstar" : "Star") { Task { await browser.toggleStar(file) } }
            .disabled(targets.count != 1)
        Button("Move to Trash") { Task { await browser.trash(targets) } }
        Button("Share…") { browser.share(file) }
        Button("Copy Link") { browser.copyLink(file) }
    }
}
