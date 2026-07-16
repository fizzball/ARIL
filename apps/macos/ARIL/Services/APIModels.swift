import Foundation

struct HealthResponse: Codable {
    let status: String
    let service: String?
    let version: String?
    let env: String?
    let gateway: String?
    let chatProvider: String?
    let openrouterConfigured: Bool?

    enum CodingKeys: String, CodingKey {
        case status, service, version, env, gateway
        case chatProvider = "chat_provider"
        case openrouterConfigured = "openrouter_configured"
    }
}

struct APIRoutingProfile: Codable, Equatable {
    var coding: String
    var security: String
    var reasoning: String
    var vision: String
    var cost: String
    var performance: String
    var confidence: String
    var general: String

    init(_ profile: RoutingProfile) {
        coding = profile.coding
        security = profile.security
        reasoning = profile.reasoning
        vision = profile.vision
        cost = profile.cost
        performance = profile.performance
        confidence = profile.confidence
        general = profile.general
    }
}

struct PreviewRequest: Encodable {
    let prompt: String
    let temperature: Double?
    let routeMode: RouteMode
    let preferredModel: String?
    let sessionId: String?
    let routingProfile: APIRoutingProfile?
    let enhanceAlternatives: Bool
    let skipAnalysisOnJudgement: Bool
    let updateJudgement: Bool
    let systemPrompt: String?

    enum CodingKeys: String, CodingKey {
        case prompt, temperature
        case routeMode = "route_mode"
        case preferredModel = "preferred_model"
        case sessionId = "session_id"
        case routingProfile = "routing_profile"
        case enhanceAlternatives = "enhance_alternatives"
        case skipAnalysisOnJudgement = "skip_analysis_on_judgement"
        case updateJudgement = "update_judgement"
        case systemPrompt = "system_prompt"
    }
}

struct PreviewResponse: Codable, Equatable {
    let classification: ClassificationResult
    let grade: PromptGrade
    let alternatives: [PromptAlternative]
    let recommendedModel: String
    let routes: [ModelEstimate]
    let cache: CacheInsight
    let temperature: Double
    let routeMode: RouteMode
    let alternativesSource: String?
    let userOverride: UserOverrideInsight?
    let analysisSkipped: Bool?
    /// When Auto honors a Prefer win (fingerprint or category).
    let preferenceReason: String?

    enum CodingKeys: String, CodingKey {
        case classification, grade, alternatives, routes, cache, temperature
        case recommendedModel = "recommended_model"
        case routeMode = "route_mode"
        case alternativesSource = "alternatives_source"
        case userOverride = "user_override"
        case analysisSkipped = "analysis_skipped"
        case preferenceReason = "preference_reason"
    }
}

struct UserOverrideInsight: Codable, Equatable {
    let classificationId: String
    let category: RouteCategory
    let model: String?
    let accuracy: Double?
    let categoryOverridden: Bool
    let promptSnippet: String?

    enum CodingKeys: String, CodingKey {
        case category, model, accuracy
        case classificationId = "classification_id"
        case categoryOverridden = "category_overridden"
        case promptSnippet = "prompt_snippet"
    }
}

struct ClassificationResult: Codable, Equatable {
    let primary: RouteCategory
    let secondary: [RouteCategory]
    let confidence: Double
}

struct PromptGrade: Codable, Equatable {
    let overall: Double
    let clarity: Double
    let constraints: Double
    let successCriteria: Double
    let tokenEfficiency: Double
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case overall, clarity, constraints, notes
        case successCriteria = "success_criteria"
        case tokenEfficiency = "token_efficiency"
    }
}

struct PromptAlternative: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let rationale: String
    let estimatedGrade: Double

    enum CodingKeys: String, CodingKey {
        case id, text, rationale
        case estimatedGrade = "estimated_grade"
    }
}

struct ScoreBreakdown: Codable, Equatable {
    let categoryFit: Double
    let cost: Double
    let base: Double
    let learning: Double
    let confidenceIndex: Double

    enum CodingKeys: String, CodingKey {
        case cost, base, learning
        case categoryFit = "category_fit"
        case confidenceIndex = "confidence_index"
    }
}

struct ModelEstimate: Codable, Equatable, Identifiable {
    var id: String { modelId }
    let modelId: String
    let provider: String
    let categoryFit: RouteCategory
    let estimatedInputTokens: Int
    let estimatedOutputTokens: Int
    let estimatedCostUsd: Double
    let score: Double
    let reasons: [String]
    let breakdown: ScoreBreakdown?

    enum CodingKeys: String, CodingKey {
        case provider, score, reasons, breakdown
        case modelId = "model_id"
        case categoryFit = "category_fit"
        case estimatedInputTokens = "estimated_input_tokens"
        case estimatedOutputTokens = "estimated_output_tokens"
        case estimatedCostUsd = "estimated_cost_usd"
    }
}

struct CacheInsight: Codable, Equatable {
    let eligible: Bool
    let estimatedInputTokens: Int
    let threshold: Int
    let wouldHit: Bool
    let estimatedSavingsPct: Double?

    enum CodingKeys: String, CodingKey {
        case eligible, threshold
        case estimatedInputTokens = "estimated_input_tokens"
        case wouldHit = "would_hit"
        case estimatedSavingsPct = "estimated_savings_pct"
    }
}

struct APIChatMessage: Codable {
    let role: String
    let content: String
}

struct MCPServerInRequestDTO: Encodable {
    let id: String
    let name: String
    let url: String
    let authStyle: String
    let authHeaderName: String?
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url
        case authStyle = "auth_style"
        case authHeaderName = "auth_header_name"
        case apiKey = "api_key"
    }
}

struct ChatRequest: Encodable {
    let messages: [APIChatMessage]
    let model: String?
    let temperature: Double?
    let routeMode: RouteMode
    let useCache: Bool
    let sessionId: String?
    let previewId: String?
    let routingProfile: APIRoutingProfile?
    let attachments: [AttachmentDTO]
    let webSearch: Bool
    /// Enter before analysis idle timer — chat normally but do not seed Learning.
    let skipAutoJudgement: Bool
    let mcpServers: [MCPServerInRequestDTO]

    enum CodingKeys: String, CodingKey {
        case messages, model, temperature, attachments
        case routeMode = "route_mode"
        case useCache = "use_cache"
        case sessionId = "session_id"
        case previewId = "preview_id"
        case routingProfile = "routing_profile"
        case webSearch = "web_search"
        case skipAutoJudgement = "skip_auto_judgement"
        case mcpServers = "mcp_servers"
    }
}

struct AttachmentDTO: Encodable {
    let filename: String
    let mimeType: String
    let dataBase64: String

    enum CodingKeys: String, CodingKey {
        case filename
        case mimeType = "mime_type"
        case dataBase64 = "data_base64"
    }
}

struct ChatResponseDTO: Codable {
    let sessionId: String
    let message: APIChatMessage
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUsd: Double
    let cached: Bool
    let routeCategory: RouteCategory

    enum CodingKeys: String, CodingKey {
        case message, model, cached
        case sessionId = "session_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case routeCategory = "route_category"
    }
}

struct SessionSummaryDTO: Codable, Identifiable {
    let id: String
    let title: String
    let updatedAt: String
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
        case messageCount = "message_count"
    }
}

struct SessionDetailDTO: Codable {
    let id: String
    let title: String
    let updatedAt: String
    let messages: [APIChatMessage]

    enum CodingKeys: String, CodingKey {
        case id, title, messages
        case updatedAt = "updated_at"
    }
}

struct SessionUpsertDTO: Encodable {
    let id: String?
    let title: String
    let messages: [APIChatMessage]
}

struct StreamDoneEvent: Codable {
    let sessionId: String
    let model: String
    let routeCategory: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let costUsd: Double?
    let cached: Bool?
    let latencyMs: Int?
    let preferenceReason: String?

    enum CodingKeys: String, CodingKey {
        case model, cached
        case sessionId = "session_id"
        case routeCategory = "route_category"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case latencyMs = "latency_ms"
        case preferenceReason = "preference_reason"
    }
}

struct ProbeRequestDTO: Encodable {
    let models: [String]
}

struct ProbeResultDTO: Codable {
    let model: String
    let latencyMs: Int
    let error: String?

    enum CodingKeys: String, CodingKey {
        case model, error
        case latencyMs = "latency_ms"
    }
}

struct ProbeResponseDTO: Codable {
    let results: [ProbeResultDTO]
}

struct StreamTokenEvent: Codable {
    let content: String
    let model: String?
}

struct CompareRequestDTO: Encodable {
    let messages: [APIChatMessage]
    let models: [String]?
    let temperature: Double?
    let routingProfile: APIRoutingProfile?
    let sessionId: String?
    let useCache: Bool
    let runProbe: Bool

    enum CodingKeys: String, CodingKey {
        case messages, models, temperature
        case routingProfile = "routing_profile"
        case sessionId = "session_id"
        case useCache = "use_cache"
        case runProbe = "run_probe"
    }
}

struct CompareResultDTO: Codable, Identifiable {
    var id: String { "\(model)-\(latencyMs)-\(inputTokens)-\(outputTokens)" }
    let model: String
    let content: String
    let inputTokens: Int
    let outputTokens: Int
    let costUsd: Double
    let latencyMs: Int
    let probeLatencyMs: Int?
    let cached: Bool
    let error: String?
    let suggestedCategory: RouteCategory?
    let categoryConfidence: Double?

    enum CodingKeys: String, CodingKey {
        case model, content, cached, error
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case latencyMs = "latency_ms"
        case probeLatencyMs = "probe_latency_ms"
        case suggestedCategory = "suggested_category"
        case categoryConfidence = "category_confidence"
    }
}

struct CompareResponseDTO: Codable {
    let sessionId: String
    let routeCategory: RouteCategory
    let results: [CompareResultDTO]

    enum CodingKeys: String, CodingKey {
        case results
        case sessionId = "session_id"
        case routeCategory = "route_category"
    }
}

struct PreferRequestDTO: Encodable {
    let prompt: String
    let model: String
    let category: RouteCategory?
    let accuracy: Double?
    let categoryOverridden: Bool
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case prompt, model, category, accuracy
        case categoryOverridden = "category_overridden"
        case sessionId = "session_id"
    }
}

struct PreferResponseDTO: Codable {
    let ok: Bool
    let category: String
    let fingerprint: String
    let model: String
    let categoryWins: Int?
    let fingerprintWins: Int?
    let classificationId: String?
    let accuracy: Double?
    let categoryOverridden: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, category, fingerprint, model, accuracy
        case categoryWins = "category_wins"
        case fingerprintWins = "fingerprint_wins"
        case classificationId = "classification_id"
        case categoryOverridden = "category_overridden"
    }
}

struct ClassificationRecordDTO: Codable, Identifiable, Equatable {
    let id: String
    let prompt: String
    let promptSnippet: String
    let fingerprint: String
    let category: String
    let model: String
    let accuracy: Double?
    let categoryOverridden: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, prompt, fingerprint, category, model, accuracy
        case promptSnippet = "prompt_snippet"
        case categoryOverridden = "category_overridden"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct PreferencesSnapshotDTO: Codable {
    let classifications: [ClassificationRecordDTO]
    let categoryWins: [String: [String: Int]]?
    let fingerprintWins: [String: [String: Int]]?

    enum CodingKeys: String, CodingKey {
        case classifications
        case categoryWins = "category_wins"
        case fingerprintWins = "fingerprint_wins"
    }
}

struct StoreRecordDTO: Codable, Identifiable, Equatable {
    let id: String
    let kind: String
    let promptSnippet: String
    let fingerprint: String
    let category: String?
    let model: String?
    let accuracy: Double?
    let categoryOverridden: Bool?
    let cached: Bool?
    let costUsd: Double?
    let sessionId: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, fingerprint, category, model, accuracy, cached
        case promptSnippet = "prompt_snippet"
        case categoryOverridden = "category_overridden"
        case costUsd = "cost_usd"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var kindLabel: String {
        switch kind {
        case "judgement": return "Judgement"
        case "analysis_cache": return "Analysis cache"
        case "chat_transaction": return "Chat transaction"
        default: return kind
        }
    }
}

struct StoreStatsDTO: Codable, Equatable {
    let retention: Int
    let counts: [String: Int]
    let total: Int
}

struct StoreStatusDTO: Codable, Equatable {
    let ready: Bool
    let engine: String
    let path: String
    let absolutePath: String
    let exists: Bool
    let writable: Bool
    let sizeBytes: Int
    let retention: Int
    let counts: [String: Int]
    let total: Int
    let message: String
    let checkedAt: String?

    enum CodingKeys: String, CodingKey {
        case ready, engine, path, exists, writable, retention, counts, total, message
        case absolutePath = "absolute_path"
        case sizeBytes = "size_bytes"
        case checkedAt = "checked_at"
    }

    var sizeLabel: String {
        if sizeBytes < 1024 { return "\(sizeBytes) B" }
        let kb = Double(sizeBytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.2f MB", kb / 1024.0)
    }
}

struct StoreRetentionUpdateDTO: Encodable {
    let retention: Int
}

struct StoreDeleteAllResponseDTO: Codable {
    let ok: Bool
    let deleted: [String: Int]
}

struct ClassificationUpdateDTO: Encodable {
    let category: RouteCategory?
    let accuracy: Double?
    let model: String?
    let removeAccuracy: Bool

    enum CodingKeys: String, CodingKey {
        case category, accuracy, model
        case removeAccuracy = "remove_accuracy"
    }
}

struct OpenRouterKeyStatusDTO: Codable {
    let configured: Bool
    let maskedKey: String
    let required: Bool

    enum CodingKeys: String, CodingKey {
        case configured, required
        case maskedKey = "masked_key"
    }
}

struct OpenRouterConnectionStatusDTO: Codable, Equatable {
    let ready: Bool
    let configured: Bool
    let maskedKey: String
    let latencyMs: Int?
    let message: String
    let checkedAt: String?
    let creditsRemaining: Double?
    let creditsSource: String?

    enum CodingKeys: String, CodingKey {
        case ready, configured, message
        case maskedKey = "masked_key"
        case latencyMs = "latency_ms"
        case checkedAt = "checked_at"
        case creditsRemaining = "credits_remaining"
        case creditsSource = "credits_source"
    }
}

struct OpenRouterKeyUpdateDTO: Encodable {
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}

struct MCPCheckRequestDTO: Encodable {
    let url: String
    let authStyle: String
    let authHeaderName: String?
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case url
        case authStyle = "auth_style"
        case authHeaderName = "auth_header_name"
        case apiKey = "api_key"
    }
}

struct MCPCheckResponseDTO: Codable {
    let ok: Bool
    let toolsCount: Int?
    let toolNames: [String]?
    let latencyMs: Int?
    let message: String
    let checkedAt: Double?

    enum CodingKeys: String, CodingKey {
        case ok, message
        case toolsCount = "tools_count"
        case toolNames = "tool_names"
        case latencyMs = "latency_ms"
        case checkedAt = "checked_at"
    }
}

struct ModelPricingDTO: Codable, Identifiable, Equatable {
    let id: String
    let promptPer1k: Double
    let completionPer1k: Double
    let webSearchPerRequest: Double?
    let source: String

    enum CodingKeys: String, CodingKey {
        case id, source
        case promptPer1k = "prompt_per_1k"
        case completionPer1k = "completion_per_1k"
        case webSearchPerRequest = "web_search_per_request"
    }

    /// OpenRouter web plugin fee (USD / search). Falls back to Exa default $0.005.
    var webSearchFee: Double {
        let fee = webSearchPerRequest ?? 0.005
        return fee > 0 ? fee : 0.005
    }
}

struct ModelPricingResponseDTO: Codable {
    let models: [ModelPricingDTO]
    let refreshed: Bool?
}

struct OpenRouterCatalogModelDTO: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let promptPer1k: Double
    let completionPer1k: Double
    let webSearchPerRequest: Double?
    let contextLength: Int?
    let inputModalities: [String]?
    let outputModalities: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name
        case promptPer1k = "prompt_per_1k"
        case completionPer1k = "completion_per_1k"
        case webSearchPerRequest = "web_search_per_request"
        case contextLength = "context_length"
        case inputModalities = "input_modalities"
        case outputModalities = "output_modalities"
    }

    var pricingLabel: String {
        String(format: "$%.4f / $%.4f per 1K", promptPer1k, completionPer1k)
    }

    /// True when the catalog lists image as an input modality.
    var acceptsImageInput: Bool? {
        guard let mods = inputModalities, !mods.isEmpty else { return nil }
        return mods.contains { $0.caseInsensitiveCompare("image") == .orderedSame }
    }

    /// True when the catalog lists image as an output modality (image-gen).
    var emitsImageOutput: Bool? {
        guard let mods = outputModalities, !mods.isEmpty else { return nil }
        return mods.contains { $0.caseInsensitiveCompare("image") == .orderedSame }
    }
}

struct OpenRouterCatalogResponseDTO: Codable {
    let models: [OpenRouterCatalogModelDTO]
    let count: Int
    let refreshed: Bool?
}

struct OpenRouterWeeklyRankingDTO: Codable, Identifiable, Equatable, Hashable {
    let rank: Int
    let id: String
    let name: String
    let promptPer1k: Double?
    let completionPer1k: Double?

    enum CodingKeys: String, CodingKey {
        case rank, id, name
        case promptPer1k = "prompt_per_1k"
        case completionPer1k = "completion_per_1k"
    }

    var pricingLabel: String? {
        guard let prompt = promptPer1k, let completion = completionPer1k else { return nil }
        return String(format: "$%.4f / $%.4f per 1K", prompt, completion)
    }
}

struct OpenRouterWeeklyRankingsResponseDTO: Codable {
    let models: [OpenRouterWeeklyRankingDTO]
    let count: Int
    let period: String?
    let refreshed: Bool?
    let source: String?
}
