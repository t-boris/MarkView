import Foundation
import SQLite3
#if canImport(MarkViewCore)
import MarkViewCore
#endif

// The architecture tables of `.dde/state.db` (`arch_*`): the scanned architecture snapshot and the cached change reviews. They are
// the Architecture domain's own storage, so they extend the database actor from here and the Insight domain names no Architecture type.
extension SemanticDatabase {
    /// Replace the stored architecture with `snapshot` in one transaction.
    func saveArchitecture(_ snapshot: ArchitectureSnapshot) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for table in ["arch_nodes", "arch_edges", "arch_coverage", "arch_metrics", "arch_meta"] {
                try execute("DELETE FROM \(table)")
            }
            for view in snapshot.views { try insertArchView(view) }
            for (nodeId, entry) in snapshot.coverage {
                let docs = String(decoding: try JSONEncoder().encode(entry.docs), as: UTF8.self)
                try execute("INSERT INTO arch_coverage (node_id, status, docs_json) VALUES (?, ?, ?)",
                            params: [.text(nodeId), .text(entry.status), .text(docs)])
            }
            let encoder = JSONEncoder()
            for (nodeId, metrics) in snapshot.metrics {
                try execute("INSERT INTO arch_metrics (node_id, json) VALUES (?, ?)",
                            params: [.text(nodeId), .text(String(decoding: try encoder.encode(metrics), as: UTF8.self))])
            }
            func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
            let meta: [String: String?] = [
                "systemName": snapshot.systemName,
                "systemPurpose": snapshot.systemPurpose,
                "codeSequences": try snapshot.codeSequences.map { try json($0) },
                "codeModel": try snapshot.codeModel.map { try json($0) },
                "codeCoverage": try snapshot.codeCoverage.map { try json($0) },
                "processGraphs": try snapshot.processGraphs.map { try json($0) },
                "components": try json(snapshot.components),
                "assignments": try json(snapshot.assignments),
                "overrides": try json(snapshot.overrides),
                "logicalSignature": snapshot.logicalSignature,
                "language": snapshot.language,
                "logicalDraft": snapshot.logicalDraft ? "1" : nil,
                // One-off filters are never stored.
                "ratings": try json(snapshot.ratings.filter { !ImportanceRater.isTemporary($0.key) }),
                "coverageReport": snapshot.coverageReport,
                "deploymentSignature": snapshot.deploymentSignature,
                "scannedAt": String(snapshot.scannedAt.timeIntervalSince1970),
                "enrichedAt": snapshot.enrichedAt.map { String($0.timeIntervalSince1970) },
                "gitHead": snapshot.gitHead,
                "deploymentHints": String(decoding: try JSONEncoder().encode(snapshot.deploymentHints), as: UTF8.self),
            ]
            for (key, value) in meta {
                guard let value else { continue }
                try execute("INSERT INTO arch_meta (key, value) VALUES (?, ?)", params: [.text(key), .text(value)])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func insertArchView(_ view: ArchView) throws {
        for node in view.nodes {
            try execute("""
                INSERT OR REPLACE INTO arch_nodes (view, id, parent_id, kind, name, path, language, loc, files, summary, role, tech, signature, summary_signature, component, tags_json, line, end_line, anchor)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, params: [.text(view.id), .text(node.id), .textOrNull(node.parent), .text(node.kind), .text(node.name),
                          .textOrNull(node.path), .textOrNull(node.language), .int(node.loc), .int(node.files),
                          .textOrNull(node.summary), .textOrNull(node.role), .textOrNull(node.tech),
                          .textOrNull(node.signature), .textOrNull(node.summarySignature), .textOrNull(node.component),
                          .textOrNull(node.tags.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }),
                          .intOrNull(node.line), .intOrNull(node.endLine), .textOrNull(node.anchor)])
        }
        for edge in view.edges {
            try execute("""
                INSERT OR REPLACE INTO arch_edges (view, source, target, kind, weight, label) VALUES (?, ?, ?, ?, ?, ?)
            """, params: [.text(view.id), .text(edge.source), .text(edge.target), .text(edge.kind),
                          .int(edge.weight), .textOrNull(edge.label)])
        }
    }

    /// Cached AI review of a diff, keyed by the diff's SHA-256.
    func loadArchitectureReview(key: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT json FROM arch_reviews WHERE diff_hash = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    func saveArchitectureReview(key: String, json: String) {
        try? execute("INSERT OR REPLACE INTO arch_reviews (diff_hash, json, created_at) VALUES (?, ?, ?)",
                     params: [.text(key), .text(json), .int(Int(Date().timeIntervalSince1970))])
    }

    /// The stored architecture, or nil when this workspace was never scanned.
    func loadArchitecture() -> ArchitectureSnapshot? { Self.readArchitecture(db) }

    /// The architecture tables of `db` as a snapshot; the connection stays the caller's.
    private static func readArchitecture(_ db: OpaquePointer?) -> ArchitectureSnapshot? {
        func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT key, value FROM arch_meta", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let key = text(stmt, 0), let value = text(stmt, 1) { meta[key] = value }
            }
        }
        sqlite3_finalize(stmt)
        guard let scanned = meta["scannedAt"].flatMap(Double.init) else { return nil }

        var nodesByView: [String: [ArchNode]] = [:]
        stmt = nil
        // In insertion order: the Book view's parts and chapters are stored in reading order.
        if sqlite3_prepare_v2(db, "SELECT view, id, parent_id, kind, name, path, language, loc, files, summary, role, tech, signature, summary_signature, component, tags_json, line, end_line, anchor FROM arch_nodes ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK {
            func int(_ column: Int32) -> Int? {
                sqlite3_column_type(stmt, column) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, column))
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let node = ArchNode(id: text(stmt, 1) ?? "", parent: text(stmt, 2), kind: text(stmt, 3) ?? "",
                                    name: text(stmt, 4) ?? "", path: text(stmt, 5), language: text(stmt, 6),
                                    loc: Int(sqlite3_column_int64(stmt, 7)), files: Int(sqlite3_column_int64(stmt, 8)),
                                    summary: text(stmt, 9), role: text(stmt, 10), tech: text(stmt, 11),
                                    signature: text(stmt, 12), summarySignature: text(stmt, 13), component: text(stmt, 14),
                                    tags: (text(stmt, 15)?.data(using: .utf8)).flatMap { StoredJSON.decode([String].self, from: $0, owner: "architecture nodes") },
                                    line: int(16), endLine: int(17), anchor: text(stmt, 18))
                nodesByView[text(stmt, 0) ?? "", default: []].append(node)
            }
        }
        sqlite3_finalize(stmt)

        var edgesByView: [String: [ArchEdge]] = [:]
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT view, source, target, kind, weight, label FROM arch_edges", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let edge = ArchEdge(source: text(stmt, 1) ?? "", target: text(stmt, 2) ?? "", kind: text(stmt, 3) ?? "",
                                    weight: Int(sqlite3_column_int64(stmt, 4)), label: text(stmt, 5))
                edgesByView[text(stmt, 0) ?? "", default: []].append(edge)
            }
        }
        sqlite3_finalize(stmt)

        var coverage: [String: CoverageEntry] = [:]
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT node_id, status, docs_json FROM arch_coverage", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let docs = (text(stmt, 2)?.data(using: .utf8)).flatMap { StoredJSON.decode([String].self, from: $0, owner: "architecture coverage") } ?? []
                coverage[text(stmt, 0) ?? ""] = CoverageEntry(status: text(stmt, 1) ?? "none", docs: docs)
            }
        }
        sqlite3_finalize(stmt)

        var metrics: [String: FileMetrics] = [:]
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT node_id, json FROM arch_metrics", -1, &stmt, nil) == SQLITE_OK {
            let decoder = JSONDecoder()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = text(stmt, 0), let data = text(stmt, 1)?.data(using: .utf8),
                   let value = StoredJSON.decode(FileMetrics.self, from: data, using: decoder, owner: "architecture metrics") { metrics[id] = value }
            }
        }
        sqlite3_finalize(stmt)

        let order = ["modules", "deployment", "docs"]
        let views = nodesByView.keys.sorted { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
            .map { ArchView(id: $0, nodes: nodesByView[$0] ?? [], edges: edgesByView[$0] ?? []) }
        let hints = (meta["deploymentHints"]?.data(using: .utf8)).flatMap { StoredJSON.decode([String].self, from: $0, owner: "architecture meta") } ?? []
        func decode<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
            (meta[key]?.data(using: .utf8)).flatMap { StoredJSON.decode(type, from: $0, owner: "architecture meta") }
        }
        return ArchitectureSnapshot(views: views, coverage: coverage, metrics: metrics,
                                    coverageReport: meta["coverageReport"],
                                    deploymentSignature: meta["deploymentSignature"],
                                    systemName: meta["systemName"], systemPurpose: meta["systemPurpose"],
                                    components: decode("components", [LogicalComponent].self) ?? [],
                                    assignments: decode("assignments", [String: LogicalAssignment].self) ?? [:],
                                    overrides: decode("overrides", [String: String].self) ?? [:],
                                    logicalSignature: meta["logicalSignature"],
                                    language: meta["language"],
                                    logicalDraft: meta["logicalDraft"] == "1",
                                    ratings: decode("ratings", [String: [String: ImportanceRater.Rating]].self) ?? [:],
                                    deploymentHints: hints,
                                    scannedAt: Date(timeIntervalSince1970: scanned),
                                    enrichedAt: meta["enrichedAt"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                                    gitHead: meta["gitHead"],
                                    codeSequences: decode("codeSequences", [CodeSequence].self),
                                    codeModel: decode("codeModel", CodeArchitectureModel.self),
                                    codeCoverage: decode("codeCoverage", CodeCoverage.self),
                                    processGraphs: decode("processGraphs", [ProcessScenario].self))
    }
}
