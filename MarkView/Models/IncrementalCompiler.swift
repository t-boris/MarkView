import Foundation

/// Stores editor block deltas in the semantic database and tracks block dependencies
/// (DependencyGraphScheduler). There is no AI extraction step.
@MainActor
class IncrementalCompiler: ObservableObject {
    let database: SemanticDatabase
    let dependencyGraph: DependencyGraphScheduler

    private let workspacePath: URL

    init(workspacePath: URL, database: SemanticDatabase) {
        self.workspacePath = workspacePath
        self.database = database
        self.dependencyGraph = DependencyGraphScheduler(database: database)
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
    }
}
