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
        guard let host, let maps, let root = project.root else { return "No project is open." }
        if isRunning(on: file) { return "An AI job is already working on this map; export when it has finished." }
        guard case .success(let map)? = maps.text(of: file).map({ ResearchMap.parse($0) }), !map.nodes.isEmpty else {
            return "This file is not a readable research map."
        }
        let wanted = Self.cleanLanguage(language)
        let code = wanted.isEmpty ? "" : ResearchMapTranslation.languageCode(for: wanted)
        let mapName = file.lastPathComponent
        let pdf = kind == "pdf"
        launch(kind: .mapReport, file: file, title: (pdf ? "PDF report: " : "Report: ") + Self.title(map.title)) { [weak host, weak maps, weak project] job in
            guard let host, let maps, let project else { return nil }
            // The map as it is now, not as it was when the export was chosen.
            guard case .success(let current)? = maps.text(of: file).map({ ResearchMap.parse($0) }) else {
                return "This file is not a readable research map."
            }
            do {
                let draft = try await Self.writeReport(map: current, mapName: mapName, language: wanted, root: root, job: job, project: project)
                let diagrams = try await Self.drawReportDiagrams(draft: draft, map: current, root: root, job: job, project: project)
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
                    guard maps.pdfExporter?(assembled.markdown, name) == true else {
                        return "The PDF could not be made: the editor page is not available. The Markdown report can still be exported."
                    }
                    maps.jobNotice[key] = (["Choose where to save the PDF."] + notes).joined(separator: " ")
                    return nil
                }
                let reportFile = ResearchMap.reportURL(forMap: file, languageCode: code)
                try Data(assembled.markdown.utf8).write(to: reportFile, options: .atomic)
                host.refreshFileTree()
                host.openFile(reportFile)
                let shown = reportFile.path.hasPrefix(root.path + "/") ? String(reportFile.path.dropFirst(root.path.count + 1)) : reportFile.lastPathComponent
                maps.jobNotice[key] = (["Report saved to \(shown)."] + notes).joined(separator: " ")
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

    /// An answer the assistant must write again: what is wrong with it, and the request that says so.
    private struct ReportRejected: LocalizedError {
        let problems: [String]
        let prompt: String
        var errorDescription: String? { problems.joined(separator: "; ") }
    }

    /// Asks for the report and checks it in code; a draft with problems goes back to the assistant with the problems listed
    /// (twice at most).
    private static func writeReport(map: ResearchMap, mapName: String, language: String, root: URL, job: JobHandle,
                                    project: any ProjectProviding) async throws -> ResearchMapReport.Draft {
        let (system, user) = ResearchMapReport.prompt(map: map, mapName: mapName, language: language.isEmpty ? nil : language)
        func request(_ prompt: String, label: String) -> CLICompletion.Request {
            mapRequest(system: system, prompt: prompt, schema: ResearchMapReport.answerSchema, root: root, label: label)
        }
        let writing = AIOperation<Void, (draft: ResearchMapReport.Draft, answer: String)>(
            name: "map-report",
            maxRepairAttempts: 2,
            buildRequest: { _ in request(user, label: "map-report") },
            parse: { _, result, _ in
                let answer = AIJSONSalvage.answerText(result)
                switch ResearchMapReport.parse(answer) {
                case .failure(let failure):
                    throw ReportRejected(problems: [failure.message],
                                         prompt: user + "\n\nYour previous answer could not be read: \(failure.message). Answer with the JSON object only.")
                case .success(let draft):
                    return (draft, answer)
                }
            },
            validate: { _, read, _ in
                let problems = ResearchMapReport.check(draft: read.draft, map: map)
                if !problems.isEmpty {
                    throw ReportRejected(problems: problems.map(\.message),
                                         prompt: user + "\n\n" + ResearchMapReport.repairPrompt(problems: problems, previousAnswer: read.answer))
                }
            },
            repair: { context in
                job.update("Rewriting the report (attempt \(context.attempt.number + 1))")
                return request((context.error as? ReportRejected)?.prompt ?? user, label: "map-report:repair\(context.attempt.number)")
            },
            onResult: { result in result.record(in: project.database) })
        job.update("Writing the report")
        do {
            return try await writing.execute((), onActivity: thinking(job)).output.draft
        } catch let rejected as ReportRejected {
            throw OutputFailure.unusable("report", rejected.problems)
        }
    }

    /// Draws the diagrams the report asked for with the Graph Creator's generator, one after another. A diagram that cannot be
    /// drawn is left out of the report (the assembly says which).
    private static func drawReportDiagrams(draft: ResearchMapReport.Draft, map: ResearchMap, root: URL, job: JobHandle,
                                           project: any ProjectProviding) async throws -> [String: String] {
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
                                                        record: { result in Task { @MainActor in result.record(in: project.database) } })
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
        guard let host, let maps, let root = project.root else { return "No project is open." }
        let wanted = Self.cleanLanguage(language)
        guard !wanted.isEmpty else { return "Choose a language." }
        guard mode == "copy" || mode == "replace" else { return "Choose what the translation does with this map." }
        if isRunning(on: file) { return "An AI job is already working on this map; translate when it has finished." }
        guard let startText = maps.text(of: file), case .success(let source) = ResearchMap.parse(startText), !source.nodes.isEmpty else {
            return "This file is not a readable research map."
        }
        let code = ResearchMapTranslation.languageCode(for: wanted)
        launch(kind: .mapTranslate, file: file, title: "Translate to \(wanted): " + Self.title(source.title)) { [weak host, weak maps, weak project] job in
            guard let host, let maps, let project else { return nil }
            do {
                var working = source
                var translated = 0, kept = 0, diagramKept = 0
                let batches = ResearchMapTranslation.batches(of: source)
                for (index, batch) in batches.enumerated() {
                    try Task.checkCancellation()
                    let done = batches.prefix(index).reduce(0) { $0 + $1.count }
                    job.update("Translating nodes \(done + 1)–\(done + batch.count) of \(source.nodes.count)")
                    let answer = try await Self.translateBatch(map: working, ids: batch, language: wanted, root: root, job: job, project: project)
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
                    host.refreshFileTree()
                    maps.jobNotice[target.standardizedFileURL.path] = notes.joined(separator: " ")
                    host.openFile(target)
                    return nil
                }
                // Replace: the map must be what the translation started from, or edits made meanwhile would be lost.
                guard let nowText = maps.text(of: file), nowText == startText else {
                    return "The map changed while it was being translated, so nothing was replaced. Translate it again."
                }
                let backup = Self.freeFile(folder.appendingPathComponent(ResearchMapTranslation.backupFileName(for: file.lastPathComponent)), root: root)
                try Data(nowText.utf8).write(to: backup, options: .withoutOverwriting)
                let result = maps.update(file) { $0 = working }
                switch result {
                case .rejected(let problem), .unreadable(let problem):
                    return "The translated map could not be saved: \(problem). The copy \(backup.lastPathComponent) holds the map as it was."
                case .done:
                    host.refreshFileTree()
                    notes.append("The map as it was is saved as \(backup.lastPathComponent).")
                    maps.jobNotice[file.standardizedFileURL.path] = notes.joined(separator: " ")
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
                                       project: any ProjectProviding) async throws -> ResearchMapTranslation.Answer {
        var answer = ResearchMapTranslation.Answer(title: nil, question: nil, nodes: [])
        let (system, user) = ResearchMapTranslation.prompt(map: map, ids: ids, language: language)
        func request(_ prompt: String, label: String) -> CLICompletion.Request {
            mapRequest(system: system, prompt: prompt, schema: ResearchMapTranslation.schema, root: root, label: label)
        }
        let record: (CLICompletion.Result) async -> Void = { result in result.record(in: project.database) }
        // The first answer; a reply that cannot be read is asked for once more, and one that still cannot be read leaves the
        // repair rounds below to ask for every node.
        let first = AIOperation<Void, ResearchMapTranslation.Answer>(
            name: "map-translate",
            maxRepairAttempts: 1,
            buildRequest: { _ in request(user, label: "map-translate") },
            parse: { _, result, _ in try ResearchMapTranslation.parse(answer: AIJSONSalvage.answerText(result)).get() },
            repair: { _ in request(user + "\n\nYour previous answer could not be read. Answer with the JSON object only.", label: "map-translate") },
            onResult: record)
        do {
            answer = try await first.execute((), onActivity: thinking(job)).output
        } catch is ResearchMapTranslation.Failure {
            // Left empty: the check below finds every node missing.
        }
        // The nodes that failed the check go back with the problems named, twice at most. A reply that cannot be read leaves the
        // answer as it was; what is still wrong after the second round is not checked again.
        let problems = ResearchMapTranslation.check(answer: answer, map: map, ids: ids)
        guard !ResearchMapTranslation.repairIds(problems).isEmpty else { return answer }
        struct Remaining: Error { let problems: [ResearchMapTranslation.Problem] }
        func repairRequest(_ problems: [ResearchMapTranslation.Problem], round: Int) -> CLICompletion.Request {
            let (repairSystem, repairUser) = ResearchMapTranslation.prompt(map: map, ids: ResearchMapTranslation.repairIds(problems), language: language)
            return mapRequest(system: repairSystem, prompt: repairUser + "\n\n" + ResearchMapTranslation.repairPrompt(problems: problems),
                              schema: ResearchMapTranslation.schema, root: root, label: "map-translate:repair\(round)")
        }
        let repairing = AIOperation<[ResearchMapTranslation.Problem], Void>(
            name: "map-translate",
            maxRepairAttempts: 1,
            buildRequest: { repairRequest($0, round: 1) },
            parse: { _, result, _ in
                if case .success(let fixed) = ResearchMapTranslation.parse(answer: AIJSONSalvage.answerText(result)) {
                    answer = ResearchMapTranslation.merged(answer, with: fixed)
                }
            },
            validate: { _, _, attempt in
                guard !attempt.isLast else { return }
                let remaining = ResearchMapTranslation.check(answer: answer, map: map, ids: ids)
                if !ResearchMapTranslation.repairIds(remaining).isEmpty { throw Remaining(problems: remaining) }
            },
            repair: { context in
                repairRequest((context.error as? Remaining)?.problems ?? context.input, round: context.attempt.number + 1)
            },
            onResult: record)
        _ = try await repairing.execute(problems, onActivity: thinking(job))
        return answer
    }

    // MARK: - Shared

    /// One assistant call without tools that answers with a JSON object.
    private static func mapRequest(system: String, prompt: String, schema: [String: Any], root: URL, label: String) -> CLICompletion.Request {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, jsonSchema: schema)
        request.timeout = TimeInterval(ResearchSettings.timeoutMinutes * 60)
        request.label = label
        return request
    }

    /// The jobs bar says "Thinking" whenever the assistant does.
    private static func thinking(_ job: JobHandle) -> @Sendable (CLICompletion.Activity) -> Void {
        { activity in
            if case .thinking = activity { Task { @MainActor in job.update("Thinking") } }
        }
    }

    /// The language the person chose, on one line and not longer than a language name.
    private static func cleanLanguage(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }
}
