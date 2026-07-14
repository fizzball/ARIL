import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [ChatSession] = []
    @Published var selectedSessionID: UUID?
    @Published var draft: String = ""
    @Published var temperature: Double = 0.7
    @Published var routeMode: RouteMode = .auto
    @Published var selectedModel: String = "openai/gpt-4.1"
    @Published var gatewayURL: String = UserDefaults.standard.string(forKey: "aril.gatewayURL") ?? "http://127.0.0.1:8741"
    @Published var gatewayReady: Bool = false
    @Published var gatewayStatus: String = "Gateway offline"
    @Published var chatProvider: String = "stub"
    @Published var preview: PreviewResponse?
    @Published var isPreviewing: Bool = false
    @Published var isSending: Bool = false
    @Published var routingProfile: RoutingProfile = AppState.loadRoutingProfile()
    @Published var showIntelligencePanel: Bool = false
    @Published var lastError: String?

    private let client = ARILAPIClient()
    private var previewTask: Task<Void, Never>?

    var selectedSession: ChatSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    init() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
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
        Task { await persistSelectedSession() }
    }

    func refreshHealth() async {
        do {
            let health = try await client.health(baseURL: gatewayURL)
            gatewayReady = health.status == "ok"
            chatProvider = health.chatProvider ?? "unknown"
            if health.gateway == "ready" {
                gatewayStatus = health.openrouterConfigured == true
                    ? "Gateway ready · OpenRouter"
                    : "Gateway ready · stub"
            } else {
                gatewayStatus = health.status
            }
        } catch {
            gatewayReady = false
            gatewayStatus = "Gateway offline"
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

    func schedulePreview() {
        previewTask?.cancel()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 12 else {
            showIntelligencePanel = false
            preview = nil
            return
        }
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await runPreview()
        }
    }

    func runPreview() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPreviewing = true
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
                    routingProfile: APIRoutingProfile(routingProfile)
                )
            )
            preview = result
            showIntelligencePanel = true
            if routeMode == .auto {
                selectedModel = result.recommendedModel
            }
        } catch {
            lastError = error.localizedDescription
            showIntelligencePanel = false
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if preview == nil {
            await runPreview()
        }

        isSending = true
        lastError = nil
        defer { isSending = false }

        ensureSession()
        guard let sid = selectedSessionID,
              let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }

        sessions[idx].messages.append(ChatMessage(role: .user, content: text))
        if sessions[idx].title == "New session" {
            sessions[idx].title = String(text.prefix(42))
        }
        draft = ""
        preview = nil
        showIntelligencePanel = false

        let historyForAPI = sessions[idx].messages.map {
            APIChatMessage(role: $0.role.rawValue, content: $0.content)
        }

        let assistantID = UUID()
        sessions[idx].messages.append(ChatMessage(id: assistantID, role: .assistant, content: ""))

        let request = ChatRequest(
            messages: historyForAPI,
            model: selectedModel,
            temperature: temperature,
            routeMode: routeMode,
            useCache: true,
            sessionId: sid.uuidString,
            previewId: nil,
            routingProfile: APIRoutingProfile(routingProfile)
        )

        do {
            _ = try await client.chatStream(baseURL: gatewayURL, request: request) { [weak self] token in
                Task { @MainActor in
                    guard let self,
                          let i = self.sessions.firstIndex(where: { $0.id == sid }),
                          let m = self.sessions[i].messages.firstIndex(where: { $0.id == assistantID })
                    else { return }
                    self.sessions[i].messages[m].content += token
                }
            }
            sessions[idx].updatedAt = .now
            await refreshHealth()
        } catch {
            lastError = error.localizedDescription
            // Fallback to non-streaming
            do {
                let response = try await client.chat(baseURL: gatewayURL, request: request)
                if let m = sessions[idx].messages.firstIndex(where: { $0.id == assistantID }) {
                    sessions[idx].messages[m].content = response.message.content
                }
            } catch {
                lastError = error.localizedDescription
                sessions[idx].messages.removeAll { $0.id == assistantID }
            }
        }
    }

    func applyAlternative(_ alt: PromptAlternative) {
        draft = alt.text
        Task { await runPreview() }
    }

    func saveGatewayURL() {
        UserDefaults.standard.set(gatewayURL, forKey: "aril.gatewayURL")
    }

    func saveRoutingProfile() {
        if let data = try? JSONEncoder().encode(routingProfile) {
            UserDefaults.standard.set(data, forKey: "aril.routingProfile")
        }
        Task { await runPreview() }
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
}
