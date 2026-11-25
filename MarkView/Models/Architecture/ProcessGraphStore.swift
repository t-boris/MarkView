import Foundation
import MarkViewCore

@MainActor
final class ProcessGraphStore {
    struct State: Encodable {
        var tracing = false
        var loading: String?
        var snippets: [String: ProcessSourceSnippet] = [:]
        var errors: [String: String] = [:]
        var levels: [String: ProcessGraph.Level] = [:]
    }

    private weak var host: ArchitectureHost?
    private let tasks = TaskBag()
    private var generation = 0
    private var sourceGeneration = 0
    private var sourceOrder: [String] = []
    private var levelOrder: [String] = []
    private(set) var state = State()

    init(host: ArchitectureHost) { self.host = host }

    func reset() {
        generation += 1
        sourceGeneration += 1
        tasks.cancelAll()
        state = State()
        sourceOrder = []
        levelOrder = []
    }

    func cancel() { tasks.cancel(key: "trace") }

    @discardableResult
    func trace(question: String, root: URL, db: SemanticDatabase?) -> Task<Void, Never>? {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !host.isBusy, !question.isEmpty, question.count <= 4000,
              let modules = host.snapshot?.view("modules") else { return nil }
        let paths = Self.sourcePaths(modules)
        guard !paths.isEmpty else { return nil }
        let run = host.beginRun()
        generation += 1
        let ticket = generation
        state.tracing = true
        host.setStatus("Tracing process from source")
        host.bump()
        let task = Task<Void, Never> { [weak self, weak host] in
            guard let self, let host else { return }
            defer {
                host.endRun(run)
                if self.generation == ticket { self.state.tracing = false; host.bump() }
            }
            do {
                try Task.checkCancellation()
                guard self.generation == ticket, host.rootPath == root.standardizedFileURL.path else { return }
                let signature = modules.nodes.first(where: { $0.id == "m:" })?.signature ?? ""
                let (graph, inspection) = try await self.generate(question: question, paths: paths, signature: signature,
                                                                 root: root, db: db, host: host)
                try Task.checkCancellation()
                guard self.generation == ticket, host.rootPath == root.standardizedFileURL.path,
                      var next = host.snapshot else { return }
                var saved = next.processGraphs ?? []
                let previous = saved.first { $0.graph.question == question }
                if let id = previous?.id {
                    self.sourceGeneration += 1
                    self.tasks.cancel(key: "source")
                    self.state.loading = nil
                    self.state.levels = self.state.levels.filter { !$0.key.hasPrefix(id + "|") }
                    self.state.snippets = self.state.snippets.filter { !$0.key.hasPrefix(id + "|") }
                }
                saved.removeAll { $0.graph.question == question }
                saved.append(ProcessScenario(id: previous?.id ?? UUID().uuidString, graph: graph,
                                             signatures: inspection.signatures, sourceHashes: inspection.hashes))
                next.processGraphs = Array(saved.suffix(20))
                host.commit(next, db: db)
            } catch is CancellationError {
                return
            } catch {
                guard self.generation == ticket, host.rootPath == root.standardizedFileURL.path else { return }
                host.setError("Could not map the process: " + error.localizedDescription)
                host.bump()
            }
        }
        tasks.store(task, for: "trace")
        return task
    }

    func loadLevel(scenario id: String, parent: String?) {
        guard let host, let saved = host.snapshot?.processGraphs?.first(where: { $0.id == id }) else { return }
        if let parent, !saved.graph.nodes.contains(where: { $0.id == parent }) { return }
        let key = id + "|" + (parent ?? "")
        state.levels[key] = saved.graph.level(parent: parent)
        levelOrder.removeAll { $0 == key }
        levelOrder.append(key)
        while levelOrder.count > 24 { state.levels[levelOrder.removeFirst()] = nil }
        host.bump()
    }

    @discardableResult
    func loadSource(scenario id: String, node nodeID: String, index: Int, root: URL) -> Task<Void, Never>? {
        guard let host, let saved = host.snapshot?.processGraphs?.first(where: { $0.id == id }),
              let node = saved.graph.nodes.first(where: { $0.id == nodeID }), node.sources.indices.contains(index),
              let modules = host.snapshot?.view("modules") else { return nil }
        let key = id + "|" + nodeID + "|" + String(index)
        let source = node.sources[index]
        let paths = Self.sourcePaths(modules)
        let expected = saved.sourceHashes[source.path]
        sourceGeneration += 1
        let ticket = sourceGeneration
        state.loading = key
        state.errors[key] = nil
        sourceOrder.removeAll { $0 == key }
        sourceOrder.append(key)
        while sourceOrder.count > 16 {
            let removed = sourceOrder.removeFirst()
            state.snippets[removed] = nil
            state.errors[removed] = nil
        }
        host.bump()
        let task = Task<Void, Never> { [weak self, weak host] in
            guard let self, let host else { return }
            defer {
                if self.sourceGeneration == ticket { self.state.loading = nil; host.bump() }
            }
            do {
                try Task.checkCancellation()
                guard self.sourceGeneration == ticket, host.rootPath == root.standardizedFileURL.path else { return }
                let snippet = try await ProcessGraphSource.offMain {
                    try ProcessGraphSource.snippet(key: key, source: source, root: root,
                                                   allowedPaths: paths, expectedHash: expected)
                }
                try Task.checkCancellation()
                guard self.sourceGeneration == ticket, host.rootPath == root.standardizedFileURL.path else { return }
                self.state.snippets[key] = snippet
            } catch is CancellationError {
                return
            } catch {
                guard self.sourceGeneration == ticket, host.rootPath == root.standardizedFileURL.path else { return }
                self.state.snippets[key] = nil
                self.state.errors[key] = error.localizedDescription
            }
        }
        tasks.store(task, for: "source")
        return task
    }

    private func generate(question: String, paths: Set<String>, signature: String, root: URL, db: SemanticDatabase?,
                          host: ArchitectureHost) async throws -> (ProcessGraph, ProcessGraphSource.Inspection) {
        let base = ProcessGraphPrompt.prompt(question: question, files: paths.sorted(), language: ArchitectureStore.graphLanguageLine)
            + "\nSource snapshot: " + signature
        var prompt = base
        for attempt in 0...1 {
            var request = CLICompletion.Request(project: host.project ?? root, prompt: prompt,
                systemPrompt: "Read the source without modifying it. Return only the requested process graph JSON.",
                jsonSchema: ProcessGraphPrompt.schema, readableFolder: root)
            request.label = "process-graph"
            request.timeout = 900
            let object = try await host.assistantCall(request, root: root, db: db, call: 0, fresh: true)
            try Task.checkCancellation()
            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                var graph = try JSONDecoder().decode(ProcessGraph.self, from: data)
                graph.question = question
                let candidate = graph
                let inspection = try await ProcessGraphSource.offMain {
                    try ProcessGraphSource.inspect(candidate, root: root, allowedPaths: paths)
                }
                return (graph, inspection)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt == 0 else { throw error }
                let previous = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                prompt = base + "\nRepair the previous answer. Keep supported node ids and relations.\n"
                    + error.localizedDescription + "\nPrevious JSON:\n" + String(String(decoding: previous, as: UTF8.self).prefix(120_000))
            }
        }
        throw ProcessGraphSource.Failure(message: "No usable process graph was returned.")
    }

    private static func sourcePaths(_ modules: ArchView) -> Set<String> {
        Set(modules.nodes.filter { $0.kind == "file" && $0.language != "markdown" }.compactMap(\.path))
    }
}
