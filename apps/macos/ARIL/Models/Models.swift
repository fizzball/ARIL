import Foundation

enum RouteMode: String, CaseIterable, Identifiable, Codable {
    case auto, manual, compare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .compare: return "Judge"
        }
    }
}

enum RouteCategory: String, CaseIterable, Codable, Identifiable {
    case coding, security, reasoning, vision, cost, performance, confidence, general
    var id: String { rawValue }
    var label: String {
        switch self {
        case .coding: return "Coding"
        case .security: return "Security"
        case .reasoning: return "Reasoning"
        case .vision: return "Vision"
        case .cost: return "Cost"
        case .performance: return "Performance"
        case .confidence: return "Confidence"
        case .general: return "General"
        }
    }
    var blurb: String {
        switch self {
        case .coding: return "Code, debugging, refactors, PRs"
        case .security: return "Vulns, auth, threat modeling"
        case .reasoning: return "Multi-step logic, math, deep analysis"
        case .vision: return "Images, screenshots, diagrams"
        case .cost: return "Cheap / short prompts"
        case .performance: return "Low latency responses"
        case .confidence: return "Highest capability when stakes are high"
        case .general: return "Everyday Q&A and writing"
        }
    }
}

struct RoutingProfile: Hashable, Codable {
    var coding: String
    var security: String
    var reasoning: String
    var vision: String
    var cost: String
    var performance: String
    var confidence: String
    var general: String

    static let `default` = RoutingProfile(
        coding: "openai/gpt-4.1",
        security: "anthropic/claude-sonnet-4",
        reasoning: "anthropic/claude-opus-4",
        vision: "google/gemini-2.5-flash",
        cost: "openai/gpt-4.1-mini",
        performance: "google/gemini-2.5-flash",
        confidence: "anthropic/claude-opus-4",
        general: "meta-llama/llama-3.3-70b-instruct"
    )

    static let recommendations: [RouteCategory: [String]] = [
        .coding: ["openai/gpt-4.1", "anthropic/claude-sonnet-4", "google/gemini-2.5-flash"],
        .security: ["anthropic/claude-sonnet-4", "anthropic/claude-opus-4", "openai/gpt-4.1"],
        .reasoning: ["anthropic/claude-opus-4", "openai/gpt-4.1", "anthropic/claude-sonnet-4"],
        .vision: ["google/gemini-2.5-flash", "openai/gpt-4.1", "anthropic/claude-sonnet-4"],
        .cost: ["openai/gpt-4.1-mini", "meta-llama/llama-3.3-70b-instruct", "google/gemini-2.5-flash"],
        .performance: ["google/gemini-2.5-flash", "openai/gpt-4.1-mini", "meta-llama/llama-3.3-70b-instruct"],
        .confidence: ["anthropic/claude-opus-4", "anthropic/claude-sonnet-4", "openai/gpt-4.1"],
        .general: ["meta-llama/llama-3.3-70b-instruct", "openai/gpt-4.1-mini", "openai/gpt-4.1"],
    ]

    func model(for category: RouteCategory) -> String {
        switch category {
        case .coding: return coding
        case .security: return security
        case .reasoning: return reasoning
        case .vision: return vision
        case .cost: return cost
        case .performance: return performance
        case .confidence: return confidence
        case .general: return general
        }
    }

    mutating func setModel(_ model: String, for category: RouteCategory) {
        switch category {
        case .coding: coding = model
        case .security: security = model
        case .reasoning: reasoning = model
        case .vision: vision = model
        case .cost: cost = model
        case .performance: performance = model
        case .confidence: confidence = model
        case .general: general = model
        }
    }

    /// Distinct model ids currently mapped across categories.
    var selectedModels: [String] {
        Array(
            Set([coding, security, reasoning, vision, cost, performance, confidence, general])
        ).sorted()
    }

    init(
        coding: String,
        security: String,
        reasoning: String,
        vision: String,
        cost: String,
        performance: String,
        confidence: String,
        general: String
    ) {
        self.coding = coding
        self.security = security
        self.reasoning = reasoning
        self.vision = vision
        self.cost = cost
        self.performance = performance
        self.confidence = confidence
        self.general = general
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RoutingProfile.default
        coding = try c.decodeIfPresent(String.self, forKey: .coding) ?? d.coding
        security = try c.decodeIfPresent(String.self, forKey: .security) ?? d.security
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning) ?? d.reasoning
        vision = try c.decodeIfPresent(String.self, forKey: .vision) ?? d.vision
        cost = try c.decodeIfPresent(String.self, forKey: .cost) ?? d.cost
        performance = try c.decodeIfPresent(String.self, forKey: .performance) ?? d.performance
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? d.confidence
        general = try c.decodeIfPresent(String.self, forKey: .general) ?? d.general
    }
}

struct ChatProject: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ChatSession: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date
    /// Running total of actual turn costs (USD). New sessions start at 0.
    var totalCostUsd: Double
    /// Optional folder grouping in the sidebar (local only).
    var projectID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        messages: [ChatMessage],
        updatedAt: Date = .now,
        totalCostUsd: Double = 0,
        projectID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.totalCostUsd = totalCostUsd
        self.projectID = projectID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, messages, updatedAt, totalCostUsd, projectID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        totalCostUsd = try c.decodeIfPresent(Double.self, forKey: .totalCostUsd) ?? 0
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        if totalCostUsd == 0 {
            recomputeTotalCost()
        }
    }

    mutating func recomputeTotalCost() {
        totalCostUsd = messages.compactMap { ChatMessage.actualCostUsd(from: $0.content) }.reduce(0, +)
    }

    var totalCostLabel: String {
        String(format: "$%.4f", totalCostUsd)
    }

    /// Filename-safe stem derived from the session title (for Markdown export).
    var exportFilenameStem: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "ARIL-session" : trimmed
        let cleaned = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        let limited = String(cleaned.prefix(80))
        return limited.isEmpty ? "ARIL-session" : limited
    }

    /// Export this session as Markdown (title, metadata, and turns).
    func markdownExport(
        userLabel: String = "You",
        assistantLabel: String = "ARIL",
        appVersion: String? = nil,
        exportedAt: Date = .now
    ) -> String {
        var lines: [String] = []
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled session"
            : title
        lines.append("# \(titleText)")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        lines.append("| Exported | \(Self.exportDateFormatter.string(from: exportedAt)) |")
        lines.append("| Updated | \(Self.exportDateFormatter.string(from: updatedAt)) |")
        lines.append("| Messages | \(messages.count) |")
        lines.append("| Session cost | \(totalCostLabel) |")
        if let appVersion, !appVersion.isEmpty {
            lines.append("| ARIL | \(appVersion) |")
        }
        lines.append("| Session ID | `\(id.uuidString.lowercased())` |")
        lines.append("")
        lines.append("---")
        lines.append("")

        if messages.isEmpty {
            lines.append("_No messages in this session._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        for message in messages {
            switch message.role {
            case .user:
                let label = message.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("## \(label?.isEmpty == false ? label! : userLabel)")
            case .assistant:
                lines.append("## \(assistantLabel)")
            case .system:
                lines.append("## System")
            }
            lines.append("")
            let body = message.bodyWithoutCostFooter
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty {
                lines.append("_Empty message._")
            } else {
                lines.append(body)
            }
            if let cost = message.costFooterLabel {
                lines.append("")
                lines.append("*\(cost)*")
            }
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Total character budget the gateway allows for context before it drops the
    /// oldest turns. Seeded from `_MAX_TOTAL_CHARS` in the gateway and refreshed from
    /// `/v1/meta/limits` so the client never drifts from the server's authoritative value.
    static var maxContextChars = 96_000
    /// Per-message cap the gateway applies before summing. Mirrors `_MAX_MESSAGE_CHARS`;
    /// refreshed from `/v1/meta/limits`.
    static var maxMessageChars = 24_000

    /// Approximate characters of model context this session sends on its next turn,
    /// matching the gateway's sanitize (base64 images stripped) + per-message cap.
    /// Falls back to a cheap count for plain-text messages to stay light during streaming.
    var contextChars: Int {
        messages.reduce(0) { acc, message in
            let content = message.content
            let counted: Int
            if content.contains("data:image") {
                counted = min(AppState.sanitizeContentForAPI(content).count, Self.maxMessageChars)
            } else {
                counted = min(content.count, Self.maxMessageChars)
            }
            return acc + counted
        }
    }

    /// Fraction of the context budget in use (0...1).
    var contextFraction: Double {
        guard Self.maxContextChars > 0 else { return 0 }
        return min(1.0, Double(contextChars) / Double(Self.maxContextChars))
    }

    /// Title or any message body matches `query` (case-insensitive).
    func matchesSearch(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if title.localizedCaseInsensitiveContains(q) { return true }
        return messagesContain(q)
    }

    func messagesContain(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        return messages.contains { message in
            let body = ChatMessage.stripActualCostFooter(message.content)
            return body.localizedCaseInsensitiveContains(q)
        }
    }

    /// Short excerpt around the first content hit for sidebar display.
    func searchSnippet(for query: String, radius: Int = 42) -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        for message in messages {
            let body = ChatMessage.stripActualCostFooter(message.content)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = body.range(of: q, options: .caseInsensitive) else { continue }
            let start = body.index(range.lowerBound, offsetBy: -radius, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(range.upperBound, offsetBy: radius, limitedBy: body.endIndex) ?? body.endIndex
            var snippet = String(body[start..<end])
            if start > body.startIndex { snippet = "…" + snippet }
            if end < body.endIndex { snippet += "…" }
            let who: String = {
                if message.role == .assistant { return "ARIL" }
                if let name = message.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                    return name
                }
                return "You"
            }()
            return "\(who): \(snippet)"
        }
        return nil
    }

    /// Collapse duplicated turns (common after gateway append + client upsert races).
    mutating func deduplicateMessages() {
        messages = Self.deduplicatedMessages(messages)
    }

    /// Prefer the richer of two near-identical messages (e.g. keep `file://` image over empty cost footer).
    static func deduplicatedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for msg in messages {
            if let last = out.last,
               last.role == msg.role,
               ChatMessage.normalizedForDedupe(last.content) == ChatMessage.normalizedForDedupe(msg.content) {
                if ChatMessage.contentRichness(msg.content) > ChatMessage.contentRichness(last.content) {
                    out[out.count - 1] = msg
                }
                continue
            }

            // Drop a repeated user→assistant pair that already appears immediately before.
            if msg.role == .assistant,
               out.count >= 3,
               out[out.count - 1].role == .user,
               out[out.count - 2].role == .assistant,
               out[out.count - 3].role == .user {
                let dupUser = out[out.count - 1]
                let prevAssistant = out[out.count - 2]
                let prevUser = out[out.count - 3]
                let sameUser = ChatMessage.normalizedForDedupe(dupUser.content)
                    == ChatMessage.normalizedForDedupe(prevUser.content)
                let sameAssistant = ChatMessage.normalizedForDedupe(msg.content)
                    == ChatMessage.normalizedForDedupe(prevAssistant.content)
                if sameUser && sameAssistant {
                    // Keep the richer assistant of the two; drop the duplicate user.
                    if ChatMessage.contentRichness(msg.content) > ChatMessage.contentRichness(prevAssistant.content) {
                        out[out.count - 2] = msg
                    }
                    out.removeLast()
                    continue
                }
            }

            out.append(msg)
        }
        return out
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Role: String, Hashable, Codable {
        case system, user, assistant
    }

    let id: UUID
    var role: Role
    var content: String
    /// Optional chat bubble label for user turns (e.g. model-test sender). Nil → Preferences display name / "You".
    var displayName: String?

    init(id: UUID = UUID(), role: Role, content: String, displayName: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
    }

    static func formatActualCostFooter(
        _ costUsd: Double,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> String {
        let cost = formatActualCostBody(costUsd, inputTokens: inputTokens, outputTokens: outputTokens)
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let leaf = model.split(separator: "/").last.map(String.init) ?? model
            return "\n\n[ \(leaf) · \(cost) ]"
        }
        return "\n\n[ \(cost) ]"
    }

    static func formatActualCostLabel(
        _ costUsd: Double,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> String {
        let cost = formatActualCostBody(costUsd, inputTokens: inputTokens, outputTokens: outputTokens)
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let leaf = model.split(separator: "/").last.map(String.init) ?? model
            return "[ \(leaf) · \(cost) ]"
        }
        return "[ \(cost) ]"
    }

    private static func formatActualCostBody(
        _ costUsd: Double,
        inputTokens: Int?,
        outputTokens: Int?
    ) -> String {
        let dollars = String(format: "$%.4f", max(0, costUsd))
        if let inputTokens, let outputTokens {
            return "tokens used \(inputTokens) / \(outputTokens): cost = \(dollars)"
        }
        return "tokens used — / —: cost = \(dollars)"
    }

    /// Matches a trailing reply cost footer (current + legacy formats).
    private static let actualCostFooterPattern =
        #"\n*\n?\s*(?:\[\s*(?:[^\]·]+·\s*)?(?:tokens used\s+(?:\d+|—)\s*/\s*(?:\d+|—):\s*cost\s*=\s*\$[0-9.]+|total(?:\s*\(in\+out\))?\s+token cost\s*=\s*\$[0-9.]+)\s*\]|-->\s*total(?:\s*\(in\+out\))?\s+token cost\s*=\s*\$[0-9.]+\s*<--|\{actual cost = \$[0-9.]+\})\s*"#

    static func stripActualCostFooter(_ content: String) -> String {
        guard let range = content.range(
            of: actualCostFooterPattern,
            options: .regularExpression
        ) else {
            return content
        }
        // Only strip a trailing footer.
        let after = content[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard after.isEmpty else { return content }
        return String(content[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func actualCostUsd(from content: String) -> Double? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:\[\s*(?:[^\]·]+·\s*)?(?:tokens used\s+(?:\d+|—)\s*/\s*(?:\d+|—):\s*cost\s*=\s*\$([0-9.]+)|total(?:\s*\(in\+out\))?\s+token cost\s*=\s*\$([0-9.]+))\s*\]|-->\s*total(?:\s*\(in\+out\))?\s+token cost\s*=\s*\$([0-9.]+)\s*<--|\{actual cost = \$([0-9.]+)\})"#,
            options: []
        ) else { return nil }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        for group in 1..<last.numberOfRanges {
            let range = last.range(at: group)
            guard range.location != NSNotFound else { continue }
            return Double(ns.substring(with: range))
        }
        return nil
    }

    /// Input / output token counts from a trailing cost footer, when present.
    static func actualTokenCounts(from content: String) -> (input: Int, output: Int)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"tokens used\s+(\d+)\s*/\s*(\d+):\s*cost\s*=\s*\$[0-9.]+"#,
            options: []
        ) else { return nil }
        let ns = content as NSString
        guard let last = regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).last,
              last.numberOfRanges > 2
        else { return nil }
        let inRange = last.range(at: 1)
        let outRange = last.range(at: 2)
        guard inRange.location != NSNotFound, outRange.location != NSNotFound,
              let input = Int(ns.substring(with: inRange)),
              let output = Int(ns.substring(with: outRange))
        else { return nil }
        return (input, output)
    }

    /// Leaf model id from a trailing `[ model · … cost = $… ]` footer, if present.
    static func actualModelLeaf(from content: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[\s*([^\]·]+?)\s*·\s*(?:tokens used|total)"#,
            options: []
        ) else { return nil }
        let ns = content as NSString
        guard let last = regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).last,
              last.numberOfRanges > 1
        else { return nil }
        let range = last.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        let leaf = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return leaf.isEmpty ? nil : leaf
    }

    static func withActualCostFooter(
        _ content: String,
        costUsd: Double,
        model: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil
    ) -> String {
        stripActualCostFooter(content)
            + formatActualCostFooter(
                costUsd,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
    }

    /// Body text without a trailing cost footer (for colored rendering).
    var bodyWithoutCostFooter: String {
        Self.stripActualCostFooter(content)
    }

    /// Stable comparison key for history dedupe (ignores cost footers / image URL variance).
    static func normalizedForDedupe(_ content: String) -> String {
        var text = stripActualCostFooter(content)
        if let fileImg = try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(file://[^)]+\)"#,
            options: [.caseInsensitive]
        ) {
            text = fileImg.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "![img](file)"
            )
        }
        if let dataImg = try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(data:image\/[^)]+\)"#,
            options: [.caseInsensitive]
        ) {
            text = dataImg.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "![img](data)"
            )
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefer messages that still carry real image payloads / body text.
    static func contentRichness(_ content: String) -> Int {
        let body = stripActualCostFooter(content).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return 0 }
        var score = min(body.count, 50_000)
        if content.contains("file://") { score += 100_000 }
        if content.contains("data:image") { score += 40_000 }
        if body.lowercased().contains("<svg") { score += 20_000 }
        return score
    }

    /// Display label for a trailing cost footer, if present.
    var costFooterLabel: String? {
        guard let cost = Self.actualCostUsd(from: content) else { return nil }
        let tokens = Self.actualTokenCounts(from: content)
        return Self.formatActualCostLabel(
            cost,
            model: Self.actualModelLeaf(from: content),
            inputTokens: tokens?.input,
            outputTokens: tokens?.output
        )
    }
}

struct PendingAttachment: Identifiable, Hashable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }

    var displaySize: String {
        let kb = Double(data.count) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

enum MCPTransport: String, CaseIterable, Identifiable, Codable {
    /// Remote MCP over HTTP/SSE (primary).
    case http
    /// Legacy label kept for decoding older drafts.
    case sse
    case stdio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .http, .sse: return "HTTP / SSE"
        case .stdio: return "stdio (local command)"
        }
    }
}

enum MCPAuthStyle: String, CaseIterable, Identifiable, Codable {
    case none
    case bearer
    case header

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .bearer: return "Bearer token"
        case .header: return "Custom header"
        }
    }
}

enum MCPCheckStatus: String, Codable, Hashable {
    case unknown
    case ok
    case failed
    case deferred
}

/// User-configured MCP server entry (Preferences). Enabled ready servers are attached to Auto/Manual chat turns.
struct MCPServerConfig: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var transport: MCPTransport
    /// Target MCP server URL (e.g. https://host/mcp).
    var url: String
    /// API key / bearer token (loaded from Application Support `.env` at runtime; not persisted in UserDefaults).
    var apiKey: String
    var enabled: Bool
    /// Stable built-in id (`agenty`, `deepwiki`, …). `nil` = custom server.
    var presetId: String?
    var authStyle: MCPAuthStyle
    /// Used when `authStyle == .header` (e.g. `X-ADM-API-Key`).
    var authHeaderName: String?
    var docsURL: String?
    /// Presets lock URL by default; customs are fully editable.
    var isEditable: Bool
    /// True for deferred entries that are not yet supported.
    var isDeferred: Bool
    var lastCheckStatus: MCPCheckStatus
    var lastCheckMessage: String

    enum CodingKeys: String, CodingKey {
        case id, name, transport, url, enabled
        case presetId, authStyle, authHeaderName, docsURL, isEditable, isDeferred
        case lastCheckStatus, lastCheckMessage
        case endpoint, args, apiKey // legacy draft fields — apiKey ignored on decode from disk
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        transport: MCPTransport = .http,
        url: String = "",
        apiKey: String = "",
        enabled: Bool = false,
        presetId: String? = nil,
        authStyle: MCPAuthStyle = .bearer,
        authHeaderName: String? = nil,
        docsURL: String? = nil,
        isEditable: Bool = true,
        isDeferred: Bool = false,
        lastCheckStatus: MCPCheckStatus = .unknown,
        lastCheckMessage: String = ""
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.url = url
        self.apiKey = apiKey
        self.enabled = enabled
        self.presetId = presetId
        self.authStyle = authStyle
        self.authHeaderName = authHeaderName
        self.docsURL = docsURL
        self.isEditable = isEditable
        self.isDeferred = isDeferred
        self.lastCheckStatus = lastCheckStatus
        self.lastCheckMessage = lastCheckMessage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        transport = try c.decodeIfPresent(MCPTransport.self, forKey: .transport) ?? .http
        let decodedURL = try c.decodeIfPresent(String.self, forKey: .url)
        let legacyEndpoint = try c.decodeIfPresent(String.self, forKey: .endpoint)
        url = (decodedURL?.isEmpty == false ? decodedURL : legacyEndpoint) ?? ""
        // Keys live in Application Support `.env` — ignore any legacy apiKey on disk.
        _ = try c.decodeIfPresent(String.self, forKey: .apiKey)
        apiKey = ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        presetId = try c.decodeIfPresent(String.self, forKey: .presetId)
        authStyle = try c.decodeIfPresent(MCPAuthStyle.self, forKey: .authStyle) ?? .bearer
        authHeaderName = try c.decodeIfPresent(String.self, forKey: .authHeaderName)
        docsURL = try c.decodeIfPresent(String.self, forKey: .docsURL)
        isEditable = try c.decodeIfPresent(Bool.self, forKey: .isEditable) ?? (presetId == nil)
        isDeferred = try c.decodeIfPresent(Bool.self, forKey: .isDeferred) ?? false
        lastCheckStatus = try c.decodeIfPresent(MCPCheckStatus.self, forKey: .lastCheckStatus) ?? .unknown
        lastCheckMessage = try c.decodeIfPresent(String.self, forKey: .lastCheckMessage) ?? ""
        _ = try c.decodeIfPresent(String.self, forKey: .args)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(transport, forKey: .transport)
        try c.encode(url, forKey: .url)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(presetId, forKey: .presetId)
        try c.encode(authStyle, forKey: .authStyle)
        try c.encodeIfPresent(authHeaderName, forKey: .authHeaderName)
        try c.encodeIfPresent(docsURL, forKey: .docsURL)
        try c.encode(isEditable, forKey: .isEditable)
        try c.encode(isDeferred, forKey: .isDeferred)
        try c.encode(lastCheckStatus, forKey: .lastCheckStatus)
        try c.encode(lastCheckMessage, forKey: .lastCheckMessage)
        // Never encode apiKey to UserDefaults.
    }

    var isPreset: Bool { presetId != nil }

    /// Stable preset id for the ARIL-managed local Nmap MCP server.
    static let nmapPresetId = "nmap-local"

    /// Stable preset id for the ARIL-managed local Semgrep code-scan MCP server.
    static let codescanPresetId = "codescan-local"

    /// Preset ids whose lifecycle (process + token + config) ARIL manages itself.
    static let managedPresetIds: Set<String> = [nmapPresetId, codescanPresetId]

    /// True for presets whose lifecycle (process + token + config) ARIL manages itself.
    var isManaged: Bool {
        guard let presetId else { return false }
        return MCPServerConfig.managedPresetIds.contains(presetId)
    }

    var needsAPIKey: Bool {
        switch authStyle {
        case .none: return false
        case .bearer, .header: return true
        }
    }

    var isReady: Bool {
        guard enabled, !isDeferred else { return false }
        let hasURL = !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasURL else { return false }
        if needsAPIKey {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let leaf = url.split(separator: "/").last.map(String.init) ?? url
        return leaf.isEmpty ? "Untitled MCP server" : leaf
    }

    /// Built-in presets (disabled by default).
    ///
    /// Only the ARIL-managed local Nmap scanner ships for now. Remote presets were
    /// removed pending a per-server architecture review; they'll be re-added
    /// selectively. Removing an entry here drops any previously-persisted copy on the
    /// next launch (see `AppState.loadMCPServers`), so no migration is needed.
    static func builtInPresets() -> [MCPServerConfig] {
        [
            MCPServerConfig(
                id: UUID(uuidString: "A1111111-1111-4111-8111-111111111108")!,
                name: "Nmap Scanner (local)",
                url: "http://127.0.0.1:8742/mcp",
                enabled: false,
                presetId: nmapPresetId,
                authStyle: .bearer,
                docsURL: "https://github.com/wzfukui/nmap-mcp-http",
                isEditable: false
            ),
            MCPServerConfig(
                id: UUID(uuidString: "A1111111-1111-4111-8111-111111111109")!,
                name: "Code Scanner (Semgrep, local)",
                url: "http://127.0.0.1:8743/mcp",
                enabled: false,
                presetId: codescanPresetId,
                authStyle: .bearer,
                docsURL: "https://github.com/semgrep/semgrep",
                isEditable: false
            ),
        ]
    }
}

/// In-memory turn log for Preferences-style analysis (last N send/response pairs).
struct ExchangeLogEntry: Identifiable, Hashable {
    enum Status: String, Hashable {
        case completed
        case error
        case cancelled
        case compare
    }

    let id: UUID
    let timestamp: Date
    let prompt: String
    var response: String
    var model: String
    var mode: String
    var status: Status
    var latencyMs: Int?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        prompt: String,
        response: String,
        model: String,
        mode: String,
        status: Status,
        latencyMs: Int? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.prompt = prompt
        self.response = response
        self.model = model
        self.mode = mode
        self.status = status
        self.latencyMs = latencyMs
        self.errorMessage = errorMessage
    }
}

// MARK: - Budget guardrails

/// Session + daily USD soft/hard caps (0 = off). Persisted in UserDefaults.
struct BudgetCaps: Equatable {
    var sessionSoftUsd: Double
    var sessionHardUsd: Double
    var dailySoftUsd: Double
    var dailyHardUsd: Double

    static let stepUsd: Double = 0.5
    static let maxUsd: Double = 100.0
    private static let schemaVersionKey = "aril.budget.schemaVersion"
    /// v2: factory defaults are all Off (0). v1 seeded Soft/Hard at $1/$5 and $5/$20.
    private static let schemaVersion = 2

    /// All caps off until the user enables them.
    static let defaults = BudgetCaps(
        sessionSoftUsd: 0,
        sessionHardUsd: 0,
        dailySoftUsd: 0,
        dailyHardUsd: 0
    )

    /// Pre–v2 factory seed (exact match → migrate to Off).
    private static let legacyFactoryDefaults = BudgetCaps(
        sessionSoftUsd: 1.0,
        sessionHardUsd: 5.0,
        dailySoftUsd: 5.0,
        dailyHardUsd: 20.0
    )

    /// Snap to $0.50 steps within 0…max.
    static func clamped(_ value: Double) -> Double {
        let stepped = (max(0, value) / stepUsd).rounded() * stepUsd
        return min(maxUsd, max(0, stepped))
    }

    static func load(from defaults: UserDefaults = .standard) -> BudgetCaps {
        migrateIfNeeded(defaults: defaults)

        let fallback = BudgetCaps.defaults
        func value(_ key: String, fallback: Double) -> Double {
            if defaults.object(forKey: key) == nil { return fallback }
            return clamped(defaults.double(forKey: key))
        }
        return BudgetCaps(
            sessionSoftUsd: value("aril.budget.sessionSoftUsd", fallback: fallback.sessionSoftUsd),
            sessionHardUsd: value("aril.budget.sessionHardUsd", fallback: fallback.sessionHardUsd),
            dailySoftUsd: value("aril.budget.dailySoftUsd", fallback: fallback.dailySoftUsd),
            dailyHardUsd: value("aril.budget.dailyHardUsd", fallback: fallback.dailyHardUsd)
        )
    }

    /// One-shot: clear the old $1/$5/$5/$20 seed so Soft/Hard start at Off.
    private static func migrateIfNeeded(defaults: UserDefaults) {
        let version = defaults.integer(forKey: schemaVersionKey)
        guard version < schemaVersion else { return }

        let keys = [
            "aril.budget.sessionSoftUsd",
            "aril.budget.sessionHardUsd",
            "aril.budget.dailySoftUsd",
            "aril.budget.dailyHardUsd",
        ]
        let anyStored = keys.contains { defaults.object(forKey: $0) != nil }
        if anyStored {
            let current = BudgetCaps(
                sessionSoftUsd: clamped(defaults.double(forKey: keys[0])),
                sessionHardUsd: clamped(defaults.double(forKey: keys[1])),
                dailySoftUsd: clamped(defaults.double(forKey: keys[2])),
                dailyHardUsd: clamped(defaults.double(forKey: keys[3]))
            )
            if current == legacyFactoryDefaults {
                BudgetCaps.defaults.save(to: defaults)
            }
        }
        // Missing keys already fall back to Off; just stamp the schema.
        defaults.set(schemaVersion, forKey: schemaVersionKey)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(sessionSoftUsd, forKey: "aril.budget.sessionSoftUsd")
        defaults.set(sessionHardUsd, forKey: "aril.budget.sessionHardUsd")
        defaults.set(dailySoftUsd, forKey: "aril.budget.dailySoftUsd")
        defaults.set(dailyHardUsd, forKey: "aril.budget.dailyHardUsd")
        defaults.set(Self.schemaVersion, forKey: Self.schemaVersionKey)
    }
}

enum BudgetGateResult: Equatable {
    case allow
    case softConfirm(message: String)
    case hardBlock(message: String)
}

/// One row from Learning → Run Selected Model Test.
struct EvalLogEntry: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let category: RouteCategory
    let model: String
    let costUsd: Double?
    let ok: Bool
    let detail: String?

    init(
        id: UUID = UUID(),
        prompt: String,
        category: RouteCategory,
        model: String,
        costUsd: Double? = nil,
        ok: Bool,
        detail: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.category = category
        self.model = model
        self.costUsd = costUsd
        self.ok = ok
        self.detail = detail
    }
}

/// Progress for the Learning → Selected Model Test slide-up.
struct ModelTestProgress: Equatable {
    let category: RouteCategory
    let model: String
    let index: Int
    let total: Int
}

/// Fixed category prompts for Learning → Run Selected Model Test (one per route category).
enum AutoEvalPrompts {
    struct Case: Equatable {
        let category: RouteCategory
        let prompt: String
    }

    /// One prompt per Preferences → Models category, in display order.
    static let cases: [Case] = [
        Case(
            category: .coding,
            prompt: "Write a one-line Swift function that returns the larger of two Ints."
        ),
        Case(
            category: .security,
            prompt: "Suggest three secure password storage practices for a web API."
        ),
        Case(
            category: .reasoning,
            prompt: "Reason step by step: if a train leaves at 3pm going 60mph and another at 4pm going 80mph from the same station same direction, when does the second catch up?"
        ),
        Case(
            category: .vision,
            prompt: "Describe how you would analyze a mobile app screenshot for accessibility issues (contrast, tap targets, labels). List five concrete checks."
        ),
        Case(
            category: .cost,
            prompt: "In one short sentence, what is HTTP status code 404?"
        ),
        Case(
            category: .performance,
            prompt: "Reply with only the word: ok"
        ),
        Case(
            category: .confidence,
            prompt: "A production payment API started returning intermittent 500s after a deploy. Outline a rigorous incident triage plan with ordered steps and what evidence to gather at each step."
        ),
        Case(
            category: .general,
            prompt: "Rewrite this sentence more clearly: 'The thing that the team did was they made improvements to the system which resulted in better performance metrics.'"
        ),
    ]

    static var all: [String] { cases.map(\.prompt) }
    static var count: Int { cases.count }
}

