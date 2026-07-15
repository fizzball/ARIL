import Foundation

enum ARILAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int, String)
    case decoding(Error)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid gateway URL"
        case .badStatus(let code, let body): return "Gateway error \(code): \(body)"
        case .decoding(let err): return "Decode error: \(err.localizedDescription)"
        case .stream(let msg): return msg
        }
    }
}

final class ARILAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Shared session with longer idle timeouts so slow TTFT / web-search streams
    /// don't die before the first token under URLSession defaults (~60s).
    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    init(session: URLSession = ARILAPIClient.defaultSession) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    func health(baseURL: String) async throws -> HealthResponse {
        let url = try url(baseURL, path: "/health")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func preview(baseURL: String, request: PreviewRequest) async throws -> PreviewResponse {
        try await post(baseURL, path: "/v1/preview", body: request)
    }

    func chat(baseURL: String, request: ChatRequest) async throws -> ChatResponseDTO {
        try await post(baseURL, path: "/v1/chat", body: request)
    }

    func listSessions(baseURL: String) async throws -> [SessionSummaryDTO] {
        let url = try url(baseURL, path: "/v1/sessions")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func getSession(baseURL: String, id: String) async throws -> SessionDetailDTO {
        let url = try url(baseURL, path: "/v1/sessions/\(id)")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func upsertSession(baseURL: String, session: SessionUpsertDTO) async throws -> SessionDetailDTO {
        var req = URLRequest(url: try url(baseURL, path: "/v1/sessions"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(session)
        let (data, response) = try await self.session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    func deleteSession(baseURL: String, id: String) async throws {
        var req = URLRequest(url: try url(baseURL, path: "/v1/sessions/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
    }

    func deleteAllSessions(baseURL: String) async throws {
        var req = URLRequest(url: try url(baseURL, path: "/v1/sessions"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
    }

    func preferences(baseURL: String) async throws -> PreferencesSnapshotDTO {
        let url = try url(baseURL, path: "/v1/preferences")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func updateClassification(
        baseURL: String,
        id: String,
        update: ClassificationUpdateDTO
    ) async throws -> ClassificationRecordDTO {
        var req = URLRequest(url: try url(baseURL, path: "/v1/preferences/classifications/\(id)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(update)
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    func deleteClassification(baseURL: String, id: String) async throws {
        var req = URLRequest(url: try url(baseURL, path: "/v1/preferences/classifications/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
    }

    func storeStats(baseURL: String) async throws -> StoreStatsDTO {
        let url = try url(baseURL, path: "/v1/store/stats")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func storeStatus(baseURL: String, check: Bool = true) async throws -> StoreStatusDTO {
        var components = URLComponents(
            url: try url(baseURL, path: "/v1/store/status"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "check", value: check ? "true" : "false")]
        guard let endpoint = components?.url else {
            throw ARILAPIError.invalidURL
        }
        let (data, response) = try await session.data(from: endpoint)
        try validate(response, data: data)
        return try decode(data)
    }

    func storeCheck(baseURL: String) async throws -> StoreStatusDTO {
        var req = URLRequest(url: try url(baseURL, path: "/v1/store/check"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    func storeRecords(baseURL: String) async throws -> [StoreRecordDTO] {
        let url = try url(baseURL, path: "/v1/store/records")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func updateStoreRetention(baseURL: String, retention: Int) async throws -> StoreStatsDTO {
        try await patch(
            baseURL,
            path: "/v1/store/retention",
            body: StoreRetentionUpdateDTO(retention: retention)
        )
    }

    func deleteStoreRecord(baseURL: String, id: String) async throws {
        var req = URLRequest(url: try url(baseURL, path: "/v1/store/records/\(id)"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
    }

    func deleteAllStoreRecords(baseURL: String) async throws -> StoreDeleteAllResponseDTO {
        var req = URLRequest(url: try url(baseURL, path: "/v1/store/records"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    func openRouterKeyStatus(baseURL: String) async throws -> OpenRouterKeyStatusDTO {
        let url = try url(baseURL, path: "/v1/settings/openrouter-key")
        let (data, response) = try await session.data(from: url)
        try validate(response, data: data)
        return try decode(data)
    }

    func setOpenRouterKey(baseURL: String, apiKey: String) async throws -> OpenRouterKeyStatusDTO {
        try await put(
            baseURL,
            path: "/v1/settings/openrouter-key",
            body: OpenRouterKeyUpdateDTO(apiKey: apiKey)
        )
    }

    func clearOpenRouterKey(baseURL: String) async throws -> OpenRouterKeyStatusDTO {
        var req = URLRequest(url: try url(baseURL, path: "/v1/settings/openrouter-key"))
        req.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    func modelPricing(
        baseURL: String,
        modelIDs: [String],
        refresh: Bool = false
    ) async throws -> ModelPricingResponseDTO {
        let ids = modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var components = URLComponents(url: try url(baseURL, path: "/v1/models/pricing"), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = []
        if !ids.isEmpty {
            query.append(URLQueryItem(name: "ids", value: ids.joined(separator: ",")))
        }
        if refresh {
            query.append(URLQueryItem(name: "refresh", value: "true"))
        }
        components?.queryItems = query.isEmpty ? nil : query
        guard let final = components?.url else { throw ARILAPIError.invalidURL }
        let (data, response) = try await session.data(from: final)
        try validate(response, data: data)
        return try decode(data)
    }

    func openRouterCatalog(
        baseURL: String,
        query: String = "",
        refresh: Bool = false
    ) async throws -> OpenRouterCatalogResponseDTO {
        var components = URLComponents(url: try url(baseURL, path: "/v1/models/catalog"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            items.append(URLQueryItem(name: "q", value: q))
        }
        if refresh {
            items.append(URLQueryItem(name: "refresh", value: "true"))
        }
        components?.queryItems = items.isEmpty ? nil : items
        guard let final = components?.url else { throw ARILAPIError.invalidURL }
        let (data, response) = try await session.data(from: final)
        try validate(response, data: data)
        return try decode(data)
    }

    private func put<Body: Encodable, Response: Decodable>(
        _ baseURL: String,
        path: String,
        body: Body
    ) async throws -> Response {
        var req = URLRequest(url: try url(baseURL, path: path))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    private func patch<Body: Encodable, Response: Decodable>(
        _ baseURL: String,
        path: String,
        body: Body
    ) async throws -> Response {
        var req = URLRequest(url: try url(baseURL, path: path))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    /// Consume SSE from `/v1/chat/stream`.
    func chatStream(
        baseURL: String,
        request: ChatRequest,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> StreamDoneEvent {
        var req = URLRequest(url: try url(baseURL, path: "/v1/chat/stream"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 300
        req.httpBody = try encoder.encode(request)

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ARILAPIError.badStatus(http.statusCode, "stream failed")
        }

        var eventName = "message"
        var dataLines: [String] = []
        var done: StreamDoneEvent?
        var receivedTokens = false
        var lastModel: String?

        func flushEvent() throws {
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll()
            let name = eventName
            eventName = "message"
            guard !payload.isEmpty else { return }

            if name == "token" {
                if let token = try? decoder.decode(StreamTokenEvent.self, from: Data(payload.utf8)) {
                    if !token.content.isEmpty {
                        receivedTokens = true
                        if let model = token.model { lastModel = model }
                        onToken(token.content)
                    }
                } else if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                          let content = obj["content"] as? String,
                          !content.isEmpty {
                    receivedTokens = true
                    onToken(content)
                }
            } else if name == "done" {
                // Soft-decode so a trailing schema quirk doesn't kill a successful stream.
                if let parsed = try? decoder.decode(StreamDoneEvent.self, from: Data(payload.utf8)) {
                    done = parsed
                } else if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                    done = StreamDoneEvent(
                        sessionId: obj["session_id"] as? String ?? request.sessionId ?? "",
                        model: obj["model"] as? String ?? lastModel ?? request.model ?? "unknown",
                        routeCategory: obj["route_category"] as? String,
                        inputTokens: obj["input_tokens"] as? Int,
                        outputTokens: obj["output_tokens"] as? Int,
                        costUsd: obj["cost_usd"] as? Double,
                        cached: obj["cached"] as? Bool,
                        latencyMs: obj["latency_ms"] as? Int
                    )
                }
            } else if name == "error" {
                if let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                   let err = obj["error"] as? String {
                    throw ARILAPIError.stream(err)
                }
                throw ARILAPIError.stream(payload)
            }
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if trimmed.hasPrefix("event:") {
                eventName = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("data:") {
                dataLines.append(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
                continue
            }
            if trimmed.isEmpty {
                try flushEvent()
            }
        }
        // Final event may arrive without a trailing blank line.
        try flushEvent()

        if let done { return done }

        // Connection closed after tokens — treat as a finished stream rather than a cryptic error.
        if receivedTokens {
            return StreamDoneEvent(
                sessionId: request.sessionId ?? "",
                model: lastModel ?? request.model ?? "unknown",
                routeCategory: nil,
                inputTokens: nil,
                outputTokens: nil,
                costUsd: nil,
                cached: false,
                latencyMs: nil
            )
        }
        throw ARILAPIError.stream("No response received from the model. Try sending again.")
    }

    func compare(baseURL: String, request: CompareRequestDTO) async throws -> CompareResponseDTO {
        try await post(baseURL, path: "/v1/compare", body: request)
    }

    func probe(baseURL: String, models: [String]) async throws -> ProbeResponseDTO {
        try await post(baseURL, path: "/v1/probe", body: ProbeRequestDTO(models: models))
    }

    func prefer(baseURL: String, request: PreferRequestDTO) async throws -> PreferResponseDTO {
        try await post(baseURL, path: "/v1/feedback/prefer", body: request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ baseURL: String,
        path: String,
        body: Body
    ) async throws -> Response {
        var req = URLRequest(url: try url(baseURL, path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try decode(data)
    }

    private func url(_ base: String, path: String) throws -> URL {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: root + path) else {
            throw ARILAPIError.invalidURL
        }
        return url
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ARILAPIError.badStatus(http.statusCode, body)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ARILAPIError.decoding(error)
        }
    }
}
