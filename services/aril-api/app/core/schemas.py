from __future__ import annotations

from enum import Enum
from typing import Literal

from pydantic import BaseModel, Field


class RouteCategory(str, Enum):
    coding = "coding"
    security = "security"
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
    cost: str = "openai/gpt-4.1-mini"
    performance: str = "openai/gpt-4.1-mini"
    confidence: str = "anthropic/claude-opus-4"
    general: str = "openai/gpt-4.1"

    def as_map(self) -> dict[RouteCategory, str]:
        return {
            RouteCategory.coding: self.coding,
            RouteCategory.security: self.security,
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


class ModelEstimate(BaseModel):
    model_id: str
    provider: str
    category_fit: RouteCategory
    estimated_input_tokens: int
    estimated_output_tokens: int
    estimated_cost_usd: float
    score: float
    reasons: list[str] = Field(default_factory=list)


class ClassificationResult(BaseModel):
    primary: RouteCategory
    secondary: list[RouteCategory] = Field(default_factory=list)
    confidence: float = Field(ge=0, le=1)


class CacheInsight(BaseModel):
    eligible: bool
    estimated_input_tokens: int
    threshold: int
    would_hit: bool = False
    estimated_savings_pct: float | None = None


class PreviewRequest(BaseModel):
    prompt: str = Field(min_length=1)
    temperature: float | None = Field(default=None, ge=0, le=2)
    route_mode: RouteMode = RouteMode.auto
    preferred_model: str | None = None
    session_id: str | None = None
    routing_profile: RoutingProfile | None = None
    enhance_alternatives: bool = True


class PreviewResponse(BaseModel):
    classification: ClassificationResult
    grade: PromptGrade
    alternatives: list[PromptAlternative]
    recommended_model: str
    routes: list[ModelEstimate]
    cache: CacheInsight
    temperature: float
    route_mode: RouteMode
    alternatives_source: Literal["none", "heuristic", "llm"] = "heuristic"


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


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


class ChatResponse(BaseModel):
    session_id: str
    message: ChatMessage
    model: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    cached: bool
    route_category: RouteCategory


class CompareRequest(BaseModel):
    messages: list[ChatMessage]
    models: list[str] | None = None
    temperature: float | None = Field(default=None, ge=0, le=2)
    routing_profile: RoutingProfile | None = None
    session_id: str | None = None
    use_cache: bool = True


class CompareResult(BaseModel):
    model: str
    content: str
    input_tokens: int
    output_tokens: int
    cost_usd: float
    latency_ms: int
    cached: bool = False
    error: str | None = None


class CompareResponse(BaseModel):
    session_id: str
    route_category: RouteCategory
    results: list[CompareResult]


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
