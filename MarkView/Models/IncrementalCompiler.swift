import Foundation

/// Orchestrates the incremental semantic compilation pipeline (TZ §4.1 Steps A–H).
/// Uses AIOrchestrator for extraction, SemanticReconciler for claim dedup,
/// DependencyGraphScheduler for cascade invalidation, OverlayManager for glossary/suppressions.
@MainActor
class IncrementalCompiler: ObservableObject {
    @Published var compilationQueue: [String] = []
    @Published var currentBlockId: String?
    @Published var diagnostics: [Diagnostic] = []

    let database: SemanticDatabase
    let orchestrator: AIOrchestrator
    let reconciler: SemanticReconciler
    let dependencyGraph: DependencyGraphScheduler
    let overlayManager: OverlayManager

    private let workspacePath: URL
    private var prioritizedBlockId: String?

    init(workspacePath: URL, database: SemanticDatabase, apiKey: String? = nil) {
        self.workspacePath = workspacePath
        self.database = database
        self.orchestrator = AIOrchestrator(database: database, workspacePath: workspacePath, apiKey: apiKey)
        self.reconciler = SemanticReconciler(database: database)
        self.dependencyGraph = DependencyGraphScheduler(database: database)
        self.overlayManager = OverlayManager(workspacePath: workspacePath)

        // Apply overlay privacy mode to orchestrator
        orchestrator.setPrivacyMode(overlayManager.privacyMode)
    }

    // MARK: - Step A+B: Delta Processing (from JS bridge)

    /// Process block delta — the entry point for incremental compilation
    func compileDelta(_ delta: BlocksDelta, forFile fileURL: URL) {
        let filePath = fileURL.lastPathComponent
        let documentId = filePath

        // Ensure document exists in DB
        try? database.upsertDocument(
            id: documentId,
            projectId: workspacePath.lastPathComponent,
            filePath: filePath,
            fileName: fileURL.deletingPathExtension().lastPathComponent,
            fileExt: fileURL.pathExtension,
            contentHash: ""
        )

        // Step C: Resolve affected blocks
        var blocksToCompile: [SemanticBlock] = []

        for block in delta.changed + delta.added {
            blocksToCompile.append(block)

            // Mark dirty in dependency graph and find cascade
            let affected = dependencyGraph.handleBlockChange(blockId: block.id)
            if !affected.isEmpty {
                NSLog("[Compiler] Block \(block.id) change cascaded to \(affected.count) dependent nodes")
            }
        }

        // Remove deleted blocks
        for blockId in delta.removed {
            try? database.deleteBlock(id: blockId)
            try? database.deleteClaimsForBlock(blockId)
            try? database.deleteRelationsForBlock(blockId)
            try? database.deleteDiagnosticsForBlock(blockId)
            dependencyGraph.clearDependencies(for: blockId)
        }

        // NOTE: Do NOT auto-submit to AI here.
        // AI extraction only happens during background analysis (WorkspaceManager.analyzeAllFiles).
        // This prevents money leaking on every tab switch / text change.
        // Blocks are stored in DB; AI extraction is a separate, explicit step.
    }

    /// Prioritize the block under cursor for immediate compilation
    func prioritizeBlock(_ blockId: String) {
        prioritizedBlockId = blockId
        if let idx = compilationQueue.firstIndex(of: blockId), idx > 0 {
            compilationQueue.remove(at: idx)
            compilationQueue.insert(blockId, at: 0)
        }
    }

    // MARK: - Step G: Diagnostic Generation

    /// Run contradiction detection across all claims
    func runContradictionDetection() {
        let claims = orchestrator.extractedClaims

        // Find claims with same subject + predicate but different objects
        var claimsByAxis: [String: [SemanticClaim]] = [:]
        for claim in claims {
            let axis = "\(claim.subjectEntityId)|\(claim.predicate)|\(claim.scopeKind)|\(claim.temporalContextId ?? "none")"
            claimsByAxis[axis, default: []].append(claim)
        }

        for (axis, axisGroup) in claimsByAxis where axisGroup.count > 1 {
            // Check for conflicting objects
            let activeGroup = axisGroup.filter { ["accepted", "implemented", "planned"].contains($0.status) }
            guard activeGroup.count > 1 else { continue }

            let objects = Set(activeGroup.map { $0.object })
            if objects.count > 1 {
                // Contradiction detected
                let claimIds = activeGroup.map { $0.id }
                let diag = Diagnostic(
                    id: "diag_contradiction_\(fnv1aHash(axis))",
                    type: .architecturalContradiction,
                    severity: .error,
                    message: "Contradicting claims: \(activeGroup.map { "'\($0.safeRawText.prefix(50))'" }.joined(separator: " vs "))",
                    explanation: "These claims have the same subject and predicate but different objects, and are both active",
                    documentId: activeGroup.first?.safeSourceFile ?? "",
                    blockId: activeGroup.first?.safeSourceBlockId,
                    claimIds: claimIds,
                    entityIds: [activeGroup.first?.safeSubjectEntityId ?? ""],
                    suggestedFix: "Resolve by updating one claim or adding temporal/scope differentiation",
                    isSuppressed: overlayManager.shouldSuppress(
                        diagnosticType: "architecturalContradiction",
                        entityName: nil
                    ),
                    createdAt: Date()
                )

                diagnostics.removeAll { $0.id == diag.id }
                diagnostics.append(diag)
                try? database.upsertDiagnostic(diag)
            }
        }
    }

    // MARK: - Full Document Ingestion

    func ingestDocument(blocks: [SemanticBlock], fileURL: URL) {
        let filePath = fileURL.lastPathComponent
        let documentId = filePath

        try? database.upsertDocument(
            id: documentId,
            projectId: workspacePath.lastPathComponent,
            filePath: filePath,
            fileName: fileURL.deletingPathExtension().lastPathComponent,
            fileExt: fileURL.pathExtension,
            contentHash: ""
        )

        for block in blocks {
            try? database.upsertBlock(block, documentId: documentId)
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
