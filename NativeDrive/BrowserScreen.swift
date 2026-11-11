import SwiftUI
import NativeDriveCore

struct BrowserScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: BrowserModel
    @ObservedObject var transfers: TransferCenter

    var body: some View {
        NavigationSplitView {
            SidebarView(browser: browser)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            FileBrowserView(browser: browser)
        }
        .navigationTitle(browser.title)
        .toolbar { toolbar }
        .searchable(text: searchText, placement: .toolbar, prompt: "Search in Drive")
        .inspector(isPresented: $transfers.isPresented) {
            TransfersView(center: transfers)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
        }
        .background {
            KeyMonitor { event in
                KeyRouting.handle(event, browser: browser)
            }
            .frame(width: 0, height: 0)
        }
        .alert("Something went wrong", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(browser.errorMessage ?? "")
        }
        .sheet(item: renameItem) { file in
            RenameSheet(name: file.name) {
                browser.renameTarget = nil
            } onSave: { name in
                let target = file
                browser.renameTarget = nil
                Task { await browser.rename(target, to: name) }
            }
        }
    }

    private var searchText: Binding<String> {
        Binding(get: { browser.searchText }, set: { browser.updateSearchText($0) })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { browser.errorMessage != nil }, set: { if !$0 { browser.errorMessage = nil } })
    }

    private var renameItem: Binding<DriveFile?> {
        Binding(get: { browser.renameTarget }, set: { browser.renameTarget = $0 })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!browser.canGoBack)
                .help("Back")
            Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!browser.canGoForward)
                .help("Forward")
            Button { browser.goUp() } label: { Image(systemName: "arrow.up") }
                .help("Enclosing Folder")
        }
        ToolbarItem(placement: .principal) {
            AccountMenu()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if browser.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
            Button { browser.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload")
            Button {
                transfers.isPresented.toggle()
            } label: {
                Image(systemName: transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .help("Transfers")
        }
    }
}

struct AccountMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.selectAccount(id: account.id)
                } label: {
                    if account.id == model.activeAccountID {
                        Label(account.email, systemImage: "checkmark")
                    } else {
                        Text(account.email)
                    }
                }
            }
            Divider()
            Button(model.isSigningIn ? "Waiting for Google…" : "Add Account…") {
                model.addAccount()
            }
            .disabled(!AppConfig.canSignIn || model.isSigningIn)
            Button("Sign Out") { model.pendingSignOut = true }
                .disabled(model.activeAccount == nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle")
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.activeAccount?.title ?? "No account")
                    if let email = model.activeAccount?.email {
                        Text(email).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var browser: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            AccountMenu()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            List(selection: selection) {
                Section("Drive") {
                    ForEach(DriveRoot.sidebarBuiltins, id: \.self) { root in
                        Label(root.title, systemImage: symbol(for: root))
                            .tag(root)
                    }
                }
                Section("Shared drives") {
                    if browser.sharedDrives.isEmpty {
                        Text("No shared drives")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(browser.sharedDrives) { drive in
                            Label(drive.name, systemImage: "externaldrive")
                                .tag(DriveRoot.sharedDrive(id: drive.id, name: drive.name))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var selection: Binding<DriveRoot?> {
        Binding(
            get: { browser.path.root },
            set: { root in
                guard let root else { return }
                browser.selectRoot(root)
            }
        )
    }

    private func symbol(for root: DriveRoot) -> String {
        switch root {
        case .myDrive: return "internaldrive"
        case .sharedWithMe: return "person.2"
        case .recent: return "clock"
        case .starred: return "star"
        case .trash: return "trash"
        case .sharedDrive: return "externaldrive"
        }
    }
}
