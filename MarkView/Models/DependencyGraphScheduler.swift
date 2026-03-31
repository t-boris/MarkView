import Foundation

/// Manages the recompute graph — tracks dependencies between blocks, entities, claims,
/// and determines which nodes need recompilation when something changes.
@MainActor
class DependencyGraphScheduler {
    private weak var database: SemanticDatabase?

    /// Adjacency list: nodeId → [dependent nodeIds]
    private var forwardEdges: [String: Set<String>] = [:]
    /// Reverse: nodeId → [nodes it depends on]
    private var reverseEdges: [String: Set<String>] = [:]
    /// Dirty tracking
    private var dirtyNodes: Set<String> = []

    init(database: SemanticDatabase) {
        self.database = database
    }

    // MARK: - Edge Management

    /// Register that `dependent` depends on `dependency`
    func addDependency(from dependent: String, to dependency: String) {
        forwardEdges[dependency, default: []].insert(dependent)
        reverseEdges[dependent, default: []].insert(dependency)
    }

    /// Register dependencies from extraction results
    func registerBlockDependencies(blockId: String, entityIds: [String], claimIds: [String]) {
        // Block depends on entities it references
        for entityId in entityIds {
            addDependency(from: blockId, to: entityId)
        }
        // Block depends on claims it contains
        for claimId in claimIds {
            addDependency(from: claimId, to: blockId)
        }
    }

    /// Remove all edges for a block (when it's removed or fully recompiled)
    func clearDependencies(for nodeId: String) {
        // Remove forward edges
        if let dependents = forwardEdges.removeValue(forKey: nodeId) {
            for dep in dependents {
                reverseEdges[dep]?.remove(nodeId)
            }
        }
        // Remove reverse edges
        if let dependencies = reverseEdges.removeValue(forKey: nodeId) {
            for dep in dependencies {
                forwardEdges[dep]?.remove(nodeId)
            }
        }
    }

    // MARK: - Dirty Tracking

    /// Mark a node as dirty (needs recompilation)
    func markDirty(_ nodeId: String) {
        dirtyNodes.insert(nodeId)
    }

    /// Get all nodes that are affected by changes to the given nodes (transitive)
    func transitiveAffected(from changedNodeIds: [String], maxDepth: Int = 3) -> Set<String> {
        var affected = Set<String>()
        var queue = changedNodeIds
        var depth = 0

        while !queue.isEmpty && depth < maxDepth {
            var nextQueue: [String] = []
            for nodeId in queue {
                if let dependents = forwardEdges[nodeId] {
                    for dep in dependents where !affected.contains(dep) {
                        affected.insert(dep)
                        nextQueue.append(dep)
                    }
                }
            }
            queue = nextQueue
            depth += 1
        }

        return affected
    }

    /// Get all dirty block IDs that need recompilation
    func dirtyBlockIds() -> [String] {
        Array(dirtyNodes).filter { $0.hasPrefix("blk_") || !$0.contains("_") }
    }

    /// Mark nodes as clean after recompilation
    func markClean(_ nodeIds: [String]) {
        for id in nodeIds {
            dirtyNodes.remove(id)
        }
    }

    /// Process a block change: mark it dirty + propagate to dependents
    func handleBlockChange(blockId: String) -> Set<String> {
        markDirty(blockId)
        let affected = transitiveAffected(from: [blockId])
        for id in affected {
            markDirty(id)
        }
        return affected
    }
}
