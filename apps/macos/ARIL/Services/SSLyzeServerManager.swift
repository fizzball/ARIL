import Foundation
import Security

/// Launches and supervises the ARIL-managed SSLyze TLS/certificate MCP server.
///
/// Mirrors `NmapServerManager` / `CodeScanServerManager`: ARIL generates a bearer
/// token on each enable, writes it into a `config.json` (host pinned to 127.0.0.1)
/// and stores the same token in Application Support `.env`, then launches the
/// server — so the token the server enforces and the token the app sends can never
/// drift. The server is served by the same bundled `aril-gateway` binary via its
/// `sslyze-mcp` subcommand (or `python -m app.sslyze_mcp` in dev checkouts).
@MainActor
final class SSLyzeServerManager: ObservableObject {
    @Published private(set) var isManagingProcess = false
    @Published private(set) var lastMessage: String = ""
    @Published private(set) var sslyzeInstalled: Bool = false

    private var process: Process?
    let port: Int

    init(port: Int = 8744) {
        self.port = port
        self.sslyzeInstalled = Self.resolveSSLyzePath() != nil
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var mcpURL: String { "\(baseURL)/mcp" }

    /// Generate a URL-safe random bearer token (256-bit).
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Refresh whether an sslyze binary is present on this Mac.
    @discardableResult
    func refreshSSLyzeInstalled() -> Bool {
        let found = Self.resolveSSLyzePath() != nil
        sslyzeInstalled = found
        return found
    }

    /// Ensure the server is running with the given bearer token. Returns true on success.
    @discardableResult
    func ensureRunning(token: String, forceRestart: Bool = false) async -> Bool {
        refreshSSLyzeInstalled()
        if forceRestart {
            stop()
            freeListenPort()
        } else if await healthOK() {
            lastMessage = "SSLyze MCP already running on port \(port)"
            isManagingProcess = process != nil
            return true
        }
        guard writeConfig(token: token) else {
            lastMessage = "Could not write SSLyze MCP config"
            return false
        }
        guard start() else { return false }
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await healthOK() {
                lastMessage = "SSLyze MCP started on port \(port)"
                return true
            }
        }
        lastMessage = "Could not start SSLyze MCP server"
        stop()
        return false
    }

    func stop() {
        process?.terminate()
        process = nil
        isManagingProcess = false
    }

    private func freeListenPort() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-lc", "lsof -tiTCP:\(port) -sTCP:LISTEN | xargs kill 2>/dev/null || true"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Health

    private func healthOK() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let installed = obj["sslyze_installed"] as? Bool {
                sslyzeInstalled = installed
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Config

    private func configDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ARIL/sslyze-mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var configPath: URL { configDir().appendingPathComponent("config.json") }

    private func writeConfig(token: String) -> Bool {
        let payload: [String: Any] = [
            "host": "127.0.0.1",
            "port": port,
            "path": "/mcp",
            "token": token,
            "sslyze_path": Self.resolveSSLyzePath() ?? "sslyze",
            "scan_timeout": 180,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return false
        }
        do {
            try data.write(to: configPath, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Launch

    @discardableResult
    private func start() -> Bool {
        guard let launch = resolveLaunch() else {
            lastMessage = "SSLyze MCP server binary not found (bundle Resources or services/aril-api)"
            return false
        }
        let proc = Process()
        proc.executableURL = launch.executable
        proc.arguments = launch.arguments
        proc.currentDirectoryURL = launch.workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        do {
            try proc.run()
            process = proc
            isManagingProcess = true
            lastMessage = launch.isBundled ? "Starting bundled SSLyze MCP…" : "Starting SSLyze MCP…"
            return true
        } catch {
            lastMessage = "Failed to launch SSLyze MCP: \(error.localizedDescription)"
            return false
        }
    }

    private struct ServerLaunch {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL?
        let isBundled: Bool
    }

    private func resolveLaunch() -> ServerLaunch? {
        let configArg = configPath.path

        if let custom = UserDefaults.standard.string(forKey: "aril.sslyzeMcpRoot"),
           FileManager.default.fileExists(atPath: custom) {
            return pythonLaunch(apiRoot: URL(fileURLWithPath: custom), config: configArg)
        }

        if let bundled = bundledGatewayExecutable() {
            return ServerLaunch(
                executable: bundled,
                arguments: ["sslyze-mcp", "--config", configArg],
                workingDirectory: bundled.deletingLastPathComponent(),
                isBundled: true
            )
        }

        if let apiRoot = monorepoAPIRoot() {
            return pythonLaunch(apiRoot: apiRoot, config: configArg)
        }
        return nil
    }

    /// Reuse the same frozen gateway binary; it serves the SSLyze MCP via subcommand.
    private func bundledGatewayExecutable() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resources.appendingPathComponent("aril-gateway/aril-gateway"),
            resources.appendingPathComponent("aril-gateway"),
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func monorepoAPIRoot() -> URL? {
        let fileWalk = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("services/aril-api")
        let candidates = [
            fileWalk,
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/Claude/Projects/ARIL/services/aril-api"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("app/sslyze_mcp/server.py").path)
        }
    }

    private func pythonLaunch(apiRoot: URL, config: String) -> ServerLaunch {
        let venvPython = apiRoot.appendingPathComponent(".venv/bin/python")
        let pythonBin = FileManager.default.isExecutableFile(atPath: venvPython.path)
            ? venvPython
            : URL(fileURLWithPath: "/usr/bin/python3")
        return ServerLaunch(
            executable: pythonBin,
            arguments: ["-m", "app.sslyze_mcp", "--config", config],
            workingDirectory: apiRoot,
            isBundled: false
        )
    }

    // MARK: - SSLyze discovery

    static func resolveSSLyzePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/sslyze",
            "/usr/local/bin/sslyze",
            "/usr/bin/sslyze",
            "\(home)/.local/bin/sslyze",
            "\(home)/.local/pipx/venvs/sslyze/bin/sslyze",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", "sslyze"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
