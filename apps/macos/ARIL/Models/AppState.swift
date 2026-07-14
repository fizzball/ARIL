import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

enum AnalysisStatus: Equatable {
    case idle
    case analysing(secondsRemaining: Int)
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

    /// Seconds of typing idle before prompt analysis runs.
    static let analysisIdleSeconds = 2

    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionID: UUID?
    @Published var draft: String = ""
    @Published var temperature: Double = 0.7
    @Published var routeMode: RouteMode = .auto
    @Published var selectedModel: String
    @Published var defaultModel: String
    @Published var gatewayURL: String
    @Published var soloMode: Bool
    @Published var gatewayReady: Bool = false
    @Published var gatewayStatus: String = "Gateway offline"
    @Published var chatProvider: String = "stub"
    @Published var preview: PreviewResponse?
    @Published var analysisStatus: AnalysisStatus = .idle
    @Published var isPreviewing: Bool = false
    @Published var isSending: Bool = false
    @Published var generationPhase: GenerationPhase = .idle
    @Published var generationElapsedMs: Int = 0
    @Published var routingProfile: RoutingProfile = AppState.loadRoutingProfile()
    @Published var showIntelligencePanel: Bool = false
    @Published var showAbout: Bool = false
    @Published var lastError: String?
    @Published var compareResults: [CompareResultDTO] = []
    @Published var lastCacheLabel: String = "—"
    @Published var lastLatencyMs: Int?
    @Published var estimatedLatencyMs: Int?
    @Published var preferredCompareModel: String?
    @Published var pendingAttachments: [PendingAttachment] = []
    @Published var webSearchEnabled: Bool = false
    @Published var userDisplayName: String

    private let client = ARILAPIClient()
    let gatewayManager = LocalGatewayManager()
    private var previewTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var generationTimerTask: Task<Void, Never>?
    private var lastUserPromptForPrefer: String = ""

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
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.2"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "32"
        return "\(short) (\(build))"
    }

    init() {
        let defaults = UserDefaults.standard
        let storedDefault = defaults.string(forKey: "aril.defaultModel") ?? "openai/gpt-4.1"
        defaultModel = storedDefault
        selectedModel = defaults.string(forKey: "aril.lastModel") ?? storedDefault
        gatewayURL = defaults.string(forKey: "aril.gatewayURL") ?? "http://127.0.0.1:8741"
        soloMode = defaults.object(forKey: "aril.soloMode") as? Bool ?? true
        userDisplayName = defaults.string(forKey: "aril.userDisplayName") ?? ""
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        if soloMode {
            await gatewayManager.ensureRunning()
            gatewayURL = gatewayManager.baseURL
        }
        await refreshHealth()
        await loadSessions()
        if selectedSessionID == nil {
            createSession()
        }
    }

    func createSession() {
        let session = ChatSession(title: "New session", messages: [])
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        preferredCompareModel = nil
        pendingAttachments = []
        Task { await persistSelectedSession() }
    }

    func deleteSession(_ id: UUID) async {
        sessions.removeAll { $0.id == id }
        if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
            draft = ""
            preview = nil
            showIntelligencePanel = false
            analysisStatus = .idle
            compareResults = []
            preferredCompareModel = nil
            pendingAttachments = []
        }
        if sessions.isEmpty {
            createSession()
        }
        do {
            try await client.deleteSession(baseURL: gatewayURL, id: id.uuidString)
        } catch {
            // Local removal already applied; gateway may be offline.
            lastError = error.localizedDescription
        }
    }

    func deleteAllSessions() async {
        let ids = sessions.map(\.id)
        sessions = []
        selectedSessionID = nil
        draft = ""
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        preferredCompareModel = nil
        pendingAttachments = []
        for id in ids {
            try? await client.deleteSession(baseURL: gatewayURL, id: id.uuidString)
        }
        createSession()
    }

    func refreshHealth() async {
        do {
            let health = try await client.health(baseURL: gatewayURL)
            gatewayReady = health.status == "ok"
            chatProvider = health.chatProvider ?? "unknown"
            if health.gateway == "ready" {
                let solo = soloMode ? " · Solo" : ""
                gatewayStatus = health.openrouterConfigured == true
                    ? "Gateway ready · OpenRouter\(solo)"
                    : "Gateway ready · stub\(solo)"
            } else {
                gatewayStatus = health.status
            }
        } catch {
            gatewayReady = false
            gatewayStatus = soloMode ? "Starting solo gateway…" : "Gateway offline"
            chatProvider = "offline"
        }
    }

    func loadSessions() async {
        do {
            let summaries = try await client.listSessions(baseURL: gatewayURL)
            var loaded: [ChatSession] = []
            for summary in summaries.prefix(40) {
                guard let uuid = UUID(uuidString: summary.id) else { continue }
                if let detail = try? await client.getSession(baseURL: gatewayURL, id: summary.id) {
                    let messages = detail.messages.compactMap { msg -> ChatMessage? in
                        guard let role = ChatMessage.Role(rawValue: msg.role) else { return nil }
                        return ChatMessage(role: role, content: msg.content)
                    }
                    loaded.append(
                        ChatSession(
                            id: uuid,
                            title: detail.title,
                            messages: messages,
                            updatedAt: ISO8601DateFormatter().date(from: detail.updatedAt) ?? .now
                        )
                    )
                }
            }
            if !loaded.isEmpty {
                sessions = loaded
                selectedSessionID = loaded.first?.id
            }
        } catch {
            // Keep local sessions if gateway history is unavailable
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
            analysisStatus = .idle
            estimatedLatencyMs = nil
            return
        }

        showIntelligencePanel = true
        preview = nil
        estimatedLatencyMs = nil
        let idle = Self.analysisIdleSeconds
        analysisStatus = .analysing(secondsRemaining: idle)

        previewTask = Task {
            for remaining in stride(from: idle, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                analysisStatus = .analysing(secondsRemaining: remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await runPreview()
        }
    }

    func runPreview() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPreviewing = true
        analysisStatus = .analysing(secondsRemaining: 0)
        lastError = nil
        defer { isPreviewing = false }
        do {
            let result = try await client.preview(
                baseURL: gatewayURL,
                request: PreviewRequest(
                    prompt: text,
                    temperature: temperature,
                    routeMode: routeMode,
                    preferredModel: selectedModel,
                    sessionId: selectedSessionID?.uuidString,
                    routingProfile: APIRoutingProfile(routingProfile),
                    enhanceAlternatives: true
                )
            )
            preview = result
            showIntelligencePanel = true
            analysisStatus = .ready
            updateCacheLabel(from: result)
            // Auto adopts the recommended model. Manual/Compare keep the user's pick
            // (still run analysis for grade, fit, cost, alternatives).
            if routeMode == .auto {
                selectedModel = result.recommendedModel
                objectWillChange.send()
            }
            await refreshEstimatedLatency(for: result.recommendedModel)
        } catch {
            lastError = error.localizedDescription
            analysisStatus = .idle
        }
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
        if let error {
            lastError = error
        }
    }

    private func performSend(promptOverride: String?) async {
        let text = (promptOverride ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pendingAttachments.isEmpty else { return }

        if promptOverride != nil {
            draft = text
        }

        // Always analyse first when we have text (including Manual — grades/alternatives),
        // but Manual never adopts the recommended model.
        if !text.isEmpty, (preview == nil || analysisStatus != .ready) {
            await runPreview()
        }

        isSending = true
        lastError = nil
        beginGenerationTracking()
        defer { endGenerationTracking() }

        ensureSession()
        guard let sid = selectedSessionID,
              let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }

        let attachmentNote: String = {
            guard !pendingAttachments.isEmpty else { return "" }
            let names = pendingAttachments.map(\.filename).joined(separator: ", ")
            return text.isEmpty ? "[Attached: \(names)]" : "\n\n[Attached: \(names)]"
        }()
        let displayText = text.isEmpty ? attachmentNote : text + attachmentNote

        lastUserPromptForPrefer = text.isEmpty ? displayText : text
        sessions[idx].messages.append(ChatMessage(role: .user, content: displayText))
        if sessions[idx].title == "New session" {
            sessions[idx].title = String((text.isEmpty ? pendingAttachments.first?.filename ?? "Attachment" : text).prefix(42))
        }
        draft = ""
        let attachmentsForSend = pendingAttachments
        pendingAttachments = []
        let lockedManualModel = UserDefaults.standard.string(forKey: "aril.lastModel") ?? defaultModel
        let compareModels: [String] = {
            if let routes = preview?.routes, routes.count >= 2 {
                return Array(routes.prefix(2).map(\.modelId))
            }
            // Distinct fallback pair so Compare always has two models
            let a = routeMode == .manual ? lockedManualModel : selectedModel
            let b = (a == routingProfile.cost) ? routingProfile.confidence : routingProfile.cost
            return a == b ? [a, defaultModel] : [a, b]
        }()
        let cacheEligible = preview?.cache.eligible ?? false
        preview = nil
        showIntelligencePanel = false
        analysisStatus = .idle
        compareResults = []
        preferredCompareModel = nil
        lastCacheLabel = cacheEligible ? "not cached" : "not eligible"

        let historyForAPI = sessions[idx].messages.map {
            APIChatMessage(role: $0.role.rawValue, content: $0.content)
        }

        if Task.isCancelled { return }

        if routeMode == .compare {
            await sendCompare(sessionID: sid, index: idx, history: historyForAPI, models: compareModels)
            return
        }

        if routeMode == .manual {
            selectedModel = lockedManualModel
        }

        let assistantID = UUID()
        sessions[idx].messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))

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
            sessionId: sid.uuidString,
            previewId: nil,
            routingProfile: APIRoutingProfile(routingProfile),
            attachments: attachmentDTOs,
            webSearch: webSearchEnabled
        )

        do {
            let done = try await client.chatStream(baseURL: gatewayURL, request: request) { [weak self] token in
                Task { @MainActor in
                    guard let self,
                          let i = self.sessions.firstIndex(where: { $0.id == sid }),
                          let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID })
                    else { return }
                    if self.generationPhase == .thinking {
                        self.generationPhase = .streaming
                    }
                    self.sessions[i].messages[m].content += token
                }
            }
            if Task.isCancelled { return }
            lastCacheLabel = (done.cached ?? false) ? "cached" : "not cached"
            if let ms = done.latencyMs {
                lastLatencyMs = ms
            }
            sessions[idx].updatedAt = .now
            await refreshHealth()
        } catch is CancellationError {
            sessions[idx].messages.removeAll { $0.id == assistantID && $0.content.isEmpty }
        } catch {
            if Task.isCancelled { return }
            lastError = error.localizedDescription
            do {
                let response = try await client.chat(baseURL: gatewayURL, request: request)
                if let m = sessions[idx].messages.firstIndex(where: { $0.id == assistantID }) {
                    sessions[idx].messages[m].content = response.message.content
                }
                lastCacheLabel = response.cached ? "cached" : "not cached"
                generationPhase = .streaming
            } catch {
                lastError = error.localizedDescription
                sessions[idx].messages.removeAll { $0.id == assistantID }
            }
        }
    }

    private func sendCompare(sessionID: UUID, index: Int, history: [APIChatMessage], models: [String]) async {
        generationPhase = .thinking
        do {
            let response = try await client.compare(
                baseURL: gatewayURL,
                request: CompareRequestDTO(
                    messages: history,
                    models: models,
                    temperature: temperature,
                    routingProfile: APIRoutingProfile(routingProfile),
                    sessionId: sessionID.uuidString,
                    useCache: true,
                    runProbe: true
                )
            )
            if Task.isCancelled { return }
            generationPhase = .streaming
            compareResults = response.results
            lastCacheLabel = response.results.contains(where: \.cached) ? "cached" : "not cached"
            if let fastest = response.results.map(\.latencyMs).min() {
                lastLatencyMs = fastest
            }
            sessions[index].updatedAt = .now
            await refreshHealth()
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
        }
    }

    func preferCompareResult(_ result: CompareResultDTO) async {
        preferredCompareModel = result.model
        selectModel(result.model)
        do {
            _ = try await client.prefer(
                baseURL: gatewayURL,
                request: PreferRequestDTO(
                    prompt: lastUserPromptForPrefer,
                    model: result.model,
                    category: nil,
                    sessionId: selectedSessionID?.uuidString
                )
            )
            if let idx = sessions.firstIndex(where: { $0.id == selectedSessionID }) {
                sessions[idx].messages.append(
                    ChatMessage(role: .assistant, content: result.content)
                )
            }
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

    private func persistSelectedSession() async {
        guard let session = selectedSession else { return }
        let payload = SessionUpsertDTO(
            id: session.id.uuidString,
            title: session.title,
            messages: session.messages.map { APIChatMessage(role: $0.role.rawValue, content: $0.content) }
        )
        _ = try? await client.upsertSession(baseURL: gatewayURL, session: payload)
    }

    deinit {
        // Process cleanup on main from gateway manager when app quits via App delegate if needed
    }
}
