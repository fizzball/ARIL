import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var sessions: [ChatSession] = ChatSession.samples
    @Published var selectedSessionID: UUID?
    @Published var draft: String = ""
    @Published var temperature: Double = 0.7
    @Published var routeMode: RouteMode = .auto
    @Published var selectedModel: String = "openai/gpt-4.1"
    @Published var gatewayURL: String = "http://127.0.0.1:8741"
    @Published var gatewayReady: Bool = false
    @Published var gatewayStatus: String = "Gateway offline"
    @Published var preview: PreviewResponse?
    @Published var isPreviewing: Bool = false
    @Published var isSending: Bool = false
    @Published var routingProfile: RoutingProfile = .default
    @Published var showIntelligencePanel: Bool = false
    @Published var lastError: String?

    private let client = ARILAPIClient()
    private var previewTask: Task<Void, Never>?

    var selectedSession: ChatSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    init() {
        selectedSessionID = sessions.first?.id
        Task { await refreshHealth() }
    }

    func createSession() {
        let session = ChatSession(title: "New session", messages: [])
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        draft = ""
        preview = nil
        showIntelligencePanel = false
        withHeroReset()
    }

    private func withHeroReset() {
        // placeholder for animation hook
    }

    func refreshHealth() async {
        do {
            let health = try await client.health(baseURL: gatewayURL)
            gatewayReady = health.status == "ok"
            gatewayStatus = health.gateway == "ready" ? "Gateway ready" : health.status
        } catch {
            gatewayReady = false
            gatewayStatus = "Gateway offline"
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
                    sessionId: selectedSessionID?.uuidString
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

        do {
            let response = try await client.chat(
                baseURL: gatewayURL,
                request: ChatRequest(
                    messages: sessions[idx].messages.map {
                        APIChatMessage(role: $0.role.rawValue, content: $0.content)
                    },
                    model: selectedModel,
                    temperature: temperature,
                    routeMode: routeMode,
                    useCache: true,
                    sessionId: sid.uuidString,
                    previewId: nil
                )
            )
            sessions[idx].messages.append(
                ChatMessage(role: .assistant, content: response.message.content)
            )
            draft = ""
            preview = nil
            showIntelligencePanel = false
            await refreshHealth()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyAlternative(_ alt: PromptAlternative) {
        draft = alt.text
        Task { await runPreview() }
    }

    private func ensureSession() {
        if selectedSessionID == nil {
            createSession()
        }
    }
}
