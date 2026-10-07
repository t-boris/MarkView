import Foundation

/// The assistant side of Prototype Studio: builds a clickable HTML prototype from requirements,
/// revises it on request, and writes the specification that goes with the export. Runs are headless
/// and read-only (`CLICompletion`); the assistant answers with files and edits, and
/// `PrototypeFiles.apply` is the only code that writes them.
enum PrototypeAI {

    struct Outcome {
        var summary: String
        var screens: [String]
        var assumptions: [String]
        var written: [String]
    }

    /// What the user pointed at in the preview.
    struct Pick: Equatable {
        var selector: String
        var tag: String
        var text: String
        var html: String
        var screen: String
    }

    /// What the studio shows while a run is going: `status` replaces the current line, `log` adds a line to the
    /// activity list, `step` does both.
    enum Event: Sendable {
        case status(String)
        case log(String)
        case step(String)
    }
    typealias Stage = @Sendable (Event) -> Void

    /// Turns the assistant's activity (files read, searches, the answer growing) into events. The CLI reports
    /// from its own threads and for every token, so the answer is scanned for the file being written and the
    /// size line is throttled.
    final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let emit: Stage
        private let rootPrefix: String
        private var buffer = ""
        private var lastPath = ""
        private var lastSize = Date.distantPast
        private var thinking = false
        private var reads = 0

        init(root: URL, emit: @escaping Stage) {
            self.emit = emit
            rootPrefix = root.standardizedFileURL.path + "/"
        }

        private func short(_ path: String) -> String { path.replacingOccurrences(of: rootPrefix, with: "") }

        func handle(_ activity: CLICompletion.Activity) {
            lock.lock(); defer { lock.unlock() }
            if case .thinking = activity {} else { thinking = false }
            switch activity {
            case .read(let path):
                reads += 1
                emit(.log("Reading \(short(path))"))
                emit(.status("Reading the requirements (\(reads) file\(reads == 1 ? "" : "s") so far)"))
            case .search(let query):
                emit(.log("Searching for “\(query.prefix(60))”"))
            case .run(let command):
                emit(.log("Running \(command.prefix(80))"))
            case .webSearch, .webFetch:
                break
            case .thinking:
                if !thinking { emit(.log("Thinking")) }
                thinking = true
                emit(.status(reads == 0 ? "Thinking" : "Designing the screens"))
            case .writing(let count):
                guard Date().timeIntervalSince(lastSize) > 0.7 else { return }
                lastSize = Date()
                emit(.status("Writing the files — \(count / 1000) K characters so far"))
            case .answerDelta(let text):
                buffer += text
                if buffer.count > 600 { buffer = String(buffer.suffix(600)) }
                guard let match = try? NSRegularExpression(pattern: "\"path\"\\s*:\\s*\"([^\"]+)\"")
                        .matches(in: buffer, range: NSRange(buffer.startIndex..., in: buffer)).last,
                      let range = Range(match.range(at: 1), in: buffer) else { return }
                let path = String(buffer[range])
                if path != lastPath {
                    lastPath = path
                    emit(.log("Writing \(path)"))
                }
            }
        }
    }

    // MARK: - Schemas

    private static let fileSchema: [String: Any] = [
        "type": "object",
        "properties": ["path": ["type": "string"], "content": ["type": "string"]],
        "required": ["path", "content"], "additionalProperties": false,
    ]

    static let generateSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "screens": ["type": "array", "items": ["type": "string"]],
            "assumptions": ["type": "array", "items": ["type": "string"]],
            "files": ["type": "array", "items": fileSchema],
        ],
        "required": ["title", "summary", "screens", "assumptions", "files"], "additionalProperties": false,
    ]

    static let reviseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "screens": ["type": "array", "items": ["type": "string"]],
            "files": ["type": "array", "items": fileSchema],
            "edits": ["type": "array", "items": [
                "type": "object",
                "properties": ["path": ["type": "string"], "find": ["type": "string"], "replace": ["type": "string"]],
                "required": ["path", "find", "replace"], "additionalProperties": false,
            ]],
            "delete": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["summary", "screens", "files", "edits", "delete"], "additionalProperties": false,
    ]

    // MARK: - Prompts

    private static let craft = """
    You build clickable HTML prototypes that a team approves before any implementation starts, so the prototype \
    must behave like the real product, not look like a picture of it.

    Rules for the files you write:
    - Plain HTML, CSS and JavaScript, no build step, no framework download, no network request, no external font, \
    image or script. It must work when index.html is opened from disk. Use inline SVG or CSS for icons and charts.
    - File layout: index.html (structure and the screen containers), styles.css, app.js (state, routing, behaviour), \
    data.js (realistic sample data and a small fake backend: functions that read and change it).
    - Navigation is a hash router: every screen has its own #/route, the browser Back button works, and the \
    current screen is highlighted in the navigation.
    - Everything that looks interactive works: buttons, links, tabs, menus, modals, forms with validation and error \
    messages, create/edit/delete with confirmation, search, filter, sort, pagination, toggles, drag only if the \
    requirements ask for it. A control that cannot work yet is not drawn.
    - Show the states the requirements imply: empty, loading (short fake delay), error, success, disabled, \
    permission-restricted. A toolbar switch labelled "Prototype" lets the reviewer force the empty and error states.
    - State lives in memory and is written to localStorage so a reload keeps it; a "Reset demo data" action in the \
    Prototype switch restores the sample data.
    - Sample data is specific and plausible (real-looking names, dates, amounts, long and short values), never \
    "Lorem ipsum" or "Item 1".
    - Visual quality: one coherent design system (spacing scale, type scale, a restrained palette, focus rings), \
    responsive down to a phone width, keyboard accessible, readable contrast.
    - Use the vocabulary of the requirements for every label, field and entity. Do not invent features; where the \
    requirements are silent and you had to decide, say so in the assumptions list.
    - Keep each file under 150 KB.
    """

    static func generateSystem(language: String) -> String {
        craft + """


        Work in this order. First read the requirement sources with your tools and list the users, goals, entities, \
        rules and flows in them. Then design the screens and the transitions between them. Then write the files. \
        Answer with the JSON object only: `title` (short product name), `summary` (what was built, two sentences), \
        `screens` (the screen names, in navigation order), `assumptions` (decisions the requirements did not make), \
        `files` (path and full content of every file).\(language)
        """
    }

    static func generatePrompt(brief: String, sources: [String]) -> String {
        let list = sources.isEmpty ? "the whole project folder" : sources.map { "- \($0)" }.joined(separator: "\n")
        return """
        Build the prototype of the product described by these requirement sources (files or folders, relative to \
        the project root; read all of them, and any code or documents they refer to):
        \(list)

        What the reviewer asks for:
        \(brief.isEmpty ? "A complete prototype of everything the sources describe." : brief)
        """
    }

    static func reviseSystem(language: String) -> String {
        craft + """


        You revise an existing prototype on the reviewer's request. Change what was asked and keep everything else \
        as it is, including the look, the data and the behaviour of the screens that were not mentioned. Make the \
        smallest set of changes that fully does the job, and keep every flow working end to end afterwards.
        Answer with the JSON object only: `summary` (what you changed, in one or two sentences, written for the \
        reviewer), `screens` (the screen names after the change), and the change itself:
        - `edits`: path, `find` (text that occurs exactly once in that file; include enough surrounding lines to be \
        unique) and `replace`. Prefer edits for local changes.
        - `files`: path and the full new content, for new files or when most of a file changes.
        - `delete`: paths to remove.
        Leave an unused list empty.\(language)
        """
    }

    static func revisePrompt(instruction: String, pick: Pick?, siteRelative: String, files: [PrototypeFiles.File],
                             runtimeErrors: [String], priorFailure: String?) -> String {
        var out = "The prototype lives in `\(siteRelative)/` (relative to the project root). Its requirements come from the project's documents; read them when the request touches behaviour they define.\n\n"
        let total = files.reduce(0) { $0 + $1.content.utf8.count }
        if total <= 150_000 {
            out += "Current files:\n"
            for file in files { out += "\n=== \(file.path) ===\n\(file.content)\n" }
        } else {
            out += "Files (read the ones you need with your tools):\n"
            for file in files { out += "- \(file.path) (\(file.content.utf8.count) bytes)\n" }
        }
        if let pick {
            out += """


            The reviewer pointed at this element in the preview (screen \(pick.screen.isEmpty ? "#/" : pick.screen)):
            selector: \(pick.selector)
            text: \(pick.text)
            html: \(pick.html)
            """
        }
        if !runtimeErrors.isEmpty {
            out += "\n\nJavaScript errors the preview reported (fix them as part of this change):\n"
                + runtimeErrors.map { "- \($0)" }.joined(separator: "\n")
        }
        if let priorFailure {
            out += "\n\nYour previous answer could not be applied:\n\(priorFailure)\nAnswer again with edits whose `find` text matches the current files exactly once, or give whole files."
        }
        out += "\n\nReviewer's request:\n\(instruction)"
        return out
    }

    static let specSystem = """
    You write the implementation specification that travels with an approved prototype. A developer who has not \
    seen the prototype must be able to build the real product from the specification and the prototype files. \
    Read the prototype files and the requirement sources with your tools; state only what they show. Answer with \
    the Markdown document only: no preface, no code fence around it.
    """

    // MARK: - Runs

    /// One structured run. `record` receives the finished run for the usage counter.
    private static func call(root: URL, system: String, prompt: String, schema: [String: Any]?, label: String,
                             record: @MainActor (CLICompletion.Result) -> Void, stage: @escaping Stage) async throws -> CLICompletion.Result {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, readableFolder: root)
        request.jsonSchema = schema
        request.effort = "medium"
        request.timeout = 1500
        request.label = label
        stage(.log("Started the assistant"))
        let tracker = ProgressTracker(root: root, emit: stage)
        let result = try await CLICompletion.run(request, onActivity: { tracker.handle($0) })
        stage(.log("The assistant finished"))
        await record(result)
        return result
    }

    /// Builds the first version into `site`. Returns the outcome; `manifest` fields are the caller's to update.
    static func generate(root: URL, folder: URL, brief: String, sources: [String], language: String,
                         record: @MainActor (CLICompletion.Result) -> Void, stage: @escaping Stage) async throws -> (title: String, outcome: Outcome) {
        let result = try await call(root: root, system: generateSystem(language: language),
                                    prompt: generatePrompt(brief: brief, sources: sources), schema: generateSchema,
                                    label: "prototype:generate", record: record, stage: stage)
        guard let object = result.structured as? [String: Any] else {
            throw CLICompletion.Failure.invalidOutput(.claude, "no prototype in the answer")
        }
        let change = PrototypeFiles.change(from: object)
        guard change.files.contains(where: { $0.path == "index.html" }) else {
            throw CLICompletion.Failure.invalidOutput(.claude, "the answer has no index.html")
        }
        stage(.step("Saving the prototype"))
        let written = try PrototypeFiles.apply(change, to: PrototypeFiles.site(of: folder))
        return (object["title"] as? String ?? "Prototype",
                Outcome(summary: object["summary"] as? String ?? "", screens: object["screens"] as? [String] ?? [],
                        assumptions: object["assumptions"] as? [String] ?? [], written: written))
    }

    /// Applies one reviewer request. A change that cannot apply is sent back to the assistant once with the reason.
    static func revise(root: URL, folder: URL, instruction: String, pick: Pick?, runtimeErrors: [String], language: String,
                       record: @MainActor (CLICompletion.Result) -> Void, stage: @escaping Stage) async throws -> Outcome {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: reviseSystem(language: language),
                                        prompt: revisePrompt(instruction: instruction, pick: pick, siteRelative: relative,
                                                             files: PrototypeFiles.read(site: site), runtimeErrors: runtimeErrors,
                                                             priorFailure: failure),
                                        schema: reviseSchema, label: "prototype:revise", record: record, stage: stage)
            let change = PrototypeFiles.change(from: result.structured)
            guard !change.isEmpty else {
                failure = "The answer contained no files, edits or deletes."
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                continue
            }
            do {
                stage(.step("Saving the change"))
                let written = try PrototypeFiles.apply(change, to: site)
                let object = result.structured as? [String: Any] ?? [:]
                return Outcome(summary: object["summary"] as? String ?? "Updated \(written.joined(separator: ", "))",
                               screens: object["screens"] as? [String] ?? [], assumptions: [], written: written)
            } catch let error as PrototypeFiles.Failure {
                failure = error.localizedDescription
                if attempt == 1 { throw error }
            }
        }
        throw PrototypeFiles.Failure.edits([failure ?? "The change could not be applied."])
    }

    /// SPEC.md for the export: screens, states, transitions, data, rules and traceability to the sources.
    static func specification(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, language: String,
                              record: @MainActor (CLICompletion.Result) -> Void, stage: @escaping Stage) async throws -> String {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        let decisions = manifest.history.map { "- v\($0.version): \($0.instruction.isEmpty ? "initial build" : $0.instruction) → \($0.summary)" }
            .joined(separator: "\n")
        let prompt = """
        Write SPEC.md for the approved prototype "\(manifest.title)" (version \(manifest.version)). The prototype files are in \
        `\(relative)/`; the requirement sources are:
        \(manifest.sources.isEmpty ? "- the project folder" : manifest.sources.map { "- \($0)" }.joined(separator: "\n"))

        Sections, in this order:
        1. Purpose and users (from the requirements).
        2. Screens: for each, its route, purpose, the data it shows, every control and what it does, and its empty, loading, error and permission states.
        3. Navigation and flows: the transitions between screens as a table (from, trigger, to, condition).
        4. Data model: entities, fields, types, relations, validation rules and the sample data shape used by data.js.
        5. Business rules and behaviours the prototype demonstrates (numbered, testable statements).
        6. Requirements traceability: a table of requirement (quote or reference to the source) → screens and rules that satisfy it, and requirements not covered.
        7. Decisions made during review (below), and assumptions the requirements did not settle.
        8. Out of scope for the prototype, and what the real implementation must add (authentication, persistence, integrations).

        Decisions made during review:
        \(decisions.isEmpty ? "(none)" : decisions)

        Assumptions recorded at the first build:
        \(manifest.assumptions.isEmpty ? "(none)" : manifest.assumptions.map { "- \($0)" }.joined(separator: "\n"))\(language)
        """
        let result = try await call(root: root, system: specSystem, prompt: prompt, schema: nil, label: "prototype:spec",
                                    record: record, stage: stage)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CLICompletion.Failure.invalidOutput(.claude, "the specification is empty") }
        return text
    }

    // MARK: - Export

    enum ExportFailure: LocalizedError {
        case zip(String)
        var errorDescription: String? { if case .zip(let detail) = self { return "Could not create the archive: \(detail)" } else { return nil } }
    }

    /// Packs `prototype/` (the live site), `SPEC.md`, `CHANGES.md` and `README.md` into
    /// `<folder>/export/<slug>-v<version>.zip` and returns it.
    static func packageArchive(folder: URL, manifest: PrototypeFiles.Manifest, spec: String) throws -> URL {
        let fm = FileManager.default
        let name = "\(manifest.slug)-v\(manifest.version)"
        let exportDir = folder.appendingPathComponent("export", isDirectory: true)
        let staging = fm.temporaryDirectory.appendingPathComponent("markview-proto-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging.deletingLastPathComponent()) }
        try fm.copyItem(at: PrototypeFiles.site(of: folder), to: staging.appendingPathComponent("prototype", isDirectory: true))
        try spec.write(to: staging.appendingPathComponent("SPEC.md"), atomically: true, encoding: .utf8)

        let formatter = ISO8601DateFormatter()
        var changes = "# Review history: \(manifest.title)\n\n"
        for entry in manifest.history {
            changes += "## v\(entry.version) — \(formatter.string(from: entry.date))\n"
            changes += entry.instruction.isEmpty ? "Initial build.\n\n" : "Request: \(entry.instruction)\n\n"
            changes += "\(entry.summary)\n\n"
        }
        try changes.write(to: staging.appendingPathComponent("CHANGES.md"), atomically: true, encoding: .utf8)

        let readme = """
        # \(manifest.title) — approved prototype (v\(manifest.version))

        - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
        - `SPEC.md` — screens, states, flows, data, rules and requirement traceability.
        - `CHANGES.md` — the review requests that shaped this version.

        The prototype is the agreed behaviour and look. Implement the product to match it; where the prototype and \
        SPEC.md differ, ask before choosing.

        """
        try readme.write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let archive = exportDir.appendingPathComponent(name + ".zip")
        try? fm.removeItem(at: archive)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--keepParent", staging.path, archive.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let detail = errors.fileHandleForReading.readDataToEndOfFile()  // drained before waiting
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportFailure.zip(String(decoding: detail, as: UTF8.self))
        }
        return archive
    }
}
