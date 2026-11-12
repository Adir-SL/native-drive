import Combine
import Foundation
import NativeDriveCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var accounts: [DriveAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published private(set) var isSigningIn = false
    @Published var authError: String?
    @Published var startupError: String?
    @Published var showSetup = false
    @Published var pendingSignOut = false

    let transfers = TransferCenter()

    private let accountStore: AccountStore
    private let cache: DriveCache
    private let tokenStore: KeychainTokenStore
    private let http = URLSessionHTTPClient()
    private let downloadRoot: URL
    private var browsers: [String: BrowserModel] = [:]
    private var signInTask: Task<Void, Never>?
    private let oauth = OAuthCoordinator()
    private var didStart = false

    init() {
        let paths = Self.makePaths()
        accountStore = paths.accounts
        cache = paths.cache
        downloadRoot = paths.downloads
        tokenStore = KeychainTokenStore()
        startupError = paths.error
    }

    private struct Stores {
        var accounts: AccountStore
        var cache: DriveCache
        var downloads: URL
        var error: String?
    }

    private static func makePaths() -> Stores {
        do {
            let support = try AppPaths.supportDirectory()
            let downloads = try AppPaths.downloadCacheDirectory()
            let accounts = try AccountStore(fileURL: support.appendingPathComponent("accounts.json"))
            let cache = try DriveCache(rootDirectory: support.appendingPathComponent("cache", isDirectory: true))
            return Stores(accounts: accounts, cache: cache, downloads: downloads, error: nil)
        } catch {
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("NativeDrive-\(UUID().uuidString)", isDirectory: true)
            let downloads = fallback.appendingPathComponent("downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let accounts = try? AccountStore(fileURL: fallback.appendingPathComponent("accounts.json"))
            let cache = try? DriveCache(rootDirectory: fallback.appendingPathComponent("cache", isDirectory: true))
            guard let accounts, let cache else {
                fatalError("Native Drive couldn't create local storage.")
            }
            return Stores(accounts: accounts, cache: cache, downloads: downloads, error: error.localizedDescription)
        }
    }

    var browser: BrowserModel? {
        guard let activeAccountID else { return nil }
        return browsers[activeAccountID]
    }

    var activeAccount: DriveAccount? {
        accounts.first { $0.id == activeAccountID }
    }

    func startup() async {
        guard !didStart else { return }
        didStart = true
        accounts = await accountStore.list()
        if let id = accounts.first?.id {
            await activate(id)
        }
    }

    func addAccount() {
        guard let config = AppConfig.oauthConfig() else {
            showSetup = true
            return
        }
        isSigningIn = true
        authError = nil
        signInTask = Task {
            defer { isSigningIn = false }
            do {
                let tokens = try await oauth.signIn(config: config, useLoopback: AppConfig.useLoopback)
                let client = DriveClient(http: http, auth: LiteralTokenProvider(token: tokens.accessToken))
                let user = try await client.aboutUser()
                let id = AccountID.make(email: user.emailAddress, permissionID: user.permissionId)
                let email = user.emailAddress ?? IDTokenClaims.string("email", jwt: tokens.idToken ?? "") ?? id
                try await tokenStore.save(tokens, for: id)
                let account = DriveAccount(
                    id: id,
                    email: email,
                    displayName: user.displayName ?? IDTokenClaims.string("name", jwt: tokens.idToken ?? ""),
                    pictureURL: user.photoLink,
                    addedAt: Date(),
                    hostedDomain: ShareAccount.workspaceDomain(email: email, idToken: tokens.idToken)
                )
                try await accountStore.upsert(account)
                accounts = await accountStore.list()
                await activate(id)
            } catch OAuthFlowError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                authError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        isSigningIn = false
    }

    func selectAccount(at index: Int) {
        guard accounts.indices.contains(index) else { return }
        let id = accounts[index].id
        Task { await activate(id) }
    }

    func selectAccount(id: String) {
        Task { await activate(id) }
    }

    func signOutActive() async {
        guard let id = activeAccountID else { return }
        browsers[id]?.closeQuickLook()
        browsers[id] = nil
        try? await tokenStore.delete(for: id)
        try? await cache.clear(accountID: id)
        let downloads = downloadRoot.appendingPathComponent(AccountID.sanitize(id), isDirectory: true)
        try? FileManager.default.removeItem(at: downloads)
        try? await accountStore.remove(id: id)
        accounts = await accountStore.list()
        if let next = accounts.first?.id {
            await activate(next)
        } else {
            activeAccountID = nil
            objectWillChange.send()
        }
    }

    private func activate(_ id: String) async {
        activeAccountID = id
        if browsers[id] == nil {
            let provider = RefreshingTokenProvider(accountID: id, config: AppConfig.oauthConfig() ?? OAuthClientConfig(clientID: "", clientSecret: nil, redirectURI: ""), store: tokenStore, http: http)
            let client = DriveClient(http: http, auth: provider)
            let model = BrowserModel(accountID: id, client: client, cache: cache, transfers: transfers, downloadRoot: downloadRoot)
            model.workspaceDomain = await hostedDomain(for: id)
            browsers[id] = model
            objectWillChange.send()
            await model.restore()
        } else {
            browsers[id]?.workspaceDomain = await hostedDomain(for: id)
            objectWillChange.send()
        }
    }

    private func hostedDomain(for id: String) async -> String? {
        if let existing = accounts.first(where: { $0.id == id })?.hostedDomain, !existing.isEmpty {
            return existing
        }
        guard let tokens = try? await tokenStore.load(for: id) else { return nil }
        let email = accounts.first(where: { $0.id == id })?.email
        guard let domain = ShareAccount.workspaceDomain(email: email, idToken: tokens.idToken) else { return nil }
        if var account = accounts.first(where: { $0.id == id }) {
            account.hostedDomain = domain
            try? await accountStore.upsert(account)
            accounts = await accountStore.list()
        }
        return domain
    }
}
