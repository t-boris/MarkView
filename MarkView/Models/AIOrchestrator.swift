import Foundation

/// Central hub for AI interactions — manages jobs, caching, deduplication, and provider routing.
/// Editor UI never calls AI providers directly — everything goes through AIOrchestrator.
@MainActor
class AIOrchestrator: ObservableObject {
    @Published var activeJobs: [AIJob] = []
    @Published var isProcessing = false
    @Published var extractedEntities: [SemanticEntity] = []
    @Published var extractedClaims: [SemanticClaim] = []
    @Published var extractedRelations: [SemanticRelation] = []
    @Published var lastError: String?
    @Published var isDisabled = false
    @Published var isPaused = false
    @Published var currentFile: String?  // Shows which file is being processed
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    @Published var completedJobCount: Int = 0

    let providerClient: AIProviderClient
    private let cacheManager: CacheManager
    private weak var database: SemanticDatabase?
    private var privacyMode: PrivacyMode = .trustedRemote

    private var pendingJobContent: [String: String] = [:]
    private var jobQueue: [AIJob] = []
    private var consecutiveFailures = 0

    init(database: SemanticDatabase, workspacePath: URL, apiKey: String? = nil) {
        self.database = database
        self.cacheManager = CacheManager(workspacePath: workspacePath)
        self.providerClient = AIProviderClient(apiKey: apiKey)

        // Load persisted usage stats from previous sessions
        let stats = database.getUsageStats()
        self.totalInputTokens = stats.totalInputTokens
        self.totalOutputTokens = stats.totalOutputTokens
        self.completedJobCount = stats.totalJobs
    }

    var hasAPIKey: Bool { providerClient.hasAPIKey }

    func updateAPIKey(_ key: String?) {
        providerClient.updateAPIKey(key)
    }

    func setPrivacyMode(_ mode: PrivacyMode) {
        self.privacyMode = mode
    }

    /// Reset error state — user can call this after fixing billing/key issues
    func resetAndRetry() {
        isDisabled = false
        lastError = nil
        consecutiveFailures = 0
    }

    // MARK: - Job Submission

    /// Submit a semantic extraction job for a block
    func submitExtraction(block: SemanticBlock, documentId: String, file: String) {
        guard !isDisabled else { return }
        guard !isPaused else { return }

        guard privacyMode != .localOnly else { return }
        guard providerClient.hasAPIKey else { return }

        // Skip empty blocks
        let content = block.content
        guard content.count > 10 else { return }

        let inputHash = fnv1aHash(content)

        // Check cache — skip if same content was already processed
        if let cached = cacheManager.loadCachedResponse(inputHash: inputHash) {
            if let result = try? JSONDecoder().decode(BlockExtractionResult.self, from: cached) {
                NSLog("[AIOrchestrator] Cache hit for block \(block.id)")
                // Ensure block exists in DB (for FK constraints on claims)
                try? database?.upsertBlock(block, documentId: documentId)
                handleExtractionResult(result, blockId: block.id, documentId: documentId, file: file)
                return
            }
        }

        // Note: removed ai_jobs table cache check — file cache above is sufficient
        // and ai_jobs can become stale after clearAll()

        let job = AIJob(
            id: UUID().uuidString,
            jobType: .extractBlockSemantics,
            priority: .responsive,
            status: .pending,
            documentId: documentId,
            blockIds: [block.id],
            inputHash: inputHash,
            modelPolicy: nil,
            privacyMode: privacyMode,
            resultRef: nil,
            errorState: nil,
            createdAt: Date(),
            startedAt: nil,
            completedAt: nil,
            retryCount: 0,
            costTokens: nil
        )

        // Store the block content alongside the job
        pendingJobContent[job.id] = block.content

        try? database?.insertAIJob(job)
        jobQueue.append(job)
        activeJobs.append(job)
        processQueue()
    }

    // MARK: - Queue Processing (concurrent, up to 3 simultaneous)

    private let maxConcurrent = 3
    private var runningCount = 0

    private func processQueue() {
        guard !isPaused, !isDisabled else { return }

        while runningCount < maxConcurrent, !jobQueue.isEmpty {
            let job = jobQueue.removeFirst()
            runningCount += 1
            isProcessing = true

            Task {
                await executeJob(job)
                runningCount -= 1
                isProcessing = runningCount > 0 || !jobQueue.isEmpty
                if !jobQueue.isEmpty {
                    processQueue()
                }
            }
        }
    }

    private func executeJob(_ job: AIJob) async {
        var mutableJob = job
        mutableJob.status = .inProgress
        mutableJob.startedAt = Date()
        currentFile = mutableJob.documentId
        try? database?.updateAIJobStatus(job.id, status: .inProgress)
        updateActiveJob(mutableJob)

        // Get the block content that was stored when the job was submitted
        let blockContent = pendingJobContent.removeValue(forKey: job.id) ?? ""
        guard !blockContent.isEmpty else {
            mutableJob.status = .failed
            mutableJob.errorState = "No block content available"
            try? database?.updateAIJobStatus(job.id, status: .failed, error: "No content")
            updateActiveJob(mutableJob)
            return
        }

        do {
            let response = try await providerClient.extractBlockSemantics(
                blockContent: blockContent,
                jobType: mutableJob.jobType
            )

            // Track token usage (in-memory + persisted to DB)
            totalInputTokens += response.inputTokens
            totalOutputTokens += response.outputTokens
            completedJobCount += 1

            // Persist to DB so it survives restarts
            // Sonnet 4: $3/1M input, $15/1M output
            let costCents = (Double(response.inputTokens) * 0.0003 + Double(response.outputTokens) * 0.0015)
            database?.addUsage(inputTokens: response.inputTokens, outputTokens: response.outputTokens, costCents: costCents)

            // Cache the response — but ONLY if it has actual data (don't cache empty results)
            let hasData = !response.result.safeEntities.isEmpty || !response.result.safeClaims.isEmpty
            if hasData, let data = try? JSONEncoder().encode(response.result) {
                cacheManager.saveCachedResponse(inputHash: mutableJob.inputHash, data: data)
            }

            // Handle extraction results — persist to DB and update @Published
            let blockId = mutableJob.blockIds.first ?? ""
            let documentId = mutableJob.documentId ?? ""
            handleExtractionResult(response.result, blockId: blockId, documentId: documentId, file: documentId)

            mutableJob.status = .completed
            mutableJob.completedAt = Date()
            mutableJob.costTokens = response.inputTokens + response.outputTokens
            try? database?.updateAIJobStatus(job.id, status: .completed, resultRef: mutableJob.inputHash)
            updateActiveJob(mutableJob)

            consecutiveFailures = 0
            NSLog("[AIOrchestrator] Job \(job.id) completed: \(response.result.safeEntities.count) entities, \(response.result.safeClaims.count) claims (\(response.inputTokens)+\(response.outputTokens) tokens)")

        } catch {
            mutableJob.status = .failed
            mutableJob.errorState = error.localizedDescription
            try? database?.updateAIJobStatus(job.id, status: .failed, error: error.localizedDescription)
            updateActiveJob(mutableJob)
            consecutiveFailures += 1

            // Check if this is a fatal/billing error — stop everything
            let errorMsg = error.localizedDescription
            if errorMsg.contains("credit balance") || errorMsg.contains("billing") ||
               errorMsg.contains("authentication") || errorMsg.contains("invalid_api_key") ||
               errorMsg.contains("HTTP 401") || errorMsg.contains("HTTP 403") {
                isDisabled = true
                lastError = errorMsg
                jobQueue.removeAll()
                pendingJobContent.removeAll()
                NSLog("[AIOrchestrator] FATAL: API error, stopping all jobs: \(errorMsg)")
                return
            }

            // Stop after 3 consecutive failures (rate limit, server issues)
            if consecutiveFailures >= 3 {
                isDisabled = true
                lastError = "Stopped after \(consecutiveFailures) consecutive failures: \(errorMsg)"
                jobQueue.removeAll()
                pendingJobContent.removeAll()
                NSLog("[AIOrchestrator] Stopped after \(consecutiveFailures) failures")
                return
            }

            NSLog("[AIOrchestrator] Job failed (\(consecutiveFailures)/3): \(error)")
        }
    }

    private func updateActiveJob(_ job: AIJob) {
        if let idx = activeJobs.firstIndex(where: { $0.id == job.id }) {
            activeJobs[idx] = job
        }
        if job.status == .completed || job.status == .failed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.activeJobs.removeAll { $0.id == job.id }
            }
        }
    }

    // MARK: - Result Handling

    private func handleExtractionResult(_ result: BlockExtractionResult, blockId: String, documentId: String, file: String) {
        guard let db = database else { return }

        // Reconcile: remove old claims/relations for this block, insert new ones
        try? db.deleteClaimsForBlock(blockId)
        try? db.deleteRelationsForBlock(blockId)

        var normalizedEntities: [SemanticEntity] = []
        var entityIdMap: [String: String] = [:]

        // Persist and accumulate entities — deduplicate by canonicalName
        for var entity in result.safeEntities {
            let originalEntityId = entity.id
            // Make ID unique by prefixing with blockId hash to avoid Claude's duplicate short IDs
            entity = SemanticEntity(
                id: "\(entity.id)_\(blockId.prefix(8))",
                name: entity.name, type: entity.type, canonicalName: entity.canonicalName,
                aliases: entity.aliases, attributes: entity.attributes,
                description: entity.description, status: entity.status,
                sourceFile: file, sourceBlockId: blockId
            )
            entityIdMap[originalEntityId] = entity.id
            entityIdMap[entity.id] = entity.id
            try? db.upsertEntity(entity)
            // Deduplicate in memory by canonicalName
            if let idx = extractedEntities.firstIndex(where: { $0.canonicalName == entity.canonicalName }) {
                extractedEntities[idx] = entity // update existing
            } else {
                extractedEntities.append(entity)
            }
            normalizedEntities.append(entity)
        }

        // Persist and accumulate claims — deduplicate by rawText
        extractedClaims.removeAll { $0.safeSourceBlockId == blockId }
        var normalizedClaims: [SemanticClaim] = []
        for var claim in result.safeClaims {
            claim = SemanticClaim(
                id: "\(claim.id)_\(blockId.prefix(8))",
                type: claim.type,
                subjectEntityId: claim.subjectEntityId.flatMap { entityIdMap[$0] },
                predicate: claim.predicate, object: claim.object,
                objectEntityId: claim.objectEntityId.flatMap { entityIdMap[$0] },
                sourceFile: file, sourceBlockId: blockId,
                rawText: claim.rawText, status: claim.status,
                confidence: claim.confidence,
                scopeKind: claim.scopeKind, scopeValue: claim.scopeValue,
                temporalContextId: claim.temporalContextId,
                evidenceBlockIds: claim.evidenceBlockIds
            )
            do {
                try db.upsertClaim(claim)
            } catch {
                NSLog("[AIOrchestrator] Failed to save claim: \(error)")
            }
            extractedClaims.append(claim)
            normalizedClaims.append(claim)
        }

        // Persist relations with unique IDs
        extractedRelations.removeAll { $0.sourceBlockId == blockId }
        var normalizedRelations: [SemanticRelation] = []
        for var relation in result.safeRelations {
            guard let normalizedSourceId = entityIdMap[relation.sourceId],
                  let normalizedTargetId = entityIdMap[relation.targetId] else {
                continue
            }
            relation = SemanticRelation(
                id: "\(relation.id)_\(blockId.prefix(8))",
                sourceId: normalizedSourceId, targetId: normalizedTargetId,
                type: relation.type, sourceFile: file, sourceBlockId: blockId
            )
            try? db.upsertRelation(relation)
            extractedRelations.append(relation)
            normalizedRelations.append(relation)
        }

        // Persist temporal contexts
        for tc in result.safeTemporalContexts {
            try? db.upsertTemporalContext(tc)
        }

        // Run basic diagnostic generation
        generateBasicDiagnostics(
            entities: normalizedEntities,
            claims: normalizedClaims,
            relations: normalizedRelations,
            blockId: blockId,
            documentId: documentId
        )
    }

    // MARK: - Basic Diagnostics

    private func generateBasicDiagnostics(
        entities: [SemanticEntity],
        claims: [SemanticClaim],
        relations: [SemanticRelation],
        blockId: String,
        documentId: String
    ) {
        guard let db = database else { return }
        _ = relations

        // Remove old diagnostics for this block
        try? db.deleteDiagnosticsForBlock(blockId)

        // Check for claims missing rationale
        for claim in claims where claim.safeType == "Decision" {
            let hasRationale = claims.contains { $0.safeType == "Rationale" && $0.safeSubjectEntityId == claim.safeSubjectEntityId }
            if !hasRationale {
                let diag = Diagnostic(
                    id: "diag_\(fnv1aHash("\(claim.id)_rationale"))",
                    type: .missingRationale,
                    severity: .warning,
                    message: "Decision '\(claim.safeRawText.prefix(60))...' lacks rationale",
                    explanation: "Architecture decisions should include reasoning for traceability",
                    documentId: documentId,
                    blockId: blockId,
                    claimIds: [claim.id],
                    entityIds: [claim.safeSubjectEntityId],
                    suggestedFix: "Add a rationale paragraph explaining why this decision was made",
                    isSuppressed: false,
                    createdAt: Date()
                )
                try? db.upsertDiagnostic(diag)
            }
        }

        // Check for entities without owners
        for entity in entities where (entity.type == "Service" || entity.type == "System") {
            let hasOwner = claims.contains { $0.safeType == "OwnershipClaim" && $0.safeSubjectEntityId == entity.id }
            if !hasOwner {
                let diag = Diagnostic(
                    id: "diag_\(fnv1aHash("\(entity.id)_owner"))",
                    type: .missingOwner,
                    severity: .info,
                    message: "\(entity.type) '\(entity.name)' has no declared owner",
                    explanation: nil,
                    documentId: documentId,
                    blockId: blockId,
                    claimIds: [],
                    entityIds: [entity.id],
                    suggestedFix: "Add ownership claim: 'Team X owns \(entity.name)'",
                    isSuppressed: false,
                    createdAt: Date()
                )
                try? db.upsertDiagnostic(diag)
            }
        }
    }

    // MARK: - Helpers

    private func fnv1aHash(_ str: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in str.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(hash, radix: 16)
    }
}
