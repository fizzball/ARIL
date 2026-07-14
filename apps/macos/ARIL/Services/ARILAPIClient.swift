import Foundation

enum ARILAPIError: LocalizedError {
    case invalidURL
    case badStatus(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid gateway URL"
        case .badStatus(let code, let body): return "Gateway error \(code): \(body)"
        case .decoding(let err): return "Decode error: \(err.localizedDescription)"
        }
    }
}

final class ARILAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
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
