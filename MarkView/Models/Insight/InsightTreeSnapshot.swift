import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The persisted node tree of one Insight session (`<cache>/snapshot.json`): the root and every generated
/// deep-dive child, restored on reopen so deep-dive buttons reuse the cached children instead of running
/// Phase 1 and Phase 2 again. Pure value type: the session gathers its nodes, this type decides what is
/// worth saving, how it is encoded and how a saved tree (or an older root-only snapshot) becomes nodes again.
struct InsightTreeSnapshot: Codable {
    /// One persisted node (the root or any deep-dive child).
    struct Entry: Codable {
        let nodeId: UUID
        let parentId: UUID?
        let level: Int
        let title: String
        let scope: NodeScope
        let skeleton: InsightSkeleton
        let sectionBuffers: [String: String]
        let childIds: [UUID]
    }

    let rootId: UUID
    let folderPath: String
    let createdAt: Date
    // Legacy fields kept for forward compatibility (older snapshots only had these).
    let skeleton: InsightSkeleton?
    let sectionBuffers: [String: String]?
    // The full tree.
    let nodes: [Entry]?

    /// A snapshot of `nodes`: those that are ready, with a skeleton and at least one byte of content. A node still
    /// generating is left out, since it would come back ready with half its text: explore all saves the tree each time
    /// one of the nodes it runs side by side ends, while the others are still streaming.
    init(rootId: UUID, folderPath: String, nodes: [InsightNode], createdAt: Date = Date()) {
        self.rootId = rootId
        self.folderPath = folderPath
        self.createdAt = createdAt
        self.skeleton = nil
        self.sectionBuffers = nil
        self.nodes = nodes.compactMap { node in
            guard node.status == .ready, let skeleton = node.skeleton else { return nil }
            let buffers = node.sectionStates.mapValues(\.buffer)
            guard buffers.values.contains(where: { !$0.isEmpty }) else { return nil }
            return Entry(nodeId: node.id, parentId: node.parentId, level: node.level, title: node.title, scope: node.scope,
                         skeleton: skeleton, sectionBuffers: buffers, childIds: node.children)
        }
    }

    static func decode(_ data: Data) -> InsightTreeSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return StoredJSON.decode(InsightTreeSnapshot.self, from: data, using: decoder, owner: "insight tree snapshot")
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The nodes of the saved tree. Prefers the full tree; an older snapshot that only has the root's skeleton and
    /// buffers yields a single root node titled `rootTitle`. Nil when the snapshot holds neither.
    func restoredNodes(rootTitle: String) -> [InsightNode]? {
        let entries: [Entry]
        if let tree = nodes, !tree.isEmpty {
            entries = tree
        } else if let skeleton, let sectionBuffers {
            entries = [Entry(nodeId: rootId, parentId: nil, level: 0, title: rootTitle, scope: .folderRoot,
                             skeleton: skeleton, sectionBuffers: sectionBuffers, childIds: [])]
        } else {
            return nil
        }
        return entries.map { entry in
            let node = InsightNode(id: entry.nodeId, parentId: entry.parentId, level: entry.level, title: entry.title, scope: entry.scope)
            node.skeleton = entry.skeleton
            node.sectionStates = Dictionary(uniqueKeysWithValues: entry.skeleton.sections.map { section in
                var state = SectionState()
                state.buffer = entry.sectionBuffers[section.id] ?? ""
                state.status = state.buffer.isEmpty ? .pending : .ready
                return (section.id, state)
            })
            node.status = .ready
            node.children = entry.childIds
            return node
        }
    }
}
