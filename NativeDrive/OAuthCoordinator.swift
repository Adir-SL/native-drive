import AppKit
import AuthenticationServices
import Foundation
import NativeDriveCore

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let http = URLSessionHTTPClient()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let window = NSApp.keyWindow { return window }
        if let window = NSApp.mainWindow { return window }
        if let window = NSApp.windows.first { return window }
        return NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    func signIn(config: OAuthClientConfig, useLoopback: Bool) async throws -> OAuthTokens {
        if useLoopback {
            return try await signInWithLoopback(config)
        }
        return try await signInWithScheme(config)
    }

    private func signInWithScheme(_ config: OAuthClientConfig) async throws -> OAuthTokens {
        let verifier = PKCE.generateVerifier()
        let state = PKCE.generateVerifier()
        let scheme = URL(string: config.redirectURI)?.scheme ?? AppConfig.redirectScheme
        var live = config
        live.redirectURI = "\(scheme):/oauth2callback"
        let url = OAuthFlow.authorizationURL(config: live, codeChallenge: PKCE.challenge(for: verifier), state: state)
        let callback = try await webAuth(url: url, scheme: scheme)
        let code = try OAuthFlow.parseCallback(url: callback, expectedState: state)
        return try await OAuthFlow.exchange(code: code, verifier: verifier, config: live, http: http)
    }

    private func signInWithLoopback(_ config: OAuthClientConfig) async throws -> OAuthTokens {
        let server = LoopbackOAuthServer()
        let port = try server.start()
        var live = config
        live.redirectURI = "http://127.0.0.1:\(port)"
        let verifier = PKCE.generateVerifier()
        let state = PKCE.generateVerifier()
        let authURL = OAuthFlow.authorizationURL(config: live, codeChallenge: PKCE.challenge(for: verifier), state: state)
        let gate = CallbackGate()

        return try await withTaskCancellationHandler {
            let serverTask = Task { @MainActor in
                do {
                    let callback = try await server.waitForCallback()
                    await gate.succeed(callback)
                    self.session?.cancel()
                } catch {
                    await gate.fail(error)
                }
            }
            defer {
                serverTask.cancel()
                server.stop()
            }

            do {
                let callback = try await webAuth(url: authURL, scheme: "http")
                await gate.succeed(callback)
            } catch OAuthFlowError.presentationFailed {
                NSWorkspace.shared.open(authURL)
            } catch OAuthFlowError.cancelled {
                if await gate.current() == nil {
                    server.stop()
                    await gate.fail(OAuthFlowError.cancelled)
                }
            } catch {
                NSWorkspace.shared.open(authURL)
            }

            let callback = try await gate.wait()
            let code = try OAuthFlow.parseCallback(url: callback, expectedState: state)
            return try await OAuthFlow.exchange(code: code, verifier: verifier, config: live, http: http)
        } onCancel: {
            server.stop()
            Task { await gate.fail(OAuthFlowError.cancelled) }
        }
    }

    private func webAuth(url: URL, scheme: String) async throws -> URL {
        let box = AuthCallbackBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                box.resume(continuation, with: Self.authResult(callback: callback, error: error))
            }
            MainActor.assumeIsolated {
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                NSApp.activate()
                if !session.start() {
                    box.resume(continuation, with: .failure(OAuthFlowError.presentationFailed))
                }
            }
        }
    }

    private nonisolated static func authResult(callback: URL?, error: Error?) -> Result<URL, Error> {
        if let callback {
            return .success(callback)
        }
        let nsError = error as NSError?
        if nsError?.domain == ASWebAuthenticationSessionErrorDomain,
           nsError?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
            return .failure(OAuthFlowError.cancelled)
        }
        if let error {
            return .failure(error)
        }
        return .failure(OAuthFlowError.cancelled)
    }
}

private final class AuthCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<URL, Error>, with result: Result<URL, Error>) {
        lock.lock()
        let shouldResume = !resumed
        resumed = true
        lock.unlock()
        guard shouldResume else { return }
        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor CallbackGate {
    private var value: URL?
    private var failure: Error?
    private var waiters: [CheckedContinuation<URL, Error>] = []

    func current() -> URL? { value }

    func succeed(_ url: URL) {
        guard value == nil, failure == nil else { return }
        value = url
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: url) }
    }

    func fail(_ error: Error) {
        guard value == nil, failure == nil else { return }
        failure = error
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }

    func wait() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.assumeIsolated { gate in
                if let value = gate.value {
                    continuation.resume(returning: value)
                } else if let failure = gate.failure {
                    continuation.resume(throwing: failure)
                } else {
                    gate.waiters.append(continuation)
                }
            }
        }
    }
}
