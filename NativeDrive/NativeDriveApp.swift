import SwiftUI
import NativeDriveCore

@main
struct NativeDriveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            NativeDriveCommands(model: model)
        }
        Settings {
            SettingsView()
        }
    }
}

struct NativeDriveCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage(BrowserPreference.viewMode) private var viewMode = BrowserViewMode.list.rawValue
    @AppStorage(BrowserPreference.folderColors) private var folderColors = true
    @AppStorage(BrowserPreference.showPreview) private var showPreview = true
    @AppStorage(BrowserPreference.videoPreviews) private var videoPreviews = true
    @AppStorage(BrowserPreference.foldersFirst) private var foldersFirst = true
    @AppStorage(BrowserPreference.showPath) private var showPath = true
    @AppStorage(BrowserPreference.showStatus) private var showStatus = true
    @AppStorage(BrowserPreference.useGroups) private var useGroups = false
    @AppStorage(BrowserPreference.showSharedBadges) private var showSharedBadges = true
    @ObservedObject private var sorts = FolderSortStore.shared

    private var folderKey: String { model.browser?.currentLocation.cacheKey ?? "myDrive" }
    private var currentSort: FileSort { sorts.sort(for: folderKey, foldersFirst: foldersFirst) }

    @ViewBuilder
    private var viewModeButtons: some View {
        ForEach(BrowserViewMode.allCases) { mode in
            Toggle(mode.title, isOn: Binding(
                get: { viewMode == mode.rawValue },
                set: { if $0 { viewMode = mode.rawValue } }
            ))
            .keyboardShortcut(mode.shortcut, modifiers: .command)
        }
    }

    private func setSort(_ key: FileSortKey) {
        sorts.update(currentSort.toggled(key), for: folderKey)
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Account…") { model.addAccount() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!AppConfig.canSignIn || model.isSigningIn)
        }
        CommandMenu("File") {
            Button("Open") { model.browser?.openSelection() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.browser == nil)
            Button("Quick Look") { model.browser?.quickLookSelection() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.browser == nil)
            Button("Download…") { model.browser?.downloadSelection() }
                .disabled(model.browser == nil)
            Button("Rename…") { model.browser?.beginRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.browser?.singleSelection() == nil)
            Button("Star") { model.browser?.toggleStarSelection() }
                .disabled(model.browser?.singleSelection() == nil)
            Button("Move to Trash") { model.browser?.trashSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.browser == nil)
            Button("Share…") { model.browser?.shareSelection() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.browser?.selectedFiles().isEmpty != false)
            Button("Copy Link") { model.browser?.copyLinkSelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.browser == nil)
        }
        CommandMenu("View") {
            viewModeButtons
            Divider()
            Toggle("Show Path Bar", isOn: $showPath)
            Toggle("Show Status Bar", isOn: $showStatus)
            Toggle("Show Preview", isOn: $showPreview)
            Toggle("Video Previews", isOn: $videoPreviews)
            Toggle("Folder Colors", isOn: $folderColors)
            Toggle("Show Folders First", isOn: $foldersFirst)
            Toggle("Use Groups", isOn: $useGroups)
            Toggle("Show Shared Badges", isOn: $showSharedBadges)
            Divider()
            Menu("Sort By") {
                ForEach(FileSortKey.allCases) { key in
                    Button {
                        setSort(key)
                    } label: {
                        if currentSort.key == key {
                            Label(key.title, systemImage: currentSort.ascending ? "chevron.up" : "chevron.down")
                        } else {
                            Text(key.title)
                        }
                    }
                }
            }
        }
        CommandMenu("Go") {
            Button("Back") { model.browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.browser?.canGoBack != true)
            Button("Forward") { model.browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.browser?.canGoForward != true)
            Button("Enclosing Folder") { model.browser?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.browser == nil)
            Divider()
            Button("Reload") { model.browser?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.browser == nil)
        }
        CommandMenu("Account") {
            ForEach(Array(model.accounts.prefix(9).enumerated()), id: \.element.id) { index, account in
                Button(account.email) { model.selectAccount(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
            if !model.accounts.isEmpty {
                Divider()
            }
            Button("Sign Out") { model.pendingSignOut = true }
                .disabled(model.activeAccountID == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Google Drive Setup…") { model.showSetup = true }
        }
    }
}
