import Foundation

/// Hybrid search combining FTS5 + embeddings + graph proximity
/// Score = 0.45 * FTS5_BM25 + 0.35 * cosine_similarity + 0.20 * graph_proximity
@MainActor
class HybridSearch {
    let db: SemanticDatabase
    let embeddingClient: EmbeddingClient
    let embeddingsDir: URL

    init(db: SemanticDatabase, embeddingClient: EmbeddingClient, workspacePath: URL) {
        self.db = db
        self.embeddingClient = embeddingClient
        self.embeddingsDir = workspacePath.appendingPathComponent(".dde/cache/embeddings")
        try? FileManager.default.createDirectory(at: embeddingsDir, withIntermediateDirectories: true)
    }

    struct HybridResult {
        let documentId: String
        let title: String
        let snippet: String
        let score: Double
        let ftsScore: Double
        let semanticScore: Double
        let graphScore: Double
    }

    // MARK: - Search

    /// Hybrid search: FTS5 + optional embeddings + graph expansion
    func search(query: String, limit: Int = 20) async -> [HybridResult] {
        // Layer 1: FTS5 — sanitize query for FTS5 syntax
        let sanitized = sanitizeFTSQuery(query)
        let ftsResults = db.search(query: sanitized, limit: limit * 2)

        // Layer 2: Semantic (if embeddings available)
        var semanticScores: [String: Double] = [:]
        if embeddingClient.hasAPIKey {
            do {
                let queryVec = try await embeddingClient.embed(text: query)
                // Compare against cached document embeddings
                let docs = ftsResults.map { $0.documentId } + topDocuments(limit: 20)
                for docId in Set(docs) {
                    let embFile = embeddingsDir.appendingPathComponent("\(docId).emb")
                    if let docVec = EmbeddingClient.loadEmbedding(from: embFile) {
                        semanticScores[docId] = Double(EmbeddingClient.cosineSimilarity(queryVec, docVec))
                    }
                }
            } catch {
                NSLog("[HybridSearch] Embedding error: \(error)")
            }
        }

        // Layer 3: Graph proximity (documents linked to FTS hits)
        var graphScores: [String: Double] = [:]
        for fts in ftsResults.prefix(5) {
            // 1 hop: documents linked from this document
            let rels = db.relationsForModule(fts.documentId)
            for rel in rels {
                graphScores[rel.targetId, default: 0] += 0.2
            }
            // Also check incoming
            let inRels = db.incomingRelationsForModule(fts.documentId)
            for rel in inRels {
                graphScores[rel.sourceId, default: 0] += 0.15
            }
        }

        // Combine scores
        let allDocIds = Set(ftsResults.map { $0.documentId } + Array(semanticScores.keys) + Array(graphScores.keys))

        // Normalize FTS scores (BM25 returns negative, closer to 0 = better)
        let maxFTS = ftsResults.map { abs($0.rank) }.max() ?? 1.0
        var ftsNorm: [String: Double] = [:]
        for r in ftsResults {
            ftsNorm[r.documentId] = 1.0 - (abs(r.rank) / max(maxFTS, 1.0))
        }

        var combined: [HybridResult] = []
        for docId in allDocIds {
            let fts = ftsNorm[docId] ?? 0.0
            let sem = semanticScores[docId] ?? 0.0
            let graph = min(graphScores[docId] ?? 0.0, 1.0)

            let score = 0.45 * fts + 0.35 * sem + 0.20 * graph

            let ftsResult = ftsResults.first(where: { $0.documentId == docId })
            combined.append(HybridResult(
                documentId: docId,
                title: ftsResult?.title ?? docId,
                snippet: ftsResult?.snippet ?? "",
                score: score,
                ftsScore: fts,
                semanticScore: sem,
                graphScore: graph
            ))
        }

        return combined.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    // MARK: - Embedding Index

    /// Index all documents as embeddings (call explicitly, costs money)
    func indexEmbeddings(progress: ((String) -> Void)? = nil) async {
        guard embeddingClient.hasAPIKey else { return }

        let docs = db.allModules() // Use modules to find documents
        // Gather all markdown content
        var textsToEmbed: [(docId: String, text: String)] = []

        // Get documents from FTS (they have content)
        // For now, use a simpler approach: read files
        let fm = FileManager.default
        for mod in docs {
            let dirURL = URL(fileURLWithPath: mod.path)
            guard let files = try? fm.contentsOfDirectory(at: dirURL, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "md" {
                let embFile = embeddingsDir.appendingPathComponent("\(file.lastPathComponent).emb")
                if fm.fileExists(atPath: embFile.path) { continue } // Already embedded

                if let content = try? String(contentsOf: file, encoding: .utf8) {
                    // Use first 8000 chars as document embedding
                    textsToEmbed.append((file.lastPathComponent, String(content.prefix(8000))))
                }
            }
        }

        guard !textsToEmbed.isEmpty else { return }

        progress?("Embedding \(textsToEmbed.count) documents...")

        // Batch embed (up to 20 at a time)
        for batch in stride(from: 0, to: textsToEmbed.count, by: 20) {
            let end = min(batch + 20, textsToEmbed.count)
            let batchTexts = textsToEmbed[batch..<end].map { $0.text }
            let batchIds = textsToEmbed[batch..<end].map { $0.docId }

            do {
                let vectors = try await embeddingClient.embedBatch(texts: Array(batchTexts))
                for (i, vec) in vectors.enumerated() {
                    let embFile = embeddingsDir.appendingPathComponent("\(batchIds[i]).emb")
                    EmbeddingClient.saveEmbedding(vec, to: embFile)
                }
                progress?("Embedded \(min(end, textsToEmbed.count))/\(textsToEmbed.count)")
            } catch {
                NSLog("[HybridSearch] Batch embedding error: \(error)")
                break
            }
        }
    }

    // MARK: - Helpers

    /// Sanitize user query for FTS5 MATCH syntax
    private func sanitizeFTSQuery(_ query: String) -> String {
        // Remove special characters that break FTS5
        var clean = query
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ":", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common stop words to improve FTS5 matching
        let stopWords = Set(["what", "is", "the", "are", "how", "does", "do", "can", "will", "a", "an", "in", "of", "for", "to", "and", "or", "this", "that", "with"])
        let words = clean.lowercased().components(separatedBy: .whitespaces).filter { !stopWords.contains($0) && $0.count > 1 }

        if words.isEmpty { return clean } // fallback to original if all stop words
        // Join remaining words with OR for broader matching
        return words.joined(separator: " OR ")
    }

    private func topDocuments(limit: Int) -> [String] {
        // Return document IDs from modules that have the most symbols
        let modules = db.allModules()
        return modules.sorted { $0.fileCount > $1.fileCount }.prefix(limit).map { $0.id }
    }
}
