import Foundation
import AppKit

/// Checks GitHub for a newer ARIL release and installs the notarized DMG into `/Applications`.
enum AppUpdateService {
    struct LatestRelease: Equatable {
        let tag: String
        /// Marketing version without leading `v` (e.g. `0.4.2`).
        let version: String
        let dmgURL: URL
        let dmgName: String
        let htmlURL: URL?
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case noRelease
        case noDMG
        case downloadFailed(String)
        case mountFailed(String)
        case appMissingInDMG
        case installFailed(String)
        case notWritable

        var errorDescription: String? {
            switch self {
            case .network(let m): return m
            case .noRelease: return "Could not read the latest GitHub release."
            case .noDMG: return "Latest release has no ARIL-*.dmg asset."
            case .downloadFailed(let m): return "Download failed: \(m)"
            case .mountFailed(let m): return "Could not open the DMG: \(m)"
            case .appMissingInDMG: return "ARIL.app was not found inside the DMG."
            case .installFailed(let m): return m
            case .notWritable: return "Cannot write to /Applications. Try installing manually from the DMG."
            }
        }
    }

    static func fetchLatestRelease() async throws -> LatestRelease {
        guard let url = URL(string: "https://api.github.com/repos/fizzball/ARIL/releases/latest") else {
            throw UpdateError.noRelease
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ARIL-macOS", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.network("GitHub returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw UpdateError.noRelease
        }
        let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let dmgAsset = assets.first { asset in
            let name = (asset["name"] as? String ?? "").lowercased()
            return name.hasPrefix("aril-") && name.hasSuffix(".dmg")
        }
        guard let dmgAsset,
              let dmgName = dmgAsset["name"] as? String,
              let link = dmgAsset["browser_download_url"] as? String,
              let dmgURL = URL(string: link) else {
            throw UpdateError.noDMG
        }
        let html = (obj["html_url"] as? String).flatMap(URL.init(string:))
        return LatestRelease(tag: tag, version: version, dmgURL: dmgURL, dmgName: dmgName, htmlURL: html)
    }

    /// True when `latest` is strictly newer than `current` (marketing versions like `0.4.1`).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        compareVersions(latest, current) == .orderedDescending
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parseVersion(a)
        let pb = parseVersion(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func parseVersion(_ s: String) -> [Int] {
        let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
        return cleaned.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
    }

    /// Download DMG, mount it, stage a post-quit installer, then terminate ARIL.
    /// The helper replaces `/Applications/ARIL.app` after this process exits and relaunches.
    static func downloadAndScheduleInstall(
        release: LatestRelease,
        progress: @escaping @MainActor (String) -> Void
    ) async throws {
        await progress("Downloading \(release.dmgName)…")

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ARIL-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmgPath = work.appendingPathComponent(release.dmgName)

        do {
            let (tmpURL, response) = try await URLSession.shared.download(from: release.dmgURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw UpdateError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            if FileManager.default.fileExists(atPath: dmgPath.path) {
                try FileManager.default.removeItem(at: dmgPath)
            }
            try FileManager.default.moveItem(at: tmpURL, to: dmgPath)
        } catch let err as UpdateError {
            throw err
        } catch {
            throw UpdateError.downloadFailed(error.localizedDescription)
        }

        await progress("Opening disk image…")
        let mountPoint = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = try run(
            "/usr/bin/hdiutil",
            ["attach", dmgPath.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        )
        guard attach.status == 0 else {
            throw UpdateError.mountFailed(attach.stderr.isEmpty ? attach.stdout : attach.stderr)
        }

        defer {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
        }

        let mountedApp = mountPoint.appendingPathComponent("ARIL.app")
        guard FileManager.default.fileExists(atPath: mountedApp.path) else {
            throw UpdateError.appMissingInDMG
        }

        let dest = URL(fileURLWithPath: "/Applications/ARIL.app")
        // Probe writability of /Applications (replace may need delete + copy).
        let appsDir = URL(fileURLWithPath: "/Applications")
        if !FileManager.default.isWritableFile(atPath: appsDir.path) {
            throw UpdateError.notWritable
        }

        await progress("Preparing installer…")

        // Copy the new app out of the DMG so we can detach before quit.
        let stagedApp = work.appendingPathComponent("ARIL.app")
        if FileManager.default.fileExists(atPath: stagedApp.path) {
            try FileManager.default.removeItem(at: stagedApp)
        }
        try FileManager.default.copyItem(at: mountedApp, to: stagedApp)

        // Detach now that we have a staged copy.
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])

        let scriptURL = work.appendingPathComponent("install.sh")
        let script = """
        #!/bin/bash
        set -euo pipefail
        OLD_PID=\(ProcessInfo.processInfo.processIdentifier)
        SRC=\(shellQuote(stagedApp.path))
        DEST=\(shellQuote(dest.path))
        WORK=\(shellQuote(work.path))
        LOG="$WORK/install.log"

        # Wait for ARIL to exit (up to ~60s).
        for i in $(seq 1 60); do
          if ! kill -0 "$OLD_PID" 2>/dev/null; then
            break
          fi
          sleep 1
        done
        # Brief settle so the bundle unlocks.
        sleep 1

        {
          echo "Installing ARIL \(release.version)…"
          if [ -d "$DEST" ]; then
            rm -rf "$DEST"
          fi
          /usr/bin/ditto --noextattr --norsrc "$SRC" "$DEST"
          /usr/bin/xattr -cr "$DEST" 2>/dev/null || true
          /usr/bin/codesign --verify --deep --strict "$DEST" 2>/dev/null || true
          echo "Launching…"
          /usr/bin/open "$DEST"
          # Best-effort cleanup of staging (ignore failures if still busy).
          sleep 2
          rm -rf "$WORK" 2>/dev/null || true
        } >>"$LOG" 2>&1
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        await progress("Installing to /Applications and relaunching…")

        // Launch detached so the helper survives ARIL quitting.
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [
            "-c",
            "nohup \(shellQuote(scriptURL.path)) >/dev/null 2>&1 &",
        ]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()
        launcher.waitUntilExit()

        // Brief pause so the helper can start waiting on our PID.
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(_ launchPath: String, _ args: [String]) throws -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(status: proc.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
