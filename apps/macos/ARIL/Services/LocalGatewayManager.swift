import Foundation

/// Launches the local ARIL API for Solo mode.
///
/// Resolution order:
/// 1. `UserDefaults` key `aril.apiRoot` (dev override)
/// 2. Bundled PyInstaller gateway at `Contents/Resources/aril-gateway/`
/// 3. Monorepo `services/aril-api` + `.venv` (Debug / contributor checkouts)
@MainActor
final class LocalGatewayManager: ObservableObject {
    @Published private(set) var isManagingProcess = false
    @Published private(set) var lastMessage: String = ""

    private var process: Process?
    private let port: Int
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(port: Int = 8741) {
        self.port = port
    }

    func ensureRunning() async {
        if await healthOK() {
            if await gatewayAPICompatible() {
                lastMessage = "Local gateway already running"
                return
            }
            lastMessage = "Recycling outdated local gateway…"
            await recyclePortListener()
        }
        start()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await healthOK(), await gatewayAPICompatible() {
                lastMessage = "Solo gateway started on port \(port)"
                return
            }
        }
        lastMessage = "Could not start local gateway — see docs/INSTALL.md or run ./scripts/dev-up.sh"
    }

    func stop() {
        process?.terminate()
        process = nil
        isManagingProcess = false
    }

    private func healthOK() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func storeAPIAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/store/stats") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// True when this listener exposes the routes the current client expects.
    /// Stale Solo binaries (still on :8741 after an upgrade) must be recycled —
    /// `/health` alone is not enough.
    private func gatewayAPICompatible() async -> Bool {
        guard await storeAPIAvailable() else { return false }
        guard await mcpCheckAPIAvailable() else { return false }
        return await weeklyRankingsAPIAvailable()
    }

    /// `POST /v1/mcp/check` exists when GET returns 405 (not 404).
    private func mcpCheckAPIAvailable() async -> Bool {
        await routeExistsPreferringNon404(path: "/v1/mcp/check", method: "GET")
    }

    /// Weekly popularity rankings (added in 0.3.27).
    private func weeklyRankingsAPIAvailable() async -> Bool {
        await routeExistsPreferringNon404(path: "/v1/models/rankings/weekly", method: "GET")
    }

    /// Existing route typically returns 200/405/422/…; missing route → 404.
    private func routeExistsPreferringNon404(path: String, method: String) async -> Bool {
        guard let url = URL(string: "\(baseURL)\(path)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = method
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code != 404 && code != 0
        } catch {
            return false
        }
    }

    private func recyclePortListener() async {
        stop()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["bash", "-lc", "lsof -tiTCP:\(port) -sTCP:LISTEN | xargs kill 2>/dev/null || true"]
        try? task.run()
        task.waitUntilExit()
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func start() {
        guard let launch = resolveLaunch() else {
            lastMessage = "ARIL gateway not found (bundle Resources or services/aril-api)"
            return
        }

        let proc = Process()
        proc.executableURL = launch.executable
        proc.arguments = launch.arguments
        proc.currentDirectoryURL = launch.workingDirectory
        proc.environment = gatewayEnvironment()

        do {
            try proc.run()
            process = proc
            isManagingProcess = true
            lastMessage = launch.isBundled
                ? "Starting bundled Solo gateway…"
                : "Starting solo gateway…"
        } catch {
            lastMessage = "Failed to launch gateway: \(error.localizedDescription)"
        }
    }

    private struct GatewayLaunch {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL?
        let isBundled: Bool
    }

    private func resolveLaunch() -> GatewayLaunch? {
        if let custom = UserDefaults.standard.string(forKey: "aril.apiRoot"),
           FileManager.default.fileExists(atPath: custom) {
            return pythonLaunch(apiRoot: URL(fileURLWithPath: custom), bundled: false)
        }

        if let bundled = bundledGatewayExecutable() {
            return GatewayLaunch(
                executable: bundled,
                arguments: [],
                workingDirectory: bundled.deletingLastPathComponent(),
                isBundled: true
            )
        }

        if let apiRoot = monorepoAPIRoot() {
            return pythonLaunch(apiRoot: apiRoot, bundled: false)
        }
        return nil
    }

    /// Prefer `Resources/aril-gateway/aril-gateway` (onedir) or `Resources/aril-gateway` (onefile).
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
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("app/main.py").path)
        }
    }

    private func pythonLaunch(apiRoot: URL, bundled: Bool) -> GatewayLaunch {
        let venvPython = apiRoot.appendingPathComponent(".venv/bin/python")
        let pythonBin = FileManager.default.isExecutableFile(atPath: venvPython.path)
            ? venvPython
            : URL(fileURLWithPath: "/usr/bin/python3")

        var args = [
            "-m", "uvicorn",
            "app.main:app",
            "--host", "127.0.0.1",
            "--port", "\(port)",
        ]
        #if DEBUG
        // Hot reload only for local contributor checkouts.
        if !bundled {
            args.insert("--reload", at: 3)
        }
        #endif

        return GatewayLaunch(
            executable: pythonBin,
            arguments: args,
            workingDirectory: apiRoot,
            isBundled: bundled
        )
    }

    private func gatewayEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["ARIL_ENV"] = "production"
        env["ARIL_HOST"] = "127.0.0.1"
        env["ARIL_PORT"] = "\(port)"
        env["ARIL_DATA_DIR"] = applicationSupportDataDir().path

        if let key = UserDefaults.standard.string(forKey: "aril.openRouterAPIKey"),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["OPENROUTER_API_KEY"] = key
        }
        return env
    }

    private func applicationSupportDataDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ARIL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
