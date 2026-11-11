import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if !AppConfig.canSignIn {
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
            Button(model.isSigningIn ? "Waiting for Google…" : "Sign in with Google") {
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
            setupMessage
            GroupBox("This build") {
                Text(AppConfig.configurationSummary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if AppConfig.canSignIn {
                Button(model.isSigningIn ? "Waiting for Google…" : "Sign in with Google") {
                    model.addAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSigningIn)
            }
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

    @ViewBuilder
    private var setupMessage: some View {
        if AppConfig.needsClientSecret {
            Text("Add GOOGLE_CLIENT_SECRET to Config.local.xcconfig (copy from Config.example.xcconfig) and rebuild.")
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            Text("The Desktop client ID is already in this build. Google requires the client secret for the token exchange, and that secret stays on your Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !AppConfig.isConfigured {
            Text("This build has no Google OAuth client ID. Set GOOGLE_CLIENT_ID in Config.xcconfig or Config.local.xcconfig and rebuild.")
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("This build can sign in with the Google OAuth client baked in at build time.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
