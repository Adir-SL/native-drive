import SwiftUI

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
    }
}

struct NativeDriveCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Account…") { model.addAccount() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!AppConfig.isConfigured || model.isSigningIn)
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
            Button("Copy Link") { model.browser?.copyLinkSelection() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.browser == nil)
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
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
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
