import Foundation
import CryptoKit

/// Fast AI filters: a criterion ("payment flow") becomes search terms once (one short
/// AI call, cached), then every file and section is scored locally from where those
/// terms occur. The result is a provisional rating for the whole project in seconds;
/// the AI then confirms only the strongest candidates.
enum FilterSearch {
    struct Match {
        var score: Double
        /// Terms found, most frequent first.
        var hits: [String]
    }

    // MARK: - Terms

    /// Search terms for `filter` — words, identifier fragments and synonyms, in the
    /// languages the project may use. Cached in `cache` by criterion.
    static func terms(for filter: ImportanceRater.Filter, cache: URL?) async throws -> [String] {
        let key = SHA256.hash(data: Data(("terms\u{1}" + filter.criterion.lowercased()).utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(24)
        let file = cache?.appendingPathComponent("terms-\(key).json")
        if let file, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode([String].self, from: data) {
            return cached
        }
        var request = CLICompletion.Request(
            prompt: "Criterion: \(filter.criterion)",
            systemPrompt: """
            You turn a topic into search terms for finding the parts of a project (code, docs, notes) that \
            are about it. Return 10-25 terms: words and short phrases, identifier fragments as they appear in \
            code (e.g. "checkout", "invoice", "stripe", "refund"), related concepts and synonyms, and the same \
            terms in Russian and English. Lowercase, no explanations.
            """,
            jsonSchema: ["type": "object",
                         "properties": ["terms": ["type": "array", "items": ["type": "string"]]],
                         "required": ["terms"]])
        request.model = AIAssistantPreferences.xrayModel(for: request.tool)
        request.effort = "low"
        request.timeout = 90
        let result = try await CLICompletion.run(request)
        var terms = ((result.structured as? [String: Any])?["terms"] as? [String] ?? [])
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 3 }
        // The criterion's own words always count.
        let ownWords = filter.criterion.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 }
        terms.append(contentsOf: ownWords)
        var seen = Set<String>()
        terms = terms.filter { seen.insert($0).inserted }
        if let file, let data = try? JSONEncoder().encode(terms) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return terms
    }

    // MARK: - Scoring

    /// Score of one text: a hit in the name weighs much more than one in the body, and
    /// many hits of one term count sub-linearly.
    static func score(name: String, text: String, terms: [String]) -> Match {
        let name = name.lowercased(), body = text.lowercased()
        var score = 0.0
        var counts: [(String, Int)] = []
        for term in terms {
            let inName = occurrences(of: term, in: name, limit: 5)
            let inBody = occurrences(of: term, in: body, limit: 60)
            guard inName + inBody > 0 else { continue }
            score += 6 * Double(inName) + 2 * log2(1 + Double(inBody))
            counts.append((term, inName * 10 + inBody))
        }
        return Match(score: score, hits: counts.sorted { $0.1 > $1.1 }.map(\.0))
    }

    private static func occurrences(of term: String, in text: String, limit: Int) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while count < limit, let found = text.range(of: term, options: .literal, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    /// Scores of files under `root` (read in parallel, up to 256 KB each).
    static func scoreFiles(_ paths: [String], root: URL, terms: [String]) -> [String: Match] {
        var results = [Match?](repeating: nil, count: paths.count)
        results.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                let url = root.appendingPathComponent(paths[i])
                guard let handle = try? FileHandle(forReadingFrom: url) else { return }
                defer { try? handle.close() }
                let text = String(decoding: (try? handle.read(upToCount: 256 * 1024)) ?? Data(), as: UTF8.self)
                out[i] = score(name: paths[i], text: text, terms: terms)
            }
        }
        var map: [String: Match] = [:]
        for (i, path) in paths.enumerated() { if let match = results[i] { map[path] = match } }
        return map
    }

    /// Relevance levels from scores: the top tenth "strong", the next quarter "moderate",
    /// any other hit "weak", no hit "none" — relative, so a broad topic still separates.
    static func levels(_ scores: [String: Double]) -> [String: String] {
        let positive = scores.values.filter { $0 > 0 }.sorted(by: >)
        guard !positive.isEmpty else { return scores.mapValues { _ in "none" } }
        let strong = max(8, positive[min(positive.count - 1, positive.count / 10)])
        let moderate = max(4, positive[min(positive.count - 1, positive.count * 35 / 100)])
        return scores.mapValues { value in
            value <= 0 ? "none" : value >= strong ? "strong" : value >= moderate ? "moderate" : "weak"
        }
    }

    /// The lines around the first hit, as evidence for the AI check.
    static func excerpt(of text: String, terms: [String], limit: Int = 400) -> String {
        let lower = text.lowercased()
        guard let first = terms.compactMap({ lower.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(text.prefix(limit))
        }
        let offset = lower.distance(from: lower.startIndex, to: first.lowerBound)
        let start = text.index(text.startIndex, offsetBy: max(0, offset - limit / 3), limitedBy: text.endIndex) ?? text.startIndex
        return String(text[start...].prefix(limit))
    }
}
