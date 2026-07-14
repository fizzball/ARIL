import Foundation

struct HealthResponse: Codable {
    let status: String
    let service: String?
    let version: String?
    let env: String?
    let gateway: String?
}

struct PreviewRequest: Encodable {
    let prompt: String
    let temperature: Double?
    let routeMode: RouteMode
    let preferredModel: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case prompt, temperature
        case routeMode = "route_mode"
        case preferredModel = "preferred_model"
        case sessionId = "session_id"
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

    enum CodingKeys: String, CodingKey {
        case classification, grade, alternatives, routes, cache, temperature
        case recommendedModel = "recommended_model"
        case routeMode = "route_mode"
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

    enum CodingKeys: String, CodingKey {
        case provider, score, reasons
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

    enum CodingKeys: String, CodingKey {
        case messages, model, temperature
        case routeMode = "route_mode"
        case useCache = "use_cache"
        case sessionId = "session_id"
        case previewId = "preview_id"
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
