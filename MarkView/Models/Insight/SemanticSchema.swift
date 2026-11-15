import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The schema of `.dde/state.db` as an ordered list of migrations (`AR-38`). `PRAGMA user_version` is the number of the last
/// step applied. A new schema change is a new step at the end of the list; no step is ever edited once released, and no
/// step deletes data the index run cannot rebuild.
///
/// Releases up to 6.26.2 had no migration list: they created every table with `CREATE ... IF NOT EXISTS` at each open,
/// topped up the columns of `arch_nodes`, and stamped `user_version = 1` ("docId scheme"). A file stamped 1 therefore
/// already carries the docId scheme, and step 2 brings any older release's table set to the current one without
/// touching a row.
enum SemanticSchema {
    /// Applied to each connection before the migrations (`foreign_keys` has no effect inside a transaction).
    static let pragmas = [
        "PRAGMA foreign_keys = ON",
        "PRAGMA journal_mode = WAL",
        "PRAGMA synchronous = NORMAL",
        "PRAGMA temp_store = MEMORY",
        "PRAGMA cache_size = -20000",
    ]

    /// How long a statement waits for a lock held by another connection or process (the indexer child) before it fails.
    static let busyTimeoutMilliseconds: Int32 = 5000

    static let migrations: [SQLiteMigration] = [
        SQLiteMigration(version: 1, name: "docId scheme") { try clearRowsKeyedByTheOldDocumentIds($0) },
        SQLiteMigration(version: 2, name: "table set of release 6.26") { try createCurrentTables($0) },
    ]

    /// A file with a `documents` table and no version predates the docId scheme (path relative to the root): its document,
    /// module, entity and relation rows are keyed by file name and the index run writes them again. Foreign keys cascade
    /// the blocks, symbols, chunks and diagnostics. X-Ray groupings, usage totals and every other table stay.
    private static func clearRowsKeyedByTheOldDocumentIds(_ db: OpaquePointer) throws {
        guard SQLiteSchema.tableExists(db, "documents") else { return }
        for table in ["fts_documents", "struct_relations", "entity_relations", "claims", "entities", "documents", "modules"]
        where SQLiteSchema.tableExists(db, table) {
            try SQLiteSchema.execute(db, "DELETE FROM \(table)")
        }
    }

    /// Every table the app uses, created only when missing, plus the `arch_nodes` columns later releases added. It is safe
    /// on a database written by any earlier release and a no-op on one written by 6.26.
    private static func createCurrentTables(_ db: OpaquePointer) throws {
        // Projects
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_documents_project ON documents(project_id)")

        // Blocks
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_blocks_document ON blocks(document_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_blocks_doc_order ON blocks(document_id, order_index)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_blocks_text_hash ON blocks(text_hash)")

        // Block compilation cache
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_entities_canonical ON entities(canonical_name)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_entities_type ON entities(type)")

        // Claims
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_claims_block ON claims(source_block_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_claims_entity ON claims(subject_entity_id)")

        // Entity Relations
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_relations_source ON entity_relations(source_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_relations_target ON entity_relations(target_id)")

        // Temporal Contexts
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_diagnostics_doc ON diagnostics(document_id)")

        // AI Jobs
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_ai_jobs_hash ON ai_jobs(input_hash)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_ai_jobs_status ON ai_jobs(status)")

        // Compile profiles
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS recompute_nodes (
                node_id TEXT PRIMARY KEY,
                node_type TEXT NOT NULL,
                is_dirty INTEGER DEFAULT 0,
                last_computed_at INTEGER
            )
        """)

        // Recompute graph edges
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS usage_stats (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                total_input_tokens INTEGER NOT NULL DEFAULT 0,
                total_output_tokens INTEGER NOT NULL DEFAULT 0,
                total_jobs INTEGER NOT NULL DEFAULT 0,
                total_cost_cents REAL NOT NULL DEFAULT 0.0
            )
        """)
        // Ensure single row exists
        try SQLiteSchema.execute(db, "INSERT OR IGNORE INTO usage_stats (id, total_input_tokens, total_output_tokens, total_jobs, total_cost_cents) VALUES (1, 0, 0, 0, 0.0)")

        // ============================================
        // V1: Structure-First Tables (C4/arc42)
        // ============================================

        // Modules: directories as logical units
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_symbols_doc ON symbols(document_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_symbols_module ON symbols(module_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_symbols_kind ON symbols(kind)")

        // Structural relations: deterministic links between modules/docs
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS struct_relations (
                relation_id TEXT PRIMARY KEY,
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                type TEXT NOT NULL,
                source_doc TEXT,
                evidence TEXT
            )
        """)
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_srel_source ON struct_relations(source_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_srel_target ON struct_relations(target_id)")
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_srel_type ON struct_relations(type)")

        // Artifacts: generated content (summaries, diagrams, ADRs)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS artifacts (
                artifact_id TEXT PRIMARY KEY,
                module_id TEXT,
                kind TEXT NOT NULL,
                content TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                model_used TEXT
            )
        """)
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_artifacts_module ON artifacts(module_id)")

        // FTS5 full-text search index
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_chunks_doc ON chunks(document_id)")

        // Quality attributes (arc42)
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS citations (
                citation_id TEXT PRIMARY KEY,
                artifact_id TEXT NOT NULL,
                document_id TEXT NOT NULL,
                line_start INTEGER,
                line_end INTEGER,
                quote_text TEXT
            )
        """)
        try SQLiteSchema.execute(db, "CREATE INDEX IF NOT EXISTS idx_citations_artifact ON citations(artifact_id)")

        // ============================================
        // V3: Implementation + GraphRAG (tables created early)
        // ============================================

        // Change plans
        try SQLiteSchema.execute(db, """
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
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS communities (
                community_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                module_ids_json TEXT,
                summary TEXT,
                level INTEGER DEFAULT 0
            )
        """)

        // Architecture views (ArchitectureStore)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_nodes (
                view TEXT NOT NULL,
                id TEXT NOT NULL,
                parent_id TEXT,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                path TEXT,
                language TEXT,
                loc INTEGER NOT NULL DEFAULT 0,
                files INTEGER NOT NULL DEFAULT 0,
                summary TEXT,
                role TEXT,
                tech TEXT,
                signature TEXT,
                summary_signature TEXT,
                component TEXT,
                tags_json TEXT,
                PRIMARY KEY (view, id)
            )
        """)
        // Databases created before these columns existed keep their table; add them.
        try SQLiteSchema.addMissingColumns(db, table: "arch_nodes", [
            ("signature", "TEXT"), ("summary_signature", "TEXT"), ("component", "TEXT"), ("tags_json", "TEXT"),
            // Book view: where a section or item is in its document.
            ("line", "INTEGER"), ("end_line", "INTEGER"), ("anchor", "TEXT"),
        ])
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_edges (
                view TEXT NOT NULL,
                source TEXT NOT NULL,
                target TEXT NOT NULL,
                kind TEXT NOT NULL,
                weight INTEGER NOT NULL DEFAULT 1,
                label TEXT,
                PRIMARY KEY (view, source, target, kind)
            )
        """)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_coverage (
                node_id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                docs_json TEXT NOT NULL DEFAULT '[]'
            )
        """)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_metrics (
                node_id TEXT PRIMARY KEY,
                json TEXT NOT NULL
            )
        """)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_reviews (
                diff_hash TEXT PRIMARY KEY,
                json TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)
        try SQLiteSchema.execute(db, """
            CREATE TABLE IF NOT EXISTS arch_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
        """)

        // user_version replaces this table, which no release ever wrote a row to.
        try SQLiteSchema.execute(db, "DROP TABLE IF EXISTS applied_migrations")
    }
}
