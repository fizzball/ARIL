from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field


class RouteCategory(str, Enum):
    coding = "coding"
    security = "security"
    reasoning = "reasoning"
    vision = "vision"
    cost = "cost"
    performance = "performance"
    confidence = "confidence"
    general = "general"


class RouteMode(str, Enum):
    auto = "auto"
    manual = "manual"
    compare = "compare"


class RoutingProfile(BaseModel):
    """Category → preferred OpenRouter model id."""

    coding: str = "openai/gpt-4.1"
    security: str = "anthropic/claude-sonnet-4"
    reasoning: str = "anthropic/claude-opus-4"
    vision: str = "google/gemini-2.5-flash-image"
    cost: str = "openai/gpt-4.1-mini"
    performance: str = "google/gemini-2.5-flash"
    confidence: str = "anthropic/claude-opus-4"
    general: str = "meta-llama/llama-3.3-70b-instruct"

    def as_map(self) -> dict[RouteCategory, str]:
        return {
            RouteCategory.coding: self.coding,
            RouteCategory.security: self.security,
            RouteCategory.reasoning: self.reasoning,
            RouteCategory.vision: self.vision,
            RouteCategory.cost: self.cost,
            RouteCategory.performance: self.performance,
            RouteCategory.confidence: self.confidence,
            RouteCategory.general: self.general,
        }


class PromptGrade(BaseModel):
    overall: float = Field(ge=0, le=1, description="0=weak, 1=excellent")
    clarity: float = Field(ge=0, le=1)
    constraints: float = Field(ge=0, le=1)
    success_criteria: float = Field(ge=0, le=1)
    token_efficiency: float = Field(ge=0, le=1)
    notes: list[str] = Field(default_factory=list)


class PromptAlternative(BaseModel):
    id: str
    text: str
    rationale: str
    estimated_grade: float = Field(ge=0, le=1)


class ScoreBreakdown(BaseModel):
    """Per-metric scores that combine into the confidence index."""

    category_fit: float = Field(ge=0, le=1)
    cost: float = Field(ge=0, le=1)
    base: float = Field(ge=0, le=1)
    learning: float = Field(ge=0, le=1)
    confidence_index: float = Field(ge=0, le=1)


class ModelEstimate(BaseModel):
    model_id: str
    provider: str
    category_fit: RouteCategory
    estimated_input_tokens: int
    estimated_output_tokens: int
    estimated_cost_usd: float
    score: float
    reasons: list[str] = Field(default_factory=list)
    breakdown: ScoreBreakdown | None = None


class ClassificationResult(BaseModel):
    primary: RouteCategory
    secondary: list[RouteCategory] = Field(default_factory=list)
    confidence: float = Field(ge=0, le=1)


class UserOverrideInsight(BaseModel):
    classification_id: str
    category: RouteCategory
    model: str | None = None
    accuracy: float | None = Field(default=None, ge=0, le=1)
    category_overridden: bool = False
    prompt_snippet: str | None = None


class CacheInsight(BaseModel):
    eligible: bool
    estimated_input_tokens: int
    threshold: int
    would_hit: bool = False
    estimated_savings_pct: float | None = None
    # Tokens still needed to cross the eligibility threshold (0 when eligible).
    tokens_to_eligible: int = 0
    # Prior cached prompt text similar to the draft (offer Edit/Submit for a hit).
    suggested_hit_prompt: str | None = None
    suggested_hit_rationale: str | None = None


class ContextLimitsResponse(BaseModel):
    """Authoritative context-window budgets so clients don't hardcode them."""

    max_total_chars: int
    max_message_chars: int
    cache_token_threshold: int


class PreviewRequest(BaseModel):
    prompt: str = Field(min_length=1)
    temperature: float | None = Field(default=None, ge=0, le=2)
    route_mode: RouteMode = RouteMode.auto
    preferred_model: str | None = None
    session_id: str | None = None
    routing_profile: RoutingProfile | None = None
    enhance_alternatives: bool = True
    # When true and a Learning judgement matches, skip re-grading / LLM rewrite
    # and reuse judgement (+ optional analysis-cache) to save tokens.
    skip_analysis_on_judgement: bool = False
    # After a full analysis (Redo), upsert the Learning judgement for this prompt.
    update_judgement: bool = False
    # Optional Claude.md-style system prompt; counted toward token/cost estimates only.
    system_prompt: str | None = None


class PreviewResponse(BaseModel):
    classification: ClassificationResult
    grade: PromptGrade
    alternatives: list[PromptAlternative]
    recommended_model: str
    routes: list[ModelEstimate]
    cache: CacheInsight
    temperature: float
    route_mode: RouteMode
    alternatives_source: Literal["none", "heuristic", "llm", "cache", "judgement"] = "heuristic"
    user_override: UserOverrideInsight | None = None
    analysis_skipped: bool = False
    # When Auto honors a Prefer win (fingerprint or category).
    preference_reason: str | None = None


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class Attachment(BaseModel):
    filename: str
    mime_type: str
    data_base64: str


class ChatRequest(BaseModel):
    messages: list[ChatMessage]
    model: str | None = None
    temperature: float | None = Field(default=None, ge=0, le=2)
    route_mode: RouteMode = RouteMode.auto
    use_cache: bool = True
    session_id: str | None = None
    preview_id: str | None = None
    routing_profile: RoutingProfile | None = None
    stream: bool = False
    attachments: list[Attachment] = Field(default_factory=list)
    web_search: bool = False
    # Enter before analysis idle timer — chat normally but do not seed Learning.
    skip_auto_judgement: bool = False
    # Ready remote MCP servers for this turn (keys from the Mac Keychain).
    mcp_servers: list[MCPServerInRequest] = Field(default_factory=list)


class ChatResponse(BaseModel):
    session_id: str
    message: ChatMessage
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    cached: bool
    route_category: RouteCategory
    preference_reason: str | None = None


class CompareRequest(BaseModel):
    messages: list[ChatMessage]
    models: list[str] | None = None
    temperature: float | None = Field(default=None, ge=0, le=2)
    routing_profile: RoutingProfile | None = None
    session_id: str | None = None
    use_cache: bool = True
    run_probe: bool = True


class CompareResult(BaseModel):
    model: str
    content: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int
    probe_latency_ms: int | None = None
    cached: bool = False
    error: str | None = None
    suggested_category: RouteCategory | None = None
    category_confidence: float | None = None


class CompareResponse(BaseModel):
    session_id: str
    route_category: RouteCategory
    results: list[CompareResult]
    probe: list[dict] = Field(default_factory=list)


class ProbeRequest(BaseModel):
    models: list[str] = Field(min_length=1)


class ProbeResult(BaseModel):
    model: str
    latency_ms: int
    error: str | None = None


class ProbeResponse(BaseModel):
    results: list[ProbeResult]


class PreferRequest(BaseModel):
    prompt: str
    model: str
    category: RouteCategory | None = None
    accuracy: float | None = Field(default=None, ge=0, le=1)
    category_overridden: bool = False
    session_id: str | None = None


class PreferResponse(BaseModel):
    ok: bool
    category: str
    fingerprint: str
    model: str
    category_wins: int
    fingerprint_wins: int
    classification_id: str | None = None
    accuracy: float | None = None
    category_overridden: bool = False


class ClassificationUpdateRequest(BaseModel):
    category: RouteCategory | None = None
    accuracy: float | None = Field(default=None, ge=0, le=1)
    model: str | None = None
    remove_accuracy: bool = False


class ClassificationRecord(BaseModel):
    id: str
    prompt: str = ""
    prompt_snippet: str = ""
    fingerprint: str
    category: str
    model: str
    accuracy: float | None = None
    category_overridden: bool = False
    created_at: str | None = None
    updated_at: str | None = None


class PreferencesSnapshot(BaseModel):
    category_wins: dict[str, dict[str, int]] = Field(default_factory=dict)
    fingerprint_wins: dict[str, dict[str, int]] = Field(default_factory=dict)
    classifications: list[ClassificationRecord] = Field(default_factory=list)


class StoreRecord(BaseModel):
    id: str
    kind: str  # judgement | analysis_cache | chat_transaction
    prompt_snippet: str = ""
    fingerprint: str = ""
    category: str | None = None
    model: str | None = None
    accuracy: float | None = None
    category_overridden: bool | None = None
    cached: bool | None = None
    cost_usd: float | None = None
    input_tokens: int | None = None
    output_tokens: int | None = None
    session_id: str | None = None
    created_at: str | None = None
    updated_at: str | None = None


class StoreStats(BaseModel):
    retention: int
    counts: dict[str, int] = Field(default_factory=dict)
    total: int = 0


class StoreStatus(BaseModel):
    ready: bool
    engine: str = "sqlite"
    path: str
    absolute_path: str
    exists: bool = False
    writable: bool = False
    size_bytes: int = 0
    retention: int = 100
    counts: dict[str, int] = Field(default_factory=dict)
    total: int = 0
    message: str = ""
    checked_at: str | None = None


class StoreRetentionUpdate(BaseModel):
    retention: int = Field(ge=1, le=10000)


class StoreDeleteAllResponse(BaseModel):
    ok: bool = True
    deleted: dict[str, int] = Field(default_factory=dict)


class SessionSummary(BaseModel):
    id: str
    title: str
    updated_at: str
    message_count: int


class SessionDetail(BaseModel):
    id: str
    title: str
    updated_at: str
    messages: list[ChatMessage]


class SessionUpsert(BaseModel):
    id: str | None = None
    title: str = "New session"
    messages: list[ChatMessage] = Field(default_factory=list)


class OpenRouterKeyStatus(BaseModel):
    configured: bool
    masked_key: str = ""
    required: bool = True


class OpenRouterConnectionStatus(BaseModel):
    """Result of Preferences → OpenRouter “Check connection”."""

    ready: bool
    configured: bool
    masked_key: str = ""
    latency_ms: int | None = None
    message: str = ""
    checked_at: str | None = None
    # Remaining USD when OpenRouter reports account balance or a key limit.
    credits_remaining: float | None = None
    credits_source: str | None = None


class ModelPricing(BaseModel):
    id: str
    prompt_per_1k: float
    completion_per_1k: float
    web_search_per_request: float = 0.005
    source: str = "fallback"


class ModelPricingResponse(BaseModel):
    models: list[ModelPricing]
    refreshed: bool = False


class OpenRouterCatalogModel(BaseModel):
    id: str
    name: str
    prompt_per_1k: float
    completion_per_1k: float
    web_search_per_request: float = 0.005
    context_length: int | None = None
    input_modalities: list[str] = Field(default_factory=list)
    output_modalities: list[str] = Field(default_factory=list)


class OpenRouterCatalogResponse(BaseModel):
    models: list[OpenRouterCatalogModel]
    count: int
    refreshed: bool = False


class OpenRouterWeeklyRankingModel(BaseModel):
    rank: int
    id: str
    name: str
    prompt_per_1k: float = 0.0
    completion_per_1k: float = 0.0


class OpenRouterWeeklyRankingsResponse(BaseModel):
    models: list[OpenRouterWeeklyRankingModel]
    count: int
    period: str = "top-weekly"
    refreshed: bool = False
    source: str = "openrouter"


class OpenRouterKeyUpdate(BaseModel):
    api_key: str = Field(min_length=1)


class MCPCheckRequest(BaseModel):
    url: str = Field(min_length=1)
    auth_style: str = "bearer"
    auth_header_name: str | None = None
    api_key: str | None = None


class MCPCheckResponse(BaseModel):
    ok: bool
    tools_count: int | None = None
    tool_names: list[str] = Field(default_factory=list)
    latency_ms: int | None = None
    message: str
    checked_at: float | None = None


class MCPServerInRequest(BaseModel):
    """Per-turn MCP server config from the macOS client (secrets not stored on gateway)."""

    id: str = ""
    name: str = ""
    url: str = Field(min_length=1)
    auth_style: str = "bearer"
    auth_header_name: str | None = None
    api_key: str | None = None

