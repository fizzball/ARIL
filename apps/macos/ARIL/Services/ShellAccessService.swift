import Foundation

/// Runs short-lived local shell commands for the OS Access skill.
enum ShellAccessService {
    struct Result: Sendable {
        let command: String
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var combinedOutput: String {
            var parts: [String] = []
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { parts.append(out) }
            if !err.isEmpty { parts.append("stderr:\n\(err)") }
            if parts.isEmpty {
                parts.append(timedOut ? "(timed out)" : "(no output)")
            }
            return parts.joined(separator: "\n")
        }
    }

    enum ShellError: LocalizedError {
        case emptyCommand
        case blocked(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyCommand: return "Empty shell command."
            case .blocked(let reason): return reason
            case .launchFailed(let msg): return msg
            }
        }
    }

    private static let blockedPatterns: [String] = [
        #"rm\s+-rf\s+/"#,
        #"rm\s+-rf\s+~"#,
        #"mkfs\."#,
        #"diskutil\s+(erase|partition)"#,
        #":\(\)\s*\{\s*:\|:&\s*\}\s*;"#,
        #"dd\s+if=.+of=/dev/"#,
        #"curl\s+[^\n]*\|\s*(ba)?sh"#,
        #"wget\s+[^\n]*\|\s*(ba)?sh"#,
    ]

    private static let knownCommands: Set<String> = [
        "ls", "dig", "host", "nslookup", "ping", "traceroute", "whoami", "id", "hostname",
        "pwd", "df", "du", "ps", "top", "uname", "sw_vers", "date", "cal", "uptime",
        "cat", "head", "tail", "wc", "file", "which", "type", "command", "echo", "printf",
        "curl", "wget", "open", "stat", "find", "grep", "rg", "awk", "sed", "sort", "uniq",
        "env", "printenv", "brew", "git", "ssh", "scp", "rsync", "nmap", "ifconfig",
        "ip", "netstat", "lsof", "diskutil", "system_profiler", "defaults", "plutil",
        "python3", "python", "node", "ruby", "perl", "swift", "bash", "zsh", "sh",
    ]

    static func run(_ command: String, timeoutSeconds: TimeInterval = 30) async throws -> Result {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShellError.emptyCommand }
        if let reason = blockReason(for: trimmed) {
            throw ShellError.blocked(reason)
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(trimmed, timeoutSeconds: timeoutSeconds)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func blockReason(for command: String) -> String? {
        for pattern in blockedPatterns {
            if command.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return "Refused unsafe command pattern."
            }
        }
        return nil
    }

    private static func runSync(_ command: String, timeoutSeconds: TimeInterval) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                timedOut = true
                Thread.sleep(forTimeInterval: 0.4)
                if process.isRunning { process.interrupt() }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        let stdout = clamp(String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        let stderr = clamp(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
        return Result(
            command: command,
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private static func clamp(_ text: String, limit: Int = 80_000) -> String {
        guard text.count > limit else { return text }
        let idx = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<idx]) + "\n…(truncated)"
    }

    // MARK: - Command discovery

    /// Extract shell commands from fenced blocks in model text (line scanner).
    static func extractCommands(from markdown: String) -> [String] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var found: [String] = []
        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let opener = rawLine.trimmingCharacters(in: .whitespaces)
            index += 1
            guard opener.hasPrefix("```") else { continue }

            let afterTicks = String(opener.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let langToken = afterTicks.split(whereSeparator: { $0.isWhitespace }).first
                .map(String.init)?
                .lowercased() ?? ""

            if let inline = inlineFenceCommand(opener) {
                if !found.contains(inline) { found.append(inline) }
                continue
            }

            guard isShellLanguage(langToken) || langToken.isEmpty else { continue }

            var body: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    index += 1
                    break
                }
                body.append(line)
                index += 1
            }
            let command = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty lang: only accept if it looks like a real shell argv.
            if langToken.isEmpty, !looksLikeShellArgv(command) { continue }
            if !command.isEmpty, !found.contains(command) {
                found.append(command)
            }
        }
        return found
    }

    private static func isShellLanguage(_ lang: String) -> Bool {
        let l = lang.lowercased()
        if l.isEmpty { return false }
        let names = ["aril-shell", "shell", "bash", "zsh", "console", "terminal", "sh", "zsh-shell"]
        return names.contains { l == $0 || l.hasPrefix($0 + ":") || l.hasPrefix($0 + "{") }
    }

    private static func inlineFenceCommand(_ opener: String) -> String? {
        let trimmed = opener.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6 else { return nil }
        let inner = String(trimmed.dropFirst(3).dropLast(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = inner.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let lang = parts.first.map({ String($0).lowercased() }),
              isShellLanguage(lang),
              parts.count > 1
        else { return nil }
        let cmd = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return cmd.isEmpty ? nil : cmd
    }

    static func looksLikeShellArgv(_ command: String) -> Bool {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        if first.hasPrefix("/") || first.hasPrefix("./") || first.hasPrefix("~/") { return true }
        return knownCommands.contains(first)
    }

    /// Map natural-language OS requests to a concrete command when the model fence path fails.
    static func inferCommand(fromNaturalLanguage text: String) -> String? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }

        // Project documents ≠ Mac directory listing.
        if t.contains("project") && (t.contains("file") || t.contains("document") || t.contains("pdf")) {
            return nil
        }

        if t.contains("list") && (t.contains("file") || t.contains("dir") || t.contains("directory") || t.contains("folder") || t.contains("lookup")) {
            return "ls -la"
        }
        if (t.contains("directory") || t.contains("folder")) && (t.contains("lookup") || t.contains("show") || t.contains("contents")) {
            return "ls -la"
        }
        if t.contains("current directory") || t.contains("working directory") || t.contains("where am i") {
            if t.contains("list") || t.contains("show") || t.contains("file") || t.contains("content") {
                return "ls -la"
            }
            return "pwd"
        }
        if t.contains("hostname") || t.contains("computer name") { return "hostname" }
        if t.contains("who am i") || t.contains("whoami") || t.contains("current user") { return "whoami" }
        if t.contains("disk") && (t.contains("space") || t.contains("usage")) { return "df -h" }
        if t.contains("uptime") { return "uptime" }
        if t.contains("ip address") || t.contains("network interfaces") { return "ifconfig" }

        // DNS / dig style
        if t.contains("dns") || t.contains("mx record") || t.contains("name server") ||
            (t.contains("lookup") && (t.contains("domain") || t.contains("host") || t.contains("google") || t.contains("aril"))) {
            if let host = firstHostname(in: t) {
                if t.contains("mx") { return "dig \(host) MX +short" }
                return "dig \(host) +short"
            }
        }

        return nil
    }

    private static func firstHostname(in text: String) -> String? {
        let pattern = #"\b([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    static func formatResult(_ result: Result) -> String {
        var lines = [
            "**OS Access** · `\(result.command)`",
            "",
        ]
        if result.timedOut {
            lines.append("Timed out after waiting for the command.")
            lines.append("")
        }
        lines.append("exit \(result.exitCode)")
        lines.append("")
        lines.append("```")
        lines.append(result.combinedOutput)
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    static func debugLog(_ message: String) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ARIL", isDirectory: true)
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("os-access-debug.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
