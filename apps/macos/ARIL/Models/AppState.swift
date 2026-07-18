import Foundation
import Combine
import AppKit
import CryptoKit
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
    case modelPopularity
    case learning
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modelPopularity: return "Model popularity"
        case .learning: return "Learning"
        case .about: return "About ARIL"
        }
    }

    /// Shared flyout width for every tools panel.
    static let flyoutWidth: CGFloat = 560
}

/// Outcome of the context-window warning dialog.
enum ContextLimitDecision {
    case proceed
    case newSession
    case cancel
}

@MainActor
final class AppState: ObservableObject {
    /// Built-in starter models for the Manual-mode picker (before Other… picks).
    static let factoryModelCatalog = [
        "openai/gpt-4.1",
        "openai/gpt-4.1-mini",
        "anthropic/claude-sonnet-4",
        "anthropic/claude-opus-4",
        "google/gemini-2.5-flash",
        "meta-llama/llama-3.3-70b-instruct",
    ]

    /// Cap for the Manual / Preferences shortlist (factory set + Other… picks).
    static let maxModelCatalogSize = 8

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
    /// When on, reopen the most recent session on launch instead of starting fresh (Preferences).
    @Published var openLastSessionOnStartup: Bool = false
    /// Master switch — when on, enabled MCP server entries are considered configured.
    @Published var mcpEnabled: Bool = false
    @Published var mcpServers: [MCPServerConfig] = []
    /// Managed Nmap MCP server lifecycle mirrors (for the Preferences UI).
    @Published var nmapServerRunning: Bool = false
    @Published var nmapInstalled: Bool = false
    @Published var nmapServerStatus: String = ""
    @Published var nmapServerBusy: Bool = false
    /// Managed Semgrep code-scan MCP server lifecycle mirrors (for the Preferences UI).
    @Published var codeScanServerRunning: Bool = false
    @Published var semgrepInstalled: Bool = false
    @Published var codeScanServerStatus: String = ""
    @Published var codeScanServerBusy: Bool = false
    /// Shell-style prompt history (most recent last), recalled with ↑/↓ in the input bar.
    @Published var promptHistory: [String] = AppState.loadPromptHistory()
    static let promptHistoryLimit = 10
    /// Index into `promptHistory` while browsing with ↑/↓; nil when not browsing.
    private var historyNavIndex: Int?
    /// Draft stashed when the user starts browsing history, restored on ↓ past newest.
    private var historyStash: String = ""
    @Published var mcpCheckingServerID: UUID?
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
    /// Shortlist shown in Manual mode (and Preferences pickers). Max `maxModelCatalogSize`.
    @Published var modelCatalog: [String]
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
    /// Weekly popularity rankings (`sort=top-weekly`) for the Other… callout.
    @Published var openRouterWeeklyRankings: [OpenRouterWeeklyRankingDTO] = []
    @Published var isLoadingWeeklyRankings: Bool = false
    @Published var weeklyRankingsError: String?

    /// Preferences → Budget soft/hard USD caps (0 = off for that cap).
    @Published var budgetCaps: BudgetCaps = .defaults
    /// Master switch — when off, caps are ignored regardless of Soft/Hard values.
    @Published var budgetEnabled: Bool = false
    /// Spend accrued today (local calendar date), for daily caps.
    @Published var dailySpendUsd: Double = 0
    /// Soft-confirm dialog message; nil when no prompt is showing.
    @Published var budgetConfirmMessage: String?
    /// Context-window limit dialog message; nil when no prompt is showing.
    @Published var contextLimitMessage: String?
    @Published var categoryPreferWins: [String: [String: Int]] = [:]
    @Published var fingerprintPreferWins: [String: [String: Int]] = [:]
    @Published var evalLog: [EvalLogEntry] = []
    @Published var isRunningAutoEval: Bool = false

    private let client = ARILAPIClient()
    let gatewayManager = LocalGatewayManager()
    let nmapServerManager = NmapServerManager()
    let codeScanServerManager = CodeScanServerManager()
    private var previewTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generationTimerTask: Task<Void, Never>?
    private var lastUserPromptForPrefer: String = ""
    /// Local tombstone so reload can't resurrect until gateway agrees.
    private var deletedSessionIDs: Set<UUID> = []
    private var budgetConfirmContinuation: CheckedContinuation<Bool, Never>?
    /// Skip budget UI while Learning → Run Auto eval is driving sends.
    private var budgetBypassForEval: Bool = false
    private var contextLimitContinuation: CheckedContinuation<ContextLimitDecision, Never>?
    /// Sessions where the user chose "Continue" past the context warning — don't nag again.
    private var contextWarnAcknowledged: Set<UUID> = []
    /// Periodic footer health probe (gateway / database / OpenRouter).
    private var healthPollTask: Task<Void, Never>?
    /// Consecutive failed health probes before flipping footer indicators red.
    private var healthFailStreak = 0
    /// Keep the Solo gateway process from App Nap while ARIL is open.
    private var gatewayActivity: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?

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
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.4.1"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "52"
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
        modelCatalog = Self.loadModelCatalog()
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
        openLastSessionOnStartup = defaults.object(forKey: "aril.openLastSessionOnStartup") as? Bool ?? false
        mcpEnabled = defaults.object(forKey: "aril.mcpEnabled") as? Bool ?? false
        mcpServers = Self.loadMCPServers()
        systemPromptEnabled = defaults.object(forKey: "aril.systemPromptEnabled") as? Bool ?? false
        let storedPrompt = defaults.string(forKey: "aril.systemPrompt") ?? ""
        systemPrompt = storedPrompt
        systemPromptBaseline = storedPrompt
        systemPromptDirty = false
        budgetCaps = BudgetCaps.load()
        budgetEnabled = UserDefaults.standard.object(forKey: "aril.budget.enabled") as? Bool ?? false
        dailySpendUsd = Self.loadDailySpendUsd()
        loadDeletedSessionIDs()
        // Restore history synchronously so the first frame never looks empty.
        loadLocalSessions()
        // Seed built-in rates immediately so Preferences pricing isn’t blank
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

    func setOpenLastSessionOnStartup(_ enabled: Bool) {
        openLastSessionOnStartup = enabled
        UserDefaults.standard.set(enabled, forKey: "aril.openLastSessionOnStartup")
    }

    func setBudgetEnabled(_ enabled: Bool) {
        budgetEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "aril.budget.enabled")
    }

    func setBudgetCaps(_ caps: BudgetCaps) {
        budgetCaps = BudgetCaps(
            sessionSoftUsd: BudgetCaps.clamped(caps.sessionSoftUsd),
            sessionHardUsd: BudgetCaps.clamped(caps.sessionHardUsd),
            dailySoftUsd: BudgetCaps.clamped(caps.dailySoftUsd),
            dailyHardUsd: BudgetCaps.clamped(caps.dailyHardUsd)
        )
        budgetCaps.save()
    }

    func respondToBudgetConfirm(_ proceed: Bool) {
        budgetConfirmMessage = nil
        let cont = budgetConfirmContinuation
        budgetConfirmContinuation = nil
        cont?.resume(returning: proceed)
    }

    private func requestBudgetConfirmation(message: String) async -> Bool {
        if budgetConfirmContinuation != nil {
            respondToBudgetConfirm(false)
        }
        return await withCheckedContinuation { continuation in
            budgetConfirmContinuation = continuation
            budgetConfirmMessage = message
        }
    }

    func respondToContextLimit(_ decision: ContextLimitDecision) {
        contextLimitMessage = nil
        let cont = contextLimitContinuation
        contextLimitContinuation = nil
        cont?.resume(returning: decision)
    }

    private func requestContextLimitConfirmation(message: String) async -> ContextLimitDecision {
        if contextLimitContinuation != nil {
            respondToContextLimit(.cancel)
        }
        return await withCheckedContinuation { continuation in
            contextLimitContinuation = continuation
            contextLimitMessage = message
        }
    }

    private static func localDayKey(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func loadDailySpendUsd(defaults: UserDefaults = .standard) -> Double {
        let today = localDayKey()
        let storedDay = defaults.string(forKey: "aril.budget.dailyDate") ?? ""
        if storedDay != today {
            defaults.set(today, forKey: "aril.budget.dailyDate")
            defaults.set(0.0, forKey: "aril.budget.dailyTotalUsd")
            return 0
        }
        return max(0, defaults.double(forKey: "aril.budget.dailyTotalUsd"))
    }

    private func accrueDailySpend(_ amount: Double) {
        guard amount > 0 else { return }
        let today = Self.localDayKey()
        let defaults = UserDefaults.standard
        let storedDay = defaults.string(forKey: "aril.budget.dailyDate") ?? ""
        var total = storedDay == today ? max(0, defaults.double(forKey: "aril.budget.dailyTotalUsd")) : 0
        total += amount
        defaults.set(today, forKey: "aril.budget.dailyDate")
        defaults.set(total, forKey: "aril.budget.dailyTotalUsd")
        dailySpendUsd = total
    }

    /// Refresh published daily spend (e.g. after midnight while app stays open).
    func refreshDailySpendFromDefaults() {
        dailySpendUsd = Self.loadDailySpendUsd()
    }

    private var sessionSpendUsd: Double {
        selectedSession?.totalCostUsd ?? 0
    }

    private func looksLikeImageGenModel(_ modelID: String) -> Bool {
        if let row = openRouterCatalog.first(where: { $0.id == modelID }),
           row.emitsImageOutput == true {
            return true
        }
        let hay = modelID.lowercased()
        return hay.contains("image") || hay.contains("dall-e") || hay.contains("flux")
            || hay.contains("gpt-image") || hay.contains("imagen")
    }

    private func estimateOutgoingCostUsd() -> Double {
        let routes = preview?.routes ?? []
        if routeMode == .compare {
            let peers = Array(routes.prefix(3))
            if !peers.isEmpty {
                return peers.map(\.estimatedCostUsd).reduce(0, +)
            }
            let one = routes.first?.estimatedCostUsd ?? 0.02
            return one * 3
        }
        if let top = routes.first {
            var est = top.estimatedCostUsd
            if webSearchEnabled {
                let fee = modelPricingByID[top.modelId]?.webSearchFee
                    ?? Self.defaultWebSearchPerRequest
                // Preview may already include web; add only when estimate looks token-only.
                if est < fee {
                    est += fee
                }
            }
            return est
        }
        var fallback = 0.01
        if webSearchEnabled {
            fallback += Self.defaultWebSearchPerRequest
        }
        return fallback
    }

    private func evaluateBudgetGate(estimate: Double) -> BudgetGateResult {
        refreshDailySpendFromDefaults()
        let caps = budgetCaps
        let sessionTotal = sessionSpendUsd
        let dailyTotal = dailySpendUsd
        let sessionNext = sessionTotal + estimate
        let dailyNext = dailyTotal + estimate

        if caps.sessionHardUsd > 0, sessionNext > caps.sessionHardUsd {
            return .hardBlock(message: String(
                format: "Session hard budget $%.2f would be exceeded (now $%.4f + est. $%.4f). Send blocked.",
                caps.sessionHardUsd, sessionTotal, estimate
            ))
        }
        if caps.dailyHardUsd > 0, dailyNext > caps.dailyHardUsd {
            return .hardBlock(message: String(
                format: "Daily hard budget $%.2f would be exceeded (today $%.4f + est. $%.4f). Send blocked.",
                caps.dailyHardUsd, dailyTotal, estimate
            ))
        }

        var softReasons: [String] = []
        if caps.sessionSoftUsd > 0, sessionNext > caps.sessionSoftUsd, sessionTotal <= caps.sessionSoftUsd {
            softReasons.append(String(
                format: "session soft $%.2f (now $%.4f + est. $%.4f)",
                caps.sessionSoftUsd, sessionTotal, estimate
            ))
        } else if caps.sessionSoftUsd > 0, sessionNext > caps.sessionSoftUsd {
            softReasons.append(String(
                format: "session soft $%.2f already crossed (now $%.4f + est. $%.4f)",
                caps.sessionSoftUsd, sessionTotal, estimate
            ))
        }
        if caps.dailySoftUsd > 0, dailyNext > caps.dailySoftUsd {
            softReasons.append(String(
                format: "daily soft $%.2f (today $%.4f + est. $%.4f)",
                caps.dailySoftUsd, dailyTotal, estimate
            ))
        }

        let anySoftConfigured = caps.sessionSoftUsd > 0 || caps.dailySoftUsd > 0
        if anySoftConfigured {
            if routeMode == .compare {
                softReasons.append("Judge runs ~3 models")
            }
            if webSearchEnabled {
                softReasons.append("web search is on")
            }
            let modelForImage: String = {
                if routeMode == .manual {
                    return UserDefaults.standard.string(forKey: "aril.lastModel") ?? selectedModel
                }
                return preview?.routes.first?.modelId ?? selectedModel
            }()
            if looksLikeImageGenModel(modelForImage) {
                softReasons.append("image generation model")
            }
        }

        // Dedupe while preserving order
        var seen = Set<String>()
        let unique = softReasons.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return .allow }
        let message = "Budget check: \(unique.joined(separator: "; ")). Send anyway?"
        return .softConfirm(message: message)
    }

    /// Returns false when send should abort (hard block or user cancelled soft confirm).
    /// Pull the gateway's authoritative context budgets so the client indicator and
    /// the send-time gate always match what the server actually trims to.
    func refreshContextLimits() async {
        guard let limits = try? await client.contextLimits(baseURL: gatewayURL) else { return }
        if limits.maxTotalChars > 0 {
            ChatSession.maxContextChars = limits.maxTotalChars
        }
        if limits.maxMessageChars > 0 {
            ChatSession.maxMessageChars = limits.maxMessageChars
        }
        // Republish so sidebar indicators recompute against the fresh budget.
        objectWillChange.send()
    }

    /// Warn when the upcoming turn would reach the model context budget. Returns false
    /// to abort the current send (either cancelled, or diverted to a new session).
    private func passContextGate(newUserText: String) async -> Bool {
        guard let sid = selectedSessionID,
              let session = sessions.first(where: { $0.id == sid })
        else { return true }
        if contextWarnAcknowledged.contains(sid) { return true }

        var projected = session.contextChars
        projected += min(Self.sanitizeContentForAPI(newUserText).count, ChatSession.maxMessageChars)
        if systemPromptEnabled {
            let sp = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sp.isEmpty { projected += sp.count }
        }

        guard projected >= ChatSession.maxContextChars else { return true }

        let pct = Int((Double(projected) / Double(ChatSession.maxContextChars) * 100).rounded())
        let limit = ChatSession.maxContextChars.formatted()
        let message = """
        This session is at ~\(pct)% of the model context limit (\(limit) characters).

        Start a new session for the best results, or continue — the oldest messages will be dropped to fit the window.
        """
        let decision = await requestContextLimitConfirmation(message: message)
        switch decision {
        case .proceed:
            contextWarnAcknowledged.insert(sid)
            return true
        case .newSession:
            let carriedAttachments = pendingAttachments
            createSession()
            draft = newUserText
            pendingAttachments = carriedAttachments
            return false
        case .cancel:
            return false
        }
    }

    private func passBudgetGate() async -> Bool {
        if budgetBypassForEval || !budgetEnabled { return true }
        let estimate = estimateOutgoingCostUsd()
        switch evaluateBudgetGate(estimate: estimate) {
        case .allow:
            return true
        case .hardBlock(let message):
            lastError = message
            return false
        case .softConfirm(let message):
            let proceed = await requestBudgetConfirmation(message: message)
            if !proceed {
                lastError = nil
            }
            return proceed
        }
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
        mcpEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "aril.mcpEnabled")
    }

    func updateMCPServer(_ server: MCPServerConfig) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == server.id }) else { return }
        var next = server
        if next.isDeferred {
            next.enabled = false
        }
        mcpServers[idx] = next
        MCPKeychainStore.save(serverID: next.id, apiKey: next.apiKey)
        saveMCPServers()
    }

    func setMCPServerEnabled(id: UUID, enabled: Bool) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        if mcpServers[idx].isDeferred { return }
        // Managed servers own their own process lifecycle; route by preset.
        if mcpServers[idx].isManaged {
            let presetId = mcpServers[idx].presetId
            Task {
                if presetId == MCPServerConfig.codescanPresetId {
                    enabled ? await startCodeScanServer() : stopCodeScanServer()
                } else {
                    enabled ? await startNmapServer() : stopNmapServer()
                }
            }
            return
        }
        mcpServers[idx].enabled = enabled
        saveMCPServers()
    }

    /// Resolve a managed server token, preferring the copy already loaded into memory
    /// (populated by `loadMCPServers`) so we don't hit the Keychain again. Falls back
    /// to a Keychain read, and finally generates + persists a fresh token if absent.
    private func ensureManagedToken(for id: UUID) -> String {
        if let idx = mcpServers.firstIndex(where: { $0.id == id }) {
            let inMemory = mcpServers[idx].apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !inMemory.isEmpty {
                return inMemory
            }
        }
        let existing = MCPKeychainStore.load(serverID: id)
        if !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let token = NmapServerManager.generateToken()
        MCPKeychainStore.save(serverID: id, apiKey: token)
        return token
    }

    // MARK: - Managed Nmap MCP server

    private var nmapPreset: MCPServerConfig? {
        mcpServers.first(where: { $0.presetId == MCPServerConfig.nmapPresetId })
    }

    func refreshNmapInstalled() {
        nmapInstalled = nmapServerManager.refreshNmapInstalled()
    }

    /// Generate/reuse a token, write config.json, launch the server, and wire the preset.
    func startNmapServer() async {
        guard let idx = mcpServers.firstIndex(where: { $0.presetId == MCPServerConfig.nmapPresetId })
        else { return }
        let id = mcpServers[idx].id
        nmapServerBusy = true
        defer { nmapServerBusy = false }

        let token = ensureManagedToken(for: id)
        let ok = await nmapServerManager.ensureRunning(token: token)
        nmapServerRunning = ok
        nmapInstalled = nmapServerManager.nmapInstalled
        nmapServerStatus = nmapServerManager.lastMessage

        if let latest = mcpServers.firstIndex(where: { $0.id == id }) {
            mcpServers[latest].apiKey = token
            mcpServers[latest].url = nmapServerManager.mcpURL
            mcpServers[latest].enabled = ok
            if !ok {
                mcpServers[latest].lastCheckStatus = .failed
                mcpServers[latest].lastCheckMessage = nmapServerManager.lastMessage
            }
            saveMCPServers()
        }
    }

    func stopNmapServer() {
        nmapServerManager.stop()
        nmapServerRunning = false
        nmapServerStatus = "Nmap MCP stopped"
        if let idx = mcpServers.firstIndex(where: { $0.presetId == MCPServerConfig.nmapPresetId }) {
            mcpServers[idx].enabled = false
            saveMCPServers()
        }
    }

    // MARK: - Managed Semgrep code-scan MCP server

    private var codeScanPreset: MCPServerConfig? {
        mcpServers.first(where: { $0.presetId == MCPServerConfig.codescanPresetId })
    }

    func refreshSemgrepInstalled() {
        semgrepInstalled = codeScanServerManager.refreshSemgrepInstalled()
    }

    /// Generate/reuse a token, write config.json, launch the server, and wire the preset.
    func startCodeScanServer() async {
        guard let idx = mcpServers.firstIndex(where: { $0.presetId == MCPServerConfig.codescanPresetId })
        else { return }
        let id = mcpServers[idx].id
        codeScanServerBusy = true
        defer { codeScanServerBusy = false }

        let token = ensureManagedToken(for: id)
        let ok = await codeScanServerManager.ensureRunning(token: token)
        codeScanServerRunning = ok
        semgrepInstalled = codeScanServerManager.semgrepInstalled
        codeScanServerStatus = codeScanServerManager.lastMessage

        if let latest = mcpServers.firstIndex(where: { $0.id == id }) {
            mcpServers[latest].apiKey = token
            mcpServers[latest].url = codeScanServerManager.mcpURL
            mcpServers[latest].enabled = ok
            if !ok {
                mcpServers[latest].lastCheckStatus = .failed
                mcpServers[latest].lastCheckMessage = codeScanServerManager.lastMessage
            }
            saveMCPServers()
        }
    }

    func stopCodeScanServer() {
        codeScanServerManager.stop()
        codeScanServerRunning = false
        codeScanServerStatus = "Code Scan MCP stopped"
        if let idx = mcpServers.firstIndex(where: { $0.presetId == MCPServerConfig.codescanPresetId }) {
            mcpServers[idx].enabled = false
            saveMCPServers()
        }
    }

    func setMCPServerAPIKey(id: UUID, apiKey: String) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        mcpServers[idx].apiKey = apiKey
        MCPKeychainStore.save(serverID: id, apiKey: apiKey)
        saveMCPServers()
    }

    func addCustomMCPServer(_ server: MCPServerConfig = MCPServerConfig()) {
        var next = server
        next.presetId = nil
        next.isEditable = true
        next.isDeferred = false
        if next.transport == .stdio {
            next.transport = .http
        }
        mcpServers.append(next)
        MCPKeychainStore.save(serverID: next.id, apiKey: next.apiKey)
        saveMCPServers()
    }

    func deleteMCPServer(id: UUID) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        guard mcpServers[idx].presetId == nil else { return }
        MCPKeychainStore.delete(serverID: id)
        mcpServers.remove(at: idx)
        saveMCPServers()
    }

    func resetMCPPreset(id: UUID) {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }),
              let presetId = mcpServers[idx].presetId,
              let factory = MCPServerConfig.builtInPresets().first(where: { $0.presetId == presetId })
        else { return }
        var restored = factory
        restored.id = mcpServers[idx].id
        restored.apiKey = ""
        MCPKeychainStore.delete(serverID: restored.id)
        mcpServers[idx] = restored
        saveMCPServers()
    }

    func checkMCPServerConnection(id: UUID) async {
        guard let idx = mcpServers.firstIndex(where: { $0.id == id }) else { return }
        var server = mcpServers[idx]
        if server.isDeferred {
            server.lastCheckStatus = .deferred
            server.lastCheckMessage = "Coming soon — requires local Node (stdio)."
            mcpServers[idx] = server
            saveMCPServers()
            return
        }
        mcpCheckingServerID = id
        defer { mcpCheckingServerID = nil }
        do {
            let result = try await client.checkMCPServer(
                baseURL: gatewayURL,
                url: server.url,
                authStyle: server.authStyle.rawValue,
                authHeaderName: server.authHeaderName,
                apiKey: server.apiKey
            )
            server.lastCheckStatus = result.ok ? .ok : .failed
            let toolsNote: String = {
                guard result.ok, let count = result.toolsCount else { return "" }
                let names = (result.toolNames ?? []).prefix(8).joined(separator: ", ")
                if names.isEmpty { return " · \(count) tools" }
                return " · \(count) tools (\(names)\(count > 8 ? ", …" : ""))"
            }()
            server.lastCheckMessage = result.message + toolsNote
            if let ms = result.latencyMs {
                server.lastCheckMessage += " · \(ms) ms"
            }
        } catch {
            server.lastCheckStatus = .failed
            server.lastCheckMessage = error.localizedDescription
        }
        if let latest = mcpServers.firstIndex(where: { $0.id == id }) {
            mcpServers[latest] = server
            saveMCPServers()
        }
    }

    private func saveMCPServers() {
        // Persist non-secrets only (apiKey stripped by encode).
        if let data = try? JSONEncoder().encode(mcpServers) {
            UserDefaults.standard.set(data, forKey: "aril.mcpServers")
        }
    }

    private static func loadMCPServers() -> [MCPServerConfig] {
        let presets = MCPServerConfig.builtInPresets()
        var byPreset: [String: MCPServerConfig] = [:]
        for p in presets { if let pid = p.presetId { byPreset[pid] = p } }

        var customs: [MCPServerConfig] = []
        if let data = UserDefaults.standard.data(forKey: "aril.mcpServers"),
           let saved = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            for var row in saved {
                if let pid = row.presetId, var preset = byPreset[pid] {
                    // Keep stable preset id UUID from factory; restore user enable + URL override if editable.
                    preset.enabled = row.enabled && !preset.isDeferred
                    if row.isEditable || !preset.url.isEmpty {
                        // Allow advanced URL overrides only when user saved a non-empty url on a preset.
                        if !row.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           row.url != MCPServerConfig.builtInPresets().first(where: { $0.presetId == pid })?.url {
                            // Keep factory URL for non-editable presets.
                            if preset.isEditable {
                                preset.url = row.url
                            }
                        }
                    }
                    preset.lastCheckStatus = row.lastCheckStatus
                    preset.lastCheckMessage = row.lastCheckMessage
                    preset.apiKey = MCPKeychainStore.load(serverID: preset.id)
                    byPreset[pid] = preset
                } else if row.presetId == nil {
                    row.apiKey = MCPKeychainStore.load(serverID: row.id)
                    customs.append(row)
                }
            }
        }

        var merged: [MCPServerConfig] = MCPServerConfig.builtInPresets().compactMap { factory in
            guard let pid = factory.presetId else { return factory }
            var row = byPreset[pid] ?? factory
            if row.apiKey.isEmpty {
                row.apiKey = MCPKeychainStore.load(serverID: row.id)
            }
            return row
        }
        merged.append(contentsOf: customs)
        return merged
    }

    private func bootstrap() async {
        // Cache already loaded in init; refresh again in case another process wrote.
        loadLocalSessions()
        if soloMode {
            await gatewayManager.ensureRunning()
            gatewayURL = gatewayManager.baseURL
        }
        await refreshHealth(reloadSessionsOnReady: false)
        await refreshContextLimits()
        await loadSessions(retryCount: 8)
        reconcileSelection()
        // Default: start each launch on a fresh session to minimise context exhaustion.
        // Users can opt into reopening the most recent session via Preferences.
        if !openLastSessionOnStartup {
            createSession()
        }
        saveLocalSessions()
        // Always keep default rates available; overlay live OpenRouter pricing only when a key is set.
        applyDefaultModelPricing()
        if openRouterConfigured {
            await refreshModelPricing(forceRefresh: true)
        } else {
            fillMissingPricingWithDefaults()
        }
        // Managed Nmap server: reflect nmap availability, resume if it was left on.
        refreshNmapInstalled()
        if mcpEnabled, let preset = nmapPreset, preset.enabled {
            await startNmapServer()
        }
        // Managed Semgrep code-scan server: reflect availability, resume if left on.
        refreshSemgrepInstalled()
        if mcpEnabled, let preset = codeScanPreset, preset.enabled {
            await startCodeScanServer()
        }
        beginGatewayActivity()
        startHealthPolling()
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
        for model in modelCatalog { ids.insert(model) }
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

    func refreshWeeklyRankings(forceRefresh: Bool = false) async {
        isLoadingWeeklyRankings = true
        weeklyRankingsError = nil
        defer { isLoadingWeeklyRankings = false }
        do {
            let response = try await client.openRouterWeeklyRankings(
                baseURL: gatewayURL,
                limit: 25,
                refresh: forceRefresh
            )
            openRouterWeeklyRankings = response.models
        } catch {
            weeklyRankingsError = error.localizedDescription
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
            healthFailStreak = 0
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
            // Solo: try waking / restarting the local gateway before declaring offline.
            if soloMode {
                await gatewayManager.ensureRunning()
                gatewayURL = gatewayManager.baseURL
                if let health = try? await client.health(baseURL: gatewayURL), health.status == "ok" {
                    healthFailStreak = 0
                    gatewayReady = true
                    chatProvider = health.chatProvider ?? "unknown"
                    openRouterConfigured = health.openrouterConfigured == true
                    gatewayStatus = health.gateway == "ready" ? "Gateway ready" : health.status
                    await refreshOpenRouterKeyStatus()
                    await refreshOpenRouterStatus()
                    await refreshDatabaseStatus()
                    if reloadSessionsOnReady, !wasReady {
                        await loadSessions(retryCount: 5)
                        reconcileSelection()
                        saveLocalSessions()
                    }
                    return
                }
            }
            healthFailStreak += 1
            // Require two consecutive failures so a single idle blip doesn't flash red.
            guard healthFailStreak >= 2 || !wasReady else { return }
            gatewayReady = false
            gatewayStatus = soloMode ? "Starting gateway…" : "Gateway offline"
            chatProvider = "offline"
            openRouterConfigured = false
            markOpenRouterUnavailable(reason: "Gateway offline")
            markDatabaseUnavailable(reason: "Gateway offline")
        }
    }

    /// Poll gateway / database / OpenRouter so the status footer stays fresh while idle.
    private func startHealthPolling() {
        healthPollTask?.cancel()
        healthPollTask = Task { [weak self] in
            // Initial delay so bootstrap's own refresh settles first.
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshHealth(reloadSessionsOnReady: false)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        if becomeActiveObserver == nil {
            becomeActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshHealth(reloadSessionsOnReady: false)
                }
            }
        }
    }

    private func stopHealthPolling() {
        healthPollTask?.cancel()
        healthPollTask = nil
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
            self.becomeActiveObserver = nil
        }
        endGatewayActivity()
    }

    /// Discourage App Nap from suspending the Solo gateway while ARIL is open.
    private func beginGatewayActivity() {
        guard gatewayActivity == nil else { return }
        gatewayActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Keep Solo gateway responsive for status and chat"
        )
    }

    private func endGatewayActivity() {
        if let gatewayActivity {
            ProcessInfo.processInfo.endActivity(gatewayActivity)
            self.gatewayActivity = nil
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
                } else if session.messages.count == existing.messages.count {
                    // Prefer the copy with real content over one whose images were
                    // dropped to a placeholder; fall back to the most recent update.
                    let newPlaceholders = Self.placeholderCount(session)
                    let oldPlaceholders = Self.placeholderCount(existing)
                    if newPlaceholders < oldPlaceholders {
                        byID[session.id] = session
                    } else if newPlaceholders == oldPlaceholders,
                              session.updatedAt > existing.updatedAt {
                        byID[session.id] = session
                    }
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

    /// Count messages whose generated image was reduced to a lossy placeholder.
    private static func placeholderCount(_ session: ChatSession) -> Int {
        session.messages.reduce(0) { $0 + ($1.content.contains("omitted-from-context") ? 1 : 0) }
    }

    func selectModel(_ model: String) {
        selectedModel = model
        routeMode = .manual
        UserDefaults.standard.set(model, forKey: "aril.lastModel")
    }

    /// Insert `model` at the top of the Manual shortlist. Caps at `maxModelCatalogSize`
    /// by dropping the oldest (last) entry when a new id is added.
    func promoteModelToCatalog(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = modelCatalog.filter { $0 != trimmed }
        next.insert(trimmed, at: 0)
        if next.count > Self.maxModelCatalogSize {
            next = Array(next.prefix(Self.maxModelCatalogSize))
        }
        modelCatalog = next
        saveModelCatalog()
        Task { await refreshModelPricing(forceRefresh: false, focusing: trimmed) }
    }

    /// Select from the full OpenRouter catalog: promote into the shortlist, then lock Manual.
    func selectModelFromCatalog(_ model: String) {
        promoteModelToCatalog(model)
        selectModel(model)
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
        } else if routeMode == .auto {
            // Drop the Manual lock so the footer does not keep showing it, and so a
            // fast send before preview cannot re-send the Manual id as a hint.
            selectedModel = defaultModel
        }
    }

    /// Called on every draft change — panel appears immediately; analysis after idle.
    func schedulePreview() {
        previewTask?.cancel()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        // Slash commands own the `/` palette — never start the intelligence window
        // for them (it otherwise competes with / suppresses the command menu).
        if text.hasPrefix("/") {
            showIntelligencePanel = false
            preview = nil
            pinnedFullAnalysisPrompt = ""
            lastJudgementSkipPrompt = ""
            analysisStatus = .idle
            estimatedLatencyMs = nil
            return
        }

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

    // MARK: - Prompt history (shell-style ↑/↓ recall)

    private static func loadPromptHistory() -> [String] {
        (UserDefaults.standard.array(forKey: "aril.promptHistory") as? [String]) ?? []
    }

    private func savePromptHistory() {
        UserDefaults.standard.set(promptHistory, forKey: "aril.promptHistory")
    }

    /// Record a submitted prompt (dedupes consecutive repeats; caps at the limit).
    func recordPromptHistory(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if promptHistory.last == trimmed {
            // no-op: identical to the most recent entry
        } else {
            promptHistory.append(trimmed)
            if promptHistory.count > Self.promptHistoryLimit {
                promptHistory.removeFirst(promptHistory.count - Self.promptHistoryLimit)
            }
            savePromptHistory()
        }
        historyNavIndex = nil
        historyStash = ""
    }

    /// ↑ — recall an older prompt. Returns true if the key was consumed.
    func recallPreviousPrompt() -> Bool {
        guard !promptHistory.isEmpty else { return false }
        if let idx = historyNavIndex {
            guard idx > 0 else { return true }
            historyNavIndex = idx - 1
        } else {
            historyStash = draft
            historyNavIndex = promptHistory.count - 1
        }
        if let idx = historyNavIndex { draft = promptHistory[idx] }
        return true
    }

    /// ↓ — move toward newer prompts, restoring the stashed draft past the newest.
    func recallNextPrompt() -> Bool {
        guard let idx = historyNavIndex else { return false }
        if idx < promptHistory.count - 1 {
            historyNavIndex = idx + 1
            draft = promptHistory[idx + 1]
        } else {
            historyNavIndex = nil
            draft = historyStash
            historyStash = ""
        }
        return true
    }

    /// Called when the draft changes from typing; drops history browsing if edited.
    func noteDraftEditedFromTyping() {
        guard let idx = historyNavIndex else { return }
        if draft != promptHistory[idx] && draft != historyStash {
            historyNavIndex = nil
            historyStash = ""
        }
    }

    // MARK: - Slash commands

    /// One entry in the `/` command palette.
    struct SlashCommand: Identifiable, Hashable {
        let id: String       // canonical token, e.g. "/status"
        let summary: String  // one-line description shown in the palette
    }

    /// Source of truth for the command palette (canonical commands + base summaries).
    ///
    /// `/nmap` and `/codescan` summaries are overridden at runtime by
    /// `paletteCommands` to reflect whether their MCP server is enabled.
    static let slashCommands: [SlashCommand] = [
        SlashCommand(id: "/status", summary: "Health check — gateway, OpenRouter, Nmap, code scan, MCP, latest release"),
        SlashCommand(id: "/update", summary: "Check for a newer ARIL release and install it to /Applications"),
        SlashCommand(id: "/nmap", summary: "Example Nmap prompts — port, host, and vuln scans"),
        SlashCommand(id: "/codescan", summary: "Example Semgrep prompts — scan a path or inline code"),
        SlashCommand(id: "/clear", summary: "Clear the current chat transcript"),
        SlashCommand(id: "/reset", summary: "Delete ALL sessions and Learning entries (asks to confirm)"),
        SlashCommand(id: "/exit", summary: "Quit ARIL"),
        SlashCommand(id: "/help", summary: "Show the list of commands"),
    ]

    /// True when the master MCP switch is on and the managed Nmap preset is enabled.
    var nmapServerEnabled: Bool {
        mcpEnabled && (nmapPreset?.enabled ?? false)
    }

    /// True when the master MCP switch is on and the managed Semgrep preset is enabled.
    var codeScanServerEnabled: Bool {
        mcpEnabled && (codeScanPreset?.enabled ?? false)
    }

    /// Palette commands with runtime-computed summaries (server enabled/disabled state).
    var paletteCommands: [SlashCommand] {
        Self.slashCommands.map { command in
            switch command.id {
            case "/nmap":
                return SlashCommand(
                    id: command.id,
                    summary: nmapServerEnabled
                        ? command.summary
                        : "Example Nmap prompts — ⚠︎ Nmap MCP server disabled"
                )
            case "/codescan":
                return SlashCommand(
                    id: command.id,
                    summary: codeScanServerEnabled
                        ? command.summary
                        : "Example Semgrep prompts — ⚠︎ Code Scan MCP server disabled"
                )
            default:
                return command
            }
        }
    }

    /// Highlighted row in the palette while it's open.
    @Published var slashMenuIndex: Int = 0
    /// True when the user dismissed the palette (Esc) without changing the draft.
    @Published var slashMenuDismissed: Bool = false

    /// Commands matching the current draft prefix (empty when the palette is inert).
    var filteredSlashCommands: [SlashCommand] {
        let q = draft.lowercased()
        guard q.hasPrefix("/"), !q.contains(" "), !q.contains("\n") else { return [] }
        if q == "/" { return paletteCommands }
        return paletteCommands.filter { $0.id.hasPrefix(q) }
    }

    /// Whether the `/` command palette should be shown above the input bar.
    var slashMenuVisible: Bool {
        !slashMenuDismissed && !filteredSlashCommands.isEmpty
    }

    func slashMenuMove(_ delta: Int) {
        let items = filteredSlashCommands
        guard !items.isEmpty else { return }
        slashMenuIndex = max(0, min(items.count - 1, slashMenuIndex + delta))
    }

    /// Run the highlighted command immediately.
    func executeSelectedSlash() {
        let items = filteredSlashCommands
        guard items.indices.contains(slashMenuIndex) else { return }
        let cmd = items[slashMenuIndex].id
        slashMenuIndex = 0
        slashMenuDismissed = false
        draft = ""
        _ = handleSlashCommand(cmd)
    }

    /// Insert the highlighted command (with a trailing space) without running it.
    func insertSelectedSlash() {
        let items = filteredSlashCommands
        guard items.indices.contains(slashMenuIndex) else { return }
        draft = items[slashMenuIndex].id + " "
        slashMenuIndex = 0
    }

    func dismissSlashMenu() {
        slashMenuDismissed = true
    }

    /// Keep the palette selection valid and re-arm it as the draft changes.
    func onDraftChangedForSlash() {
        slashMenuDismissed = false
        if slashMenuIndex >= filteredSlashCommands.count {
            slashMenuIndex = 0
        }
    }

    /// Handle `/clear`, `/status`, `/help`. Returns true if `raw` was a known command.
    func handleSlashCommand(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() } ?? ""
        switch command {
        case "/clear", "/cls":
            recordPromptHistory(trimmed)
            draft = ""
            clearCurrentTranscript()
            return true
        case "/status", "/health":
            recordPromptHistory(trimmed)
            draft = ""
            Task { await runStatusCommand() }
            return true
        case "/update", "/upgrade":
            recordPromptHistory(trimmed)
            draft = ""
            Task { await runUpdateCommand() }
            return true
        case "/help", "/?":
            recordPromptHistory(trimmed)
            draft = ""
            appendLocalAssistantNote(slashHelpText)
            return true
        case "/nmap":
            recordPromptHistory(trimmed)
            draft = ""
            appendLocalAssistantNote(nmapExamplesNote())
            return true
        case "/codescan", "/code":
            recordPromptHistory(trimmed)
            draft = ""
            appendLocalAssistantNote(codeScanExamplesNote())
            return true
        case "/reset":
            recordPromptHistory(trimmed)
            draft = ""
            showResetConfirmation = true
            return true
        case "/exit", "/quit":
            recordPromptHistory(trimmed)
            draft = ""
            shutdown()
            NSApplication.shared.terminate(nil)
            return true
        default:
            return false
        }
    }

    /// Backing flag for the `/reset` confirmation alert (presented by ContentView).
    @Published var showResetConfirmation = false

    /// `/update` confirmation — non-nil message shows the upgrade alert.
    @Published var updateConfirmMessage: String?
    /// Pending release waiting on the upgrade alert.
    private var pendingUpdateRelease: AppUpdateService.LatestRelease?
    /// True while download/install is in progress (disables re-entry).
    @Published var isUpdatingApp = false
    /// Note id for in-place progress updates during `/update`.
    private var updateNoteID: UUID?

    /// Wipe every session and all Learning/judgement records. Destructive; only run
    /// after the user confirms the `/reset` warning.
    func performReset() async {
        await deleteAllSessions()
        await deleteAllStoreRecords(includeWins: true)
        lastError = nil
        appendLocalAssistantNote(
            "**Reset complete** — all sessions and Learning entries were cleared."
        )
    }

    private var slashHelpText: String {
        var lines = ["**ARIL commands**", ""]
        for command in paletteCommands {
            lines.append("- `\(command.id)` — \(command.summary)")
        }
        lines.append("")
        lines.append(
            "Tip: type `/` for the command menu, or press ↑ / ↓ in the prompt box to recall recent prompts (last \(Self.promptHistoryLimit))."
        )
        return lines.joined(separator: "\n")
    }

    /// Example prompts for the managed Nmap MCP server (`/nmap`).
    private func nmapExamplesNote() -> String {
        var lines: [String] = ["**Nmap MCP — example prompts**", ""]
        if !nmapServerEnabled {
            lines.append(
                "⚠︎ The Nmap MCP server is currently **disabled**. Enable **Nmap Scanner (local)** in Preferences → MCP (and turn on **Use MCP servers**) before running these."
            )
            lines.append("")
        }
        lines.append(contentsOf: [
            "- use nmap mcp to scan tcp ports 1-100 on google.com",
            "- use nmap mcp to do a quick scan of scanme.nmap.org",
            "- use nmap mcp to scan host 4.4.4.4",
            "- use nmap mcp to run a vuln scan on 127.0.0.1",
            "- use nmap mcp to do a service/version scan of example.com on ports 80,443",
            "",
            "Copy one into the prompt box (edit the target) and send it.",
        ])
        return lines.joined(separator: "\n")
    }

    /// Example prompts for the managed Semgrep code-scan MCP server (`/codescan`).
    private func codeScanExamplesNote() -> String {
        var lines: [String] = ["**Code Scanner (Semgrep) MCP — example prompts**", ""]
        if !codeScanServerEnabled {
            lines.append(
                "⚠︎ The Code Scan MCP server is currently **disabled**. Enable **Code Scanner (Semgrep, local)** in Preferences → MCP (and turn on **Use MCP servers**) before running these."
            )
            lines.append("")
        }
        lines.append(contentsOf: [
            "- use the code scanner to run a security check on /path/to/project",
            "- use semgrep mcp to scan this file: /path/to/app.py",
            "- use the code scanner with the p/owasp-top-ten ruleset on /path/to/src",
            "- use semgrep mcp to scan this code for vulnerabilities (filename app.py):\n    ```python\n    def run(x):\n        return eval(x)\n    ```",
            "- use the code scanner with a custom rule to flag eval() calls in the snippet above",
            "",
            "Provide a path, or paste inline code with a filename so the language is detected.",
        ])
        return lines.joined(separator: "\n")
    }

    /// Clear the visible transcript for the current session (in place).
    func clearCurrentTranscript() {
        compareResults = []
        compareRouteCategory = nil
        preferredCompareModel = nil
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        lastError = nil
        guard let sid = selectedSessionID else { return }
        updateSession(sid) { session in
            session.messages.removeAll()
            session.totalCostUsd = 0
        }
    }

    /// Append a local (non-billed) assistant note to the current session.
    private func appendLocalAssistantNote(_ text: String) {
        ensureSession()
        guard let sid = selectedSessionID else { return }
        updateSession(sid) { $0.messages.append(ChatMessage(role: .assistant, content: text)) }
    }

    /// Update the most recent assistant note in place (used to refresh `/status`).
    private func updateLastAssistantNote(id: UUID, text: String) {
        guard let sid = selectedSessionID,
              let i = sessions.firstIndex(where: { $0.id == sid }),
              let m = sessions[i].messages.firstIndex(where: { $0.id == id }) else { return }
        var next = sessions
        next[i].messages[m].content = text
        sessions = next
        saveLocalSessions()
    }

    /// Run `/status`: probe gateway, OpenRouter, Nmap, MCP, and the latest GitHub release.
    func runStatusCommand() async {
        ensureSession()
        guard let sid = selectedSessionID else { return }
        let noteID = ChatMessage(role: .assistant, content: "")
        updateSession(sid) { $0.messages.append(ChatMessage(id: noteID.id, role: .assistant, content: "Running ARIL status check…")) }

        var lines: [String] = ["### ARIL status", ""]

        // Gateway
        if let health = try? await client.health(baseURL: gatewayURL) {
            let ver = health.version ?? "?"
            let provider = health.chatProvider ?? "?"
            lines.append("- **Gateway:** ✅ \(soloMode ? "Solo" : "Remote") · \(gatewayURL) · v\(ver) · provider \(provider)")
        } else {
            lines.append("- **Gateway:** ❌ not reachable at \(gatewayURL)")
        }

        // OpenRouter
        if openRouterConfigured {
            if let conn = try? await client.checkOpenRouterConnection(baseURL: gatewayURL) {
                let latency = conn.latencyMs.map { "\($0) ms" } ?? "—"
                let credits = conn.creditsRemaining.map { String(format: "$%.2f", $0) } ?? "unknown"
                lines.append("- **OpenRouter:** \(conn.ready ? "✅ ready" : "⚠️ not ready") · latency \(latency) · credits \(credits)")
            } else {
                lines.append("- **OpenRouter:** ❌ connection check failed")
            }
        } else {
            lines.append("- **OpenRouter:** ⚠️ no API key set (Preferences → General)")
        }

        // Nmap managed server
        refreshNmapInstalled()
        let nmapState = nmapServerRunning ? "✅ running on port \(nmapServerManager.port)" : "○ stopped"
        let nmapBin = nmapInstalled ? "nmap installed" : "nmap missing (brew install nmap)"
        lines.append("- **Nmap MCP:** \(nmapState) · \(nmapBin)")

        // Semgrep managed code-scan server
        refreshSemgrepInstalled()
        let codeState = codeScanServerRunning ? "✅ running on port \(codeScanServerManager.port)" : "○ stopped"
        let codeBin = semgrepInstalled ? "semgrep installed" : "semgrep missing (brew install semgrep)"
        lines.append("- **Code Scan MCP:** \(codeState) · \(codeBin)")

        // MCP servers
        if mcpEnabled {
            let ready = mcpServers.filter(\.isReady).count
            let enabled = mcpServers.filter(\.enabled).count
            lines.append("- **MCP servers:** on · \(ready) ready · \(enabled) enabled")
        } else {
            lines.append("- **MCP servers:** off")
        }

        // Latest release (GitHub)
        let current = appVersion
        if let latest = await fetchLatestReleaseTag() {
            let latestClean = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if AppUpdateService.isNewer(latestClean, than: current) {
                lines.append("- **Version:** ⚠️ \(current) installed · latest is \(latestClean) — run `/update` or https://github.com/fizzball/ARIL/releases/latest")
            } else if AppUpdateService.compareVersions(latestClean, current) == .orderedSame {
                lines.append("- **Version:** ✅ \(current) (latest)")
            } else {
                // Running newer than published (dev / local build).
                lines.append("- **Version:** \(current) (ahead of published \(latestClean))")
            }
        } else {
            lines.append("- **Version:** \(current) (latest release check unavailable)")
        }

        updateLastAssistantNote(id: noteID.id, text: lines.joined(separator: "\n"))
    }

    /// `/update`: check GitHub for a newer DMG and prompt to install into `/Applications`.
    func runUpdateCommand() async {
        if isUpdatingApp {
            appendLocalAssistantNote("An update is already in progress.")
            return
        }
        ensureSession()
        guard let sid = selectedSessionID else { return }
        let note = ChatMessage(role: .assistant, content: "Checking GitHub for the latest ARIL release…")
        updateNoteID = note.id
        updateSession(sid) { $0.messages.append(note) }

        let current = appVersion
        do {
            let release = try await AppUpdateService.fetchLatestRelease()
            if !AppUpdateService.isNewer(release.version, than: current) {
                let text: String
                if AppUpdateService.compareVersions(release.version, current) == .orderedSame {
                    text = "**ARIL update**\n\nYou’re on **\(current)** — that’s the latest release."
                } else {
                    text = "**ARIL update**\n\nYou’re on **\(current)**, which is newer than the latest published release (**\(release.version)**). No install needed."
                }
                updateLastAssistantNote(id: note.id, text: text)
                updateNoteID = nil
                return
            }
            updateLastAssistantNote(
                id: note.id,
                text: "**ARIL update**\n\nVersion **\(release.version)** is available (you have **\(current)**).\n\nConfirm in the dialog to download \(release.dmgName) and install it to `/Applications`."
            )
            pendingUpdateRelease = release
            updateConfirmMessage =
                "ARIL \(release.version) is available (you have \(current)).\n\nDownload \(release.dmgName) and replace /Applications/ARIL.app? ARIL will quit and relaunch when the install finishes."
        } catch {
            updateLastAssistantNote(
                id: note.id,
                text: "**ARIL update**\n\nCould not check for updates: \(error.localizedDescription)\n\nReleases: https://github.com/fizzball/ARIL/releases/latest"
            )
            updateNoteID = nil
        }
    }

    func respondToUpdateConfirm(_ upgrade: Bool) {
        updateConfirmMessage = nil
        if upgrade {
            guard let release = pendingUpdateRelease else { return }
            pendingUpdateRelease = nil
            Task { await performAppUpdate(release: release) }
            return
        }
        // Ignore dismiss-after-accept (alert binding may fire false after Upgrade).
        guard pendingUpdateRelease != nil else { return }
        pendingUpdateRelease = nil
        if let id = updateNoteID {
            updateLastAssistantNote(id: id, text: "**ARIL update**\n\nUpgrade cancelled.")
        }
        updateNoteID = nil
    }

    private func performAppUpdate(release: AppUpdateService.LatestRelease) async {
        isUpdatingApp = true
        let noteID = updateNoteID
        do {
            try await AppUpdateService.downloadAndScheduleInstall(release: release) { [weak self] message in
                guard let self, let noteID else { return }
                self.updateLastAssistantNote(
                    id: noteID,
                    text: "**ARIL update** → \(release.version)\n\n\(message)"
                )
            }
            if let noteID {
                updateLastAssistantNote(
                    id: noteID,
                    text: "**ARIL update** → \(release.version)\n\nInstaller started. Quitting so `/Applications/ARIL.app` can be replaced…"
                )
            }
            updateNoteID = nil
            isUpdatingApp = false
            shutdown()
            NSApplication.shared.terminate(nil)
        } catch {
            isUpdatingApp = false
            let msg = error.localizedDescription
            if let noteID {
                updateLastAssistantNote(
                    id: noteID,
                    text: "**ARIL update** failed\n\n\(msg)\n\nYou can install manually from https://github.com/fizzball/ARIL/releases/latest"
                )
            } else {
                appendLocalAssistantNote("**ARIL update** failed: \(msg)")
            }
            updateNoteID = nil
            lastError = msg
        }
    }

    /// Current app marketing version (e.g. "0.4.0").
    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    /// Fetch the latest ARIL release tag from GitHub (nil on any failure).
    private func fetchLatestReleaseTag() async -> String? {
        (try? await AppUpdateService.fetchLatestRelease())?.tag
    }

    func send(promptOverride: String? = nil) {
        // Intercept slash commands before starting a model turn.
        if promptOverride == nil {
            let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("/"), handleSlashCommand(raw) {
                return
            }
        }
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

        if !text.isEmpty {
            recordPromptHistory(text)
        }

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

        // Budget soft/hard gates — before mutating the session.
        if !(await passBudgetGate()) {
            return
        }

        // Context-window gate — warn near the 96k char limit before mutating the session.
        if !(await passContextGate(newUserText: text)) {
            return
        }

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

        let mcpForRequest: [MCPServerInRequestDTO] = {
            guard mcpEnabled else { return [] }
            return mcpServers.filter(\.isReady).map {
                MCPServerInRequestDTO(
                    id: $0.id.uuidString,
                    name: $0.name,
                    url: $0.url,
                    authStyle: $0.authStyle.rawValue,
                    authHeaderName: $0.authHeaderName,
                    apiKey: $0.apiKey.isEmpty ? nil : $0.apiKey
                )
            }
        }()

        // Auto must not send the Manual lock as `model` — the gateway ignores it for
        // Auto routing, but omitting it keeps the contract obvious.
        let requestModel: String? = routeMode == .manual ? selectedModel : nil

        let request = ChatRequest(
            messages: historyForAPI,
            model: requestModel,
            temperature: temperature,
            routeMode: routeMode,
            useCache: true,
            sessionId: sid.uuidString.lowercased(),
            previewId: nil,
            routingProfile: APIRoutingProfile(routingProfile),
            attachments: attachmentDTOs,
            webSearch: webSearchEnabled,
            skipAutoJudgement: interruptedIdleAnalysis,
            mcpServers: mcpForRequest
        )

        // Stream token UI updates are async; track receipt so we never fall back to
        // /v1/chat after the gateway already wrote a chat_transaction.
        let streamTokens = StreamTokenProbe()
        do {
            let done = try await client.chatStream(
                baseURL: gatewayURL,
                request: request,
                onToken: { [weak self] token in
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
                },
                onMCPStatus: { [weak self] server, tool, phase, note in
                    Task { @MainActor in
                        guard let self,
                              let i = self.sessions.firstIndex(where: { $0.id == sid }),
                              let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID })
                        else { return }
                        if self.generationPhase == .thinking {
                            self.generationPhase = .streaming
                        }
                        let line: String = {
                            switch phase {
                            case "preparing":
                                if tool == "connect" {
                                    return "Connecting to \(server)…\n"
                                }
                                return "Asking model with MCP tools…\n"
                            case "calling":
                                return "Using \(server) · \(tool)…\n"
                            case "progress":
                                let detail = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                return detail.isEmpty ? "" : "  ↳ \(detail)\n"
                            default:
                                return ""
                            }
                        }()
                        guard !line.isEmpty else { return }
                        var next = self.sessions
                        let existing = next[i].messages[m].content
                        if !existing.contains(line) {
                            next[i].messages[m].content = existing + line
                            self.sessions = next
                        }
                    }
                }
            )
            if Task.isCancelled { return }
            // Persist any generated image to disk before it gets stripped from history.
            persistInlineImages(sessionID: sid, assistantID: assistantID)
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
            if routeMode == .auto, !done.model.isEmpty {
                selectedModel = done.model
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
                persistInlineImages(sessionID: sid, assistantID: assistantID)
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
                persistInlineImages(sessionID: sid, assistantID: assistantID)
                applyActualCost(
                    sessionID: sid,
                    assistantID: assistantID,
                    model: response.model,
                    reportedCost: response.costUsd,
                    inputTokens: response.inputTokens,
                    outputTokens: response.outputTokens
                )
                if routeMode == .auto, !response.model.isEmpty {
                    selectedModel = response.model
                }
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
            session.messages[m].content = ChatMessage.withActualCostFooter(
                body,
                costUsd: cost,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens
            )
            session.recomputeTotalCost()
        }
        accrueDailySpend(cost)
    }

    /// Drop embedded base64 images / huge blobs from outbound context (UI keeps originals).
    nonisolated static func sanitizeContentForAPI(_ content: String) -> String {
        guard !content.isEmpty else { return content }
        var text = ChatMessage.stripActualCostFooter(content)
        text = sanitizeBulkyPayloads(text, truncateAt: 24_000, truncationMarker: "\n\n…[truncated for model context]")
        return text
    }

    /// Persist a slim copy of history while keeping actual-cost footers for session totals.
    nonisolated static func sanitizeContentForStorage(_ content: String) -> String {
        guard !content.isEmpty else { return content }
        return sanitizeBulkyPayloads(content, truncateAt: 48_000, truncationMarker: "\n\n…[truncated for storage]")
    }

    nonisolated private static func sanitizeBulkyPayloads(
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
            let model = ChatMessage.actualModelLeaf(from: text)
            let tokens = ChatMessage.actualTokenCounts(from: text)
            let footer = ChatMessage.actualCostUsd(from: text).map {
                ChatMessage.formatActualCostFooter(
                    $0,
                    model: model,
                    inputTokens: tokens?.input,
                    outputTokens: tokens?.output
                )
            } ?? ""
            let budget = max(0, maxChars - footer.count - truncationMarker.count)
            let keep = text.prefix(budget)
            text = String(keep) + truncationMarker + footer
        }
        return text
    }

    /// On-disk home for generated images so they survive app restarts.
    private var generatedImagesDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ARIL/GeneratedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write any inline base64 images in an assistant message to disk and rewrite the
    /// stored content to reference stable `file://` URLs. Inline `data:` images are
    /// stripped from both persisted history and model context, so persisting them as
    /// files is what lets generated images survive a restart. Returns true if changed.
    @discardableResult
    func persistInlineImages(sessionID sid: UUID, assistantID: UUID) -> Bool {
        guard let i = sessions.firstIndex(where: { $0.id == sid }),
              let m = sessions[i].messages.firstIndex(where: { $0.id == assistantID })
        else { return false }
        let original = sessions[i].messages[m].content
        let rewritten = Self.rewriteInlineImagesToFiles(original, directory: generatedImagesDir)
        guard rewritten != original else { return false }
        var next = sessions
        next[i].messages[m].content = rewritten
        sessions = next
        return true
    }

    /// Replace `![alt](data:image/...;base64,...)` with file-backed links, writing the
    /// decoded bytes into `directory`. Content without inline images is returned as-is.
    static func rewriteInlineImagesToFiles(_ content: String, directory: URL) -> String {
        guard content.contains("data:image/") else { return content }
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(data:image\/([a-zA-Z0-9.+-]+);base64,([A-Za-z0-9+/=\s]+)\)"#,
            options: [.caseInsensitive]
        ) else { return content }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }

        let mutable = NSMutableString(string: content)
        // Replace back-to-front so earlier match ranges stay valid after edits.
        for match in matches.reversed() {
            let altRange = match.range(at: 1)
            let alt = altRange.location != NSNotFound ? ns.substring(with: altRange) : ""
            let mime = ns.substring(with: match.range(at: 2)).lowercased()
            let rawB64 = ns.substring(with: match.range(at: 3))
            let b64 = rawB64.replacingOccurrences(of: #"\s"#, with: "", options: .regularExpression)
            guard let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]), !data.isEmpty
            else { continue }
            let ext = imageExtension(forMime: mime)
            // Content-address the file (sha256) so it matches the gateway's scheme and
            // identical images never duplicate on disk.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(32)
            let fileURL = directory.appendingPathComponent("img-\(digest).\(ext)")
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard (try? data.write(to: fileURL, options: .atomic)) != nil else { continue }
            }
            mutable.replaceCharacters(in: match.range, with: "![\(alt)](\(fileURL.absoluteString))")
        }
        return mutable as String
    }

    private static func imageExtension(forMime mime: String) -> String {
        if mime.contains("jpeg") || mime.contains("jpg") { return "jpg" }
        if mime.contains("gif") { return "gif" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("heic") { return "heic" }
        return "png"
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
                    ChatMessage(
                        role: .assistant,
                        content: ChatMessage.withActualCostFooter(
                            result.content,
                            costUsd: cost,
                            model: result.model,
                            inputTokens: result.inputTokens,
                            outputTokens: result.outputTokens
                        )
                    )
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
            categoryPreferWins = snap.categoryWins ?? [:]
            fingerprintPreferWins = snap.fingerprintWins ?? [:]
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
            let preferences = try await snap
            classifications = preferences.classifications
            categoryPreferWins = preferences.categoryWins ?? [:]
            fingerprintPreferWins = preferences.fingerprintWins ?? [:]
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

    func deleteAllStoreRecords(includeWins: Bool = false) async {
        do {
            _ = try await client.deleteAllStoreRecords(baseURL: gatewayURL, includeWins: includeWins)
            storeRecords = []
            classifications = []
            categoryPreferWins = [:]
            fingerprintPreferWins = [:]
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

    /// Learning → Run Auto eval: fixed smoke prompts through Auto routing.
    func runAutoEval() async {
        guard !isRunningAutoEval, !isSending else { return }
        isRunningAutoEval = true
        budgetBypassForEval = true
        let previousMode = routeMode
        routeMode = .auto
        evalLog = []
        defer {
            routeMode = previousMode
            budgetBypassForEval = false
            isRunningAutoEval = false
        }

        for prompt in AutoEvalPrompts.all {
            if Task.isCancelled { break }
            draft = prompt
            isSending = true
            beginGenerationTracking()
            await performSend(promptOverride: prompt)
            if isSending {
                endGenerationTracking()
            }

            let assistant = selectedSession?.messages.last(where: { $0.role == .assistant })
            let body = assistant?.content ?? ""
            let cost = ChatMessage.actualCostUsd(from: body)
            let ok = !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && lastError == nil
            let modelLeaf = exchangeLog.last?.model ?? selectedModel
            evalLog.append(
                EvalLogEntry(
                    prompt: prompt,
                    model: modelLeaf,
                    costUsd: cost,
                    ok: ok,
                    detail: ok ? nil : (lastError ?? "Empty response")
                )
            )
            lastError = nil
        }
        await loadStoreBrowser()
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
        stopHealthPolling()
        // Discard any sessions the user started but never sent a prompt into.
        if sessions.contains(where: { $0.messages.isEmpty }) {
            sessions.removeAll { $0.messages.isEmpty }
            if let sel = selectedSessionID, !sessions.contains(where: { $0.id == sel }) {
                selectedSessionID = sessions.first?.id
            }
        }
        saveLocalSessions()
        nmapServerManager.stop()
        codeScanServerManager.stop()
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

    private static func loadModelCatalog() -> [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: "aril.modelCatalog") {
            let cleaned = saved
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for id in cleaned where !unique.contains(id) {
                unique.append(id)
            }
            if !unique.isEmpty {
                return Array(unique.prefix(maxModelCatalogSize))
            }
        }
        return factoryModelCatalog
    }

    private func saveModelCatalog() {
        UserDefaults.standard.set(modelCatalog, forKey: "aril.modelCatalog")
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
        // Don't persist a brand-new session that has no messages yet — it is discarded on exit.
        if session.messages.isEmpty { return }
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
