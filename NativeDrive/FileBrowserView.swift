import AppKit
import SwiftUI
import NativeDriveCore
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @ObservedObject var browser: BrowserModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if browser.isOffline {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                    Text("Can't reach Google Drive. Showing saved files for this account.")
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary)
            }
            breadcrumb
            Divider()
            table
        }
        .contextMenu {
            if browser.creationDeniedReason == nil {
                NewItemMenu(browser: browser)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            browser.upload(urls: urls, parentID: browser.currentLocation.uploadParentID)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumbButton(browser.path.root.title, isCurrent: browser.path.folders.isEmpty && browser.activeSearch == nil) {
                    browser.jumpToCrumb(nil)
                }
                ForEach(Array(browser.path.folders.enumerated()), id: \.offset) { index, folder in
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    crumbButton(folder.name, isCurrent: index == browser.path.folders.count - 1 && browser.activeSearch == nil) {
                        browser.jumpToCrumb(index)
                    }
                }
                if let query = browser.activeSearch {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Search: \(query)")
                        .fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func crumbButton(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(isCurrent ? .semibold : .regular)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var table: some View {
        if browser.files.isEmpty && browser.isRefreshing {
            skeleton
        } else if browser.files.isEmpty {
            ContentUnavailableView(
                browser.activeSearch == nil ? "Empty" : "No results",
                systemImage: browser.activeSearch == nil ? "folder" : "magnifyingglass",
                description: Text(browser.activeSearch == nil ? "This folder doesn't have any files." : "Try a different name or phrase.")
            )
        } else {
            Table(browser.files, selection: $browser.selection) {
                TableColumn("Name") { file in
                    HStack(spacing: 8) {
                        RowThumbnail(file: file, browser: browser)
                        if browser.renamingID == file.id {
                            InlineNameField(browser: browser)
                        } else {
                            Text(file.name)
                                .lineLimit(1)
                        }
                    }
                    .onTapGesture(count: 2) { Task { await browser.open(file) } }
                    .onHover { browser.hover(file, inside: $0) }
                    .contextMenu { contextMenu(for: file) }
                    .onDrag { browser.dragProvider(for: file) }
                    .dropDestination(for: URL.self) { urls, _ in
                        guard file.isFolder, file.capabilities?.canAddChildren != false else { return false }
                        browser.upload(urls: urls, parentID: file.id)
                        return true
                    }
                    .onAppear { browser.loadMoreIfNeeded(currentID: file.id) }
                }
                .width(min: 240, ideal: 420)

                TableColumn("Date Modified") { file in
                    Text(file.modifiedTime?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        .foregroundStyle(.secondary)
                        .contextMenu { contextMenu(for: file) }
                        .onTapGesture(count: 2) { Task { await browser.open(file) } }
                }
                .width(min: 140, ideal: 180)

                TableColumn("Size") { file in
                    Text(file.size.map(ByteFormatting.string) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contextMenu { contextMenu(for: file) }
                        .onTapGesture(count: 2) { Task { await browser.open(file) } }
                }
                .width(min: 70, ideal: 90)

                TableColumn("Owner") { file in
                    Text(file.ownerLabel)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .contextMenu { contextMenu(for: file) }
                        .onTapGesture(count: 2) { Task { await browser.open(file) } }
                }
                .width(min: 120, ideal: 180)
            }
            .transaction { $0.animation = nil }
            .onChange(of: browser.selection) { _, _ in
                browser.prefetchSelection()
            }
        }
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<8, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 14)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func contextMenu(for file: DriveFile) -> some View {
        let targets = browser.targets(for: file)
        Button("Open") { Task { await browser.open(file) } }
        Button("Download…") {
            if targets.count == 1 {
                browser.selection = [file.id]
            }
            browser.downloadSelection()
        }
        .disabled(file.isGoogleNative && targets.count == 1)
        Divider()
        Button("Rename…") { browser.renameTarget = file }
            .disabled(targets.count != 1)
        Button(file.starred ? "Unstar" : "Star") { Task { await browser.toggleStar(file) } }
            .disabled(targets.count != 1)
        Button("Move to Trash") { Task { await browser.trash(targets) } }
        Button("Copy Link") { browser.copyLink(file) }
    }
}

private struct RowThumbnail: View {
    let file: DriveFile
    @ObservedObject var browser: BrowserModel
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image, MediaClassifier.kind(of: file) == .image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                FileTypeIcon(file: file)
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .task(id: file.id) {
            guard MediaClassifier.kind(of: file) == .image else { return }
            image = await browser.thumbnail(for: file, edge: ThumbnailPlan.rowEdge)
        }
    }
}

struct NewItemMenu: View {
    @ObservedObject var browser: BrowserModel

    var body: some View {
        Button("New Folder") { browser.makeNew(.folder) }
        Divider()
        Button("Google Docs") { browser.makeNew(.document) }
        Button("Google Sheets") { browser.makeNew(.spreadsheet) }
        Button("Google Slides") { browser.makeNew(.presentation) }
        Button("Google Forms") { browser.makeNew(.form) }
        Button("Google Drawings") { browser.makeNew(.drawing) }
        Divider()
        Button("File upload…") { browser.chooseFilesToUpload() }
        Button("Folder upload…") { browser.chooseFoldersToUpload() }
    }
}

private struct InlineNameField: View {
    @ObservedObject var browser: BrowserModel
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: Binding(
            get: { browser.renameDraft },
            set: { browser.renameDraft = $0 }
        ))
        .focused($focused)
        .onSubmit { browser.commitInlineRename() }
        .onExitCommand { browser.cancelInlineRename() }
        .onAppear { focused = true }
    }
}

struct FileTypeIcon: View {
    let file: DriveFile

    var body: some View {
        image
            .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private var image: some View {
        if file.isFolder {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .scaledToFit()
        } else if let symbol = Self.symbol(for: file.mimeType) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        } else {
            Image(nsImage: workspaceIcon)
                .resizable()
                .scaledToFit()
        }
    }

    private var workspaceIcon: NSImage {
        let ext = URL(fileURLWithPath: file.name).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return NSWorkspace.shared.icon(for: .data)
        }
        return NSWorkspace.shared.icon(for: type)
    }

    private static func symbol(for mimeType: String) -> String? {
        switch mimeType {
        case DriveMime.document: return "doc.richtext"
        case DriveMime.spreadsheet: return "tablecells"
        case DriveMime.presentation: return "play.rectangle"
        case DriveMime.drawing: return "paintbrush.pointed"
        case DriveMime.form: return "list.clipboard"
        case DriveMime.shortcut: return "arrowshape.turn.up.right"
        default: return nil
        }
    }
}

enum ByteFormatting {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct RenameSheet: View {
    @State var name: String
    var onCancel: () -> Void
    var onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $name)
                .onSubmit { onSave(name) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { onSave(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct TransfersView: View {
    @ObservedObject var center: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers")
                    .font(.headline)
                Spacer()
                Button("Clear") { center.clearFinished() }
                    .disabled(center.items.allSatisfy { item in
                        switch item.phase {
                        case .queued, .running: return true
                        case .completed, .failed, .cancelled: return false
                        }
                    })
            }
            .padding(12)
            Divider()
            if center.items.isEmpty {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down", description: Text("Downloads and uploads show up here."))
            } else {
                List(center.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: item.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            if item.phase == .running || item.phase == .queued {
                                Button("Cancel") { center.cancel(item.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        progress(for: item)
                        Text(status(for: item))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func progress(for item: TransferCenter.Item) -> some View {
        switch item.phase {
        case .running, .queued:
            if let fraction = item.fraction {
                ProgressView(value: fraction)
            } else if item.phase == .running {
                ProgressView()
            }
        case .completed:
            ProgressView(value: 1)
        case .failed, .cancelled:
            EmptyView()
        }
    }

    private func status(for item: TransferCenter.Item) -> String {
        switch item.phase {
        case .queued: return "Waiting"
        case .running:
            if let total = item.totalBytes {
                return "\(ByteFormatting.string(item.completedBytes)) of \(ByteFormatting.string(total))"
            }
            return ByteFormatting.string(item.completedBytes)
        case .completed: return "Finished"
        case .cancelled: return "Cancelled"
        case .failed(let message): return message
        }
    }
}
