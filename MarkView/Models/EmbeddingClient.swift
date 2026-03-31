import Foundation

/// OpenAI Embeddings API client — text-embedding-3-small (1536 dimensions)
class EmbeddingClient {
    private var apiKey: String?
    private let baseURL = "https://api.openai.com/v1/embeddings"
    private let model = "text-embedding-3-small"
    private let session = URLSession.shared
    static let dimensions = 1536

    var hasAPIKey: Bool { apiKey != nil && !(apiKey?.isEmpty ?? true) }

    init(apiKey: String? = nil) {
        self.apiKey = apiKey ?? Self.loadKey()
    }

    func updateAPIKey(_ key: String?) { self.apiKey = key; if let k = key { Self.saveKey(k) } }

    // MARK: - Embed

    /// Get embedding vector for a text chunk
    func embed(text: String) async throws -> [Float] {
        guard let apiKey = apiKey, !apiKey.isEmpty else { throw EmbeddingError.noAPIKey }

        let body: [String: Any] = [
            "model": model,
            "input": text,
            "dimensions": Self.dimensions
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 30

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw EmbeddingError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let first = dataArray.first,
              let embedding = first["embedding"] as? [Double] else {
            throw EmbeddingError.parseError
        }

        return embedding.map { Float($0) }
    }

    /// Batch embed multiple texts (up to 2048 per request)
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        guard let apiKey = apiKey, !apiKey.isEmpty else { throw EmbeddingError.noAPIKey }
        guard !texts.isEmpty else { return [] }

        let body: [String: Any] = [
            "model": model,
            "input": texts,
            "dimensions": Self.dimensions
        ]

        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 60

        let (responseData, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw EmbeddingError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.parseError
        }

        // Sort by index to maintain order
        let sorted = dataArray.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return sorted.compactMap { item in
            (item["embedding"] as? [Double])?.map { Float($0) }
        }
    }

    // MARK: - Vector Math

    /// Cosine similarity between two vectors
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Storage

    /// Save embedding vector to file
    static func saveEmbedding(_ vector: [Float], to url: URL) {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: url)
    }

    /// Load embedding vector from file
    static func loadEmbedding(from url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.withUnsafeBytes { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }

    // MARK: - Key Storage

    private static let storageKey = "com.markview.dde.openai.apikey"
    static func loadKey() -> String? { UserDefaults.standard.string(forKey: storageKey) }
    static func saveKey(_ key: String) { UserDefaults.standard.set(key, forKey: storageKey) }
}

enum EmbeddingError: Error, LocalizedError {
    case noAPIKey
    case httpError(Int, String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No OpenAI API key"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parseError: return "Failed to parse embedding response"
        }
    }
}
