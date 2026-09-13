import AppKit
import Network
import Foundation

/// Native browser authorization using an ephemeral loopback-only callback.
/// PKCE, state, scopes and token exchange belong to OAuthService in FloraCore.
@MainActor
final class OAuthBrowserSession {
    private let openURL: @MainActor (URL) -> Bool
    init(openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) { self.openURL = openURL }
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, any Error>?
    private var completion: CheckedContinuation<URL, any Error>?
    private var timeout: Task<Void, Never>?
    private var redirect: URL?
    private var expectedState: String?

    func prepare(callbackHost: String = "127.0.0.1") async throws -> URL {
        guard callbackHost == "127.0.0.1" || callbackHost == "localhost" else { throw AccountConnectionError.callbackUnavailable }
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port,
                          let url = URL(string: "http://\(callbackHost):\(port.rawValue)/oauth/callback") else {
                        self.cancel(error: AccountConnectionError.callbackUnavailable); return
                    }
                    self.redirect = url
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed: self.cancel(error: AccountConnectionError.callbackUnavailable)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    self?.cancel(error: AccountConnectionError.callbackUnavailable)
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func authenticate(authorizationURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard redirect != nil,
              let state = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
              !state.isEmpty, authorizationURL.scheme == "https" else { throw AccountConnectionError.callbackUnavailable }
        expectedState = state
        timeout?.cancel()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    self?.cancel(error: AccountConnectionError.authenticationTimedOut)
                }
                guard openURL(authorizationURL) else {
                    cancel(error: AccountConnectionError.browserUnavailable); return
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel(error: any Error = CancellationError()) {
        timeout?.cancel(); timeout = nil
        ready?.resume(throwing: error); ready = nil
        completion?.resume(throwing: error); completion = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]; expectedState = nil
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffered: Data())
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if let remaining = self?.connections.removeValue(forKey: id) { remaining.cancel() }
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, finished, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var combined = buffered
                if let data { combined.append(data) }
                guard combined.count <= 16_384, error == nil else { self.close(id); return }
                if let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") {
                    self.handle(text, connection: connection, id: id)
                } else if finished { self.close(id) }
                else { self.receive(connection, id: id, buffered: combined) }
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection, id: UUID) {
        guard let redirect else { close(id); return }
        let target = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
        guard target.count == 3, target[0] == "GET", target[2] == "HTTP/1.1",
              let callback = Self.validatedCallback(target: String(target[1]), redirect: redirect, expectedState: expectedState) else {
            respond("400 Bad Request", body: "This sign-in callback is not valid. Return to Flora Mail.", connection: connection, id: id)
            return
        }
        respond("200 OK", body: "Sign-in response received. Return to Flora Mail to finish connecting your account.", connection: connection, id: id)
        completion?.resume(returning: callback); completion = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil; expectedState = nil
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// Reject unrelated requests before ending the session. Never echo codes or
    /// provider error descriptions into the browser response or application log.
    static func validatedCallback(target: String, redirect: URL, expectedState: String?) -> URL? {
        guard target.hasPrefix("/oauth/callback?"), !target.contains("#"),
              let expectedState, let relative = URLComponents(string: target),
              relative.path == "/oauth/callback", relative.host == nil, relative.scheme == nil,
              let items = relative.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else { return nil }
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)
        callback?.percentEncodedQuery = relative.percentEncodedQuery
        return callback?.url
    }

    private func respond(_ status: String, body: String, connection: NWConnection, id: UUID) {
        let content = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(content.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + content, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(id) }
        })
    }
    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}

enum AccountConnectionError: LocalizedError {
    case callbackUnavailable, authenticationTimedOut, browserUnavailable, wrongAccount, invalidAccount, missingConfiguration, storageUnavailable, alreadyConnected
    var errorDescription: String? {
        switch self {
        case .callbackUnavailable: "Flora could not start the local sign-in callback. Retry connecting."
        case .authenticationTimedOut: "Sign-in timed out. Connect again when you are ready."
        case .browserUnavailable: "The sign-in page could not be opened in your browser."
        case .wrongAccount: "This sign-in belongs to a different account. Add it as a separate account instead."
        case .invalidAccount: "The provider did not return a usable account identity."
        case .missingConfiguration: "Enter the public client ID from your app registration before connecting."
        case .storageUnavailable: "Reconnect after restoring local storage. Temporary demo sessions cannot save account credentials."
        case .alreadyConnected: "This account is already added. Use Reauthenticate on its existing account entry."
        }
    }
}
