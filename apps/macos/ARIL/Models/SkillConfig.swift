import Foundation

/// Built-in and future user-defined ARIL skills (local capabilities, not MCP tools).
struct SkillConfig: Identifiable, Codable, Hashable {
    /// Stable skill id (e.g. `document-export`).
    var id: String
    var name: String
    var summary: String
    var enabled: Bool
    /// Factory skills cannot be deleted from Preferences.
    var isBuiltIn: Bool
    /// Tokens accepted after `@` in the prompt (e.g. `OS`, `os-access`).
    var mentionTags: [String]

    static let documentExportId = "document-export"
    static let osAccessId = "os-access"

    /// Canonical short `@` tag shown when inserting from the picker.
    var primaryMentionTag: String {
        mentionTags.first ?? id
    }

    func matchesMention(_ raw: String) -> Bool {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
        guard !q.isEmpty else { return false }
        if id.lowercased() == q { return true }
        if name.lowercased() == q { return true }
        return mentionTags.contains { $0.lowercased() == q }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, enabled, isBuiltIn, mentionTags
    }

    init(
        id: String,
        name: String,
        summary: String,
        enabled: Bool,
        isBuiltIn: Bool,
        mentionTags: [String]
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.enabled = enabled
        self.isBuiltIn = isBuiltIn
        self.mentionTags = mentionTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decode(String.self, forKey: .summary)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? true
        mentionTags = try c.decodeIfPresent([String].self, forKey: .mentionTags) ?? []
    }

    static func builtInPresets() -> [SkillConfig] {
        [
            SkillConfig(
                id: documentExportId,
                name: "Document Export",
                summary: "Save a reply as Word (.docx) or PDF. Use @Document to auto-save after the reply, or /save pdf|docx anytime.",
                enabled: true,
                isBuiltIn: true,
                mentionTags: ["Document", "export", "document-export", "docx", "pdf"]
            ),
            SkillConfig(
                id: osAccessId,
                name: "OS Access",
                summary: "Run local terminal commands (e.g. dig, ls) and report results. Use @OS to force this skill.",
                enabled: true,
                isBuiltIn: true,
                mentionTags: ["OS", "os-access", "shell", "terminal"]
            ),
        ]
    }
}

/// Parsed `@Skill` mentions from a user prompt.
struct SkillMentionParse {
    /// Skill ids referenced via `@…`.
    var mentionedIds: [String]
    /// Prompt text with `@mentions` removed (collapsed whitespace preserved lightly).
    var cleanedPrompt: String
    /// Original prompt.
    var originalPrompt: String
}
