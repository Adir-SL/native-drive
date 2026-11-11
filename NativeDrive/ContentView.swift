import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !AppConfig.isConfigured {
                SetupView(showsClose: false)
            } else if let browser = model.browser {
                BrowserScreen(browser: browser, transfers: model.transfers)
                    .id(browser.accountID)
            } else {
                WelcomeView()
            }
        }
        .task { await model.startup() }
        .alert("Something went wrong", isPresented: authPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.authError ?? "")
        }
        .alert("Couldn't open Native Drive's folders", isPresented: startupPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.startupError ?? "")
        }
        .confirmationDialog(
            "Sign out of \(model.activeAccount?.email ?? "this account")?",
            isPresented: $model.pendingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await model.signOutActive() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account's tokens and cached files from this Mac. Files in Google Drive stay where they are.")
        }
        .sheet(isPresented: $model.showSetup) {
            SetupView(showsClose: true)
                .frame(width: 560, height: 460)
        }
    }

    private var authPresented: Binding<Bool> {
        Binding(get: { model.authError != nil }, set: { if !$0 { model.authError = nil } })
    }

    private var startupPresented: Binding<Bool> {
        Binding(get: { model.startupError != nil }, set: { if !$0 { model.startupError = nil } })
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Native Drive")
                .font(.largeTitle)
            Text("Add a Google account to browse My Drive, shared drives, and files shared with you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button(model.isSigningIn ? "Waiting for Google…" : "Add Account") {
                model.addAccount()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isSigningIn)
            if model.isSigningIn {
                Button("Cancel") { model.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    var showsClose: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Google Drive setup")
                .font(.title2)
            Text("Native Drive reads the OAuth client from Config.local.xcconfig at build time. The client ID is not stored in the repository.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("This build") {
                Text(AppConfig.configurationSummary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Copy Config.example.xcconfig to Config.local.xcconfig, paste the Desktop OAuth client, run xcodegen, and rebuild. The steps are in docs/GOOGLE_SETUP.md.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if showsClose {
                    Button("Close") { model.showSetup = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
