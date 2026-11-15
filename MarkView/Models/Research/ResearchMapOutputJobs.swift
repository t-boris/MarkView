import Foundation

/// The two jobs that turn a research map into another document (feature mind-map): the narrative report (REQ-013, DEC-014)
/// and the translation of the map into another language (REQ-014, DEC-015). Both are cancellable jobs of the jobs bar, run
/// the assistant without tools, and let code check the answer before anything is written; the pure parts live in
/// `ResearchMapReport` and `ResearchMapTranslation`.
extension ResearchJobs {
    // MARK: - Report

    /// Export (REQ-013): the assistant writes a narrative report of the map in `language` ("" = the map's own language); `kind`
    /// "markdown" saves it next to the map and opens it, "pdf" renders the same text to a PDF the person saves. The map is not
    /// changed. Returns a one-line reason when it cannot start.
    func reportMap(file: URL, kind: String, language: String) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        if isRunning(on: file) { return "An AI job is already working on this map; export when it has finished." }
        guard case .success(let map)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }), !map.nodes.isEmpty else {
            return "This file is not a readable research map."
        }
        let wanted = Self.cleanLanguage(language)
        let code = wanted.isEmpty ? "" : ResearchMapTranslation.languageCode(for: wanted)
        let mapName = file.lastPathComponent
        let pdf = kind == "pdf"
        launch(kind: .mapReport, file: file, title: (pdf ? "PDF report: " : "Report: ") + Self.title(map.title)) { [weak workspace] job in
            guard let workspace else { return nil }
            // The map as it is now, not as it was when the export was chosen.
            guard case .success(let current)? = workspace.researchMapText(file).map({ ResearchMap.parse($0) }) else {
                return "This file is not a readable research map."
            }
            do {
                let draft = try await Self.writeReport(map: current, mapName: mapName, language: wanted, root: root, job: job, workspace: workspace)
                let diagrams = try await Self.drawReportDiagrams(draft: draft, map: current, root: root, job: job, workspace: workspace)
                job.update("Putting the report together")
                let assembled = ResearchMapReport.assemble(draft: draft, map: current, diagrams: diagrams, mapName: mapName, date: FeatureStore.today)
                var notes: [String] = []
                if !assembled.droppedDiagrams.isEmpty {
                    notes.append("\(assembled.droppedDiagrams.count) requested diagram\(assembled.droppedDiagrams.count == 1 ? "" : "s") could not be drawn and \(assembled.droppedDiagrams.count == 1 ? "was" : "were") left out.")
                }
                if !assembled.emptyVisuals.isEmpty {
                    notes.append("\(assembled.emptyVisuals.count) diagram or image node\(assembled.emptyVisuals.count == 1 ? "" : "s") had nothing to show and \(assembled.emptyVisuals.count == 1 ? "was" : "were") left out.")
                }
                let key = file.standardizedFileURL.path
                if pdf {
                    let name = file.deletingPathExtension().lastPathComponent + (code.isEmpty ? "" : "-" + code) + ".pdf"
                    guard workspace.researchMapPDFExporter?(assembled.markdown, name) == true else {
                        return "The PDF could not be made: the editor page is not available. The Markdown report can still be exported."
                    }
                    workspace.researchMapJobNotice[key] = (["Choose where to save the PDF."] + notes).joined(separator: " ")
                    return nil
                }
                let reportFile = ResearchMap.reportURL(forMap: file, languageCode: code)
                try Data(assembled.markdown.utf8).write(to: reportFile, options: .atomic)
                workspace.refreshFileTree()
                workspace.openFile(reportFile)
                let shown = reportFile.path.hasPrefix(root.path + "/") ? String(reportFile.path.dropFirst(root.path.count + 1)) : reportFile.lastPathComponent
                workspace.researchMapJobNotice[key] = (["Report saved to \(shown)."] + notes).joined(separator: " ")
                return nil
            } catch is CancellationError {
                return "Export stopped. Nothing was written."
            } catch {
                return "The report could not be written: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// A report diagram is printed on one page beside the text: at most this many nodes, short labels.
    static let pageNodes = 10
    private static let pageNote = " This diagram is printed on one page next to the text: at most \(pageNodes) nodes, labels of 1 to 3 words."

    private enum OutputFailure: LocalizedError {
        case unusable(String, [String])
        var errorDescription: String? {
            switch self {
            case .unusable(let what, let problems):
                return "the assistant's \(what) was not usable: " + problems.prefix(3).joined(separator: "; ")
            }
        }
    }

    /// Asks for the report and checks it in code; a draft with problems goes back to the assistant with the problems listed
    /// (twice at most).
    private static func writeReport(map: ResearchMap, mapName: String, language: String, root: URL, job: JobHandle,
                                    workspace: WorkspaceManager) async throws -> ResearchMapReport.Draft {
        let (system, user) = ResearchMapReport.prompt(map: map, mapName: mapName, language: language.isEmpty ? nil : language)
        var attempt = user
        var lastProblems: [String] = []
        for round in 0...2 {
            try Task.checkCancellation()
            let answer = try await ask(system: system, prompt: attempt, schema: ResearchMapReport.answerSchema, root: root,
                                       label: round == 0 ? "map-report" : "map-report:repair\(round)",
                                       step: round == 0 ? "Writing the report" : "Rewriting the report (attempt \(round + 1))", job: job, workspace: workspace)
            switch ResearchMapReport.parse(answer) {
            case .failure(let failure):
                lastProblems = [failure.message]
                attempt = user + "\n\nYour previous answer could not be read: \(failure.message). Answer with the JSON object only."
            case .success(let draft):
                let problems = ResearchMapReport.check(draft: draft, map: map)
                if problems.isEmpty { return draft }
                lastProblems = problems.map(\.message)
                attempt = user + "\n\n" + ResearchMapReport.repairPrompt(problems: problems, previousAnswer: answer)
            }
        }
        throw OutputFailure.unusable("report", lastProblems)
    }

    /// Draws the diagrams the report asked for with the Graph Creator's generator, one after another. A diagram that cannot be
    /// drawn is left out of the report (the assembly says which).
    private static func drawReportDiagrams(draft: ResearchMapReport.Draft, map: ResearchMap, root: URL, job: JobHandle,
                                           workspace: WorkspaceManager) async throws -> [String: String] {
        var drawn: [String: String] = [:]
        for (index, request) in draft.diagrams.enumerated() {
            try Task.checkCancellation()
            guard let kind = DiagramKind(rawValue: request.kind) else { continue }
            job.update("Drawing diagram \(index + 1) of \(draft.diagrams.count)")
            let context = draft.sections.first { $0.markdown.contains("{{diagram:\(request.id)}}") }?.markdown ?? ""
            let prompt = DiagramAI.mapPrompt(kind: kind, instruction: request.what + Self.pageNote, question: map.question, path: [map.title],
                                             title: String(request.what.prefix(120)), nodeText: context, evidence: [], root: root)
            // A report diagram follows the language of the report section it sits in.
            let language = DiagramAI.mapLanguage(title: request.what, nodeText: context, evidence: [])?.code
            do {
                let spec = try await DiagramAI.generate(prompt: prompt, root: root, label: "map-report-diagram:\(kind.rawValue)", system: DiagramAI.mapSystem,
                                                        expectedLanguage: language, maxNodes: Self.pageNodes,
                                                        onStage: { _ in },
                                                        record: { result in Task { @MainActor in result.record(in: workspace.semanticDatabase) } })
                // A wide left-to-right diagram is shrunk to the page width until its text cannot be read; a page is tall, so it runs downwards.
                var onPage = spec
                if onPage.nodes.count > 5 { onPage.direction = "TB" }
                drawn[request.id] = DiagramAI.plainMermaid(onPage, kind: kind)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return drawn
    }

    // MARK: - Translate

    /// Translate (REQ-014, DEC-015): the assistant translates the texts of the map into `language`; code applies them onto a copy
    /// of the parsed map, so the structure cannot change. `mode` "copy" writes a new map next to this one and opens it;
    /// "replace" first saves a copy of this map, then rewrites it. Returns a one-line reason when it cannot start.
    func translateMap(file: URL, language: String, mode: String) -> String? {
        guard let workspace, let root = workspace.rootNode?.url else { return "No project is open." }
        let wanted = Self.cleanLanguage(language)
        guard !wanted.isEmpty else { return "Choose a language." }
        guard mode == "copy" || mode == "replace" else { return "Choose what the translation does with this map." }
        if isRunning(on: file) { return "An AI job is already working on this map; translate when it has finished." }
        guard let startText = workspace.researchMapText(file), case .success(let source) = ResearchMap.parse(startText), !source.nodes.isEmpty else {
            return "This file is not a readable research map."
        }
        let code = ResearchMapTranslation.languageCode(for: wanted)
        launch(kind: .mapTranslate, file: file, title: "Translate to \(wanted): " + Self.title(source.title)) { [weak workspace] job in
            guard let workspace else { return nil }
            do {
                var working = source
                var translated = 0, kept = 0, diagramKept = 0
                let batches = ResearchMapTranslation.batches(of: source)
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    let done = batches.prefix(index).reduce(0) { $0 + $1.count }
                    job.update("Translating nodes \(done + 1)–\(done + batch.count) of \(source.nodes.count)")
                    let answer = try await Self.translateBatch(map: working, ids: batch, language: wanted, root: root, job: job, workspace: workspace)
                    let applied = ResearchMapTranslation.apply(answer: answer, to: &working, ids: batch)
                    translated += applied.translatedCount
                    kept += applied.keptOriginal.count
                    diagramKept += applied.diagramKept.count
                }
                try Task.checkCancellation()
                job.update(mode == "copy" ? "Saving the translated map" : "Saving a copy and replacing the map")
                var notes: [String] = ["Translated \(translated) of \(source.nodes.count) nodes into \(wanted)."]
                if kept > 0 { notes.append("\(kept) kept their text because the translation failed the checks.") }
                if diagramKept > 0 { notes.append("\(diagramKept) diagram\(diagramKept == 1 ? "" : "s") kept the original labels.") }
                let folder = file.deletingLastPathComponent()
                if mode == "copy" {
                    let wantedName = ResearchMapTranslation.translatedFileName(for: file.lastPathComponent, code: code)
                    let target = Self.freeFile(folder.appendingPathComponent(wantedName), root: root)
                    var copy = working
                    copy.id = ResearchDocument.id(forPath: target.path)
                    try Data(copy.markdown().utf8).write(to: target, options: .withoutOverwriting)
                    workspace.refreshFileTree()
                    workspace.researchMapJobNotice[target.standardizedFileURL.path] = notes.joined(separator: " ")
                    workspace.openFile(target)
                    return nil
                }
                // Replace: the map must be what the translation started from, or edits made meanwhile would be lost.
                guard let nowText = workspace.researchMapText(file), nowText == startText else {
                    return "The map changed while it was being translated, so nothing was replaced. Translate it again."
                }
                let backup = Self.freeFile(folder.appendingPathComponent(ResearchMapTranslation.backupFileName(for: file.lastPathComponent)), root: root)
                try Data(nowText.utf8).write(to: backup, options: .withoutOverwriting)
                let result = workspace.updateResearchMap(file) { $0 = working }
                switch result {
                case .rejected(let problem), .unreadable(let problem):
                    return "The translated map could not be saved: \(problem). The copy \(backup.lastPathComponent) holds the map as it was."
                case .done:
                    workspace.refreshFileTree()
                    notes.append("The map as it was is saved as \(backup.lastPathComponent).")
                    workspace.researchMapJobNotice[file.standardizedFileURL.path] = notes.joined(separator: " ")
                    return nil
                }
            } catch is CancellationError {
                return "Translation stopped. The map is unchanged."
            } catch {
                return "The map could not be translated: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// One batch of nodes: asks, checks, and sends the nodes that failed back twice at most. What still fails is left to
    /// `ResearchMapTranslation.apply`, which keeps the original text of such a node.
    private static func translateBatch(map: ResearchMap, ids: [String], language: String, root: URL, job: JobHandle,
                                       workspace: WorkspaceManager) async throws -> ResearchMapTranslation.Answer {
        var answer = ResearchMapTranslation.Answer(title: nil, question: nil, nodes: [])
        let (system, user) = ResearchMapTranslation.prompt(map: map, ids: ids, language: language)
        // The first answer; a reply that cannot be read is asked for once more.
        for attempt in 0...1 {
            let text = try await ask(system: system, prompt: attempt == 0 ? user : user + "\n\nYour previous answer could not be read. Answer with the JSON object only.",
                                     schema: ResearchMapTranslation.schema, root: root, label: "map-translate", step: nil, job: job, workspace: workspace)
            if case .success(let parsed) = ResearchMapTranslation.parse(answer: text) { answer = parsed; break }
        }
        var repairs = 0
        while repairs < 2 {
            let problems = ResearchMapTranslation.check(answer: answer, map: map, ids: ids)
            let again = ResearchMapTranslation.repairIds(problems)
            guard !again.isEmpty else { break }
            repairs += 1
            try Task.checkCancellation()
            let (repairSystem, repairUser) = ResearchMapTranslation.prompt(map: map, ids: again, language: language)
            let text = try await ask(system: repairSystem, prompt: repairUser + "\n\n" + ResearchMapTranslation.repairPrompt(problems: problems),
                                     schema: ResearchMapTranslation.schema, root: root, label: "map-translate:repair\(repairs)", step: nil, job: job, workspace: workspace)
            if case .success(let fixed) = ResearchMapTranslation.parse(answer: text) { answer = ResearchMapTranslation.merged(answer, with: fixed) }
        }
        return answer
    }

    // MARK: - Shared

    /// One assistant call without tools that answers with a JSON object; returns the answer as text.
    private static func ask(system: String, prompt: String, schema: [String: Any], root: URL, label: String, step: String?,
                            job: JobHandle, workspace: WorkspaceManager) async throws -> String {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, jsonSchema: schema)
        request.timeout = TimeInterval(ResearchSettings.timeoutMinutes * 60)
        request.label = label
        if let step { job.update(step) }
        let result = try await CLICompletion.run(request, onActivity: { activity in
            if case .thinking = activity { Task { @MainActor in job.update("Thinking") } }
        })
        await MainActor.run { result.record(in: workspace.semanticDatabase) }
        if let object = result.structured, JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) {
            return text
        }
        return result.text
    }

    /// The language the person chose, on one line and not longer than a language name.
    private static func cleanLanguage(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}
