import Foundation

struct ChatSession: Identifiable, Hashable {
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

struct ChatMessage: Identifiable, Hashable {
    enum Role: String, Hashable {
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

enum RouteMode: String, CaseIterable, Identifiable, Codable {
    case auto, manual, compare
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .compare: return "Compare"
        }
    }
}

enum RouteCategory: String, CaseIterable, Codable, Identifiable {
    case coding, security, cost, performance, confidence, general
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct RoutingProfile: Hashable, Codable {
    var coding: String
    var security: String
    var cost: String
    var performance: String
    var confidence: String
    var general: String

    static let `default` = RoutingProfile(
        coding: "openai/gpt-4.1",
        security: "anthropic/claude-sonnet-4",
        cost: "openai/gpt-4.1-mini",
        performance: "openai/gpt-4.1-mini",
        confidence: "anthropic/claude-opus-4",
        general: "openai/gpt-4.1"
    )
}
