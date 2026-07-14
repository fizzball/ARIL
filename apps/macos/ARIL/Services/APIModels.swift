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

    enum CodingKeys: String, CodingKey {
        case prompt, temperature
        case routeMode = "route_mode"
        case preferredModel = "preferred_model"
        case sessionId = "session_id"
        case routingProfile = "routing_profile"
        case enhanceAlternatives = "enhance_alternatives"
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

    enum CodingKeys: String, CodingKey {
        case classification, grade, alternatives, routes, cache, temperature
        case recommendedModel = "recommended_model"
        case routeMode = "route_mode"
        case alternativesSource = "alternatives_source"
        case userOverride = "user_override"
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

    enum CodingKeys: String, CodingKey {
        case messages, model, temperature, attachments
        case routeMode = "route_mode"
        case useCache = "use_cache"
        case sessionId = "session_id"
        case previewId = "preview_id"
        case routingProfile = "routing_profile"
        case webSearch = "web_search"
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

    enum CodingKeys: String, CodingKey {
        case model, cached
        case sessionId = "session_id"
        case routeCategory = "route_category"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUsd = "cost_usd"
        case latencyMs = "latency_ms"
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

struct OpenRouterKeyUpdateDTO: Encodable {
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
    }
}
