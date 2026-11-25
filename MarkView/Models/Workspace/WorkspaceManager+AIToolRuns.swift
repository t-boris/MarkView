import Foundation
import MarkViewCore

// The AI tool runs a window starts (`AIToolJobs` shows them): diagrams, code maps, reviews and audits, each a headless assistant run
// whose result file opens in the window. They work on the window's project and tabs, so they belong to `WorkspaceManager`, not to the AI layer.

extension WorkspaceManager {
    private var jobRecorder: @Sendable (CLICompletion.Result) -> Void {
        { [weak self] result in Task { @MainActor in result.record(in: self?.project.database) } }
    }

    private func languageNote() -> String {
        ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage
            ? "" : "\n\nWrite labels, notes and text in \(ActionOutputLanguage.current)."
    }

    /// Graph Creator: a diagram of `kind` from the chosen documents, written next to them and opened.
    func generateDiagram(kind: DiagramKind, instruction: String, sourcePaths: [String], folder: URL?) {
        guard let root = project.root else { return }
        let title = "\(kind.title) diagram"
        guard !aiJobs.isRunning(title: title) else { return }
        let target = folder ?? root
        let sources = sourcePaths.sorted().compactMap { path -> (path: String, text: String)? in
            (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)).map { (path, $0) }
        }
        let prompt = DiagramAI.prompt(kind: kind, instruction: instruction, sources: sources, root: root)
            + languageNote()
        aiJobs.start(title: title, work: { [jobRecorder] handle in
            let spec = try await DiagramAI.generate(prompt: prompt, root: root, label: "diagram:\(kind.rawValue)",
                                                    onStage: { handle.stage($0) }, record: jobRecorder)
            let url = DiagramAI.freeURL(in: target, base: kind.defaultName)
            try AtomicFile.write(DiagramAI.markdown(spec), to: url)
            return url
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    /// Change an existing diagram on instruction. The file is rewritten by the app; a file this tool
    /// wrote is regenerated whole (its legend stays true), any other file only has the block replaced.
    func editDiagram(instruction: String, currentMermaid: String) {
        guard let root = project.root, let tab = activeTab else { return }
        let url = tab.url
        let title = "Edit diagram"
        guard !aiJobs.isRunning(title: title) else { return }
        let prompt = DiagramAI.editPrompt(instruction: instruction, currentMermaid: currentMermaid) + languageNote()
        aiJobs.start(title: title, work: { [jobRecorder] handle in
            let spec = try await DiagramAI.generate(prompt: prompt, root: root, label: "diagram:edit",
                                                    onStage: { handle.stage($0) }, record: jobRecorder)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated: String
            if old.contains("**Takeaway:**") && old.contains("## Components") {
                updated = DiagramAI.markdown(spec)
            } else if let range = old.range(of: currentMermaid.trimmingCharacters(in: .whitespacesAndNewlines)) {
                updated = old.replacingCharacters(in: range, with: DiagramAI.mermaid(spec))
            } else {
                throw DiagramAI.Failure.unusable(["the diagram block was not found in \(url.lastPathComponent); it changed while the assistant worked"])
            }
            try AtomicFile.write(updated, to: url)
            return url
        }, onDone: { [weak self] url in
            // The open tab picks the changed file up on its own (file watching), keep the tab on it.
            if let url { self?.openFile(url) }
        })
    }

    // MARK: Text tools

    /// One headless, read-only call that answers in Markdown.
    private func markdownCall(root: URL, system: String, prompt: String, label: String, effort: String = "medium",
                              handle: AIToolJobs.Handle) async throws -> String {
        try await Self.runMarkdownCall(root: root, system: system, prompt: prompt, label: label, effort: effort,
                                       onStage: { handle.stage($0) }, record: jobRecorder)
    }

    private nonisolated static func runMarkdownCall(root: URL, system: String, prompt: String, label: String, effort: String = "medium",
                                                    onStage: @escaping @Sendable (String) -> Void,
                                                    record: @escaping @Sendable (CLICompletion.Result) -> Void) async throws -> String {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, readableFolder: root)
        request.effort = effort
        request.timeout = 900
        request.label = label
        let operation = AIOperation<CLICompletion.Request, String>(
            name: label,
            parse: { result in
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw DiagramAI.Failure.unusable(["the assistant returned no text"]) }
                return text
            },
            onResult: { record($0) })
        return try await operation.execute(request, onDelta: { _ in onStage("Writing") }, onActivity: { activity in
            switch activity {
            case .read: onStage("Reading project files")
            case .search: onStage("Searching the code")
            case .thinking: onStage("Thinking")
            default: break
            }
        }).output
    }

    private static let writerSystem = """
    You write project documentation from the real code. Read the files with your tools before you write; \
    state only what the code or documents show, and mark anything inferred as inferred. Answer with the \
    Markdown document only: no preface, no closing remarks, no code fence around it. Do not put Mermaid \
    diagrams in it; diagrams are drawn separately.
    """

    /// Code structure map: a diagram of the layers (checked against the code) plus the written sections.
    func runCodemap() {
        guard let root = project.root else { return }
        let title = "Code structure map"
        guard !aiJobs.isRunning(title: title) else { return }
        let diagramPrompt = DiagramAI.prompt(kind: .codemap, instruction: "", sources: [], root: root) + languageNote()
        let textPrompt = """
        Describe the code base in the current folder in Markdown with exactly these sections:
        ## Directory Tree: the tree to two or three levels, one line of purpose per folder and key file.
        ## Configuration Map: a table (Config file | Purpose | Key settings | Environment variables) for every config, manifest, Docker and CI file.
        ## Entry Points: every entry point (app start, routes, CLI commands, workers, schedulers, handlers) with file path and how it is triggered.
        ## File Statistics: a table of totals (files, source, tests, config, languages) and the ten largest files.
        Use real paths and numbers from the project.
        """ + languageNote()
        aiJobs.start(title: title, work: { [jobRecorder] handle in
            handle.stage("Generating diagram and sections")
            async let diagramSpec = DiagramAI.generate(prompt: diagramPrompt, root: root, label: "codemap:diagram",
                                                       onStage: { handle.stage("Diagram: \($0)") }, record: jobRecorder)
            async let writtenSections = self.markdownCall(root: root, system: Self.writerSystem, prompt: textPrompt,
                                                          label: "codemap:text", handle: handle)
            let (spec, sections) = try await (diagramSpec, writtenSections)
            var doc = "# Code Structure Map\n\n## Architecture Layers\n\n**Question:** \(spec.question)\n\n"
            doc += "**Takeaway:** \(spec.takeaway)\n\n```mermaid\n\(DiagramAI.mermaid(spec))\n```\n\n"
            doc += spec.nodes.map { n in "- **\(n.label)** (\(n.kind))" + (n.note.map { " — \($0)" } ?? "") + (n.source.map { " — `\($0)`" } ?? "") }
                .joined(separator: "\n")
            if let omitted = spec.omitted { doc += "\n\nLeft out: \(omitted)" }
            doc += "\n\n" + sections + "\n"
            let url = DiagramAI.freeURL(in: root, base: "code-structure-map")
            try AtomicFile.write(doc, to: url)
            return url
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    /// Constructive review of the open document (or of the project's documentation) with a task list.
    func runCritic(contentOverride: String?) {
        guard let root = project.root else { return }
        let tab = activeTab
        let name = tab?.url.lastPathComponent ?? "project"
        let stem = (name as NSString).deletingPathExtension
        let content = contentOverride ?? tab?.content ?? ""
        let title = "Review \(name)"
        guard !aiJobs.isRunning(title: title) else { return }
        let prompt = """
        You are a constructive critic of documentation. \(content.isEmpty ? "Review the Markdown documentation in the project folder." : "Review the document below; check its claims against the code where it describes code.")
        Write the review in Markdown with: # Constructive Review: \(name); ## Summary; ## Strengths (specific); \
        ## Issues Found (each: ### Issue N: title, with Severity Critical/Major/Minor/Suggestion, Location, Problem, Recommendation); \
        ## Missing Content; ## Consistency Issues; ## Action Items (numbered, each P1/P2/P3 with effort); ## Overall Score (1-10 with a reason).
        Then, after a line containing only `=====TASKS=====`, the action items alone as a checklist: `- [ ] P1: description`.
        \(content.isEmpty ? "" : "\nDocument:\n\(content)")
        """ + languageNote()
        aiJobs.start(title: title, work: { handle in
            let answer = try await self.markdownCall(root: root, system: Self.writerSystem, prompt: prompt,
                                                     label: "critic", handle: handle)
            let parts = answer.components(separatedBy: "=====TASKS=====")
            let review = DiagramAI.freeURL(in: root, base: "review-\(stem)")
            try AtomicFile.write(parts[0].trimmingCharacters(in: .whitespacesAndNewlines), to: review)
            if parts.count > 1 {
                let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
                try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
                let tasks = DiagramAI.freeURL(in: tasksDir, base: "review-tasks-\(stem)")
                try AtomicFile.write(parts[1].trimmingCharacters(in: .whitespacesAndNewlines), to: tasks)
            }
            return review
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    private struct AuditPlan: Decodable, Sendable {
        struct Doc: Decodable, Sendable { var file: String; var title: String; var brief: String; var diagram: String }
        var documents: [Doc]
    }

    /// Bounded concurrency for independent audit document generation after the plan prerequisite finishes (REQ-007).
    private static let maxConcurrentAuditDocuments = 3

    /// Codebase audit as a pipeline of focused calls: one call plans the document set, then one call
    /// writes each document, with diagrams drawn (and checked) by `DiagramAI`. The result goes to
    /// docs/generated-architecture/.
    func runAudit() {
        guard let root = project.root else { return }
        let title = "Codebase audit"
        guard !aiJobs.isRunning(title: title) else { return }
        let outDir = root.appendingPathComponent("docs/generated-architecture", isDirectory: true)
        let diagramKinds = ["", "architecture", "dataflow", "deployment", "er"]
        let planSchema: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["documents"],
            "properties": ["documents": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["file", "title", "brief", "diagram"],
                "properties": [
                    "file": ["type": "string", "description": "File name like 04-high-level-architecture.md, no folders except 06-components/"],
                    "title": ["type": "string"],
                    "brief": ["type": "string", "description": "What this document must cover, which files to read, 2-4 sentences."],
                    "diagram": ["type": "string", "enum": diagramKinds, "description": "A diagram kind this document needs, or empty."],
                ]]]],
        ]
        let planPrompt = """
        Plan a documentation set that lets a new senior engineer work safely in this project. \
        List 8 to 16 documents in reading order: 00-index.md, an executive summary, a repository map, \
        a system overview, the high-level architecture, runtime flows, one document per main component \
        (in 06-components/), external interfaces, data model and configuration, operations \
        (build, CI/CD, deployment), risks and technical debt, and recommendations. Only plan what the \
        code supports. For each give the file name, title, a brief of what it must cover and which files \
        to read, and a diagram kind if the document needs one (architecture overview, data flow, \
        deployment, data model), else an empty string.
        """
        aiJobs.start(title: title, work: { [jobRecorder] handle in
            handle.stage("Planning the documents")
            var planRequest = CLICompletion.Request(project: root, prompt: planPrompt, systemPrompt: Self.writerSystem,
                                                    jsonSchema: planSchema, readableFolder: root)
            planRequest.effort = "medium"
            planRequest.timeout = 600
            planRequest.label = "audit:plan"
            // The plan is the structured answer only: prose with a JSON object in it is not a plan.
            let planning = AIOperation<CLICompletion.Request, AuditPlan>(
                name: "audit:plan",
                parse: { result in
                    guard let plan = try? AIJSONSalvage.decode(AuditPlan.self, from: result.text, structured: result.structured, allowTextSalvage: false),
                          !plan.documents.isEmpty else {
                        throw DiagramAI.Failure.unusable(["the assistant did not return a document plan"])
                    }
                    return plan
                },
                onResult: { jobRecorder($0) })
            let (plan, _) = try await planning.execute(planRequest)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outline = plan.documents.map { "- \($0.file): \($0.title)" }.joined(separator: "\n")
            let language = self.languageNote()
            struct AuditWork: Sendable {
                let order: Int
                let name: String
                let doc: AuditPlan.Doc
            }
            var seenNames = Set<String>()
            var items: [AuditWork] = []
            for (i, doc) in plan.documents.enumerated() {
                // The model names the file; keep it inside the output folder and prevent concurrent races on duplicate names.
                let name = doc.file.split(separator: "/").suffix(2).joined(separator: "/")
                    .replacingOccurrences(of: "..", with: "")
                guard !name.isEmpty, seenNames.insert(name).inserted else { continue }
                items.append(AuditWork(order: i, name: name, doc: doc))
            }
            let total = items.count
            guard total > 0 else { return nil }
            var completed = 0
            var writtenByOrder: [(order: Int, name: String, url: URL)] = []
            handle.stage("Writing 0/\(total) documents")
            try await withThrowingTaskGroup(of: (Int, String, URL).self) { group in
                var nextIndex = 0
                func enqueue(_ item: AuditWork) {
                    group.addTask {
                        try Task.checkCancellation()
                        var text = try await Self.runMarkdownCall(
                            root: root,
                            system: Self.writerSystem,
                            prompt: """
                            Write the document "\(item.doc.title)" (\(item.name)) of this documentation set:
                            \(outline)

                            What it must cover: \(item.doc.brief)

                            For every statement say whether it is confirmed from code, from config, from documents, \
                            inferred from patterns, or unknown. Link to the other documents of the set where useful. \
                            Start with a level-1 heading.
                            """ + language,
                            label: "audit:\(item.name)",
                            onStage: { _ in },
                            record: jobRecorder)
                        if let kind = DiagramKind(rawValue: item.doc.diagram) {
                            let prompt = DiagramAI.prompt(kind: kind, instruction: "The diagram illustrates this document: \(item.doc.brief)",
                                                          sources: [], root: root) + language
                            if let spec = try? await DiagramAI.generate(prompt: prompt, root: root, label: "audit:diagram:\(item.name)",
                                                                        onStage: { _ in }, record: jobRecorder) {
                                text += "\n\n## Diagram\n\n**Question:** \(spec.question)\n\n```mermaid\n\(DiagramAI.mermaid(spec))\n```\n"
                            }
                        }
                        let url = outDir.appendingPathComponent(item.name)
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try AtomicFile.write(text, to: url)
                        return (item.order, item.name, url)
                    }
                }
                while nextIndex < min(Self.maxConcurrentAuditDocuments, items.count) {
                    enqueue(items[nextIndex])
                    nextIndex += 1
                }
                while let result = try await group.next() {
                    completed += 1
                    writtenByOrder.append((result.0, result.1, result.2))
                    handle.stage("Wrote \(completed)/\(total) documents")
                    if nextIndex < items.count {
                        try Task.checkCancellation()
                        enqueue(items[nextIndex])
                        nextIndex += 1
                    }
                }
            }
            let ordered = writtenByOrder.sorted { $0.order < $1.order }
            return ordered.first(where: { $0.name.hasPrefix("00") })?.url ?? ordered.first?.url
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }
}
