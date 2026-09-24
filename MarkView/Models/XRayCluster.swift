import Foundation

/// The X-Ray structure without AI: folders that belong together, found from how the
/// project is actually connected. The AI then only names the groups and fixes them,
/// instead of placing every folder itself — a short answer instead of a long one.
///
/// Graph: the digest's unit folders; edges from imports and note links, from files
/// changed in the same commit (co-change), and a weak tie between a folder and its
/// parent so unlinked folders still stay near their siblings. Communities come from a
/// deterministic Louvain (modularity) pass.
enum XRayCluster {
    struct Cluster {
        let id: String
        /// Unit folder paths in this cluster, sorted.
        let units: [String]
        /// Suggested subsystem (a coarser community), e.g. "s2".
        let group: String
    }

    /// At most this many clusters go to the AI; more would make its answer slow.
    static let maxClusters = 70

    // MARK: - Graph

    private struct Graph {
        var nodes: [String] = []
        var index: [String: Int] = [:]
        var weights: [[Int: Double]] = []

        mutating func node(_ key: String) -> Int {
            if let i = index[key] { return i }
            index[key] = nodes.count
            nodes.append(key)
            weights.append([:])
            return nodes.count - 1
        }

        mutating func connect(_ a: Int, _ b: Int, _ weight: Double) {
            guard a != b, weight > 0 else { return }
            weights[a][b, default: 0] += weight
            weights[b][a, default: 0] += weight
        }
    }

    /// Clusters of the plan's units (deterministic for the same project).
    static func clusters(plan: XRayDigest.Plan, modules: ArchView, root: URL) -> [Cluster] {
        var graph = Graph()
        for unit in plan.units.map(\.path).sorted() { _ = graph.node(unit) }
        let unitSet = Set(plan.units.map(\.path))

        func unit(ofFile path: String) -> String? {
            var candidate = (path as NSString).deletingLastPathComponent
            while true {
                if unitSet.contains(candidate) { return candidate }
                if candidate.isEmpty { return nil }
                candidate = (candidate as NSString).deletingLastPathComponent
            }
        }

        // Imports and note links (one edge per file pair; heavy use counts sub-linearly).
        var links: [String: Double] = [:]
        for edge in modules.edges where edge.source.hasPrefix("m:") && edge.target.hasPrefix("m:") {
            guard let a = unit(ofFile: String(edge.source.dropFirst(2))),
                  let b = unit(ofFile: String(edge.target.dropFirst(2))), a != b else { continue }
            links[a < b ? a + "\u{1}" + b : b + "\u{1}" + a, default: 0] += 1 + log2(Double(max(1, edge.weight)))
        }
        for (key, weight) in links.sorted(by: { $0.key < $1.key }) {
            let pair = key.components(separatedBy: "\u{1}")
            graph.connect(graph.index[pair[0]]!, graph.index[pair[1]]!, weight)
        }

        // Co-change: folders edited in the same (reasonably small) commit belong together.
        for (key, weight) in coChange(root: root, unit: unit).sorted(by: { $0.key < $1.key }) {
            let pair = key.components(separatedBy: "\u{1}")
            graph.connect(graph.index[pair[0]]!, graph.index[pair[1]]!, 2 * weight)
        }

        // Tree: a weak tie to the parent unit, so a folder with no links joins its family.
        // The project root is not a family: tied to every top folder it would pull all the
        // unlinked ones into one catch-all cluster.
        for (parent, children) in plan.children.sorted(by: { $0.key < $1.key }) where !parent.isEmpty {
            guard let p = graph.index[parent] else { continue }
            for child in children { if let c = graph.index[child] { graph.connect(p, c, 0.5) } }
        }

        // Components: the finest level that is not too many; subsystems: the coarsest level
        // that still has a few groups.
        let levels = louvain(graph)
        let counts = levels.map { Set($0).count }
        let fine = levels.indices.first { counts[$0] <= maxClusters } ?? (levels.count - 1)
        let coarse = levels.indices.last { counts[$0] >= 3 && $0 >= fine } ?? fine
        var byCommunity: [Int: [Int]] = [:]
        for (i, community) in levels[fine].enumerated() { byCommunity[community, default: []].append(i) }
        let ordered = byCommunity.values.map { $0.sorted { graph.nodes[$0] < graph.nodes[$1] } }
            .sorted { graph.nodes[$0[0]] < graph.nodes[$1[0]] }
        var groupIds: [Int: String] = [:]
        return ordered.enumerated().map { offset, members in
            let coarseCommunity = levels[coarse][members[0]]
            if groupIds[coarseCommunity] == nil { groupIds[coarseCommunity] = "s\(groupIds.count + 1)" }
            return Cluster(id: "c\(offset + 1)", units: members.map { graph.nodes[$0] }, group: groupIds[coarseCommunity]!)
        }
    }

    /// Folder pairs changed together, weighted 1/(n-1) per commit of n folders.
    private static func coChange(root: URL, unit: (String) -> String?) -> [String: Double] {
        guard let log = ArchitectureScanner.runTool("/usr/bin/env", ["git", "-C", root.path, "log", "-n", "3000",
                                                                     "--format=>", "--name-only", "--no-renames", "--relative"])
        else { return [:] }
        var pairs: [String: Double] = [:]
        var current: Set<String> = []
        var files = 0
        func flush() {
            defer { current = []; files = 0 }
            guard files <= 25, current.count >= 2 else { return }   // mass edits say nothing
            let units = current.sorted()
            let share = 1.0 / Double(units.count - 1)
            for i in units.indices { for j in units.indices where j > i { pairs[units[i] + "\u{1}" + units[j], default: 0] += share } }
        }
        for line in log.split(separator: "\n", omittingEmptySubsequences: true) {
            if line == ">" { flush(); continue }
            files += 1
            if let u = unit(String(line)) { current.insert(u) }
        }
        flush()
        return pairs
    }

    // MARK: - Louvain

    /// Community of every node after each Louvain level, finest first (level 0 = each
    /// node alone). Deterministic: nodes are visited in index order and ties keep the
    /// lower community id.
    private static func louvain(_ graph: Graph) -> [[Int]] {
        var membership = Array(0..<graph.nodes.count)   // original node → community
        var levels = [membership]
        var level = graph.weights                         // current (aggregated) graph
        while true {
            let (assignment, moved) = localMoving(level)
            if !moved { break }
            // Renumber communities and aggregate.
            var renumber: [Int: Int] = [:]
            for c in assignment where renumber[c] == nil { renumber[c] = renumber.count }
            membership = membership.map { renumber[assignment[$0]]! }
            levels.append(membership)
            var next = Array(repeating: [Int: Double](), count: renumber.count)
            for (i, neighbours) in level.enumerated() {
                let ci = renumber[assignment[i]]!
                for (j, w) in neighbours {
                    let cj = renumber[assignment[j]]!
                    if ci != cj { next[ci][cj, default: 0] += w }
                    else if i < j { next[ci][ci, default: 0] += 2 * w }   // internal weight as a self-loop
                }
            }
            level = next
            if level.count <= 1 { break }
        }
        return levels
    }

    /// One Louvain pass: move nodes to the neighbouring community with the best modularity gain.
    private static func localMoving(_ weights: [[Int: Double]]) -> ([Int], Bool) {
        let n = weights.count
        var community = Array(0..<n)
        let degree = weights.map { $0.values.reduce(0, +) }
        let total = degree.reduce(0, +)
        guard total > 0 else { return (community, false) }
        var communityDegree = degree
        var movedAny = false
        var improved = true
        var rounds = 0
        while improved && rounds < 20 {
            improved = false
            rounds += 1
            for i in 0..<n {
                let current = community[i]
                var links: [Int: Double] = [:]
                for (j, w) in weights[i] where j != i { links[community[j], default: 0] += w }
                communityDegree[current] -= degree[i]
                var best = current
                var bestGain = (links[current] ?? 0) - communityDegree[current] * degree[i] / total
                for (c, w) in links.sorted(by: { $0.key < $1.key }) {
                    let gain = w - communityDegree[c] * degree[i] / total
                    if gain > bestGain + 1e-12 { best = c; bestGain = gain }
                }
                communityDegree[best] += degree[i]
                if best != current { community[i] = best; improved = true; movedAny = true }
            }
        }
        return (community, movedAny)
    }
}
