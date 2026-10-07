import Foundation
import SwiftUI

/// A running or failed AI tool run (diagram, code map, review, audit) that works inside a headless
/// agent. Shown by `AIToolJobsBanner`; a successful run disappears and opens its result.
struct AIToolJob: Identifiable, Equatable {
    enum Phase: Equatable { case running, failed(String) }
    let id = UUID()
    var title: String
    var stage = "Starting"
    var phase = Phase.running
    let started = Date()
}

@MainActor
final class AIToolJobs: ObservableObject {
    @Published private(set) var jobs: [AIToolJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Handed to the work closure to report progress.
    struct Handle {
        let id: UUID
        let jobs: AIToolJobs
        func stage(_ text: String) { Task { @MainActor in jobs.setStage(id, text) } }
    }

    /// Runs `work`; its returned file is opened by `onDone`. A failure keeps the job listed with its error.
    func start(title: String, work: @escaping @MainActor (Handle) async throws -> URL?,
               onDone: @escaping @MainActor (URL?) -> Void) {
        let job = AIToolJob(title: title)
        jobs.append(job)
        let handle = Handle(id: job.id, jobs: self)
        tasks[job.id] = Task { @MainActor in
            do {
                let url = try await work(handle)
                finish(job.id)
                onDone(url)
            } catch is CancellationError {
                finish(job.id)
            } catch {
                if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[i].phase = .failed(error.localizedDescription)
                }
                tasks[job.id] = nil
            }
        }
    }

    func isRunning(title: String) -> Bool {
        jobs.contains { $0.title == title && $0.phase == .running }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func dismiss(_ id: UUID) {
        tasks[id]?.cancel()
        finish(id)
    }

    private func setStage(_ id: UUID, _ text: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].phase == .running else { return }
        jobs[i].stage = text
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }
}

struct AIToolJobsBanner: View {
    @ObservedObject var jobs: AIToolJobs

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(jobs.jobs) { job in
                HStack(spacing: 8) {
                    switch job.phase {
                    case .running:
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.title).uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                            Text(job.stage).uiFont(size: 10).foregroundColor(VSDark.textDim)
                        }
                        Button("Stop") { jobs.cancel(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(VSDark.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(job.title) failed").uiFont(size: 11, weight: .semibold).foregroundColor(VSDark.text)
                            Text(message).uiFont(size: 10).foregroundColor(VSDark.textDim).lineLimit(3)
                        }
                        Button("Dismiss") { jobs.dismiss(job.id) }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: 420, alignment: .leading)
                .background(VSDark.bg.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(VSDark.textDim.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
    }
}

// MARK: - Runs

extension WorkspaceManager {
    private var jobRecorder: @Sendable (CLICompletion.Result) -> Void {
        { [weak self] result in Task { @MainActor in result.record(in: self?.semanticDatabase) } }
    }

    private func languageNote() -> String {
        ActionOutputLanguage.current == ActionOutputLanguage.documentLanguage
            ? "" : "\n\nWrite labels, notes and text in \(ActionOutputLanguage.current)."
    }

    /// Graph Creator: a diagram of `kind` from the chosen documents, written next to them and opened.
    func generateDiagram(kind: DiagramKind, instruction: String, sourcePaths: [String], folder: URL?) {
        guard let root = rootNode?.url else { return }
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
            try DiagramAI.markdown(spec).write(to: url, atomically: true, encoding: .utf8)
            return url
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    /// Change an existing diagram on instruction. The file is rewritten by the app; a file this tool
    /// wrote is regenerated whole (its legend stays true), any other file only has the block replaced.
    func editDiagram(instruction: String, currentMermaid: String) {
        guard let root = rootNode?.url, let tab = activeTab else { return }
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
            try updated.write(to: url, atomically: true, encoding: .utf8)
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
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, readableFolder: root)
        request.effort = effort
        request.timeout = 900
        request.label = label
        let result = try await CLICompletion.run(request, onDelta: { _ in handle.stage("Writing") }, onActivity: { activity in
            switch activity {
            case .read: handle.stage("Reading project files")
            case .search: handle.stage("Searching the code")
            case .thinking: handle.stage("Thinking")
            default: break
            }
        })
        jobRecorder(result)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DiagramAI.Failure.unusable(["the assistant returned no text"]) }
        return text
    }

    private static let writerSystem = """
    You write project documentation from the real code. Read the files with your tools before you write; \
    state only what the code or documents show, and mark anything inferred as inferred. Answer with the \
    Markdown document only: no preface, no closing remarks, no code fence around it. Do not put Mermaid \
    diagrams in it; diagrams are drawn separately.
    """

    /// Code structure map: a diagram of the layers (checked against the code) plus the written sections.
    func runCodemap() {
        guard let root = rootNode?.url else { return }
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
            let spec = try await DiagramAI.generate(prompt: diagramPrompt, root: root, label: "codemap:diagram",
                                                    onStage: { handle.stage("Diagram: \($0)") }, record: jobRecorder)
            let sections = try await self.markdownCall(root: root, system: Self.writerSystem, prompt: textPrompt,
                                                       label: "codemap:text", handle: handle)
            var doc = "# Code Structure Map\n\n## Architecture Layers\n\n**Question:** \(spec.question)\n\n"
            doc += "**Takeaway:** \(spec.takeaway)\n\n```mermaid\n\(DiagramAI.mermaid(spec))\n```\n\n"
            doc += spec.nodes.map { n in "- **\(n.label)** (\(n.kind))" + (n.note.map { " — \($0)" } ?? "") + (n.source.map { " — `\($0)`" } ?? "") }
                .joined(separator: "\n")
            if let omitted = spec.omitted { doc += "\n\nLeft out: \(omitted)" }
            doc += "\n\n" + sections + "\n"
            let url = DiagramAI.freeURL(in: root, base: "code-structure-map")
            try doc.write(to: url, atomically: true, encoding: .utf8)
            return url
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    /// Constructive review of the open document (or of the project's documentation) with a task list.
    func runCritic(contentOverride: String?) {
        guard let root = rootNode?.url else { return }
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
            try parts[0].trimmingCharacters(in: .whitespacesAndNewlines).write(to: review, atomically: true, encoding: .utf8)
            if parts.count > 1 {
                let tasksDir = root.appendingPathComponent("tasks", isDirectory: true)
                try FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
                let tasks = DiagramAI.freeURL(in: tasksDir, base: "review-tasks-\(stem)")
                try parts[1].trimmingCharacters(in: .whitespacesAndNewlines).write(to: tasks, atomically: true, encoding: .utf8)
            }
            return review
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }

    private struct AuditPlan: Decodable {
        struct Doc: Decodable { var file: String; var title: String; var brief: String; var diagram: String }
        var documents: [Doc]
    }

    /// Codebase audit as a pipeline of focused calls: one call plans the document set, then one call
    /// writes each document, with diagrams drawn (and checked) by `DiagramAI`. The result goes to
    /// docs/generated-architecture/.
    func runAudit() {
        guard let root = rootNode?.url else { return }
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
            let planResult = try await CLICompletion.run(planRequest)
            jobRecorder(planResult)
            guard let object = planResult.structured, JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let plan = try? JSONDecoder().decode(AuditPlan.self, from: data), !plan.documents.isEmpty else {
                throw DiagramAI.Failure.unusable(["the assistant did not return a document plan"])
            }
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let outline = plan.documents.map { "- \($0.file): \($0.title)" }.joined(separator: "\n")
            var index: URL?
            for (i, doc) in plan.documents.enumerated() {
                try Task.checkCancellation()
                // The model names the file; keep it inside the output folder.
                let name = doc.file.split(separator: "/").suffix(2).joined(separator: "/")
                    .replacingOccurrences(of: "..", with: "")
                guard !name.isEmpty else { continue }
                handle.stage("\(i + 1)/\(plan.documents.count): \(doc.title)")
                var text = try await self.markdownCall(root: root, system: Self.writerSystem,
                                                       prompt: """
                    Write the document "\(doc.title)" (\(name)) of this documentation set:
                    \(outline)

                    What it must cover: \(doc.brief)

                    For every statement say whether it is confirmed from code, from config, from documents, \
                    inferred from patterns, or unknown. Link to the other documents of the set where useful. \
                    Start with a level-1 heading.
                    """ + self.languageNote(), label: "audit:\(name)", handle: handle)
                if let kind = DiagramKind(rawValue: doc.diagram) {
                    handle.stage("\(i + 1)/\(plan.documents.count): diagram for \(doc.title)")
                    let prompt = DiagramAI.prompt(kind: kind, instruction: "The diagram illustrates this document: \(doc.brief)",
                                                  sources: [], root: root) + self.languageNote()
                    if let spec = try? await DiagramAI.generate(prompt: prompt, root: root, label: "audit:diagram:\(name)",
                                                                onStage: { handle.stage($0) }, record: jobRecorder) {
                        text += "\n\n## Diagram\n\n**Question:** \(spec.question)\n\n```mermaid\n\(DiagramAI.mermaid(spec))\n```\n"
                    }
                }
                let url = outDir.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                if index == nil || name.hasPrefix("00") { index = url }
            }
            return index
        }, onDone: { [weak self] url in
            self?.refreshFileTree()
            if let url { self?.openFile(url) }
        })
    }
}
