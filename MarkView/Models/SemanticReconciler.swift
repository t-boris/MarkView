import Foundation

/// Reconciles old vs new semantic extraction results for a block.
/// Prevents duplicates by matching claims on semantic identity:
/// same subject + same predicate family + same scope + similar object + same temporal anchor
@MainActor
class SemanticReconciler {
    private weak var database: SemanticDatabase?

    init(database: SemanticDatabase) {
        self.database = database
    }

    /// Reconcile new extraction results against existing data for a block.
    /// Returns the net changes (what was added, updated, removed).
    func reconcile(
        newResult: BlockExtractionResult,
        blockId: String,
        documentId: String,
        existingClaims: [SemanticClaim],
        existingEntities: [SemanticEntity]
    ) -> ReconciliationResult {
        var result = ReconciliationResult()

        // --- Entity reconciliation ---
        for newEntity in newResult.safeEntities {
            if let existing = existingEntities.first(where: {
                $0.canonicalName.lowercased() == newEntity.canonicalName.lowercased() &&
                $0.type == newEntity.type
            }) {
                // Entity exists — merge aliases
                var merged = existing
                let newAliases = Set(newEntity.safeAliases).subtracting(existing.safeAliases)
                if !newAliases.isEmpty {
                    merged.aliases = (merged.aliases ?? []) + Array(newAliases)
                    merged.updatedAt = Date()
                    result.updatedEntities.append(merged)
                }
            } else {
                result.addedEntities.append(newEntity)
            }
        }

        // --- Claim reconciliation by semantic identity ---
        var matchedOldClaims = Set<String>()

        for newClaim in newResult.safeClaims {
            if let match = existingClaims.first(where: { oldClaim in
                matchesSemantically(old: oldClaim, new: newClaim)
            }) {
                matchedOldClaims.insert(match.id)
                // Check if text changed (but semantics same)
                if match.rawText != newClaim.rawText || match.object != newClaim.object {
                    var updated = newClaim
                    updated.updatedAt = Date()
                    result.updatedClaims.append(updated)
                } else {
                    result.unchangedClaimIds.append(match.id)
                }
            } else {
                result.addedClaims.append(newClaim)
            }
        }

        // Claims that existed before but are no longer present
        for old in existingClaims where !matchedOldClaims.contains(old.id) {
            result.removedClaimIds.append(old.id)
        }

        // --- Relations: simple replace for now ---
        result.newRelations = newResult.safeRelations

        // --- Temporal contexts: merge by label ---
        result.newTemporalContexts = newResult.safeTemporalContexts

        return result
    }

    /// Two claims match semantically if they share the same subject + predicate axis + scope + temporal context
    private func matchesSemantically(old: SemanticClaim, new: SemanticClaim) -> Bool {
        // Same subject entity
        guard old.safeSubjectEntityId == new.safeSubjectEntityId ||
              old.safeSubjectEntityId.lowercased() == new.safeSubjectEntityId.lowercased() else { return false }

        // Same predicate family
        guard old.predicate == new.predicate else { return false }

        // Same scope
        guard old.safeScopeKind == new.safeScopeKind else { return false }

        // Same temporal context
        guard old.temporalContextId == new.temporalContextId else { return false }

        // Same claim type
        guard old.type == new.type else { return false }

        return true
    }

    /// Apply reconciliation results to the database
    func apply(_ result: ReconciliationResult, blockId: String) {
        guard let db = database else { return }

        for entity in result.addedEntities {
            try? db.upsertEntity(entity)
        }
        for entity in result.updatedEntities {
            try? db.upsertEntity(entity)
        }
        for claim in result.addedClaims {
            try? db.upsertClaim(claim)
        }
        for claim in result.updatedClaims {
            try? db.upsertClaim(claim)
        }
        for claimId in result.removedClaimIds {
            // Mark as historical rather than delete
            try? db.execute_raw("UPDATE claims SET status = 'historical' WHERE claim_id = ?", text: claimId)
        }
        try? db.deleteRelationsForBlock(blockId)
        for relation in result.newRelations {
            try? db.upsertRelation(relation)
        }
        for tc in result.newTemporalContexts {
            try? db.upsertTemporalContext(tc)
        }
    }
}

/// Result of reconciliation — what changed, what's new, what was removed
struct ReconciliationResult {
    var addedEntities: [SemanticEntity] = []
    var updatedEntities: [SemanticEntity] = []
    var addedClaims: [SemanticClaim] = []
    var updatedClaims: [SemanticClaim] = []
    var unchangedClaimIds: [String] = []
    var removedClaimIds: [String] = []
    var newRelations: [SemanticRelation] = []
    var newTemporalContexts: [TemporalContext] = []

    var hasChanges: Bool {
        !addedEntities.isEmpty || !updatedEntities.isEmpty ||
        !addedClaims.isEmpty || !updatedClaims.isEmpty || !removedClaimIds.isEmpty
    }
}
