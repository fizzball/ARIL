import Foundation

/// Launches a local ARIL API for single-user (solo) mode.
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
            if await storeAPIAvailable() {
                lastMessage = "Local gateway already running"
                return
            }
            // Stale process (pre-SQLite Learning store) — recycle so writes hit aril.db.
            lastMessage = "Recycling outdated local gateway…"
            await recyclePortListener()
        }
        start()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if await healthOK(), await storeAPIAvailable() {
                lastMessage = "Solo gateway started on port \(port)"
                return
            }
        }
        lastMessage = "Could not start local gateway — start ./scripts/dev-up.sh"
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

    /// Learning browser / chat transaction persistence requires these routes.
    private func storeAPIAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/store/stats") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
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
        guard let apiRoot = resolveAPIRoot() else {
            lastMessage = "ARIL API path not found"
            return
        }
        let python = apiRoot.appendingPathComponent(".venv/bin/python").path
        let pythonBin = FileManager.default.isExecutableFile(atPath: python)
            ? python
            : "/usr/bin/python3"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonBin)
        // Reload picks up gateway code changes without requiring a full app relaunch.
        proc.arguments = [
            "-m", "uvicorn",
            "app.main:app",
            "--reload",
            "--host", "127.0.0.1",
            "--port", "\(port)",
        ]
        proc.currentDirectoryURL = apiRoot
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        if let key = UserDefaults.standard.string(forKey: "aril.openRouterAPIKey"),
           !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env["OPENROUTER_API_KEY"] = key
        }
        proc.environment = env

        do {
            try proc.run()
            process = proc
            isManagingProcess = true
            lastMessage = "Starting solo gateway…"
        } catch {
            lastMessage = "Failed to launch gateway: \(error.localizedDescription)"
        }
    }

    /// Prefer UserDefaults override, then monorepo relative to this source layout.
    private func resolveAPIRoot() -> URL? {
        if let custom = UserDefaults.standard.string(forKey: "aril.apiRoot"),
           FileManager.default.fileExists(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        // Walk up from common locations looking for services/aril-api
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // LocalGatewayManager.swift parent...
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("services/aril-api"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Documents/Claude/Projects/ARIL/services/aril-api"),
        ]
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("app/main.py").path)
        }
    }
}
