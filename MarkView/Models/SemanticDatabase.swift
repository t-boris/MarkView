import Foundation
import SQLite3

/// SQLite wrapper for .dde/state.db — stores semantic blocks, documents, and compilation cache
@MainActor
class SemanticDatabase {
    var dbPointer: OpaquePointer? { db }
    var sqliteTransientValue: sqlite3_destructor_type { Self.sqliteTransient }
    private var db: OpaquePointer?
    let dbPath: String

    init(workspacePath: URL, dbName: String = "state.db") throws {
        let fm = FileManager.default

        // Try .dde/ next to workspace first; fall back to app container if sandboxed
        var ddeDir = workspacePath.appendingPathComponent(".dde")
        do {
            if !fm.fileExists(atPath: ddeDir.path) {
                try fm.createDirectory(at: ddeDir, withIntermediateDirectories: true)
            }
        } catch {
            // Sandbox: can't write next to workspace. Use app support directory instead.
            let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let workspaceId = workspacePath.lastPathComponent.replacingOccurrences(of: " ", with: "_")
            ddeDir = appSupport.appendingPathComponent("MarkView/\(workspaceId)")
            try fm.createDirectory(at: ddeDir, withIntermediateDirectories: true)
            NSLog("[SemanticDB] Sandbox fallback: \(ddeDir.path)")
        }

        let dbURL = ddeDir.appendingPathComponent(dbName)
        self.dbPath = dbURL.path

        var dbPointer: OpaquePointer?
        let result = sqlite3_open(dbPath, &dbPointer)
        guard result == SQLITE_OK, let pointer = dbPointer else {
            let msg = String(cString: sqlite3_errmsg(dbPointer))
            throw SemanticDBError.openFailed(msg)
        }
        self.db = pointer

        try setPragmas()
        try createTables()
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    // MARK: - Setup

    private func setPragmas() throws {
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA temp_store = MEMORY")
        try execute("PRAGMA cache_size = -20000")
    }

    private func createTables() throws {
        // Projects
        try execute("""
            CREATE TABLE IF NOT EXISTS projects (
                project_id TEXT PRIMARY KEY,
                project_name TEXT NOT NULL,
                root_path TEXT NOT NULL UNIQUE,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                dde_version TEXT,
                schema_version TEXT NOT NULL,
                config_json TEXT
            )
        """)

        // Documents
        try execute("""
            CREATE TABLE IF NOT EXISTS documents (
                document_id TEXT PRIMARY KEY,
                project_id TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                file_ext TEXT NOT NULL,
                file_mtime INTEGER,
                file_size_bytes INTEGER,
                content_hash TEXT NOT NULL,
                frontmatter_json TEXT,
                language TEXT,
                status TEXT DEFAULT 'active',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(project_id, file_path),
                FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE CASCADE
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_documents_project ON documents(project_id)")

        // Blocks
        try execute("""
            CREATE TABLE IF NOT EXISTS blocks (
                block_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                parent_block_id TEXT,
                block_kind TEXT NOT NULL,
                heading_path_json TEXT NOT NULL,
                anchor TEXT,
                order_index INTEGER NOT NULL,
                line_start INTEGER,
                line_end INTEGER,
                raw_markdown TEXT NOT NULL,
                plain_text TEXT,
                text_hash TEXT NOT NULL,
                semantic_hash TEXT,
                compile_status TEXT DEFAULT 'stale',
                last_compiled_at INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (document_id) REFERENCES documents(document_id) ON DELETE CASCADE,
                FOREIGN KEY (parent_block_id) REFERENCES blocks(block_id) ON DELETE CASCADE
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_blocks_document ON blocks(document_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_blocks_doc_order ON blocks(document_id, order_index)")
        try execute("CREATE INDEX IF NOT EXISTS idx_blocks_text_hash ON blocks(text_hash)")

        // Block compilation cache
        try execute("""
            CREATE TABLE IF NOT EXISTS block_compilation_cache (
                block_id TEXT PRIMARY KEY,
                text_hash TEXT NOT NULL,
                semantic_hash TEXT,
                extracted_entities_json TEXT,
                extracted_claims_json TEXT,
                extracted_relations_json TEXT,
                cache_created_at INTEGER NOT NULL,
                cache_updated_at INTEGER NOT NULL,
                FOREIGN KEY (block_id) REFERENCES blocks(block_id) ON DELETE CASCADE
            )
        """)

        // Entities
        try execute("""
            CREATE TABLE IF NOT EXISTS entities (
                entity_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                type TEXT NOT NULL,
                canonical_name TEXT NOT NULL,
                aliases_json TEXT,
                attributes_json TEXT,
                description TEXT,
                status TEXT DEFAULT 'active',
                source_file TEXT,
                source_block_id TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_entities_canonical ON entities(canonical_name)")
        try execute("CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(type)")

        // Claims
        try execute("""
            CREATE TABLE IF NOT EXISTS claims (
                claim_id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                subject_entity_id TEXT,
                predicate TEXT,
                object TEXT,
                object_entity_id TEXT,
                source_file TEXT NOT NULL,
                source_block_id TEXT NOT NULL,
                raw_text TEXT,
                status TEXT DEFAULT 'proposed',
                confidence REAL DEFAULT 0.5,
                authority_level TEXT,
                superseded_by TEXT,
                scope_kind TEXT DEFAULT 'global',
                scope_value TEXT,
                temporal_context_id TEXT,
                effective_from TEXT,
                effective_to TEXT,
                evidence_block_ids_json TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                FOREIGN KEY (subject_entity_id) REFERENCES entities(entity_id) ON DELETE SET NULL,
                FOREIGN KEY (source_block_id) REFERENCES blocks(block_id) ON DELETE CASCADE,
                FOREIGN KEY (temporal_context_id) REFERENCES temporal_contexts(temporal_context_id) ON DELETE SET NULL
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_claims_block ON claims(source_block_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_claims_entity ON claims(subject_entity_id)")

        // Entity Relations
        try execute("""
            CREATE TABLE IF NOT EXISTS entity_relations (
                relation_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                type TEXT NOT NULL,
                source_file TEXT,
                source_block_id TEXT,
                confidence REAL DEFAULT 0.5,
                created_at INTEGER NOT NULL
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_relations_source ON entity_relations(source_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_relations_target ON entity_relations(target_id)")

        // Temporal Contexts
        try execute("""
            CREATE TABLE IF NOT EXISTS temporal_contexts (
                temporal_context_id TEXT PRIMARY KEY,
                label TEXT NOT NULL,
                kind TEXT NOT NULL,
                order_index INTEGER DEFAULT 0,
                start_time TEXT,
                end_time TEXT,
                parent_temporal_context_id TEXT,
                FOREIGN KEY (parent_temporal_context_id) REFERENCES temporal_contexts(temporal_context_id) ON DELETE SET NULL
            )
        """)

        // Transitions
        try execute("""
            CREATE TABLE IF NOT EXISTS transitions (
                transition_id TEXT PRIMARY KEY,
                entity_id TEXT NOT NULL,
                from_state TEXT NOT NULL,
                to_state TEXT NOT NULL,
                from_temporal_context_id TEXT,
                to_temporal_context_id TEXT,
                preconditions_json TEXT,
                postconditions_json TEXT,
                rollback_strategy TEXT,
                trigger TEXT,
                evidence_block_ids_json TEXT,
                FOREIGN KEY (entity_id) REFERENCES entities(entity_id) ON DELETE CASCADE
            )
        """)

        // Diagnostics
        try execute("""
            CREATE TABLE IF NOT EXISTS diagnostics (
                diagnostic_id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                severity TEXT NOT NULL,
                message TEXT NOT NULL,
                explanation TEXT,
                document_id TEXT NOT NULL,
                block_id TEXT,
                claim_ids_json TEXT,
                entity_ids_json TEXT,
                suggested_fix TEXT,
                is_suppressed INTEGER DEFAULT 0,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (document_id) REFERENCES documents(document_id) ON DELETE CASCADE
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_diagnostics_doc ON diagnostics(document_id)")

        // AI Jobs
        try execute("""
            CREATE TABLE IF NOT EXISTS ai_jobs (
                job_id TEXT PRIMARY KEY,
                job_type TEXT NOT NULL,
                priority TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                document_id TEXT,
                block_ids_json TEXT,
                input_hash TEXT NOT NULL,
                model_policy TEXT,
                privacy_mode TEXT NOT NULL,
                result_ref TEXT,
                error_state TEXT,
                created_at INTEGER NOT NULL,
                started_at INTEGER,
                completed_at INTEGER,
                retry_count INTEGER DEFAULT 0,
                cost_tokens INTEGER
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_ai_jobs_hash ON ai_jobs(input_hash)")
        try execute("CREATE INDEX IF NOT EXISTS idx_ai_jobs_status ON ai_jobs(status)")

        // Compile profiles
        try execute("""
            CREATE TABLE IF NOT EXISTS compile_profiles (
                profile_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                audience TEXT,
                required_claim_types_json TEXT,
                required_entity_types_json TEXT,
                section_order_json TEXT,
                strictness TEXT DEFAULT 'moderate',
                language TEXT DEFAULT 'en'
            )
        """)

        // Compile jobs
        try execute("""
            CREATE TABLE IF NOT EXISTS compile_jobs (
                compile_job_id TEXT PRIMARY KEY,
                profile_id TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'pending',
                created_at INTEGER NOT NULL,
                completed_at INTEGER,
                FOREIGN KEY (profile_id) REFERENCES compile_profiles(profile_id) ON DELETE CASCADE
            )
        """)

        // Compile artifacts
        try execute("""
            CREATE TABLE IF NOT EXISTS compile_artifacts (
                artifact_id TEXT PRIMARY KEY,
                compile_job_id TEXT NOT NULL,
                artifact_kind TEXT NOT NULL,
                section_key TEXT,
                content TEXT NOT NULL,
                content_hash TEXT,
                source_block_ids_json TEXT,
                source_claim_ids_json TEXT,
                created_at INTEGER NOT NULL,
                FOREIGN KEY (compile_job_id) REFERENCES compile_jobs(compile_job_id) ON DELETE CASCADE
            )
        """)

        // Document templates
        try execute("""
            CREATE TABLE IF NOT EXISTS document_templates (
                template_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                description TEXT,
                sections_json TEXT,
                required_claim_types_json TEXT,
                required_entity_types_json TEXT
            )
        """)

        // Completeness evaluations
        try execute("""
            CREATE TABLE IF NOT EXISTS completeness_evaluations (
                evaluation_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                template_id TEXT,
                structural_score REAL,
                semantic_score REAL,
                overall_score REAL,
                missing_parts_json TEXT,
                evaluated_at INTEGER NOT NULL,
                FOREIGN KEY (document_id) REFERENCES documents(document_id) ON DELETE CASCADE
            )
        """)

        // Recompute graph nodes
        try execute("""
            CREATE TABLE IF NOT EXISTS recompute_nodes (
                node_id TEXT PRIMARY KEY,
                node_type TEXT NOT NULL,
                is_dirty INTEGER DEFAULT 0,
                last_computed_at INTEGER
            )
        """)

        // Recompute graph edges
        try execute("""
            CREATE TABLE IF NOT EXISTS recompute_edges (
                edge_id TEXT PRIMARY KEY,
                source_node_id TEXT NOT NULL,
                target_node_id TEXT NOT NULL,
                edge_type TEXT NOT NULL,
                FOREIGN KEY (source_node_id) REFERENCES recompute_nodes(node_id) ON DELETE CASCADE,
                FOREIGN KEY (target_node_id) REFERENCES recompute_nodes(node_id) ON DELETE CASCADE
            )
        """)

        // Usage tracking — persists across sessions
        try execute("""
            CREATE TABLE IF NOT EXISTS usage_stats (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                total_input_tokens INTEGER NOT NULL DEFAULT 0,
                total_output_tokens INTEGER NOT NULL DEFAULT 0,
                total_jobs INTEGER NOT NULL DEFAULT 0,
                total_cost_cents REAL NOT NULL DEFAULT 0.0
            )
        """)
        // Ensure single row exists
        try execute("INSERT OR IGNORE INTO usage_stats (id, total_input_tokens, total_output_tokens, total_jobs, total_cost_cents) VALUES (1, 0, 0, 0, 0.0)")

        // ============================================
        // V1: Structure-First Tables (C4/arc42)
        // ============================================

        // Modules: directories as logical units
        try execute("""
            CREATE TABLE IF NOT EXISTS modules (
                module_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                parent_module_id TEXT,
                level INTEGER NOT NULL DEFAULT 0,
                description TEXT,
                file_count INTEGER DEFAULT 0,
                FOREIGN KEY (parent_module_id) REFERENCES modules(module_id) ON DELETE CASCADE
            )
        """)

        // Symbols: headings, definitions, links, code blocks found by parsing
        try execute("""
            CREATE TABLE IF NOT EXISTS symbols (
                symbol_id TEXT PRIMARY KEY,
                module_id TEXT,
                document_id TEXT,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                line_start INTEGER,
                line_end INTEGER,
                context TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(module_id) ON DELETE CASCADE,
                FOREIGN KEY (document_id) REFERENCES documents(document_id) ON DELETE CASCADE
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_symbols_doc ON symbols(document_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbols(module_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_symbols_kind ON symbols(kind)")

        // Structural relations: deterministic links between modules/docs
        try execute("""
            CREATE TABLE IF NOT EXISTS struct_relations (
                relation_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                type TEXT NOT NULL,
                source_doc TEXT,
                evidence TEXT
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_srel_source ON struct_relations(source_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_srel_target ON struct_relations(target_id)")
        try execute("CREATE INDEX IF NOT EXISTS idx_srel_type ON struct_relations(type)")

        // Artifacts: generated content (summaries, diagrams, ADRs)
        try execute("""
            CREATE TABLE IF NOT EXISTS artifacts (
                artifact_id TEXT PRIMARY KEY,
                module_id TEXT,
                kind TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                model_used TEXT
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_artifacts_module ON artifacts(module_id)")

        // FTS5 full-text search index
        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS fts_documents USING fts5(
                document_id,
                title,
                content,
                tokenize='porter unicode61'
            )
        """)

        // ============================================
        // V2: Hybrid Retrieval + Citations
        // ============================================

        // Chunks for embedding (split documents into ~500 char pieces)
        try execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                chunk_id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL,
                text TEXT NOT NULL,
                char_start INTEGER,
                char_end INTEGER,
                embedding_file TEXT,
                FOREIGN KEY (document_id) REFERENCES documents(document_id) ON DELETE CASCADE
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(document_id)")

        // Quality attributes (arc42)
        try execute("""
            CREATE TABLE IF NOT EXISTS quality_tags (
                tag_id TEXT PRIMARY KEY,
                module_id TEXT,
                attribute TEXT NOT NULL,
                value TEXT NOT NULL DEFAULT 'unknown',
                source_artifact_id TEXT,
                FOREIGN KEY (module_id) REFERENCES modules(module_id) ON DELETE CASCADE
            )
        """)

        // Citations linking artifacts to source documents
        try execute("""
            CREATE TABLE IF NOT EXISTS citations (
                citation_id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL,
                document_id TEXT NOT NULL,
                line_start INTEGER,
                line_end INTEGER,
                quote_text TEXT
            )
        """)
        try execute("CREATE INDEX IF NOT EXISTS idx_citations_artifact ON citations(artifact_id)")

        // ============================================
        // V3: Implementation + GraphRAG (tables created early)
        // ============================================

        // Change plans
        try execute("""
            CREATE TABLE IF NOT EXISTS change_plans (
                plan_id TEXT PRIMARY KEY,
                module_id TEXT,
                description TEXT NOT NULL,
                steps_json TEXT,
                status TEXT DEFAULT 'draft',
                created_at INTEGER NOT NULL
            )
        """)

        // GraphRAG communities
        try execute("""
            CREATE TABLE IF NOT EXISTS communities (
                community_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                module_ids_json TEXT,
                summary TEXT,
                level INTEGER DEFAULT 0
            )
        """)

        // Schema version tracking
        try execute("""
            CREATE TABLE IF NOT EXISTS applied_migrations (
                migration_id TEXT PRIMARY KEY,
                applied_at INTEGER NOT NULL
            )
        """)
    }

    // MARK: - Project CRUD

    func ensureProject(id: String, name: String, rootPath: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try execute("""
            INSERT INTO projects (project_id, project_name, root_path, created_at, updated_at, schema_version)
            VALUES (?, ?, ?, ?, ?, '1.0')
            ON CONFLICT(project_id) DO UPDATE SET updated_at = ?
        """, params: [.text(id), .text(name), .text(rootPath), .int(now), .int(now), .int(now)])
    }

    // MARK: - Document CRUD

    func upsertDocument(id: String, projectId: String, filePath: String, fileName: String,
                        fileExt: String, contentHash: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        try execute("""
            INSERT INTO documents (document_id, project_id, file_path, file_name, file_ext, content_hash, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET content_hash = ?, updated_at = ?
        """, params: [.text(id), .text(projectId), .text(filePath), .text(fileName),
                     .text(fileExt), .text(contentHash), .int(now), .int(now),
                     .text(contentHash), .int(now)])
    }

    // MARK: - Block CRUD

    func upsertBlock(_ block: SemanticBlock, documentId: String) throws {
        let now = Int(Date().timeIntervalSince1970)
        let headingPathJSON = (try? JSONEncoder().encode(block.headingPath))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try execute("""
            INSERT INTO blocks (block_id, document_id, parent_block_id, block_kind, heading_path_json,
                anchor, order_index, line_start, line_end, raw_markdown, plain_text, text_hash,
                semantic_hash, compile_status, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stale', ?, ?)
            ON CONFLICT(block_id) DO UPDATE SET
                raw_markdown = ?, plain_text = ?, text_hash = ?, compile_status = 'stale', updated_at = ?
        """, params: [
            .text(block.id), .text(documentId), .textOrNull(block.parentBlockId),
            .text(block.type.rawValue), .text(headingPathJSON), .textOrNull(block.anchor),
            .int(block.position), .int(block.lineStart), .int(block.lineEnd),
            .text(block.content), .text(block.plainText), .text(block.contentHash),
            .textOrNull(block.semanticHash), .int(now), .int(now),
            .text(block.content), .text(block.plainText), .text(block.contentHash), .int(now)
        ])
    }

    func deleteBlock(id: String) throws {
        try execute("DELETE FROM blocks WHERE block_id = ?", params: [.text(id)])
    }

    // MARK: - Entity CRUD

    func upsertEntity(_ entity: SemanticEntity) throws {
        let now = Int(Date().timeIntervalSince1970)
        let aliasesJSON = (try? JSONEncoder().encode(entity.safeAliases)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let attrsJSON = (try? JSONEncoder().encode(entity.attributes ?? [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" as String
        try execute("""
            INSERT INTO entities (entity_id, name, type, canonical_name, aliases_json, attributes_json,
                description, status, source_file, source_block_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_id) DO UPDATE SET name=?, canonical_name=?, aliases_json=?, attributes_json=?, updated_at=?
        """, params: [.text(entity.id), .text(entity.name), .text(entity.type), .text(entity.canonicalName),
                     .text(aliasesJSON), .text(attrsJSON), .textOrNull(entity.description), .text(entity.safeStatus),
                     .textOrNull(entity.sourceFile), .textOrNull(entity.sourceBlockId), .int(now), .int(now),
                     .text(entity.name), .text(entity.canonicalName), .text(aliasesJSON), .text(attrsJSON), .int(now)])
    }

    // MARK: - Claim CRUD

    func upsertClaim(_ claim: SemanticClaim) throws {
        let now = Int(Date().timeIntervalSince1970)
        let evidenceJSON = (try? JSONEncoder().encode(claim.safeEvidenceBlockIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try execute("""
            INSERT INTO claims (claim_id, type, subject_entity_id, predicate, object, object_entity_id,
                source_file, source_block_id, raw_text, status, confidence, scope_kind, scope_value,
                temporal_context_id, evidence_block_ids_json, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(claim_id) DO UPDATE SET raw_text=?, status=?, confidence=?, updated_at=?
        """, params: [.text(claim.id), .text(claim.safeType), .text(claim.safeSubjectEntityId),
                     .text(claim.predicate ?? ""), .text(claim.safeObject), .textOrNull(claim.objectEntityId),
                     .text(claim.safeSourceFile), .text(claim.safeSourceBlockId), .text(claim.safeRawText),
                     .text(claim.safeStatus), .real(claim.safeConfidence), .text(claim.safeScopeKind),
                     .textOrNull(claim.scopeValue), .textOrNull(claim.temporalContextId),
                     .text(evidenceJSON), .int(now), .int(now),
                     .text(claim.safeRawText), .text(claim.safeStatus), .real(claim.safeConfidence), .int(now)])
    }

    func deleteClaimsForBlock(_ blockId: String) throws {
        try execute("DELETE FROM claims WHERE source_block_id = ?", params: [.text(blockId)])
    }

    // MARK: - Relation CRUD

    func upsertRelation(_ relation: SemanticRelation) throws {
        let now = Int(Date().timeIntervalSince1970)
        try execute("""
            INSERT INTO entity_relations (relation_id, source_id, target_id, type, source_file, source_block_id, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(relation_id) DO UPDATE SET type=?
        """, params: [.text(relation.id), .text(relation.sourceId), .text(relation.targetId),
                     .text(relation.type), .textOrNull(relation.sourceFile), .textOrNull(relation.sourceBlockId),
                     .real(relation.confidence ?? 0.5), .int(now), .text(relation.type)])
    }

    func deleteRelationsForBlock(_ blockId: String) throws {
        try execute("DELETE FROM entity_relations WHERE source_block_id = ?", params: [.text(blockId)])
    }

    // MARK: - Temporal Context CRUD

    func upsertTemporalContext(_ tc: TemporalContext) throws {
        try execute("""
            INSERT INTO temporal_contexts (temporal_context_id, label, kind, order_index, start_time, end_time, parent_temporal_context_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(temporal_context_id) DO UPDATE SET label=?, order_index=?
        """, params: [.text(tc.id), .text(tc.label), .text(tc.kind), .int(tc.orderIndex),
                     .textOrNull(tc.startTime), .textOrNull(tc.endTime), .textOrNull(tc.parentTemporalContextId),
                     .text(tc.label), .int(tc.orderIndex)])
    }

    // MARK: - Diagnostic CRUD

    func upsertDiagnostic(_ diag: Diagnostic) throws {
        let now = Int(Date().timeIntervalSince1970)
        let claimIdsJSON = (try? JSONEncoder().encode(diag.claimIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let entityIdsJSON = (try? JSONEncoder().encode(diag.entityIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try execute("""
            INSERT INTO diagnostics (diagnostic_id, type, severity, message, explanation, document_id, block_id,
                claim_ids_json, entity_ids_json, suggested_fix, is_suppressed, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(diagnostic_id) DO UPDATE SET message=?, severity=?
        """, params: [.text(diag.id), .text(diag.type.rawValue), .text(diag.severity.rawValue),
                     .text(diag.message), .textOrNull(diag.explanation), .text(diag.documentId),
                     .textOrNull(diag.blockId), .text(claimIdsJSON), .text(entityIdsJSON),
                     .textOrNull(diag.suggestedFix), .int(diag.isSuppressed ? 1 : 0), .int(now),
                     .text(diag.message), .text(diag.severity.rawValue)])
    }

    func deleteDiagnosticsForBlock(_ blockId: String) throws {
        try execute("DELETE FROM diagnostics WHERE block_id = ?", params: [.text(blockId)])
    }

    // MARK: - AI Job CRUD

    func insertAIJob(_ job: AIJob) throws {
        let now = Int(Date().timeIntervalSince1970)
        let blockIdsJSON = (try? JSONEncoder().encode(job.blockIds)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try execute("""
            INSERT INTO ai_jobs (job_id, job_type, priority, status, document_id, block_ids_json,
                input_hash, model_policy, privacy_mode, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text(job.id), .text(job.jobType.rawValue), .text(job.priority.rawValue),
                     .text(job.status.rawValue), .textOrNull(job.documentId), .text(blockIdsJSON),
                     .text(job.inputHash), .textOrNull(job.modelPolicy), .text(job.privacyMode.rawValue),
                     .int(now)])
    }

    func updateAIJobStatus(_ jobId: String, status: AIJobStatus, resultRef: String? = nil, error: String? = nil) throws {
        let now = Int(Date().timeIntervalSince1970)
        try execute("""
            UPDATE ai_jobs SET status = ?, result_ref = ?, error_state = ?,
                completed_at = CASE WHEN ? IN ('completed','failed','cancelled') THEN ? ELSE completed_at END
            WHERE job_id = ?
        """, params: [.text(status.rawValue), .textOrNull(resultRef), .textOrNull(error),
                     .text(status.rawValue), .int(now), .text(jobId)])
    }

    func findCachedJob(inputHash: String) throws -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT result_ref FROM ai_jobs WHERE input_hash = ? AND status = 'completed' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, inputHash, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
            return String(cString: ptr)
        }
        return nil
    }

    // MARK: - Query Helpers

    func blockCount(forDocument documentId: String) throws -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM blocks WHERE document_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Clear all semantic data (entities, claims, relations, diagnostics, jobs, cache) — keeps schema
    func clearAll() throws {
        let tables = [
            "compile_artifacts", "compile_jobs", "completeness_evaluations",
            "recompute_edges", "recompute_nodes",
            "ai_jobs", "diagnostics", "transitions", "entity_relations",
            "claims", "entities", "temporal_contexts",
            "block_compilation_cache", "blocks", "documents"
        ]
        for table in tables {
            try execute("DELETE FROM \(table)")
        }

        // Also clear the file-based response cache
        let cacheDir = URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent() // .dde/
            .appendingPathComponent("cache")
            .appendingPathComponent("provider_responses")
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }

        // Reset usage stats
        try execute("UPDATE usage_stats SET total_input_tokens=0, total_output_tokens=0, total_jobs=0, total_cost_cents=0 WHERE id=1")

        NSLog("[DDE] Database + cache fully cleared")
    }

    // MARK: - Usage Stats (persisted across sessions)

    struct UsageStats {
        var totalInputTokens: Int
        var totalOutputTokens: Int
        var totalJobs: Int
        var totalCostCents: Double

        var totalTokens: Int { totalInputTokens + totalOutputTokens }
        var totalCostDollars: Double { totalCostCents / 100.0 }
    }

    func getUsageStats() -> UsageStats {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT total_input_tokens, total_output_tokens, total_jobs, total_cost_cents FROM usage_stats WHERE id = 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else {
            return UsageStats(totalInputTokens: 0, totalOutputTokens: 0, totalJobs: 0, totalCostCents: 0)
        }
        return UsageStats(
            totalInputTokens: Int(sqlite3_column_int64(stmt, 0)),
            totalOutputTokens: Int(sqlite3_column_int64(stmt, 1)),
            totalJobs: Int(sqlite3_column_int64(stmt, 2)),
            totalCostCents: sqlite3_column_double(stmt, 3)
        )
    }

    func addUsage(inputTokens: Int, outputTokens: Int, costCents: Double) {
        try? execute("""
            UPDATE usage_stats SET
                total_input_tokens = total_input_tokens + ?,
                total_output_tokens = total_output_tokens + ?,
                total_jobs = total_jobs + 1,
                total_cost_cents = total_cost_cents + ?
            WHERE id = 1
        """, params: [.int(inputTokens), .int(outputTokens), .real(costCents)])
    }

    // MARK: - Bulk Query (load all into memory)

    func entityCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(DISTINCT canonical_name) FROM entities", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func claimCount() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM claims", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// Detect legacy broken extraction state where entities were saved but claims failed FK validation.
    func documentNeedsReanalysis(_ documentId: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT
                (SELECT COUNT(*) FROM entities WHERE source_file = ?),
                (SELECT COUNT(*) FROM claims WHERE source_file = ?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, documentId, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }

        let entityCount = Int(sqlite3_column_int(stmt, 0))
        let claimCount = Int(sqlite3_column_int(stmt, 1))
        return entityCount > 0 && claimCount == 0
    }

    /// Get deduplicated entities grouped by type (returns max ~300)
    func uniqueEntities() -> [SemanticEntity] {
        var results: [SemanticEntity] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT entity_id, name, type, canonical_name, description, status, source_file, source_block_id FROM entities GROUP BY LOWER(canonical_name) ORDER BY type, name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))
            let canonical = String(cString: sqlite3_column_text(stmt, 3))
            let desc = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let status = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let srcFile = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let srcBlock = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            results.append(SemanticEntity(id: id, name: name, type: type, canonicalName: canonical,
                                          aliases: nil, attributes: nil, description: desc,
                                          status: status, sourceFile: srcFile, sourceBlockId: srcBlock))
        }
        return results
    }

    func allClaims() -> [SemanticClaim] {
        var results: [SemanticClaim] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT claim_id, type, subject_entity_id, predicate, object, source_file, source_block_id, raw_text, status, confidence, scope_kind FROM claims"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let type = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let subj = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let pred = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let obj = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let srcFile = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let srcBlock = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            let rawText = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let status = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
            let confidence = sqlite3_column_double(stmt, 9)
            let scopeKind = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            results.append(SemanticClaim(id: id, type: type, subjectEntityId: subj, predicate: pred,
                                         object: obj != nil ? .string(obj!) : nil, objectEntityId: nil,
                                         sourceFile: srcFile, sourceBlockId: srcBlock, rawText: rawText,
                                         status: status, confidence: confidence,
                                         scopeKind: scopeKind))
        }
        return results
    }

    // MARK: - Joined Queries (for semantic panel views)

    struct DependencyRow {
        let serviceName: String
        let dependsOn: String
        let relation: String
        let targetType: String
        let sourceText: String
        let filePath: String?
    }

    /// Get dependencies: service → what it uses/stores/calls
    func serviceDependencies() -> [DependencyRow] {
        var results: [DependencyRow] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT
                COALESCE(se.canonical_name, c.subject_entity_id),
                COALESCE(oe.canonical_name, NULLIF(c.object, '')),
                c.predicate,
                COALESCE(oe.type, ''),
                COALESCE(c.raw_text, ''),
                d.file_path
            FROM claims c
            LEFT JOIN entities se ON LOWER(c.subject_entity_id) = LOWER(se.entity_id)
            LEFT JOIN entities oe ON LOWER(c.object_entity_id) = LOWER(oe.entity_id)
            LEFT JOIN documents d ON d.document_id = c.source_file
            WHERE c.predicate IS NOT NULL AND c.predicate != ''
            ORDER BY COALESCE(se.canonical_name, c.subject_entity_id), c.predicate
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let svc = String(cString: sqlite3_column_text(stmt, 0))
            let obj = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let pred = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let type = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let sourceText = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let filePath = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            if !obj.isEmpty {
                results.append(DependencyRow(
                    serviceName: svc,
                    dependsOn: obj,
                    relation: pred,
                    targetType: type,
                    sourceText: sourceText,
                    filePath: filePath
                ))
            }
        }
        return results
    }

    struct DecisionRow {
        let decision: String
        let entityName: String
        let filePath: String?
        let claimType: String
    }

    /// Get decisions with entity context
    func decisionsWithContext() -> [DecisionRow] {
        var results: [DecisionRow] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT c.raw_text, COALESCE(e.canonical_name, c.subject_entity_id), d.file_path, c.type
            FROM claims c
            LEFT JOIN entities e ON LOWER(c.subject_entity_id) = LOWER(e.entity_id)
            LEFT JOIN documents d ON d.document_id = c.source_file
            WHERE c.type IN ('Decision', 'Risk', 'Constraint', 'Assumption', 'Requirement')
            ORDER BY c.type, e.canonical_name
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let entity = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let file = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let type = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            if !text.isEmpty {
                results.append(DecisionRow(decision: text, entityName: entity, filePath: file, claimType: type))
            }
        }
        return results
    }

    struct EntityEvidenceRow {
        let id: String
        let name: String
        let type: String
        let canonicalName: String
        let snippet: String
        let filePath: String?
    }

    func entityEvidenceRows() -> [EntityEvidenceRow] {
        var results: [EntityEvidenceRow] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT
                e.entity_id,
                e.name,
                e.type,
                e.canonical_name,
                COALESCE(NULLIF(b.plain_text, ''), NULLIF(e.description, ''), e.name),
                d.file_path
            FROM entities e
            LEFT JOIN blocks b ON b.block_id = e.source_block_id
            LEFT JOIN documents d ON d.document_id = e.source_file
            GROUP BY LOWER(e.canonical_name)
            ORDER BY e.type, e.name
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(EntityEvidenceRow(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                type: String(cString: sqlite3_column_text(stmt, 2)),
                canonicalName: String(cString: sqlite3_column_text(stmt, 3)),
                snippet: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
                filePath: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            ))
        }
        return results
    }

    struct DataFlowRow {
        let from: String
        let to: String
        let predicate: String
        let sourceText: String
        let filePath: String?
    }

    func dataFlowRows() -> [DataFlowRow] {
        var results: [DataFlowRow] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
            SELECT
                COALESCE(se.canonical_name, c.subject_entity_id),
                COALESCE(oe.canonical_name, NULLIF(c.object, '')),
                c.predicate,
                COALESCE(c.raw_text, ''),
                d.file_path
            FROM claims c
            LEFT JOIN entities se ON LOWER(c.subject_entity_id) = LOWER(se.entity_id)
            LEFT JOIN entities oe ON LOWER(c.object_entity_id) = LOWER(oe.entity_id)
            LEFT JOIN documents d ON d.document_id = c.source_file
            WHERE c.predicate IN ('publishes', 'consumes', 'stores', 'reads_from', 'writes_to', 'sends', 'receives')
            ORDER BY COALESCE(se.canonical_name, c.subject_entity_id), c.predicate
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let from = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let to = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if from.isEmpty || to.isEmpty { continue }

            results.append(DataFlowRow(
                from: from,
                to: to,
                predicate: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                sourceText: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                filePath: sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            ))
        }
        return results
    }

    // MARK: - V1 Structural Index

    func upsertModule(id: String, name: String, path: String, parentId: String?, level: Int, fileCount: Int) {
        try? execute("""
            INSERT INTO modules (module_id, name, path, parent_module_id, level, file_count)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(module_id) DO UPDATE SET file_count=?, name=?
        """, params: [.text(id), .text(name), .text(path), .textOrNull(parentId), .int(level), .int(fileCount), .int(fileCount), .text(name)])
    }

    func insertSymbol(id: String, moduleId: String?, documentId: String?, name: String, kind: String, lineStart: Int?, lineEnd: Int?, context: String?) {
        try? execute("""
            INSERT OR IGNORE INTO symbols (symbol_id, module_id, document_id, name, kind, line_start, line_end, context)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text(id), .textOrNull(moduleId), .textOrNull(documentId), .text(name), .text(kind),
                     lineStart.map { .int($0) } ?? .textOrNull(nil), lineEnd.map { .int($0) } ?? .textOrNull(nil), .textOrNull(context)])
    }

    func insertRelation(id: String, sourceId: String, targetId: String, type: String, sourceDoc: String?, evidence: String?) {
        try? execute("""
            INSERT OR IGNORE INTO struct_relations (relation_id, source_id, target_id, type, source_doc, evidence)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text(id), .text(sourceId), .text(targetId), .text(type), .textOrNull(sourceDoc), .textOrNull(evidence)])
    }

    func upsertArtifact(id: String, moduleId: String?, kind: String, content: String, model: String?) {
        let now = Int(Date().timeIntervalSince1970)
        try? execute("""
            INSERT INTO artifacts (artifact_id, module_id, kind, content, created_at, model_used)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(artifact_id) DO UPDATE SET content=?, created_at=?
        """, params: [.text(id), .textOrNull(moduleId), .text(kind), .text(content), .int(now), .textOrNull(model), .text(content), .int(now)])
    }

    func indexDocumentFTS(documentId: String, title: String, content: String) {
        // Delete old entry first, then insert new
        try? execute("DELETE FROM fts_documents WHERE document_id = ?", params: [.text(documentId)])
        try? execute("INSERT INTO fts_documents (document_id, title, content) VALUES (?, ?, ?)",
                    params: [.text(documentId), .text(title), .text(content)])
    }

    // MARK: - FTS5 Search

    struct SearchResult {
        let documentId: String
        let title: String
        let snippet: String
        let rank: Double
    }

    func search(query: String, limit: Int = 50) -> [SearchResult] {
        var results: [SearchResult] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT document_id, title, snippet(fts_documents, 2, '>>>', '<<<', '...', 40), rank FROM fts_documents WHERE fts_documents MATCH ? ORDER BY rank LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let docId = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let snippet = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let rank = sqlite3_column_double(stmt, 3)
            results.append(SearchResult(documentId: docId, title: title, snippet: snippet, rank: rank))
        }
        return results
    }

    // MARK: - Module Queries

    struct ModuleInfo {
        let id: String
        let name: String
        let path: String
        let level: Int
        let fileCount: Int
        let description: String?
    }

    func allModules() -> [ModuleInfo] {
        var results: [ModuleInfo] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT module_id, name, path, level, file_count, description FROM modules ORDER BY path"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(ModuleInfo(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                name: String(cString: sqlite3_column_text(stmt, 1)),
                path: String(cString: sqlite3_column_text(stmt, 2)),
                level: Int(sqlite3_column_int(stmt, 3)),
                fileCount: Int(sqlite3_column_int(stmt, 4)),
                description: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            ))
        }
        return results
    }

    func symbolsForModule(_ moduleId: String) -> [(name: String, kind: String, doc: String?, context: String?)] {
        var results: [(String, String, String?, String?)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name, kind, document_id, context FROM symbols WHERE module_id = ? ORDER BY kind, name"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, moduleId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            ))
        }
        return results
    }

    /// Clear symbols of a given kind for a document
    func clearSymbols(forDocument docId: String, kind: String) {
        try? execute("DELETE FROM symbols WHERE document_id = ? AND kind = ?", params: [.text(docId), .text(kind)])
    }

    /// Clear all Haiku-extracted components for a document (for re-extraction)
    func clearExtractedComponents(forDocument docId: String) {
        // Delete cmod_ modules first (before deleting their symbols, since we need module_id refs)
        try? execute("DELETE FROM modules WHERE module_id LIKE 'cmod_%' AND module_id IN (SELECT DISTINCT module_id FROM symbols WHERE document_id = ? AND kind = 'component')", params: [.text(docId)])
        try? execute("DELETE FROM symbols WHERE document_id = ? AND kind = 'component'", params: [.text(docId)])
        // Clean up orphaned cmod_ modules
        try? execute("DELETE FROM modules WHERE module_id LIKE 'cmod_%' AND module_id NOT IN (SELECT DISTINCT module_id FROM symbols WHERE kind = 'component')", params: [])
    }

    /// Check if a document already has Haiku-extracted component symbols
    func hasExtractedComponents(forDocument docId: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT COUNT(*) FROM symbols WHERE document_id = ? AND kind = 'component'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, docId, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    func relationsForModule(_ moduleId: String) -> [(targetId: String, type: String, evidence: String?)] {
        var results: [(String, String, String?)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT target_id, type, evidence FROM struct_relations WHERE source_id = ? ORDER BY type"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, moduleId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            ))
        }
        return results
    }

    func incomingRelationsForModule(_ moduleId: String) -> [(sourceId: String, type: String)] {
        var results: [(String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT source_id, type FROM struct_relations WHERE target_id = ? ORDER BY type"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, moduleId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
        }
        return results
    }

    func artifactsForModule(_ moduleId: String) -> [(kind: String, content: String)] {
        var results: [(String, String)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT kind, content FROM artifacts WHERE module_id = ? ORDER BY created_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, moduleId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((String(cString: sqlite3_column_text(stmt, 0)), String(cString: sqlite3_column_text(stmt, 1))))
        }
        return results
    }

    /// All research artifacts (Q&A history), newest first
    func allResearchArtifacts() -> [(id: String, content: String, createdAt: Int)] {
        var results: [(String, String, Int)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT artifact_id, content, created_at FROM artifacts WHERE kind = 'research' ORDER BY created_at DESC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2))
            ))
        }
        return results
    }

    /// Delete all research artifacts
    func clearResearchHistory() {
        try? execute("DELETE FROM citations WHERE artifact_id IN (SELECT artifact_id FROM artifacts WHERE kind = 'research')", params: [])
        try? execute("DELETE FROM artifacts WHERE kind = 'research'", params: [])
    }

    // MARK: - V2 Chunks + Citations

    func insertChunk(id: String, documentId: String, text: String, charStart: Int, charEnd: Int) {
        try? execute("INSERT OR IGNORE INTO chunks (chunk_id, document_id, text, char_start, char_end) VALUES (?, ?, ?, ?, ?)",
                    params: [.text(id), .text(documentId), .text(text), .int(charStart), .int(charEnd)])
    }

    func chunksForDocument(_ documentId: String) -> [(id: String, text: String, charStart: Int, charEnd: Int)] {
        var results: [(String, String, Int, Int)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT chunk_id, text, char_start, char_end FROM chunks WHERE document_id = ? ORDER BY char_start"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                String(cString: sqlite3_column_text(stmt, 1)),
                Int(sqlite3_column_int(stmt, 2)),
                Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return results
    }

    func insertCitation(id: String, artifactId: String, documentId: String, lineStart: Int?, lineEnd: Int?, quoteText: String?) {
        try? execute("INSERT OR IGNORE INTO citations (citation_id, artifact_id, document_id, line_start, line_end, quote_text) VALUES (?, ?, ?, ?, ?, ?)",
                    params: [.text(id), .text(artifactId), .text(documentId),
                            lineStart.map { .int($0) } ?? .textOrNull(nil),
                            lineEnd.map { .int($0) } ?? .textOrNull(nil),
                            .textOrNull(quoteText)])
    }

    func citationsForArtifact(_ artifactId: String) -> [(documentId: String, lineStart: Int?, quoteText: String?)] {
        var results: [(String, Int?, String?)] = []
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT document_id, line_start, quote_text FROM citations WHERE artifact_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, artifactId, -1, SQLITE_TRANSIENT)
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append((
                String(cString: sqlite3_column_text(stmt, 0)),
                sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 1)),
                sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            ))
        }
        return results
    }

    func insertQualityTag(id: String, moduleId: String, attribute: String, value: String, artifactId: String?) {
        try? execute("INSERT OR REPLACE INTO quality_tags (tag_id, module_id, attribute, value, source_artifact_id) VALUES (?, ?, ?, ?, ?)",
                    params: [.text(id), .text(moduleId), .text(attribute), .text(value), .textOrNull(artifactId)])
    }

    /// Get content hash for a document (for change detection)
    func getDocumentHash(_ documentId: String) -> String? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT content_hash FROM documents WHERE document_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, documentId, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) {
            return String(cString: ptr)
        }
        return nil
    }

    /// Execute raw SQL with a single text param (for reconciler)
    func execute_raw(_ sql: String, text: String) throws {
        try execute(sql, params: [.text(text)])
    }

    // MARK: - Low-level SQL

    private enum SQLValue {
        case text(String)
        case textOrNull(String?)
        case int(Int)
        case real(Double)
    }

    /// SQLITE_TRANSIENT tells SQLite to copy string data immediately,
    /// so the temporary Swift string buffer can be safely freed.
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var SQLITE_TRANSIENT: sqlite3_destructor_type { Self.sqliteTransient }

    private func execute(_ sql: String, params: [SQLValue] = []) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SemanticDBError.prepareFailed(msg)
        }

        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case .text(let s):
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .textOrNull(let s):
                if let s = s {
                    sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, idx)
                }
            case .int(let n):
                sqlite3_bind_int64(stmt, idx, Int64(n))
            case .real(let d):
                sqlite3_bind_double(stmt, idx, d)
            }
        }

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SemanticDBError.executeFailed(msg)
        }
    }
}

enum SemanticDBError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "SQLite open failed: \(msg)"
        case .prepareFailed(let msg): return "SQLite prepare failed: \(msg)"
        case .executeFailed(let msg): return "SQLite execute failed: \(msg)"
        }
    }
}
