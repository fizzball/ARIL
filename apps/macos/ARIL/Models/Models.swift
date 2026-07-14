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

struct ChatSession: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, messages: [ChatMessage], updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    enum Role: String, Hashable, Codable {
        case system, user, assistant
    }

    let id: UUID
    var role: Role
    var content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
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
    case stdio
    case sse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stdio: return "stdio (local command)"
        case .sse: return "SSE / HTTP"
        }
    }
}

/// User-configured MCP server entry (Preferences). Runtime wiring can consume this list later.
struct MCPServerConfig: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var transport: MCPTransport
    /// Executable for stdio, or base URL for SSE/HTTP.
    var endpoint: String
    /// Optional argv for stdio (space-separated).
    var args: String
    var enabled: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        transport: MCPTransport = .stdio,
        endpoint: String = "",
        args: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.endpoint = endpoint
        self.args = args
        self.enabled = enabled
    }

    var isReady: Bool {
        enabled && !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let leaf = endpoint.split(separator: "/").last.map(String.init) ?? endpoint
        return leaf.isEmpty ? "Untitled MCP server" : leaf
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
