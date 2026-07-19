import Foundation
import CryptoKit
import Network
import AppKit

/// OpenRouter OAuth PKCE coordinator for "Sign in with OpenRouter".
///
/// Flow (no client registration required):
/// 1. Generate PKCE verifier + S256 challenge
/// 2. Listen on an ephemeral localhost port for the redirect
/// 3. Open the system browser to OpenRouter's /auth URL
/// 4. Exchange the returned code for a user-controlled API key
@MainActor
final class OpenRouterOAuthCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case waitingForBrowser
        case exchanging
        case succeeded
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var codeVerifier: String?

    private let authBase = "https://openrouter.ai/auth"
    private let exchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    /// Runs the full PKCE flow and returns the OpenRouter API key (`sk-or-…`).
    func signIn() async throws -> String {
        cancel()
        state = .waitingForBrowser

        let verifier = Self.makeCodeVerifier()
        codeVerifier = verifier
        let challenge = Self.makeS256Challenge(verifier: verifier)

        let port = try await startCallbackListener()
        let callback = "http://127.0.0.1:\(port)/callback"
        guard var components = URLComponents(string: authBase) else {
            throw OAuthError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let authURL = components.url else {
            throw OAuthError.invalidURL
        }

        let opened = NSWorkspace.shared.open(authURL)
        guard opened else {
            stopListener()
            throw OAuthError.couldNotOpenBrowser
        }

        do {
            let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                self.codeContinuation = cont
            }
            state = .exchanging
            let key = try await exchangeCode(code, verifier: verifier)
            stopListener()
            codeVerifier = nil
            state = .succeeded
            return key
        } catch {
            stopListener()
            codeVerifier = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .failed(message)
            throw error
        }
    }

    func cancel() {
        if let cont = codeContinuation {
            codeContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        stopListener()
        codeVerifier = nil
        if case .waitingForBrowser = state { state = .idle }
        if case .exchanging = state { state = .idle }
    }

    // MARK: - PKCE

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func makeS256Challenge(verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    // MARK: - Localhost callback

    private func startCallbackListener() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    let port = listener.port?.rawValue ?? 0
                    if port == 0 {
                        cont.resume(throwing: OAuthError.listenerFailed)
                    } else {
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    guard !resumed else { return }
                    resumed = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                connection.cancel()
                Task { @MainActor in
                    self.failContinuation(error)
                }
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let code = Self.extractCode(fromHTTPRequest: request)
            let body: String
            let status: String
            if let code, !code.isEmpty {
                body = """
                <!doctype html><html><body style="font-family:system-ui;padding:2rem">
                <h2>Connected to ARIL</h2>
                <p>You can close this tab and return to the app.</p>
                </body></html>
                """
                status = "200 OK"
                Task { @MainActor in
                    self.resumeContinuation(with: code)
                }
            } else {
                body = """
                <!doctype html><html><body style="font-family:system-ui;padding:2rem">
                <h2>Authorization incomplete</h2>
                <p>No code was returned. You can close this tab and try again in ARIL.</p>
                </body></html>
                """
                status = "400 Bad Request"
                Task { @MainActor in
                    self.failContinuation(OAuthError.missingCode)
                }
            }
            let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func extractCode(fromHTTPRequest request: String) -> String? {
        // First line: GET /callback?code=... HTTP/1.1
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first
        else { return nil }
        guard let comps = URLComponents(string: String(pathPart)) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func resumeContinuation(with code: String) {
        guard let cont = codeContinuation else { return }
        codeContinuation = nil
        cont.resume(returning: code)
    }

    private func failContinuation(_ error: Error) {
        guard let cont = codeContinuation else { return }
        codeContinuation = nil
        cont.resume(throwing: error)
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ARIL", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/fizzball/ARIL", forHTTPHeaderField: "HTTP-Referer")
        let payload: [String: String] = [
            "code": code,
            "code_verifier": verifier,
            "code_challenge_method": "S256",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.exchangeFailed(status: status, detail: detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String,
              key.hasPrefix("sk-or-")
        else {
            throw OAuthError.invalidKeyResponse
        }
        return key
    }

    enum OAuthError: LocalizedError {
        case invalidURL
        case couldNotOpenBrowser
        case listenerFailed
        case missingCode
        case invalidKeyResponse
        case exchangeFailed(status: Int, detail: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Could not build the OpenRouter authorization URL."
            case .couldNotOpenBrowser:
                return "Could not open your browser for OpenRouter sign-in."
            case .listenerFailed:
                return "Could not start the local OAuth callback listener."
            case .missingCode:
                return "OpenRouter did not return an authorization code."
            case .invalidKeyResponse:
                return "OpenRouter returned an unexpected key response."
            case .exchangeFailed(let status, let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "OpenRouter key exchange failed (HTTP \(status))."
                }
                return "OpenRouter key exchange failed (HTTP \(status)): \(trimmed.prefix(180))"
            }
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
