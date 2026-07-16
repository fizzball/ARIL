import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

enum AnalysisStatus: Equatable {
    case idle
    case analysing(secondsRemaining: Double)
    case ready
}

enum GenerationPhase: Equatable {
    case idle
    case thinking
    case streaming

    var label: String {
        switch self {
        case .idle: return ""
        case .thinking: return "Thinking"
        case .streaming: return "Streaming"
        }
    }
}

/// Trailing flyout opened from the toolbar.
enum ToolPanel: String, Identifiable, Equatable {
    case modelCosts
    case learning
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modelCosts: return "Model costs"
        case .learning: return "Learning"
        case .about: return "About ARIL"
        }
    }

    /// Shared flyout width for every tools panel.
    static let flyoutWidth: CGFloat = 560
}

@MainActor
final class AppState: ObservableObject {
    static let modelCatalog = [
        "openai/gpt-4.1",
        "openai/gpt-4.1-mini",
        "anthropic/claude-sonnet-4",
        "anthropic/claude-opus-4",
        "google/gemini-2.5-flash",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    /// Factory default for Preferences → Models (app default picker).
    static let factoryDefaultModel = "openai/gpt-4.1"

    /// Built-in USD / 1K rates used when OpenRouter isn’t configured or pricing can’t be fetched.
    /// Keep in sync with `services/aril-api/app/routing/pricing.py` FALLBACK_COST_PER_1K.
    static let fallbackModelPricing: [String: (promptPer1k: Double, completionPer1k: Double)] = [
        "openai/gpt-4.1": (0.002, 0.008),
        "openai/gpt-4.1-mini": (0.0004, 0.0016),
        "anthropic/claude-sonnet-4": (0.003, 0.015),
        "anthropic/claude-opus-4": (0.015, 0.075),
        "google/gemini-2.5-flash": (0.0003, 0.0025),
        "google/gemini-2.5-flash-image": (0.0003, 0.0025),
        "meta-llama/llama-3.3-70b-instruct": (0.0001, 0.0003),
    ]

    private static let genericFallbackPromptPer1k = 0.01
    private static let genericFallbackCompletionPer1k = 0.03
    private static let defaultWebSearchPerRequest = 0.005

    /// Seconds of typing idle before prompt analysis runs (Preferences; 0…10, step 0.5).
    @Published var analysisIdleSeconds: Double = 2.0
    /// When on, matching Learning judgements skip re-analysis / rewrite LLM (token saver).
    @Published var skipAnalysisOnJudgement: Bool = true
    /// When on, show ARIL in the macOS menu bar (Preferences).
    @Published var showInMenuBar: Bool = false
    /// Master switch — when on, enabled MCP server entries are considered configured.
    @Published var mcpEnabled: Bool = false
    @Published var mcpServers: [MCPServerConfig] = []
    /// When on, `systemPrompt` is sent as a system message on every chat/compare request.
    @Published var systemPromptEnabled: Bool = false
    @Published var systemPrompt: String = ""
    /// True when the editor differs from the last persisted value (enables Save).
    @Published var systemPromptDirty: Bool = false
    /// Snapshot of last persisted prompt text (for dirty checks).
    private var systemPromptBaseline: String = ""

    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionID: UUID?
    @Published var draft: String = ""
    /// Preference default — persisted; applied to session temperature on launch / when prefs change.
    @Published var defaultTemperature: Double = 0.7
    /// Session temperature used by analysis + sends; resets to `defaultTemperature` on launch.
    @Published var temperature: Double = 0.7
    @Published var routeMode: RouteMode = .auto
    @Published var selectedModel: String
    @Published var defaultModel: String
    @Published var gatewayURL: String
    @Published var soloMode: Bool
    @Published var gatewayReady: Bool = false
    @Published var gatewayStatus: String = "Gateway offline"
    @Published var databaseReady: Bool = false
    @Published var databaseStatus: String = "Database not ready"
    @Published var databasePath: String = ""
    @Published var databaseDetail: String = ""
    @Published var databaseEngine: String = "sqlite"
    @Published var databaseSizeLabel: String = "—"
    @Published var databaseCheckMessage: String?
    @Published var chatProvider: String = "stub"
    @Published var preview: PreviewResponse?
    /// Draft text for which we last showed a judgement-skipped analysis (avoid re-runs).
    private var lastJudgementSkipPrompt: String = ""
    /// After Redo Analysis, keep the fresh full result until the draft changes.
    private var pinnedFullAnalysisPrompt: String = ""
    @Published var analysisStatus: AnalysisStatus = .idle
    @Published var isPreviewing: Bool = false
    @Published var isSending: Bool = false
    @Published var generationPhase: GenerationPhase = .idle
    @Published var generationElapsedMs: Int = 0
    @Published var routingProfile: RoutingProfile = AppState.loadRoutingProfile()
    @Published var showIntelligencePanel: Bool = false
    /// Single trailing tools flyout (Preferences, Model Costs, Learning, About).
    @Published var activeToolPanel: ToolPanel?
    @Published var lastError: String?
    @Published var compareResults: [CompareResultDTO] = []
    /// Prompt capability category used to pick the 3 Judge peer models.
    @Published var compareRouteCategory: RouteCategory?
    @Published var lastCacheLabel: String = "—"
    @Published var lastLatencyMs: Int?
    @Published var estimatedLatencyMs: Int?
    @Published var preferredCompareModel: String?
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published var webSearchEnabled: Bool = false
    @Published var userDisplayName: String
    @Published var showRoutingAnalysis: Bool = false
    @Published var showExchangeLog: Bool = false
    @Published var exchangeLog: [ExchangeLogEntry] = []
    @Published var classifications: [ClassificationRecordDTO] = []
    @Published var storeRecords: [StoreRecordDTO] = []
    @Published var storeStats: StoreStatsDTO? = nil
    @Published var compareCategoryDraft: [String: RouteCategory] = [:]
    @Published var compareAccuracyDraft: [String: Double] = [:]
    @Published var openRouterConfigured: Bool = false
    @Published var openRouterMaskedKey: String = ""
    @Published var openRouterKeyRequired: Bool = true
    @Published var openRouterKeyDraft: String = ""
    @Published var isEditingOpenRouterKey: Bool = false
    @Published var openRouterKeyMessage: String?
    /// Result of Preferences → OpenRouter “Check connection” / main footer status.
    @Published var openRouterReady: Bool = false
    @Published var openRouterStatus: String = "OpenRouter not configured"
    @Published var openRouterCheckMessage: String?
    @Published var openRouterCreditsRemaining: Double?
    /// OpenRouter USD / 1K token rates keyed by model id (used in Preferences + analysis).
    @Published var modelPricingByID: [String: ModelPricingDTO] = [:]
    @Published var isLoadingModelPricing: Bool = false
    /// Full OpenRouter catalog for the Preferences “Other…” browser.
    @Published var openRouterCatalog: [OpenRouterCatalogModelDTO] = []
    @Published var isLoadingOpenRouterCatalog: Bool = false
    @Published var openRouterCatalogError: String?

    private let client = ARILAPIClient()
    let gatewayManager = LocalGatewayManager()
    private var previewTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generationTimerTask: Task<Void, Never>?
    private var lastUserPromptForPrefer: String = ""
    /// Local tombstone so reload can't resurrect until gateway agrees.
    private var deletedSessionIDs: Set<UUID> = []

    var selectedSession: ChatSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    var isAnalysing: Bool {
        if case .analysing = analysisStatus { return true }
        return isPreviewing
    }

    /// Display name for user messages (falls back to "You").
    var userLabel: String {
        let trimmed = userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "You" : trimmed
    }

    var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.14"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "44"
        return "\(short) (\(build))"
    }

    /// Placeholder / starting text for Preferences → System Prompt (Claude.md-style).
    static let defaultSystemPrompt = """
        You are a helpful, reliable AI assistant.

        Follow the user’s instructions carefully and ask concise clarifying questions only when essential. Provide accurate, practical answers tailored to the user’s context and level of expertise.

        Guidelines:
        Lead with the answer or outcome.
        Be clear, concise, and well structured.
        Do not invent facts; state uncertainty when appropriate.
        Preserve the user’s intent and constraints.
        Make reasonable assumptions when they are low risk, and disclose important ones.
        Explain complex ideas in plain language.
        For actionable tasks, provide concrete steps or complete the work when tools are available.
        Protect privacy, security, and confidential information.
        Refuse unsafe or prohibited requests briefly, while offering a safer alternative when possible.
        Review your response for correctness and completeness before sending it.
        """

    /// At least one ready MCP server while MCP use is enabled.
    var hasConfiguredMCPServers: Bool {
        mcpEnabled && mcpServers.contains(where: \.isReady)
    }

    init() {
        let defaults = UserDefaults.standard
        let storedDefault = defaults.string(forKey: "aril.defaultModel") ?? "openai/gpt-4.1"
        defaultModel = storedDefault
        selectedModel = defaults.string(forKey: "aril.lastModel") ?? storedDefault
        gatewayURL = defaults.string(forKey: "aril.gatewayURL") ?? "http://127.0.0.1:8741"
        soloMode = defaults.object(forKey: "aril.soloMode") as? Bool ?? true
        userDisplayName = defaults.string(forKey: "aril.userDisplayName") ?? ""
        let storedTemp = Self.clampedTemperature(
            defaults.object(forKey: "aril.defaultTemperature") as? Double ?? 0.7
        )
        defaultTemperature = storedTemp
        temperature = storedTemp
        analysisIdleSeconds = Self.clampedIdleSeconds(
            defaults.object(forKey: "aril.analysisIdleSeconds") as? Double ?? 2.0
        )
        skipAnalysisOnJudgement =
            defaults.object(forKey: "aril.skipAnalysisOnJudgement") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "aril.showInMenuBar") as? Bool ?? false
        mcpEnabled = false
        UserDefaults.standard.set(false, forKey: "aril.mcpEnabled")
        // Drafting is paused until the backlog MCP config (URL + API key) ships.
        mcpServers = []
        UserDefaults.standard.removeObject(forKey: "aril.mcpServers")
        systemPromptEnabled = defaults.object(forKey: "aril.systemPromptEnabled") as? Bool ?? false
        let storedPrompt = defaults.string(forKey: "aril.systemPrompt") ?? ""
        systemPrompt = storedPrompt
        systemPromptBaseline = storedPrompt
        systemPromptDirty = false
        loadDeletedSessionIDs()
        // Restore history synchronously so the first frame never looks empty.
        loadLocalSessions()
        // Seed built-in rates immediately so Preferences / Model costs aren’t blank
        // before the gateway answers (or when no OpenRouter key is configured).
        applyDefaultModelPricing()
        objectWillChange.send()
        Task { await bootstrap() }
    }

    /// Clamp temperature to the 0…1 UI range (0.1 steps preferred by sliders).
    static func clampedTemperature(_ value: Double) -> Double {
        min(1, max(0, (value * 10).rounded() / 10))
    }

    /// Clamp analysis idle to 0…10 in 0.5s steps.
    static func clampedIdleSeconds(_ value: Double) -> Double {
        min(10, max(0, (value * 2).rounded() / 2))
    }

    /// Persist the Preferences default and mirror it into the session temperature.
    func setDefaultTemperature(_ value: Double) {
        let clamped = Self.clampedTemperature(value)
        defaultTemperature = clamped
        temperature = clamped
        UserDefaults.standard.set(clamped, forKey: "aril.defaultTemperature")
    }

    func setAnalysisIdleSeconds(_ value: Double) {
        let clamped = Self.clampedIdleSeconds(value)
        analysisIdleSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: "aril.analysisIdleSeconds")
    }

    func setSkipAnalysisOnJudgement(_ enabled: Bool) {
        skipAnalysisOnJudgement = enabled
        UserDefaults.standard.set(enabled, forKey: "aril.skipAnalysisOnJudgement")
        if analysisStatus == .ready || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            schedulePreview()
        }
    }

    func setShowInMenuBar(_ enabled: Bool) {
        showInMenuBar = enabled
        UserDefaults.standard.set(enabled, forKey: "aril.showInMenuBar")
    }

    func setSystemPromptEnabled(_ enabled: Bool) {
        if !enabled {
            // Turning off keeps any edits so re-enable restores the same text.
            persistSystemPromptText()
            systemPromptEnabled = false
            UserDefaults.standard.set(false, forKey: "aril.systemPromptEnabled")
            systemPromptDirty = false
            refreshAnalysisForSystemPromptChange()
            return
        }
        systemPromptEnabled = true
        UserDefaults.standard.set(true, forKey: "aril.systemPromptEnabled")
        // Seed + persist the built-in default the first time there’s nothing stored yet.
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemPrompt = Self.defaultSystemPrompt
            persistSystemPromptText()
        }
        systemPromptDirty = false
        refreshAnalysisForSystemPromptChange()
    }

    func updateSystemPromptDraft(_ text: String) {
        systemPrompt = text
        refreshSystemPromptDirty()
        refreshAnalysisForSystemPromptChange()
    }

    func restoreDefaultSystemPrompt() {
        systemPrompt = Self.defaultSystemPrompt
        refreshSystemPromptDirty()
        refreshAnalysisForSystemPromptChange()
    }

    func saveSystemPrompt() {
        persistSystemPromptText()
        UserDefaults.standard.set(systemPromptEnabled, forKey: "aril.systemPromptEnabled")
        systemPromptDirty = false
        refreshAnalysisForSystemPromptChange()
    }

    /// Re-run cost analysis when the system prompt changes (if a draft is ready).
    private func refreshAnalysisForSystemPromptChange() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        schedulePreview()
    }

    private func persistSystemPromptText() {
        UserDefaults.standard.set(systemPrompt, forKey: "aril.systemPrompt")
        systemPromptBaseline = systemPrompt
    }

    private func refreshSystemPromptDirty() {
        systemPromptDirty = systemPrompt != systemPromptBaseline
    }

    /// Text shown when the toggle is off (saved draft, else the built-in default).
    var systemPromptShadowText: String {
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultSystemPrompt : systemPrompt
    }

    /// Rough token estimate (~4 chars/token), matching the gateway `estimate_tokens`.
    static func estimateTokens(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, trimmed.count / 4)
    }

    /// Approximate tokens for the current system-prompt draft (0 when empty).
    var systemPromptTokenEstimate: Int {
        Self.estimateTokens(systemPrompt)
    }

    /// System prompt text to send with preview/chat when the feature is enabled.
    var activeSystemPromptForAPI: String? {
        guard systemPromptEnabled else { return nil }
        let trimmed = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Build API messages for a send, injecting the global system prompt when enabled.
    func messagesForAPI(from sessionMessages: [ChatMessage]) -> [APIChatMessage] {
        var out = sessionMessages.map {
            let cleaned = ChatMessage.stripActualCostFooter($0.content)
            return APIChatMessage(role: $0.role.rawValue, content: Self.sanitizeContentForAPI(cleaned))
        }
        // Prefer a single leading system turn (Claude.md-style); drop any stored system noise.
        out.removeAll { $0.role == "system" }
        guard systemPromptEnabled else { return out }
        let prompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return out }
        out.insert(APIChatMessage(role: "system", content: prompt), at: 0)
        return out
    }

    static let maxExchangeLogCapacity = 20

    func recordExchange(
        prompt: String,
        response: String,
        model: String,
        mode: String,
        status: ExchangeLogEntry.Status,
        latencyMs: Int? = nil,
        errorMessage: String? = nil
    ) {
        let entry = ExchangeLogEntry(
            prompt: prompt,
            response: response,
            model: model,
            mode: mode,
            status: status,
            latencyMs: latencyMs,
            errorMessage: errorMessage
        )
        exchangeLog.insert(entry, at: 0)
        if exchangeLog.count > Self.maxExchangeLogCapacity {
            exchangeLog = Array(exchangeLog.prefix(Self.maxExchangeLogCapacity))
        }
    }

    func clearExchangeLog() {
        exchangeLog = []
    }

    func setMCPEnabled(_ enabled: Bool) {
        // MCP runtime wiring is still on the backlog — never persist enabled.
        guard !enabled else { return }
        mcpEnabled = false
        UserDefaults.standard.set(false, forKey: "aril.mcpEnabled")
    }

    private func bootstrap() async {
        // Cache already loaded in init; refresh again in case another process wrote.
        loadLocalSessions()
        if soloMode {
            await gatewayManager.ensureRunning()
            gatewayURL = gatewayManager.baseURL
        }
        await refreshHealth(reloadSessionsOnReady: false)
        await loadSessions(retryCount: 8)
        reconcileSelection()
        // Do not auto-create an empty session — count stays 0 until the user starts one.
        saveLocalSessions()
        // Always keep default rates available; overlay live OpenRouter pricing only when a key is set.
        applyDefaultModelPricing()
        if openRouterConfigured {
            await refreshModelPricing(forceRefresh: true)
        } else {
            fillMissingPricingWithDefaults()
        }
        objectWillChange.send()
    }

    /// Whether current pricing rows are mostly built-in defaults (no live OpenRouter overlay).
    var usingDefaultModelPricing: Bool {
        guard !modelPricingByID.isEmpty else { return true }
        return modelPricingByID.values.contains(where: { $0.source == "fallback" })
            && (!openRouterConfigured || modelPricingByID.values.allSatisfy { $0.source == "fallback" })
    }

    /// Seed / refresh built-in fallback rates for catalog + mapped models.
    func applyDefaultModelPricing() {
        var next = modelPricingByID
        for (id, rates) in Self.fallbackModelPricing {
            if let existing = next[id], existing.source == "openrouter" {
                continue
            }
            next[id] = ModelPricingDTO(
                id: id,
                promptPer1k: rates.promptPer1k,
                completionPer1k: rates.completionPer1k,
                webSearchPerRequest: Self.defaultWebSearchPerRequest,
                source: "fallback"
            )
        }
        for id in pricingModelIDs where next[id] == nil {
            next[id] = ModelPricingDTO(
                id: id,
                promptPer1k: Self.genericFallbackPromptPer1k,
                completionPer1k: Self.genericFallbackCompletionPer1k,
                webSearchPerRequest: Self.defaultWebSearchPerRequest,
                source: "fallback"
            )
        }
        modelPricingByID = next
    }

    private func fillMissingPricingWithDefaults() {
        var next = modelPricingByID
        var changed = false
        for id in pricingModelIDs where next[id] == nil {
            if let rates = Self.fallbackModelPricing[id] {
                next[id] = ModelPricingDTO(
                    id: id,
                    promptPer1k: rates.promptPer1k,
                    completionPer1k: rates.completionPer1k,
                    webSearchPerRequest: Self.defaultWebSearchPerRequest,
                    source: "fallback"
                )
            } else {
                next[id] = ModelPricingDTO(
                    id: id,
                    promptPer1k: Self.genericFallbackPromptPer1k,
                    completionPer1k: Self.genericFallbackCompletionPer1k,
                    webSearchPerRequest: Self.defaultWebSearchPerRequest,
                    source: "fallback"
                )
            }
            changed = true
        }
        if changed { modelPricingByID = next }
    }

    /// Models whose rates should be known for Preferences + Auto routing analysis.
    private var pricingModelIDs: [String] {
        var ids = Set(routingProfile.selectedModels)
        ids.insert(defaultModel)
        ids.insert(selectedModel)
        for model in Self.modelCatalog { ids.insert(model) }
        for models in RoutingProfile.recommendations.values {
            for model in models { ids.insert(model) }
        }
        return ids.sorted()
    }

    func refreshModelPricing(forceRefresh: Bool = false, focusing modelID: String? = nil) async {
        isLoadingModelPricing = true
        defer { isLoadingModelPricing = false }
        var ids = pricingModelIDs
        if let modelID, !modelID.isEmpty, !ids.contains(modelID) {
            ids.append(modelID)
        }
        do {
            let response = try await client.modelPricing(
                baseURL: gatewayURL,
                modelIDs: ids,
                refresh: forceRefresh
            )
            var next = modelPricingByID
            for row in response.models {
                next[row.id] = row
            }
            modelPricingByID = next
            fillMissingPricingWithDefaults()
        } catch {
            // Gateway / OpenRouter unavailable — keep or restore built-in defaults.
            applyDefaultModelPricing()
            fillMissingPricingWithDefaults()
        }
    }

    func pricingLabel(for modelID: String) -> String? {
        guard let row = modelPricingByID[modelID] else { return nil }
        return String(format: "$%.4f / $%.4f per 1K", row.promptPer1k, row.completionPer1k)
    }

    func setRoutingModel(_ model: String, for category: RouteCategory) {
        routingProfile.setModel(model, for: category)
        saveRoutingProfile()
        Task {
            await refreshModelPricing(forceRefresh: true, focusing: model)
            refreshAnalysisForSystemPromptChange()
        }
    }

    /// True when category mappings or the app default differ from factory originals.
    var routingModelsDifferFromDefaults: Bool {
        routingProfile != .default || defaultModel != Self.factoryDefaultModel
    }

    /// Restore category → model mappings and the app default to factory originals.
    func resetRoutingModelsToDefaults() {
        routingProfile = .default
        saveRoutingProfile()
        setDefaultModel(Self.factoryDefaultModel)
        Task {
            await refreshModelPricing(forceRefresh: true)
            refreshAnalysisForSystemPromptChange()
        }
    }

    func refreshOpenRouterCatalog(query: String = "", forceRefresh: Bool = false) async {
        isLoadingOpenRouterCatalog = true
        openRouterCatalogError = nil
        defer { isLoadingOpenRouterCatalog = false }
        do {
            let response = try await client.openRouterCatalog(
                baseURL: gatewayURL,
                query: query,
                refresh: forceRefresh
            )
            openRouterCatalog = response.models
            // Keep pricing map in sync for any selected/browser picks.
            var next = modelPricingByID
            for row in response.models {
                next[row.id] = ModelPricingDTO(
                    id: row.id,
                    promptPer1k: row.promptPer1k,
                    completionPer1k: row.completionPer1k,
                    webSearchPerRequest: row.webSearchPerRequest,
                    source: "openrouter"
                )
            }
            modelPricingByID = next
        } catch {
            openRouterCatalogError = error.localizedDescription
        }
    }

    /// Keep sidebar / chat selection pinned to a real session after list reloads.
    private func reconcileSelection() {
        if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
            return
        }
        selectedSessionID = sessions.first?.id
    }

    func createSession() {
        let session = ChatSession(title: "New session", messages: [])
        // Reassign the array so @Published / sidebar ForEach always refresh.
        var next = sessions
        next.insert(session, at: 0)
        sessions = next
        selectedSessionID = session.id
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = nil
        pendingAttachments = []
        saveLocalSessions()
        objectWillChange.send()
        Task { await persistSelectedSession() }
    }

    func deleteSession(_ id: UUID) async {
        let sid = id.uuidString.lowercased()
        deletedSessionIDs.insert(id)
        persistDeletedSessionIDs()
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
            draft = ""
            preview = nil
            showIntelligencePanel = false
            analysisStatus = .idle
            compareResults = []
            compareRouteCategory = nil
            preferredCompareModel = nil
            pendingAttachments = []
        }
        // Leave an empty sidebar (count 0) — a session is created only when the user sends.
        saveLocalSessions()
        do {
            try await client.deleteSession(baseURL: gatewayURL, id: sid)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllSessions() async {
        let ids = sessions.map(\.id)
        for id in ids { deletedSessionIDs.insert(id) }
        persistDeletedSessionIDs()
        sessions = []
        selectedSessionID = nil
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = nil
        pendingAttachments = []
        saveLocalSessions()
        do {
            try await client.deleteAllSessions(baseURL: gatewayURL)
        } catch {
            for id in ids {
                try? await client.deleteSession(baseURL: gatewayURL, id: id.uuidString.lowercased())
            }
        }
    }

    private func persistDeletedSessionIDs() {
        let values = deletedSessionIDs.map { $0.uuidString.lowercased() }
        UserDefaults.standard.set(values, forKey: "aril.deletedSessionIDs")
    }

    private func loadDeletedSessionIDs() {
        let values = UserDefaults.standard.stringArray(forKey: "aril.deletedSessionIDs") ?? []
        deletedSessionIDs = Set(values.compactMap { UUID(uuidString: $0) })
    }

    func refreshHealth(reloadSessionsOnReady: Bool = true) async {
        let wasReady = gatewayReady
        do {
            let health = try await client.health(baseURL: gatewayURL)
            gatewayReady = health.status == "ok"
            chatProvider = health.chatProvider ?? "unknown"
            openRouterConfigured = health.openrouterConfigured == true
            if health.gateway == "ready" {
                gatewayStatus = "Gateway ready"
            } else {
                gatewayStatus = health.status
            }
            await refreshOpenRouterKeyStatus()
            await refreshOpenRouterStatus()
            await refreshDatabaseStatus()
            // Reload history once the gateway becomes available after a cold start.
            // Skipped during bootstrap (which already loads sessions) to avoid races
            // that clear List selection and look like lost history.
            if reloadSessionsOnReady, gatewayReady, !wasReady {
                await loadSessions(retryCount: 5)
                reconcileSelection()
                saveLocalSessions()
            }
        } catch {
            gatewayReady = false
            gatewayStatus = soloMode ? "Starting gateway…" : "Gateway offline"
            chatProvider = "offline"
            openRouterConfigured = false
            markOpenRouterUnavailable(reason: "Gateway offline")
            markDatabaseUnavailable(reason: "Gateway offline")
        }
    }

    func refreshDatabaseStatus() async {
        do {
            let status = try await client.storeStatus(baseURL: gatewayURL, check: true)
            applyDatabaseStatus(status)
        } catch {
            markDatabaseUnavailable(reason: error.localizedDescription)
        }
    }

    /// Preferences → Database "Check database" action.
    func checkDatabase() async {
        databaseCheckMessage = nil
        do {
            let status = try await client.storeCheck(baseURL: gatewayURL)
            applyDatabaseStatus(status)
            databaseCheckMessage = status.message
        } catch {
            markDatabaseUnavailable(reason: error.localizedDescription)
            databaseCheckMessage = error.localizedDescription
        }
    }

    private func applyDatabaseStatus(_ status: StoreStatusDTO) {
        databaseReady = status.ready
        databaseStatus = status.ready ? "Database ready" : "Database not ready"
        databasePath = status.absolutePath.isEmpty ? status.path : status.absolutePath
        databaseEngine = status.engine
        databaseSizeLabel = status.sizeLabel
        databaseDetail = [
            status.message,
            status.exists ? "File present" : "File missing",
            status.writable ? "Writable" : "Not writable",
            "\(status.total) records · retention \(status.retention)",
        ].joined(separator: " · ")
        if status.ready {
            databaseCheckMessage = nil
        }
    }

    private func markDatabaseUnavailable(reason: String) {
        databaseReady = false
        databaseStatus = "Database not ready"
        databaseDetail = reason
        if databasePath.isEmpty {
            databasePath = "(unavailable)"
        }
        databaseSizeLabel = "—"
    }

    func refreshOpenRouterKeyStatus() async {
        do {
            let status = try await client.openRouterKeyStatus(baseURL: gatewayURL)
            openRouterConfigured = status.configured
            openRouterMaskedKey = status.maskedKey
            openRouterKeyRequired = status.required
            if status.configured {
                isEditingOpenRouterKey = false
                openRouterKeyDraft = ""
            } else {
                isEditingOpenRouterKey = true
                markOpenRouterUnavailable(reason: "No OpenRouter API key configured.")
            }
        } catch {
            // Keep last known status if gateway briefly unavailable
        }
    }

    /// Probe OpenRouter when a key is present (health refresh + footer).
    func refreshOpenRouterStatus() async {
        guard openRouterConfigured else {
            markOpenRouterUnavailable(reason: "No OpenRouter API key configured.")
            return
        }
        do {
            let status = try await client.checkOpenRouterConnection(baseURL: gatewayURL)
            applyOpenRouterConnectionStatus(status)
        } catch {
            markOpenRouterUnavailable(reason: error.localizedDescription)
        }
    }

    /// Preferences → OpenRouter "Check connection" action.
    func checkOpenRouterConnection() async {
        openRouterCheckMessage = nil
        guard openRouterConfigured else {
            markOpenRouterUnavailable(reason: "Save an OpenRouter API key first.")
            openRouterCheckMessage = openRouterStatus
            return
        }
        do {
            let status = try await client.checkOpenRouterConnection(baseURL: gatewayURL)
            applyOpenRouterConnectionStatus(status)
            openRouterCheckMessage = status.message
        } catch {
            markOpenRouterUnavailable(reason: error.localizedDescription)
            openRouterCheckMessage = error.localizedDescription
        }
    }

    private func applyOpenRouterConnectionStatus(_ status: OpenRouterConnectionStatusDTO) {
        openRouterReady = status.ready
        openRouterConfigured = status.configured
        if !status.maskedKey.isEmpty {
            openRouterMaskedKey = status.maskedKey
        }
        openRouterCreditsRemaining = status.ready ? status.creditsRemaining : nil
        if status.ready {
            if let credits = status.creditsRemaining {
                openRouterStatus = String(format: "OpenRouter ready (credits $%.2f)", credits)
            } else {
                openRouterStatus = "OpenRouter ready"
            }
        } else {
            openRouterStatus = "OpenRouter not ready"
        }
        if !status.message.isEmpty {
            openRouterCheckMessage = status.message
        }
    }

    private func markOpenRouterUnavailable(reason: String) {
        openRouterReady = false
        openRouterCreditsRemaining = nil
        openRouterStatus = openRouterConfigured ? "OpenRouter not ready" : "OpenRouter not configured"
        openRouterCheckMessage = reason
    }

    func saveOpenRouterKey() async {
        let key = openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            openRouterKeyMessage = "Enter an OpenRouter API key first."
            return
        }
        do {
            let status = try await client.setOpenRouterKey(baseURL: gatewayURL, apiKey: key)
            openRouterConfigured = status.configured
            openRouterMaskedKey = status.maskedKey
            openRouterKeyRequired = status.required
            openRouterKeyDraft = ""
            isEditingOpenRouterKey = false
            openRouterKeyMessage = "API key saved."
            openRouterStatus = "OpenRouter not ready"
            openRouterReady = false
            openRouterCreditsRemaining = nil
            openRouterCheckMessage = nil
            UserDefaults.standard.set(key, forKey: "aril.openRouterAPIKey")
            await refreshHealth()
            await refreshModelPricing(forceRefresh: true)
        } catch {
            openRouterKeyMessage = error.localizedDescription
            // Treat a rejected / invalid key save as unconfigured for pricing.
            applyDefaultModelPricing()
            fillMissingPricingWithDefaults()
        }
    }

    func clearOpenRouterKey() async {
        do {
            let status = try await client.clearOpenRouterKey(baseURL: gatewayURL)
            openRouterConfigured = status.configured
            openRouterMaskedKey = status.maskedKey
            openRouterKeyDraft = ""
            isEditingOpenRouterKey = true
            openRouterKeyMessage = "API key cleared. Add a key to use live models."
            markOpenRouterUnavailable(reason: "API key cleared. Add a key to use live models.")
            UserDefaults.standard.removeObject(forKey: "aril.openRouterAPIKey")
            applyDefaultModelPricing()
            await refreshHealth()
        } catch {
            openRouterKeyMessage = error.localizedDescription
        }
    }

    func beginEditingOpenRouterKey() {
        isEditingOpenRouterKey = true
        openRouterKeyDraft = ""
        openRouterKeyMessage = nil
        openRouterCheckMessage = nil
    }

    /// Toggle a trailing tools flyout; opening one closes any other.
    func openToolPanel(_ panel: ToolPanel) {
        if activeToolPanel == panel {
            activeToolPanel = nil
        } else {
            activeToolPanel = panel
        }
    }

    func closeToolPanel() {
        activeToolPanel = nil
    }

    func loadSessions(retryCount: Int = 1) async {
        let previousSelected = selectedSessionID
        for attempt in 0..<max(1, retryCount) {
            do {
                let summaries = try await client.listSessions(baseURL: gatewayURL)
                var loaded: [ChatSession] = []
                for summary in summaries.prefix(40) {
                    guard let uuid = UUID(uuidString: summary.id) else { continue }
                    if deletedSessionIDs.contains(uuid) { continue }
                    do {
                        let detail = try await client.getSession(baseURL: gatewayURL, id: summary.id)
                        let messages = detail.messages.compactMap { msg -> ChatMessage? in
                            guard let role = ChatMessage.Role(rawValue: msg.role) else { return nil }
                            return ChatMessage(role: role, content: msg.content)
                        }
                        var session = ChatSession(
                            id: uuid,
                            title: detail.title,
                            messages: messages,
                            updatedAt: Self.parseAPIDate(detail.updatedAt) ?? .now,
                            totalCostUsd: 0
                        )
                        session.recomputeTotalCost()
                        loaded.append(session)
                    } catch {
                        // Skip a single bad/oversized session; keep trying others.
                        continue
                    }
                }

                if !loaded.isEmpty || !summaries.isEmpty {
                    // Merge gateway history with any local-only sessions / longer local copies.
                    sessions = Self.mergeSessions(local: sessions, remote: loaded)
                    sessions.removeAll { deletedSessionIDs.contains($0.id) }
                    sessions.sort { $0.updatedAt > $1.updatedAt }
                    if let previousSelected, sessions.contains(where: { $0.id == previousSelected }) {
                        selectedSessionID = previousSelected
                    } else {
                        reconcileSelection()
                    }
                    // Re-publish so List/MessageList refresh even when IDs are unchanged.
                    noteSessionsChanged()
                    return
                }

                if attempt + 1 < retryCount {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }
                return
            } catch {
                if attempt + 1 < retryCount {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    continue
                }
                // Keep local sessions if gateway history is unavailable
                return
            }
        }
    }

    /// Prefer the richer copy of each session id (more messages / newer update).
    private static func mergeSessions(local: [ChatSession], remote: [ChatSession]) -> [ChatSession] {
        var byID: [UUID: ChatSession] = [:]
        for session in local + remote {
            if let existing = byID[session.id] {
                if session.messages.count > existing.messages.count {
                    byID[session.id] = session
                } else if session.messages.count == existing.messages.count,
                          session.updatedAt > existing.updatedAt {
                    byID[session.id] = session
                }
            } else {
                byID[session.id] = session
            }
        }
        return Array(byID.values).map { session in
            var next = session
            next.recomputeTotalCost()
            return next
        }
    }

    func selectModel(_ model: String) {
        selectedModel = model
        routeMode = .manual
        UserDefaults.standard.set(model, forKey: "aril.lastModel")
    }

    func setDefaultModel(_ model: String) {
        defaultModel = model
        UserDefaults.standard.set(model, forKey: "aril.defaultModel")
        Task { await refreshModelPricing(forceRefresh: true, focusing: model) }
    }

    func saveUserDisplayName() {
        UserDefaults.standard.set(userDisplayName, forKey: "aril.userDisplayName")
    }

    /// Switching modes clears the draft so analysis starts fresh for the new mode.
    func changeRouteMode(to mode: RouteMode) {
        guard mode != routeMode else { return }
        routeMode = mode
        resetPromptForModeChange()
    }

    func reusePrompt(_ text: String) {
        // Strip attachment suffix that we append for display.
        let cleaned = text
            .components(separatedBy: "\n\n[Attached:")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? text
        draft = cleaned.hasPrefix("[Attached:") ? "" : cleaned
        schedulePreview()
    }

    private func resetPromptForModeChange() {
        previewTask?.cancel()
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = nil
        estimatedLatencyMs = nil
        lastError = nil
        if routeMode == .manual {
            selectedModel = UserDefaults.standard.string(forKey: "aril.lastModel") ?? defaultModel
        }
    }

    /// Called on every draft change — panel appears immediately; analysis after idle.
    func schedulePreview() {
        previewTask?.cancel()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else {
            showIntelligencePanel = false
            preview = nil
            lastJudgementSkipPrompt = ""
            pinnedFullAnalysisPrompt = ""
            analysisStatus = .idle
            estimatedLatencyMs = nil
            return
        }

        // Fresh Redo Analysis result should stick until the draft changes.
        if text == pinnedFullAnalysisPrompt,
           preview != nil,
           preview?.analysisSkipped != true,
           analysisStatus == .ready {
            showIntelligencePanel = true
            return
        }

        // Same judged prompt already showing skipped metrics — don't re-animate analysis.
        if skipAnalysisOnJudgement,
           text == lastJudgementSkipPrompt,
           preview?.analysisSkipped == true,
           analysisStatus == .ready {
            showIntelligencePanel = true
            return
        }

        if text != pinnedFullAnalysisPrompt {
            pinnedFullAnalysisPrompt = ""
        }

        showIntelligencePanel = true
        // Keep prior skipped metrics visible during the idle wait when re-typing briefly.
        if preview?.analysisSkipped != true || text != lastJudgementSkipPrompt {
            preview = nil
        }
        estimatedLatencyMs = nil
        let idle = analysisIdleSeconds
        analysisStatus = .analysing(secondsRemaining: idle)

        previewTask = Task {
            if idle <= 0 {
                guard !Task.isCancelled else { return }
                await runPreview()
                return
            }
            // Count down in 0.5s ticks so fractional idle preferences display correctly.
            var remaining = idle
            while remaining > 0 {
                guard !Task.isCancelled else { return }
                analysisStatus = .analysing(secondsRemaining: remaining)
                let slice = min(0.5, remaining)
                try? await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
                remaining = (remaining - slice)
                if remaining < 0.05 { remaining = 0 }
            }
            guard !Task.isCancelled else { return }
            await runPreview()
        }
    }

    func runPreview(forceFullAnalysis: Bool = false, updateJudgement: Bool = false) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPreviewing = true
        analysisStatus = .analysing(secondsRemaining: 0)
        lastError = nil
        defer { isPreviewing = false }
        do {
            let skip = forceFullAnalysis ? false : skipAnalysisOnJudgement
            let result = try await client.preview(
                baseURL: gatewayURL,
                request: PreviewRequest(
                    prompt: text,
                    temperature: temperature,
                    routeMode: routeMode,
                    preferredModel: selectedModel,
                    sessionId: selectedSessionID?.uuidString.lowercased(),
                    routingProfile: APIRoutingProfile(routingProfile),
                    enhanceAlternatives: true,
                    skipAnalysisOnJudgement: skip,
                    updateJudgement: updateJudgement,
                    systemPrompt: activeSystemPromptForAPI
                )
            )
            preview = result
            showIntelligencePanel = true
            analysisStatus = .ready
            if result.analysisSkipped == true {
                lastJudgementSkipPrompt = text
                pinnedFullAnalysisPrompt = ""
            } else if updateJudgement || forceFullAnalysis {
                lastJudgementSkipPrompt = ""
                pinnedFullAnalysisPrompt = text
            } else {
                lastJudgementSkipPrompt = ""
                pinnedFullAnalysisPrompt = ""
            }
            updateCacheLabel(from: result)
            // Auto adopts the recommended model. Manual/Compare keep the user's pick
            // (still run analysis for grade, fit, cost, alternatives).
            if routeMode == .auto {
                selectedModel = result.recommendedModel
                objectWillChange.send()
            }
            await refreshEstimatedLatency(for: result.recommendedModel)
            if updateJudgement {
                await loadClassifications()
                await loadStoreBrowser()
            }
        } catch {
            lastError = error.localizedDescription
            analysisStatus = .idle
        }
    }

    /// Force a fresh grade/route analysis. Updates Learning only outside Manual.
    func redoAnalysis() async {
        lastJudgementSkipPrompt = ""
        pinnedFullAnalysisPrompt = ""
        let writeJudgement = routeMode != .manual
        await runPreview(forceFullAnalysis: true, updateJudgement: writeJudgement)
    }

    private func refreshEstimatedLatency(for model: String) async {
        do {
            let response = try await client.probe(baseURL: gatewayURL, models: [model])
            if let ms = response.results.first?.latencyMs {
                estimatedLatencyMs = ms
            }
        } catch {
            // Probe is best-effort; keep last known or nil.
        }
    }

    func send(promptOverride: String? = nil) {
        sendTask?.cancel()
        // Stop idle analysis countdown / queued preview before we possibly skip it.
        previewTask?.cancel()
        previewTask = nil
        // Show stop control immediately — including during pre-send analysis.
        isSending = true
        lastError = nil
        beginGenerationTracking()
        sendTask = Task {
            await performSend(promptOverride: promptOverride)
        }
    }

    func stopGeneration() {
        sendTask?.cancel()
        sendTask = nil
        endGenerationTracking(error: "Generation stopped")
    }

    private func beginGenerationTracking() {
        generationPhase = .thinking
        generationElapsedMs = 0
        generationTimerTask?.cancel()
        let started = Date()
        generationTimerTask = Task {
            while !Task.isCancelled {
                generationElapsedMs = Int(Date().timeIntervalSince(started) * 1000)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func endGenerationTracking(error: String? = nil) {
        generationTimerTask?.cancel()
        generationTimerTask = nil
        if generationElapsedMs > 0 {
            lastLatencyMs = generationElapsedMs
        }
        generationPhase = .idle
        isSending = false
        // Ensure sidebar / bubbles refresh after in-place session mutations.
        noteSessionsChanged()
        if let error {
            lastError = error
        }
    }

    /// Reassign `sessions` so @Published always notifies (in-place element edits often do not).
    private func noteSessionsChanged() {
        sessions = sessions
        saveLocalSessions()
    }

    /// Mutate a session and publish; bumps updatedAt and moves it to the top of the sidebar.
    private func updateSession(_ id: UUID, _ mutate: (inout ChatSession) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var next = sessions
        mutate(&next[idx])
        next[idx].updatedAt = .now
        let touched = next.remove(at: idx)
        next.insert(touched, at: 0)
        sessions = next
        saveLocalSessions()
    }

    private func performSend(promptOverride: String?) async {
        // isSending / generation timer already started in send()
        defer {
            if isSending {
                endGenerationTracking()
            }
        }

        let text = (promptOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if promptOverride != nil {
            draft = text
        }

        // Enter during the idle countdown: skip classify/preview and judgement logging.
        let interruptedIdleAnalysis: Bool = {
            if case .analysing(let remaining) = analysisStatus {
                return remaining > 0
            }
            return false
        }()

        if interruptedIdleAnalysis {
            isPreviewing = false
            preview = nil
            showIntelligencePanel = false
            analysisStatus = .idle
            estimatedLatencyMs = nil
        } else if !text.isEmpty, (preview == nil || analysisStatus != .ready) {
            await runPreview()
            if Task.isCancelled {
                return
            }
        }

        lastError = nil

        ensureSession()
        guard let sid = selectedSessionID else { return }

        let attachmentNote: String = {
            guard !pendingAttachments.isEmpty else { return "" }
            let names = pendingAttachments.map(\.filename).joined(separator: ", ")
            return text.isEmpty ? "[Attached: \(names)]" : "\n\n[Attached: \(names)]"
        }()
        let displayText = text.isEmpty ? attachmentNote : text + attachmentNote

        lastUserPromptForPrefer = text.isEmpty ? displayText : text
        updateSession(sid) { session in
            session.messages.append(ChatMessage(role: .user, content: displayText))
            if session.title == "New session" {
                session.title = String(
                    (text.isEmpty ? pendingAttachments.first?.filename ?? "Attachment" : text).prefix(42)
                )
            }
        }
        guard let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        draft = ""
        let attachmentsForSend = pendingAttachments
        pendingAttachments = []
        let lockedManualModel = UserDefaults.standard.string(forKey: "aril.lastModel") ?? defaultModel
        let cacheEligible = preview?.cache.eligible ?? false
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = nil
        lastCacheLabel = cacheEligible ? "not cached" : "not eligible"

        let historyForAPI = messagesForAPI(from: sessions[idx].messages)

        if Task.isCancelled { return }

        if routeMode == .compare {
            // Server classifies the prompt and picks 1 profile model + 2 capability peers.
            await sendCompare(sessionID: sid, index: idx, history: historyForAPI)
            return
        }

        if routeMode == .manual {
            selectedModel = lockedManualModel
        }

        let assistantID = UUID()
        updateSession(sid) { session in
            session.messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))
        }
        guard sessions.contains(where: { $0.id == sid }) else { return }

        let attachmentDTOs = attachmentsForSend.map {
            AttachmentDTO(
                filename: $0.filename,
                mimeType: $0.mimeType,
                dataBase64: $0.data.base64EncodedString()
            )
        }

        let request = ChatRequest(
            messages: historyForAPI,
            model: selectedModel,
            temperature: temperature,
            routeMode: routeMode,
            useCache: true,
            sessionId: sid.uuidString.lowercased(),
            previewId: nil,
            routingProfile: APIRoutingProfile(routingProfile),
            attachments: attachmentDTOs,
            webSearch: webSearchEnabled,
            skipAutoJudgement: interruptedIdleAnalysis
        )

        // Stream token UI updates are async; track receipt so we never fall back to
        // /v1/chat after the gateway already wrote a chat_transaction.
        let streamTokens = StreamTokenProbe()
        do {
            let done = try await client.chatStream(baseURL: gatewayURL, request: request) { [weak self] token in
                streamTokens.mark()
                Task { @MainActor in
                    guard let self,
                          let i = self.sessions.firstIndex(where: { $0.id == sid }),
                          let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID })
                    else { return }
                    if self.generationPhase == .thinking {
                        self.generationPhase = .streaming
                    }
                    // Reassign array so @Published notifies during streaming.
                    var next = self.sessions
                    next[i].messages[m].content += token
                    self.sessions = next
                }
            }
            if Task.isCancelled { return }
            let streamedText = sessions.first(where: { $0.id == sid })?
                .messages.first(where: { $0.id == assistantID })?.content ?? ""
            // Empty `done` (model returned nothing) — recover via non-stream once.
            // Server dedupes chat_transaction within 60s, so this stays Learning-safe.
            if streamedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !streamTokens.sawTokens {
                throw ARILAPIError.stream("No response received from the model. Try sending again.")
            }
            lastError = nil
            lastCacheLabel = (done.cached ?? false) ? "cached" : "not cached"
            if let ms = done.latencyMs {
                lastLatencyMs = ms
            }
            applyActualCost(
                sessionID: sid,
                assistantID: assistantID,
                model: done.model,
                reportedCost: done.costUsd,
                inputTokens: done.inputTokens,
                outputTokens: done.outputTokens
            )
            recordExchange(
                prompt: displayText,
                response: streamedText,
                model: done.model,
                mode: routeMode.label,
                status: .completed,
                latencyMs: done.latencyMs ?? lastLatencyMs
            )
            updateSession(sid) { _ in }
            await persistSelectedSession()
            await refreshHealth()
        } catch is CancellationError {
            let partial = sessions.first(where: { $0.id == sid })?
                .messages.first(where: { $0.id == assistantID })?.content ?? ""
            if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordExchange(
                    prompt: displayText,
                    response: partial,
                    model: selectedModel,
                    mode: routeMode.label,
                    status: .cancelled,
                    latencyMs: generationElapsedMs
                )
            }
            updateSession(sid) { session in
                session.messages.removeAll { $0.id == assistantID && $0.content.isEmpty }
            }
        } catch {
            if Task.isCancelled { return }
            // Prefer the streamed reply when any tokens arrived. Only fall back to
            // /v1/chat on zero-token failures; server dedupes duplicate Learning rows.
            let alreadyHasContent: Bool = {
                guard let session = sessions.first(where: { $0.id == sid }),
                      let msg = session.messages.first(where: { $0.id == assistantID })
                else { return false }
                return !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }()
            if alreadyHasContent || streamTokens.sawTokens {
                lastError = nil
                applyActualCost(
                    sessionID: sid,
                    assistantID: assistantID,
                    model: selectedModel,
                    reportedCost: nil,
                    inputTokens: nil,
                    outputTokens: nil
                )
                let responseText = sessions.first(where: { $0.id == sid })?
                    .messages.first(where: { $0.id == assistantID })?.content ?? ""
                recordExchange(
                    prompt: displayText,
                    response: responseText,
                    model: selectedModel,
                    mode: routeMode.label,
                    status: .completed,
                    latencyMs: lastLatencyMs ?? generationElapsedMs
                )
                updateSession(sid) { _ in }
                await persistSelectedSession()
                await refreshHealth()
                return
            }
            do {
                let response = try await client.chat(baseURL: gatewayURL, request: request)
                updateSession(sid) { session in
                    if let m = session.messages.firstIndex(where: { $0.id == assistantID }) {
                        session.messages[m].content = response.message.content
                    }
                }
                applyActualCost(
                    sessionID: sid,
                    assistantID: assistantID,
                    model: response.model,
                    reportedCost: response.costUsd,
                    inputTokens: response.inputTokens,
                    outputTokens: response.outputTokens
                )
                lastError = nil
                lastCacheLabel = response.cached ? "cached" : "not cached"
                generationPhase = .streaming
                let responseText = sessions.first(where: { $0.id == sid })?
                    .messages.first(where: { $0.id == assistantID })?.content ?? response.message.content
                recordExchange(
                    prompt: displayText,
                    response: responseText,
                    model: response.model,
                    mode: routeMode.label,
                    status: .completed,
                    latencyMs: lastLatencyMs ?? generationElapsedMs
                )
                await persistSelectedSession()
                await refreshHealth()
            } catch {
                lastError = error.localizedDescription
                recordExchange(
                    prompt: displayText,
                    response: "",
                    model: selectedModel,
                    mode: routeMode.label,
                    status: .error,
                    errorMessage: error.localizedDescription
                )
                updateSession(sid) { session in
                    session.messages.removeAll { $0.id == assistantID }
                }
            }
        }
    }

    private func sendCompare(sessionID: UUID, index: Int, history: [APIChatMessage]) async {
        generationPhase = .thinking
        let promptText = history.last(where: { $0.role == "user" })?.content ?? lastUserPromptForPrefer
        do {
            let response = try await client.compare(
                baseURL: gatewayURL,
                request: CompareRequestDTO(
                    messages: history,
                    models: nil,
                    temperature: temperature,
                    routingProfile: APIRoutingProfile(routingProfile),
                    sessionId: sessionID.uuidString.lowercased(),
                    useCache: true,
                    runProbe: true
                )
            )
            if Task.isCancelled { return }
            generationPhase = .streaming
            compareResults = response.results
            compareRouteCategory = response.routeCategory
            compareCategoryDraft = [:]
            compareAccuracyDraft = [:]
            for result in response.results {
                if let cat = result.suggestedCategory {
                    compareCategoryDraft[result.model] = cat
                }
                compareAccuracyDraft[result.model] = 0.8
            }
            lastCacheLabel = response.results.contains(where: \.cached) ? "cached" : "not cached"
            if let fastest = response.results.map(\.latencyMs).min() {
                lastLatencyMs = fastest
            }
            let modelList = response.results.map(\.model).joined(separator: ", ")
            let summary = response.results.map { result in
                let preview = String(result.content.prefix(240))
                return "[\(shortModelLeaf(result.model))] \(preview)"
            }.joined(separator: "\n\n---\n\n")
            recordExchange(
                prompt: promptText,
                response: summary,
                model: modelList,
                mode: RouteMode.compare.label,
                status: .compare,
                latencyMs: lastLatencyMs
            )
            // Persist the user prompt already appended locally; Prefer commits the reply.
            await persistSelectedSession()
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
                recordExchange(
                    prompt: promptText,
                    response: "",
                    model: "judge-peers",
                    mode: RouteMode.compare.label,
                    status: .error,
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    private func shortModelLeaf(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Resolve OpenRouter-reported cost, falling back to token × rate pricing when needed.
    func resolveActualCost(
        model: String,
        reportedCost: Double?,
        inputTokens: Int?,
        outputTokens: Int?
    ) -> Double {
        if let reportedCost, reportedCost > 0 {
            return reportedCost
        }
        let inTok = max(0, inputTokens ?? 0)
        let outTok = max(0, outputTokens ?? 0)
        if inTok == 0 && outTok == 0 {
            return reportedCost ?? 0
        }
        if let rates = modelPricingByID[model] {
            var cost = (Double(inTok) / 1000.0) * rates.promptPer1k
                + (Double(outTok) / 1000.0) * rates.completionPer1k
            if webSearchEnabled {
                cost += rates.webSearchFee
            }
            return round(cost * 1_000_000) / 1_000_000
        }
        return reportedCost ?? 0
    }

    private func applyActualCost(
        sessionID: UUID,
        assistantID: UUID,
        model: String,
        reportedCost: Double?,
        inputTokens: Int?,
        outputTokens: Int?
    ) {
        let cost = resolveActualCost(
            model: model,
            reportedCost: reportedCost,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        updateSession(sessionID) { session in
            guard let m = session.messages.firstIndex(where: { $0.id == assistantID }) else { return }
            let body = session.messages[m].content
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.messages[m].content = ChatMessage.withActualCostFooter(body, costUsd: cost)
            session.recomputeTotalCost()
        }
    }

    /// Drop embedded base64 images / huge blobs from outbound context (UI keeps originals).
    static func sanitizeContentForAPI(_ content: String) -> String {
        guard !content.isEmpty else { return content }
        var text = ChatMessage.stripActualCostFooter(content)
        text = sanitizeBulkyPayloads(text, truncateAt: 24_000, truncationMarker: "\n\n…[truncated for model context]")
        return text
    }

    /// Persist a slim copy of history while keeping actual-cost footers for session totals.
    static func sanitizeContentForStorage(_ content: String) -> String {
        guard !content.isEmpty else { return content }
        return sanitizeBulkyPayloads(content, truncateAt: 48_000, truncationMarker: "\n\n…[truncated for storage]")
    }

    private static func sanitizeBulkyPayloads(
        _ content: String,
        truncateAt maxChars: Int,
        truncationMarker: String
    ) -> String {
        var text = content
        if let md = try? NSRegularExpression(
            pattern: #"!\[[^\]]*\]\(data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]+\)"#,
            options: [.caseInsensitive]
        ) {
            text = md.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "![Generated image](omitted-from-context)"
            )
        }
        if let raw = try? NSRegularExpression(
            pattern: #"data:image\/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\s]{200,}"#,
            options: [.caseInsensitive]
        ) {
            text = raw.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: "data:image/(omitted-from-context)"
            )
        }
        if text.count > maxChars {
            // Preserve a trailing actual-cost footer when truncating.
            let footer = ChatMessage.actualCostUsd(from: text).map { ChatMessage.formatActualCostFooter($0) } ?? ""
            let budget = max(0, maxChars - footer.count - truncationMarker.count)
            let keep = text.prefix(budget)
            text = String(keep) + truncationMarker + footer
        }
        return text
    }

    func preferCompareResult(_ result: CompareResultDTO) async {
        let prompt = lastUserPromptForPrefer
        let suggested = result.suggestedCategory
        let chosenCategory = compareCategoryDraft[result.model] ?? suggested
        let accuracy = compareAccuracyDraft[result.model]
        let overridden = chosenCategory != nil && chosenCategory != suggested

        // Commit the preferred exchange into the transcript immediately, then
        // leave Judge for Auto — do not call selectModel (that forces Manual).
        preferredCompareModel = result.model
        if let sid = selectedSessionID {
            updateSession(sid) { session in
                while let last = session.messages.last,
                      last.role == .assistant,
                      last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    session.messages.removeLast()
                }
                let lastIsMatchingUser = session.messages.last.map {
                    $0.role == .user && $0.content == prompt
                } ?? false
                if !lastIsMatchingUser {
                    session.messages.append(ChatMessage(role: .user, content: prompt))
                }
                let cost = resolveActualCost(
                    model: result.model,
                    reportedCost: result.costUsd,
                    inputTokens: result.inputTokens,
                    outputTokens: result.outputTokens
                )
                session.messages.append(
                    ChatMessage(role: .assistant, content: ChatMessage.withActualCostFooter(result.content, costUsd: cost))
                )
                session.recomputeTotalCost()
            }
        }

        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = result.model
        routeMode = .auto
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        isSending = false
        generationPhase = .idle
        generationTimerTask?.cancel()
        generationTimerTask = nil

        recordExchange(
            prompt: prompt,
            response: result.content,
            model: result.model,
            mode: "\(RouteMode.compare.label) · Prefer",
            status: .completed,
            latencyMs: result.latencyMs
        )
        saveLocalSessions()

        // Teach routing off the UI path so Prefer never feels hung.
        do {
            _ = try await client.prefer(
                baseURL: gatewayURL,
                request: PreferRequestDTO(
                    prompt: prompt,
                    model: result.model,
                    category: chosenCategory,
                    accuracy: accuracy,
                    categoryOverridden: overridden,
                    sessionId: selectedSessionID?.uuidString.lowercased()
                )
            )
            await persistSelectedSession()
            await loadStoreBrowser()
        } catch {
            lastError = error.localizedDescription
            await persistSelectedSession()
        }
    }

    func loadClassifications() async {
        do {
            let snap = try await client.preferences(baseURL: gatewayURL)
            classifications = snap.classifications
        } catch {
            // Gateway may be offline
        }
    }

    func loadStoreBrowser() async {
        do {
            async let stats = client.storeStats(baseURL: gatewayURL)
            async let records = client.storeRecords(baseURL: gatewayURL)
            async let snap = client.preferences(baseURL: gatewayURL)
            storeStats = try await stats
            storeRecords = try await records
            classifications = try await snap.classifications
        } catch {
            // Gateway may be offline
        }
    }

    func updateStoreRetention(_ retention: Int) async {
        do {
            storeStats = try await client.updateStoreRetention(
                baseURL: gatewayURL,
                retention: retention
            )
            await loadStoreBrowser()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteStoreRecord(_ id: String) async {
        do {
            try await client.deleteStoreRecord(baseURL: gatewayURL, id: id)
            storeRecords.removeAll { $0.id == id }
            classifications.removeAll { $0.id == id }
            if let stats = try? await client.storeStats(baseURL: gatewayURL) {
                storeStats = stats
            }
            if analysisStatus == .ready {
                await runPreview()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllStoreRecords() async {
        do {
            _ = try await client.deleteAllStoreRecords(baseURL: gatewayURL)
            storeRecords = []
            classifications = []
            if let stats = try? await client.storeStats(baseURL: gatewayURL) {
                storeStats = stats
            }
            if analysisStatus == .ready {
                await runPreview()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateClassification(
        _ id: String,
        category: RouteCategory?,
        accuracy: Double?,
        removeAccuracy: Bool = false
    ) async {
        do {
            let updated = try await client.updateClassification(
                baseURL: gatewayURL,
                id: id,
                update: ClassificationUpdateDTO(
                    category: category,
                    accuracy: accuracy,
                    model: nil,
                    removeAccuracy: removeAccuracy
                )
            )
            if let idx = classifications.firstIndex(where: { $0.id == id }) {
                classifications[idx] = updated
            }
            if let idx = storeRecords.firstIndex(where: { $0.id == id }) {
                let previous = storeRecords[idx]
                storeRecords[idx] = StoreRecordDTO(
                    id: updated.id,
                    kind: previous.kind,
                    promptSnippet: updated.promptSnippet,
                    fingerprint: updated.fingerprint,
                    category: updated.category,
                    model: updated.model,
                    accuracy: updated.accuracy,
                    categoryOverridden: updated.categoryOverridden,
                    cached: previous.cached,
                    costUsd: previous.costUsd,
                    sessionId: previous.sessionId,
                    createdAt: updated.createdAt,
                    updatedAt: updated.updatedAt
                )
            }
            if analysisStatus == .ready {
                await runPreview()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteClassification(_ id: String) async {
        do {
            try await client.deleteClassification(baseURL: gatewayURL, id: id)
            classifications.removeAll { $0.id == id }
            storeRecords.removeAll { $0.id == id }
            if let stats = try? await client.storeStats(baseURL: gatewayURL) {
                storeStats = stats
            }
            if analysisStatus == .ready {
                await runPreview()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Save category/accuracy override from the Analysis sheet for the current draft.
    func saveAnalysisOverride(category: RouteCategory, accuracy: Double?, overridden: Bool) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            _ = try await client.prefer(
                baseURL: gatewayURL,
                request: PreferRequestDTO(
                    prompt: text,
                    model: selectedModel,
                    category: category,
                    accuracy: accuracy,
                    categoryOverridden: overridden,
                    sessionId: selectedSessionID?.uuidString
                )
            )
            await loadStoreBrowser()
            await runPreview()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyAlternative(_ alt: PromptAlternative) {
        draft = alt.text
        schedulePreview()
    }

    func submitAlternative(_ alt: PromptAlternative) {
        send(promptOverride: alt.text)
    }

    func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .jpeg, .png, .gif, .webP, .pdf, .plainText, .utf8PlainText, .json,
        ]
        panel.title = "Attach images or files"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            // Cap individual attachments at ~8MB
            guard data.count <= 8_000_000 else {
                lastError = "Skipped \(url.lastPathComponent) (over 8MB)"
                continue
            }
            let mime = mimeType(for: url) ?? "application/octet-stream"
            pendingAttachments.append(
                PendingAttachment(filename: url.lastPathComponent, mimeType: mime, data: data)
            )
        }
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    private func mimeType(for url: URL) -> String? {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.preferredMIMEType
        }
        return nil
    }

    func saveGatewayURL() {
        UserDefaults.standard.set(gatewayURL, forKey: "aril.gatewayURL")
    }

    func saveSoloMode() {
        UserDefaults.standard.set(soloMode, forKey: "aril.soloMode")
        Task {
            if soloMode {
                await gatewayManager.ensureRunning()
                gatewayURL = gatewayManager.baseURL
            }
            await refreshHealth()
        }
    }

    func shutdown() {
        saveLocalSessions()
        gatewayManager.stop()
    }

    var gatewayStatusDetail: String {
        gatewayManager.lastMessage
    }

    func saveRoutingProfile() {
        if let data = try? JSONEncoder().encode(routingProfile) {
            UserDefaults.standard.set(data, forKey: "aril.routingProfile")
        }
    }

    private func updateCacheLabel(from preview: PreviewResponse) {
        if !preview.cache.eligible {
            lastCacheLabel = "not eligible"
        } else if preview.cache.wouldHit {
            lastCacheLabel = "cached"
        } else {
            lastCacheLabel = "not cached"
        }
    }

    private static func loadRoutingProfile() -> RoutingProfile {
        guard let data = UserDefaults.standard.data(forKey: "aril.routingProfile"),
              let profile = try? JSONDecoder().decode(RoutingProfile.self, from: data)
        else { return .default }
        return profile
    }

    private func ensureSession() {
        if selectedSessionID == nil {
            createSession()
        }
    }

    private var localSessionsURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ARIL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions-cache.json")
    }

    private struct LocalSessionsCache: Codable {
        var selectedSessionID: UUID?
        var sessions: [ChatSession]
    }

    private func loadLocalSessions() {
        let url = localSessionsURL
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let cache = try? decoder.decode(LocalSessionsCache.self, from: data) else { return }
        let restored = cache.sessions.filter { !deletedSessionIDs.contains($0.id) }
        guard !restored.isEmpty else { return }
        // Prefer richer local copy when bootstrap races with an empty in-memory list.
        sessions = Self.mergeSessions(local: sessions, remote: restored)
            .sorted { $0.updatedAt > $1.updatedAt }
        if let selected = cache.selectedSessionID, sessions.contains(where: { $0.id == selected }) {
            selectedSessionID = selected
        } else {
            reconcileSelection()
        }
    }

    private func saveLocalSessions() {
        let cache = LocalSessionsCache(selectedSessionID: selectedSessionID, sessions: sessions)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: localSessionsURL, options: [.atomic])
    }

    /// Gateway timestamps use fractional seconds; default ISO8601DateFormatter misses them.
    private static func parseAPIDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private func persistSelectedSession() async {
        guard let session = selectedSession else { return }
        // Never re-upsert a locally deleted session id.
        if deletedSessionIDs.contains(session.id) { return }
        saveLocalSessions()
        let payload = SessionUpsertDTO(
            id: session.id.uuidString.lowercased(),
            title: session.title,
            messages: session.messages.map {
                // Keep actual-cost footers in history; only strip bulky image payloads.
                APIChatMessage(role: $0.role.rawValue, content: Self.sanitizeContentForStorage($0.content))
            }
        )
        _ = try? await client.upsertSession(baseURL: gatewayURL, session: payload)
    }

    deinit {
        // Process cleanup on main from gateway manager when app quits via App delegate if needed
    }
}

/// Tracks whether any stream token arrived (even before MainActor UI apply).
private final class StreamTokenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _saw = false

    var sawTokens: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _saw
    }

    func mark() {
        lock.lock()
        _saw = true
        lock.unlock()
    }
}
