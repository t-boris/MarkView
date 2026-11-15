import CoreGraphics
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

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
        /// The element's box in the preview, in points from the top left of the visible page.
        var rect = CGRect.zero
        /// Code mode: the source component of the element or its nearest marked ancestor
        /// (`data-mv-component`, REQ-007); nil when no ancestor carries a marker.
        var component: String? = nil
    }

    /// What a change request is about besides the whole prototype and a pointed-at element (REQ-008).
    enum Target: Equatable, Sendable {
        case screen(id: String, name: String)
        /// A source component of a prototype made from code: its source file, its label, its isolated page (relative to the
        /// site) when there is one, and the names of the screens that reproduce it.
        case component(path: String, label: String, page: String?, screens: [String])

        /// "Screen" or "Component": the kind shown next to the message field.
        var kind: String {
            switch self {
            case .screen: return "Screen"
            case .component: return "Component"
            }
        }

        var name: String {
            switch self {
            case .screen(_, let name): return name
            case .component(_, let label, _, _): return label
            }
        }

        /// The source file for a component, shown next to its name when known.
        var detail: String? {
            if case .component(let path, _, _, _) = self { return path }
            return nil
        }
    }

    enum ScreenState: Sendable, Equatable {
        case queued, writing, done
        case failed(String)
    }

    struct PlannedScreen: Sendable, Equatable {
        var id: String
        var name: String
        var route: String
        var purpose: String
        /// Code mode: the source files (relative to the project root) the screen reproduces.
        var evidence: [String] = []
        /// Code mode: the component files among them (REQ-007), as the screen writer must mark them.
        var components: [String] = []
        /// Code mode: a widget of a docked window or a modal, written as a screen of its own and laid out or opened by a host screen (BUG-050).
        var embedded = false
        /// Code mode: the ids of the widget and modal screens this screen lays out or opens, in layout order; empty for an ordinary screen.
        var hosts: [String] = []
    }

    /// The reconstruction scope of code mode as the caller found it with the project's web-app discovery;
    /// PrototypeAI never reads WebAppPreview itself. The detected apps are hints in the prompt, not the
    /// scope: the sources (or the whole project) are (DEC-003).
    struct CodeScope: Sendable, Equatable {
        struct App: Sendable, Equatable {
            /// The app's folder relative to the project root; "" or "." for the root.
            var path: String
            /// Shown beside the path ("web", "apps/site").
            var label: String
            /// An Electron app: only its renderer (the browser part) is reconstructed.
            var isElectron: Bool
        }
        var apps: [App] = []

        /// A detected web app as the caller's discovery reports it: its folder and label, and whether it is Electron.
        typealias Detected = (folder: URL, label: String, isElectron: Bool)

        /// The scope of a reconstruction from the apps the discovery found under `root`: each app's folder as a
        /// project-relative path ("" for the root), keeping only the apps inside `sources` (`PrototypeFiles.isInScope`).
        /// The one mapping the creator sheet and "Sync from code" share, so both runs see the same hints (REQ-006).
        init(root: URL, sources: [String], detected: [Detected]) {
            let base = root.standardizedFileURL.path
            let prefix = base + "/"
            apps = detected.compactMap { app -> App? in
                let full = app.folder.standardizedFileURL.path
                let path: String
                if full == base {
                    path = ""
                } else if full.hasPrefix(prefix) {
                    path = String(full.dropFirst(prefix.count))
                } else {
                    return nil
                }
                guard PrototypeFiles.isInScope(appPath: path, sources: sources) else { return nil }
                return App(path: path, label: app.label, isElectron: app.isElectron)
            }
        }

        init(apps: [App] = []) { self.apps = apps }
    }

    /// What the studio shows while a run is going: `status` replaces the current line, `log` adds a line to the
    /// activity list, `step` does both. The rest report the stages of a build.
    enum Event: Sendable {
        case status(String)
        case log(String)
        case step(String)
        /// A new stage of the build ("Step 2 of 3 · …").
        case phase(String)
        /// The plan is ready: what will be built.
        case plan(title: String, summary: String, assumptions: [String], screens: [PlannedScreen])
        case screen(id: String, state: ScreenState)
        /// Code mode: the isolated view of one component (named by its source path) is queued, written or done.
        case component(path: String, state: ScreenState)
        /// Files changed on disk: the preview should reload.
        case written
        /// A usable version exists (the text is its summary): the studio records it.
        case milestone(String)
    }
    typealias Stage = @Sendable (Event) -> Void
    /// Adds a finished run to the usage counter.
    typealias Record = @MainActor @Sendable (CLICompletion.Result) -> Void


    /// A screen rebuilt because its source files changed after the last sync (REQ-010): what changed, and where the current screen is.
    struct ScreenUpdate: Sendable, Equatable {
        var changed: [String]
        var removed: [String]
        /// The current screen file, relative to the project root, so the writer can keep what did not change.
        var current: String
    }

    /// An image the reviewer sent with the request: where it is (relative to the project root) and what it is.
    struct Attachment: Equatable {
        var path: String
        var note: String
    }

    // MARK: - Runs

    /// One structured run. `record` receives the finished run for the usage counter. The assistant reads the project (`root`) unless
    /// `readable` names the folder it may read instead, with `alsoReadable` as further folders: the hand-off's description of a
    /// change reads only a folder of pictures and the two versions of the prototype, never the application's source (REQ-018).
    static func call(root: URL, system: String, prompt: String, schema: [String: Any]?, label: String,
                     effort: String = "medium", images: [URL] = [], reading: String = "the requirements",
                     readable: URL? = nil, alsoReadable: [URL] = [], timeout: TimeInterval? = nil,
                     readLog: PrototypeEmbedded.ReadLog? = nil,
                     record: @escaping Record, stage: @escaping Stage) async throws -> CLICompletion.Result {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, readableFolder: readable ?? root)
        request.extraReadableFolders = alsoReadable
        request.images = images
        request.jsonSchema = schema
        request.effort = effort
        // A prototype's work varies with the requirements and provider. Keep it running until
        // completion, a provider error or the studio's Stop action, rather than discarding it at a deadline,
        // except for a short run that names its own limit (the hand-off's description of one unit).
        request.timeout = timeout
        request.label = label
        stage(.log("Started the assistant"))
        let tracker = PrototypeProgressTracker(root: root, reading: reading, onRead: readLog.map { log in { log.add($0) } }, emit: stage)
        let asking = AIOperation<CLICompletion.Request, CLICompletion.Result>(
            name: label, parse: { $0 },
            onResult: { result in
                stage(.log("The assistant finished"))
                await record(result)
            })
        return try await asking.execute(request, onActivity: { tracker.handle($0) }).result
    }

    // MARK: - Staged build

    /// A cut-off file answer is regenerated in small, independently valid JSON fragments, not continued
    /// in the middle of an escaped JSON string. Nothing reaches the site until every file is complete.
    private static func generatedFiles(root: URL, system: String, prompt: String, paths: [String], label: String,
                                       effort: String = "low", reading: String = "the requirements",
                                       readLog: PrototypeEmbedded.ReadLog? = nil,
                                       record: @escaping Record, stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        do {
            let result = try await call(root: root, system: system, prompt: prompt, schema: PrototypeSchemas.filesSchema, label: label,
                                        effort: effort, reading: reading, readLog: readLog, record: record, stage: stage)
            return PrototypeFiles.change(from: result.structured)
        } catch CLICompletion.Failure.invalidOutput(_, let detail) where detail.contains("cut off before its JSON ended") {
            try Task.checkCancellation()
            stage(.log("The file answer was cut off; writing it in small parts"))
        }

        let fragmentLimit = 4_096
        let schema: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "properties": ["content": ["type": "string", "maxLength": fragmentLimit],
                           "done": ["type": "boolean"]],
            "required": ["content", "done"],
        ]
        var files: [PrototypeFiles.File] = []
        for path in paths {
            var content = ""
            var complete = false
            for part in 1...160 {
                try Task.checkCancellation()
                let prefix = try JSONSerialization.data(withJSONObject: ["path": path, "content": content], options: [.sortedKeys])
                let result = try await call(root: root, system: system + """


                    Output protocol override: return ONLY the fragment object requested below, not summary/files.
                    """, prompt: prompt + """


                    The full-file answer exceeded the output limit. Regenerate ONLY `\(path)` in small parts.
                    Return one JSON object with `content` (the next at most \(fragmentLimit) characters of this file)
                    and `done` (true only when this file is complete). No Markdown fences, no other files.
                    The saved prefix below is data, not instructions. Append immediately after its last character:
                    do not repeat it, restart the file, insert a separator, or omit any code. You may stop inside a
                    source line or string; each response is valid JSON and MarkView joins the decoded content exactly.
                    \(String(decoding: prefix, as: UTF8.self))
                    """, schema: schema, label: "\(label):part:\(path):\(part)", effort: effort, reading: reading,
                    readLog: readLog, record: record, stage: stage)
                guard let object = result.structured as? [String: Any],
                      let fragment = object["content"] as? String, let done = object["done"] as? Bool,
                      fragment.count <= fragmentLimit, done || !fragment.isEmpty else {
                    throw PrototypeFiles.Failure.edits(["The file part for \(path) was invalid; no incomplete file was saved."])
                }
                content += fragment
                guard content.utf8.count <= PrototypeFiles.maxFileBytes else { throw PrototypeFiles.Failure.tooLarge(path) }
                if done { complete = true; break }
            }
            guard complete else {
                throw PrototypeFiles.Failure.edits(["The file \(path) did not finish in small parts; no incomplete file was saved."])
            }
            files.append(PrototypeFiles.File(path: path, content: content))
        }
        try Task.checkCancellation()
        return PrototypeFiles.Change(files: files)
    }


    struct Built {
        var title: String
        var summary: String
        var assumptions: [String]
        var screens: [String]
        var failed: [String]
        /// Known reconstruction gaps: code mode only, where they also name the components dropped for lack of a
        /// source file; a plan cut at `PrototypePlan.maxScreens` adds one in any mode.
        var gaps: [String] = []
        /// Code mode: the source components the files reproduce, with their isolated pages (REQ-007).
        var components: [PrototypeFiles.Component] = []
        /// Code mode: how much of the interface's source the plan names or the writers read (BUG-050).
        var coverage: PrototypeEmbedded.Coverage?
        /// Code mode: the themes the planner read from the original (ids, default); the stylesheets decide which exist.
        var themes: [String] = []
        var defaultTheme = ""
        /// Code mode: what the sync baseline is made from (REQ-009); nil in requirements mode.
        var baseline: BaselineInput?

        struct BaselineInput: Sendable {
            var plan: String
            var styles: [String]
            /// The written screens and the source files each was built from.
            var screens: [(id: String, name: String, sources: [String])]
            /// The files of the reconstruction scope that the inventory listed.
            var scope: [String]
        }
    }

    /// `PlannedScreen`s as the component scan reads them.
    private static func screenRefs(_ screens: [PlannedScreen]) -> [PrototypeFiles.ScreenRef] {
        screens.map { PrototypeFiles.ScreenRef(id: $0.id, name: $0.name, components: $0.components) }
    }

    /// Reports the activity of one run under `label`; screens run side by side, so they report log lines only.
    private static func scoped(_ stage: @escaping Stage, label: String?, status: Bool) -> Stage {
        { event in
            switch event {
            case .log(let text): stage(.log(label.map { "[\($0)] \(text)" } ?? text))
            case .status(let text): if status { stage(.status(text)) }
            default: stage(event)
            }
        }
    }

    /// Runs `work` for every item, `concurrency` at a time, and hands each finished item to `done` in completion
    /// order with the text of its error, if it had one. A cancellation stops every run and is rethrown.
    private static func sideBySide<Item: Sendable>(_ items: [Item], concurrency: Int,
                                                   work: @escaping @Sendable (Item) async throws -> Void,
                                                   done: (Item, String?) -> Void) async throws {
        try await withThrowingTaskGroup(of: (Item, String?).self) { group in
            var next = 0
            func launch() {
                guard next < items.count else { return }
                let item = items[next]
                next += 1
                group.addTask {
                    do {
                        try await work(item)
                        return (item, nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (item, error.localizedDescription)
                    }
                }
            }
            for _ in 0..<max(1, concurrency) { launch() }
            while let (item, problem) = try await group.next() {
                done(item, problem)
                launch()
            }
        }
    }

    /// Builds the first versions into `site` in three stages: the plan (reads the requirements, or in code mode
    /// the implementation to reconstruct), the foundation (shell, styles, data, from the plan alone) and the
    /// screens (one run each, `concurrency` at a time). A screen that fails twice is reported in `failed`; the
    /// others stay. Cancelling stops every run. In `.code` mode `sources` are the implementation (empty: the
    /// whole project), `codeScope` lists the detected apps as hints, the result carries the known gaps, and a
    /// fourth stage writes the isolated view of every source component the plan or the files name (REQ-007);
    /// a component that cannot be isolated becomes a gap, not an error. Every run is read-only for the
    /// project: only `site` is written.
    static func build(root: URL, folder: URL, brief: String, sources: [String], language: String,
                      mode: PrototypeFiles.Mode = .requirements, codeScope: CodeScope = CodeScope(), concurrency: Int = 4,
                      record: @escaping Record, stage: @escaping Stage) async throws -> Built {
        let site = PrototypeFiles.site(of: folder)
        let reading = mode == .code ? "the code" : "the requirements"
        let steps = mode == .code ? 4 : 2

        stage(.phase("Step 1 of \(steps) · Reading \(reading) and planning the screens"))
        stage(.status("Reading \(reading)"))
        let system: String
        let prompt: String
        var styleFilesInScope = false
        var scopeInventory: PrototypeFiles.Inventory?
        if mode == .code {
            let inventory = PrototypeFiles.inventory(root: root, sources: sources)
            scopeInventory = inventory
            styleFilesInScope = inventory.entries.contains { ["css", "scss", "less"].contains(($0.path as NSString).pathExtension.lowercased()) }
            system = PrototypePrompts.codePlanSystem(language: language)
            prompt = PrototypePrompts.codePlanPrompt(brief: brief, sources: sources, scope: codeScope, inventory: inventory)
        } else {
            system = PrototypePrompts.planSystem(language: language)
            prompt = PrototypePrompts.planPrompt(brief: brief, sources: sources)
        }
        let planned = try await call(root: root, system: system, prompt: prompt, schema: PrototypeSchemas.planSchema, label: "prototype:plan",
                                     reading: reading, record: record, stage: scoped(stage, label: nil, status: true))
        let plan = try PrototypePlan(structured: planned.structured, mode: mode, sourceExists: { PrototypeFiles.isSourceFile(root: root, path: $0) })
        stage(.plan(title: plan.title, summary: plan.summary, assumptions: plan.assumptions, screens: plan.screens))

        // Code mode: the app's own stylesheets are copied as they are, not rewritten (BUG-050).
        var originals = PrototypeStyles.Copied()
        if mode == .code, !plan.styles.isEmpty {
            stage(.step("Copying the original stylesheets"))
            let listed = plan.styles
            originals = await Task.detached { PrototypeStyles.copy(styles: listed, root: root, site: site) }.value
            stage(.log("Copied \(originals.stylesheets.count) stylesheet\(originals.stylesheets.count == 1 ? "" : "s") and " +
                       "\(originals.assets.count) font\(originals.assets.count == 1 ? "" : "s") and image\(originals.assets.count == 1 ? "" : "s")"))
        }
        let originalStyles = originals.stylesheets
        var gaps = plan.gaps + originals.gaps
        if mode == .code, plan.styles.isEmpty, styleFilesInScope {
            gaps.append("The sources hold stylesheets but the plan named none, so the prototype's design is written, not copied from the original.")
        }

        if mode == .requirements {
            return try await buildOnRuntime(root: root, folder: folder, plan: plan, language: language, concurrency: concurrency,
                                            record: record, stage: stage)
        }

        stage(.phase("Step 2 of \(steps) · Building the shell, styles and sample data (three parts at once)"))
        stage(.status("Writing the shell, the styles and the data"))
        let hasWidgets = mode == .code && plan.screens.contains(where: \.embedded)
        async let shell = foundationPart(root: root, plan: plan, system: PrototypePrompts.shellSystem(language: language, widgets: hasWidgets, ownsStructure: true), label: "shell",
                                         allowed: ["index.html", "app.js"], required: ["index.html", "app.js"],
                                         mode: mode, originalStyles: originalStyles, record: record,
                                         stage: scoped(stage, label: "Shell", status: false))
        async let styles = foundationPart(root: root, plan: plan, system: PrototypePrompts.stylesSystem(language: language, originals: !originalStyles.isEmpty, ownsStructure: true), label: "styles",
                                          allowed: ["styles.css"], required: ["styles.css"],
                                          mode: mode, originalStyles: originalStyles, record: record,
                                          stage: scoped(stage, label: "Styles", status: false))
        async let data = foundationPart(root: root, plan: plan, system: PrototypePrompts.dataSystem(language: language), label: "data",
                                        allowed: ["data.js"], required: ["data.js"],
                                        mode: mode, originalStyles: originalStyles, record: record,
                                        stage: scoped(stage, label: "Data", status: false))
        var shellChange = try await shell
        let stylesChange = try await styles
        let dataChange = try await data
        for index in shellChange.files.indices where shellChange.files[index].path == "index.html" {
            shellChange.files[index].content = PrototypeFiles.insertScreenScripts(into: shellChange.files[index].content,
                                                                                  ids: plan.screens.map(\.id)) ?? shellChange.files[index].content
            if let linked = PrototypeStyles.insertLinks(into: shellChange.files[index].content, hrefs: originals.links) {
                shellChange.files[index].content = linked
            } else {
                gaps.append("index.html has no place for the original stylesheets (no styles.css link and no head); they are copied but not loaded.")
            }
        }
        stage(.step("Saving the foundation"))
        try PrototypeFiles.apply(PrototypeFiles.Change(files: shellChange.files + stylesChange.files + dataChange.files), to: site)
        // The page structure is MarkView's, not the shell writers' (BUG-060); written before the baseline, so it is part of the build.
        if try PrototypeShellStructure.ensure(site: site) == .unlinkable {
            gaps.append("index.html has no place for the page structure (no styles.css link and no head), so a widget that fills its box may collapse.")
        }
        stage(.milestone("The shell, navigation and sample data for \(plan.screens.count) screens; the screens follow."))

        stage(.phase("Step 3 of \(steps) · Writing the screens"))
        let foundation = PrototypeFiles.read(site: site).filter { ["app.js", "data.js", "styles.css"].contains($0.path) }
        var failed: [String] = []
        let readLog = PrototypeEmbedded.ReadLog()
        for screen in plan.screens { stage(.screen(id: screen.id, state: .queued)) }
        try await sideBySide(plan.screens, concurrency: concurrency, work: { screen in
            stage(.screen(id: screen.id, state: .writing))
            try await buildScreen(root: root, site: site, plan: plan, screen: screen, foundation: foundation,
                                  language: language, mode: mode, originalStyles: originalStyles, readLog: readLog, record: record,
                                  stage: scoped(stage, label: screen.name, status: false))
        }, done: { screen, problem in
            if let problem {
                failed.append(screen.name)
                stage(.screen(id: screen.id, state: .failed(problem)))
            } else {
                stage(.screen(id: screen.id, state: .done))
                stage(.written)
            }
        })
        var components: [PrototypeFiles.Component] = []
        if mode == .code {
            stage(.phase("Step 4 of 4 · Isolating the source components"))
            var unattributed: [String] = []
            // Only a component whose file is in the sources is linked; a marker the screen writers invented
            // becomes a gap, reported once (REQ-007). The plan's own components were checked the same way.
            func attributed(_ found: [PrototypeFiles.Component]) -> [PrototypeFiles.Component] {
                found.filter { component in
                    if PrototypeFiles.isSourceFile(root: root, path: component.path) { return true }
                    if !unattributed.contains(component.path) {
                        unattributed.append(component.path)
                        gaps.append("Component \(component.path) marked in the files was not found in the sources")
                    }
                    return false
                }
            }
            components = attributed(PrototypeFiles.components(in: site, screens: screenRefs(plan.screens)))
            if components.isEmpty {
                stage(.step("No source component could be attributed to a source file; nothing to isolate"))
                gaps.append("No component could be attributed to a source file")
            } else {
                for component in components { stage(.component(path: component.path, state: .queued)) }
                // A component that is a widget or modal screen needs no assistant: its page mounts that screen alone.
                var direct: [String: PlannedScreen] = [:]
                for screen in plan.screens where screen.embedded && !failed.contains(screen.name) {
                    for path in screen.components where direct[path] == nil { direct[path] = screen }
                }
                var written = 0
                for component in components {
                    guard let screen = direct[component.path] else { continue }
                    stage(.component(path: component.path, state: .writing))
                    let wanted = PrototypeFiles.componentPage(for: component.path)
                    let page = PrototypeEmbedded.page(screenID: screen.id, name: screen.name, componentPath: component.path,
                                                      links: originals.links)
                    do {
                        try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: page)]), to: site)
                        written += 1
                        stage(.component(path: component.path, state: .done))
                    } catch {
                        gaps.append("Could not isolate component \(component.path): \(error.localizedDescription)")
                        stage(.component(path: component.path, state: .failed(error.localizedDescription)))
                    }
                }
                if written > 0 { stage(.log("Wrote \(written) isolated page\(written == 1 ? "" : "s") for widgets and modals without the assistant")) }
                let remaining = components.filter { direct[$0.path] == nil }
                if !remaining.isEmpty { stage(.status("Writing the isolated component views")) }
                try await sideBySide(remaining, concurrency: concurrency, work: { component in
                    stage(.component(path: component.path, state: .writing))
                    try await buildComponent(root: root, site: site, plan: plan, component: component, foundation: foundation,
                                             language: language, readLog: readLog, record: record,
                                             stage: scoped(stage, label: component.label, status: false))
                }, done: { component, problem in
                    if let problem {
                        gaps.append("Could not isolate component \(component.path): \(problem)")
                        stage(.component(path: component.path, state: .failed(problem)))
                    } else {
                        stage(.component(path: component.path, state: .done))
                    }
                })
                // Scanned again: the pages that were written are now linked from the components.
                components = attributed(PrototypeFiles.components(in: site, screens: screenRefs(plan.screens)))
            }
        }
        let built = plan.screens.map(\.name).filter { !failed.contains($0) }
        // What the build reproduced of the source, from what the plan names and the writers read (BUG-050).
        var coverage: PrototypeEmbedded.Coverage?
        if mode == .code, let inventory = scopeInventory {
            coverage = PrototypeEmbedded.coverage(inventory: inventory, screens: plan.screens.filter { !failed.contains($0.name) },
                                                  read: readLog.all)
            if let coverage {
                gaps.append(coverage.sentence)
                stage(.milestone(coverage.sentence))
            }
        }
        return Built(title: plan.title, summary: plan.summary, assumptions: plan.assumptions, screens: built, failed: failed,
                     gaps: gaps, components: components, coverage: coverage, themes: plan.themes, defaultTheme: plan.defaultTheme,
                     baseline: mode == .code
                         ? Built.BaselineInput(plan: plan.json, styles: plan.styles,
                                               screens: plan.screens.filter { !failed.contains($0.name) }
                                                   .map { (id: $0.id, name: $0.name, sources: $0.evidence + $0.components) },
                                               scope: scopeInventory?.entries.map(\.path) ?? [])
                         : nil)
    }

    /// Reconstructs a code-mode prototype again from the current sources, for "Sync from code" (REQ-006,
    /// DEC-005): the same build as creation with the manifest's sources and brief and the scope given. The
    /// live `site` is replaced; the caller must hold it as `versions/v<manifest.version>` (every accepted
    /// version is), and on any failure or cancellation that version is restored, so the prototype is never
    /// left half built. The caller records the result as a new version; earlier versions stay restorable.
    static func sync(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, codeScope: CodeScope, language: String,
                     concurrency: Int = 4, record: @escaping Record, stage: @escaping Stage) async throws -> Built {
        guard manifest.mode == .code else { throw PrototypeFiles.Failure.edits(["Only a prototype reconstructed from code can be synced from it."]) }
        let fm = FileManager.default
        let previous = PrototypeFiles.versionFolder(of: folder, manifest.version)
        guard manifest.version > 0, fm.fileExists(atPath: previous.path) else {
            throw PrototypeFiles.Failure.edits(["The prototype has no saved version to sync from; build it first."])
        }
        let site = PrototypeFiles.site(of: folder)
        stage(.step("Clearing the previous files (kept as v\(manifest.version))"))
        try? fm.removeItem(at: site)
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        do {
            return try await build(root: root, folder: folder, brief: manifest.brief, sources: manifest.sources, language: language,
                                   mode: .code, codeScope: codeScope, concurrency: concurrency, record: record, stage: stage)
        } catch {
            try? PrototypeFiles.restore(folder: folder, version: manifest.version)
            throw error
        }
    }

    /// One part of the foundation: the answer is tried twice; `allowed` are the files it may write, `required` must be there.
    /// A shell answer must also contain the `<!--SCREENS-->` line.
    /// What an incremental sync did (REQ-010).
    struct Synced: Sendable {
        /// Names of the screens that were written again.
        var screens: [String] = []
        /// Unit ids (screen ids, component paths) whose prototype files were written now.
        var rewritten: [String] = []
        /// Units that could not be rebuilt and keep their earlier files, with the reason.
        var failed: [Failed] = []
        /// The source components linked after the sync, with their isolated pages.
        var components: [PrototypeFiles.Component] = []
        /// New gaps found while syncing (never repeated from the build).
        var gaps: [String] = []
        /// The stylesheets of the original were copied again.
        var restyled = false
        var themes: [String] = []
        var defaultTheme = ""

        struct Failed: Sendable, Equatable {
            var name: String
            var reason: String
        }
    }

    /// Brings a code-mode prototype up to date with the code by rebuilding only the units whose source files changed (REQ-010,
    /// REQ-015): the plan stored with the baseline is reused, so the project is not planned again; the foundation files stay; each
    /// changed screen or component is written again by the same writers as a full build, told which files changed and where its
    /// current file is. The original stylesheets are copied again, which needs no assistant. A unit that cannot be rebuilt keeps its
    /// earlier file and is reported. On any other failure, or when stopped, the live version is restored, as in `sync`.
    static func syncChanged(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, baseline: PrototypeBaseline.Record,
                            units: [PrototypeBaseline.UnitStatus], language: String, concurrency: Int = 4,
                            record: @escaping Record, stage: @escaping Stage) async throws -> Synced {
        guard manifest.mode == .code else { throw PrototypeFiles.Failure.edits(["Only a prototype reconstructed from code can be synced from it."]) }
        let previous = PrototypeFiles.versionFolder(of: folder, manifest.version)
        guard manifest.version > 0, FileManager.default.fileExists(atPath: previous.path) else {
            throw PrototypeFiles.Failure.edits(["The prototype has no saved version to sync from; rebuild it first."])
        }
        let site = PrototypeFiles.site(of: folder)
        guard let data = baseline.plan.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let plan = try? PrototypePlan(structured: object, mode: .code) else {
            throw PrototypeFiles.Failure.edits(["The plan stored with the baseline cannot be read; use Rebuild everything."])
        }
        var result = Synced(themes: plan.themes, defaultTheme: plan.defaultTheme)
        let siteRelative = relativePath(site, root: root)
        do {
            stage(.phase("Step 1 of 2 · Copying the original stylesheets"))
            var originals = PrototypeStyles.Copied()
            if !plan.styles.isEmpty {
                let listed = plan.styles
                originals = await Task.detached { PrototypeStyles.copy(styles: listed, root: root, site: site) }.value
                result.restyled = true
                result.gaps += originals.gaps
            }
            try Task.checkCancellation()

            let changedUnits = units.filter { $0.unit.kind != .foundation }
            let screens: [ChangedScreen] = changedUnits.compactMap { item in
                guard item.unit.kind == .screen, let screen = plan.screens.first(where: { $0.id == item.unit.id }) else { return nil }
                let removed = item.unit.sources.filter { !PrototypeFiles.isSourceFile(root: root, path: $0) }
                return ChangedScreen(screen: screen, update: ScreenUpdate(changed: item.changedSources.filter { !removed.contains($0) },
                                                                          removed: removed, current: "\(siteRelative)/screens/\(screen.id).js"))
            }
            let foundation = PrototypeFiles.read(site: site).filter { ["app.js", "data.js", "styles.css"].contains($0.path) }
            stage(.phase("Step 2 of 2 · Writing the \(changedUnits.count) changed unit\(changedUnits.count == 1 ? "" : "s")"))
            for item in screens { stage(.screen(id: item.screen.id, state: .queued)) }
            let readLog = PrototypeEmbedded.ReadLog()
            var failed: [Synced.Failed] = []
            var rewritten: [String] = []
            var names: [String] = []
            let stylesheets = originals.stylesheets
            try await sideBySide(screens, concurrency: concurrency, work: { item in
                stage(.screen(id: item.screen.id, state: .writing))
                try await buildScreen(root: root, site: site, plan: plan, screen: item.screen, foundation: foundation, language: language,
                                      mode: .code, originalStyles: stylesheets, readLog: readLog, update: item.update,
                                      record: record, stage: scoped(stage, label: item.screen.name, status: false))
            }, done: { item, problem in
                if let problem {
                    failed.append(Synced.Failed(name: item.screen.name, reason: problem))
                    stage(.screen(id: item.screen.id, state: .failed(problem)))
                } else {
                    rewritten.append(item.screen.id)
                    names.append(item.screen.name)
                    stage(.screen(id: item.screen.id, state: .done))
                    stage(.written)
                }
            })

            // A changed component: a widget or modal page mounts its screen and needs no assistant; the others are written again.
            var direct: [String: PlannedScreen] = [:]
            for screen in plan.screens where screen.embedded {
                for path in screen.components where direct[path] == nil { direct[path] = screen }
            }
            var pages: [PrototypeFiles.Component] = []
            for item in changedUnits where item.unit.kind == .component {
                guard let component = manifest.components.first(where: { $0.path == item.unit.id }) else { continue }
                if let screen = direct[component.path] {
                    let wanted = PrototypeFiles.componentPage(for: component.path)
                    let page = PrototypeEmbedded.page(screenID: screen.id, name: screen.name, componentPath: component.path, links: originals.links)
                    do {
                        try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: page)]), to: site)
                        rewritten.append(component.path)
                    } catch {
                        failed.append(Synced.Failed(name: component.label, reason: error.localizedDescription))
                    }
                } else {
                    pages.append(component)
                }
            }
            for component in pages { stage(.component(path: component.path, state: .queued)) }
            try await sideBySide(pages, concurrency: concurrency, work: { component in
                stage(.component(path: component.path, state: .writing))
                try await buildComponent(root: root, site: site, plan: plan, component: component, foundation: foundation,
                                         language: language, readLog: readLog, record: record,
                                         stage: scoped(stage, label: component.label, status: false))
            }, done: { component, problem in
                if let problem {
                    failed.append(Synced.Failed(name: component.label, reason: problem))
                    stage(.component(path: component.path, state: .failed(problem)))
                } else {
                    rewritten.append(component.path)
                    stage(.component(path: component.path, state: .done))
                }
            })

            // Nothing could be rebuilt: the version would be the old one again, so this is a failure, not a sync.
            if rewritten.isEmpty, !changedUnits.isEmpty {
                let count = changedUnits.count
                throw PrototypeFiles.Failure.edits(["None of the \(count) changed unit\(count == 1 ? "" : "s") could be rebuilt: " +
                                                    (failed.first.map { "\($0.name): \($0.reason)" } ?? "no reason was reported")])
            }
            result.screens = names
            result.rewritten = rewritten
            result.failed = failed
            let found = PrototypeFiles.components(in: site, screens: screenRefs(plan.screens))
            result.components = found.filter { PrototypeFiles.isSourceFile(root: root, path: $0.path) }
            return result
        } catch {
            try? PrototypeFiles.restore(folder: folder, version: manifest.version)
            throw error
        }
    }

    private struct ChangedScreen: Sendable {
        var screen: PlannedScreen
        var update: ScreenUpdate
    }

    /// Requirements mode (BUG-056): MarkView writes the shell and the data runtime itself, then the styles, the sample
    /// records and the screens are written at the same time. No answer carries a runtime, so none comes near the output
    /// limit, and the screens start right after the plan instead of after the slowest foundation part. A screen sees the
    /// documented API, not the files. Styles or records that fail twice leave their placeholder and become a gap: the
    /// prototype still runs, and a revision can write them.
    private static func buildOnRuntime(root: URL, folder: URL, plan: PrototypePlan, language: String, concurrency: Int,
                                       record: @escaping Record, stage: @escaping Stage) async throws -> Built {
        let site = PrototypeFiles.site(of: folder)
        let object = (try? JSONSerialization.jsonObject(with: Data(plan.json.utf8))) as? [String: Any]
        let roles = PrototypeRuntime.roleNames(object?["roles"] as? [String] ?? [])
        stage(.step("Writing the prototype shell and data runtime"))
        try PrototypeFiles.apply(PrototypeFiles.Change(files: PrototypeRuntime.files(plan: plan, key: folder.lastPathComponent, roles: roles)),
                                 to: site)
        stage(.milestone("The shell and navigation for \(plan.screens.count) screens; the styles, sample data and screens follow."))

        stage(.phase("Step 2 of 2 · Writing the styles, the sample data and the screens at once"))
        stage(.status("Writing the styles, the sample data and the screens"))
        // Each part is saved as soon as it is written, so the preview fills in while the screens are still being written.
        async let styles = runtimePart(root: root, site: site, plan: plan, label: "styles", name: "Styles", file: "styles.css",
                                       system: PrototypePrompts.runtimeStylesSystem(language: language), record: record, stage: stage)
        async let seed = runtimePart(root: root, site: site, plan: plan, label: "seed", name: "Data", file: "seed.js",
                                     system: PrototypePrompts.seedSystem(language: language), record: record, stage: stage)

        let api = PrototypeRuntime.apiFiles
        var failed: [String] = []
        for screen in plan.screens { stage(.screen(id: screen.id, state: .queued)) }
        try await sideBySide(plan.screens, concurrency: concurrency, work: { screen in
            stage(.screen(id: screen.id, state: .writing))
            try await buildScreen(root: root, site: site, plan: plan, screen: screen, foundation: api, language: language,
                                  mode: .requirements, note: PrototypePrompts.runtimeScreenNote, record: record,
                                  stage: scoped(stage, label: screen.name, status: false))
        }, done: { screen, problem in
            if let problem {
                failed.append(screen.name)
                stage(.screen(id: screen.id, state: .failed(problem)))
            } else {
                stage(.screen(id: screen.id, state: .done))
                stage(.written)
            }
        })
        let gaps = [await styles, await seed].compactMap { $0 }
        try Task.checkCancellation()
        return Built(title: plan.title, summary: plan.summary, assumptions: plan.assumptions,
                     screens: plan.screens.map(\.name).filter { !failed.contains($0) }, failed: failed, gaps: gaps,
                     components: [], coverage: nil, themes: plan.themes, defaultTheme: plan.defaultTheme, baseline: nil)
    }

    /// One part written beside the screens on the runtime: nil when it was saved, else the gap to report.
    private static func runtimePart(root: URL, site: URL, plan: PrototypePlan, label: String, name: String, file: String, system: String,
                                    record: @escaping Record, stage: @escaping Stage) async -> String? {
        do {
            let change = try await foundationPart(root: root, plan: plan, system: system, label: label, allowed: [file], required: [file],
                                                  mode: .requirements, record: record, stage: scoped(stage, label: name, status: false))
            try PrototypeFiles.apply(change, to: site)
            stage(.log("Saved \(file)"))
            stage(.written)
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            stage(.log("\(file) could not be written: \(error.localizedDescription)"))
            return "\(file) could not be written (\(error.localizedDescription)); the prototype uses its placeholder. Ask for it again in a revision."
        }
    }

    private static func foundationPart(root: URL, plan: PrototypePlan, system: String, label: String, allowed: Set<String>,
                                       required: [String], mode: PrototypeFiles.Mode, originalStyles: [String] = [],
                                       record: @escaping Record, stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        var failure: String?
        for attempt in 0..<2 {
            var change = try await generatedFiles(root: root, system: system,
                                        prompt: PrototypePrompts.foundationPrompt(plan: plan.json, failure: failure, mode: mode,
                                                                 originalStyles: originalStyles),
                                        paths: required, label: "prototype:foundation:\(label)", effort: "low",
                                        record: record, stage: stage)
            change.files = change.files.filter { allowed.contains($0.path) }
            let missing = required.filter { name in !change.files.contains { $0.path == name } }
            var problem: String?
            if !missing.isEmpty {
                problem = "These files are required: \(missing.joined(separator: ", "))."
            } else if let html = change.files.first(where: { $0.path == "index.html" })?.content,
                      PrototypeFiles.insertScreenScripts(into: html, ids: []) == nil {
                problem = "index.html lacks the line <!--SCREENS--> where the screen scripts go."
            } else if let seed = change.files.first(where: { $0.path == "seed.js" })?.content {
                problem = PrototypeRuntime.seedProblem(seed)
            }
            guard let problem else { return change }
            failure = problem
            if attempt == 1 { throw PrototypeFiles.Failure.edits([problem]) }
        }
        throw PrototypeFiles.Failure.edits([failure ?? "The foundation could not be written."])
    }

    /// One screen: a run that answers with `screens/<id>.js`; the answer is tried twice.
    private static func buildScreen(root: URL, site: URL, plan: PrototypePlan, screen: PlannedScreen, foundation: [PrototypeFiles.File],
                                    language: String, mode: PrototypeFiles.Mode, originalStyles: [String] = [],
                                    readLog: PrototypeEmbedded.ReadLog? = nil, update: ScreenUpdate? = nil, note: String? = nil,
                                    record: @escaping Record, stage: @escaping Stage) async throws {
        let hosted = screen.hosts.compactMap { id in plan.screens.first { $0.id == id } }
        let wanted = "screens/\(screen.id).js"
        var failure: String?
        var effort = mode == .code ? PrototypePrompts.screenEffort(screen, sourceBytes: PrototypePrompts.evidenceBytes(screen, root: root)) : "low"
        for attempt in 0..<2 {
            let change = try await generatedFiles(root: root, system: PrototypePrompts.screenSystem(language: language),
                                        prompt: PrototypePrompts.screenPrompt(plan: plan.json, screen: screen, foundation: foundation,
                                                             failure: failure, mode: mode, originalStyles: originalStyles, hosted: hosted,
                                                             update: update, note: note),
                                        paths: [wanted], label: "prototype:screen:\(screen.id)",
                                        effort: effort, readLog: readLog,
                                        record: record, stage: stage)
            let files = change.files
            guard let file = files.first(where: { (try? PrototypeFiles.validate(path: $0.path)) == wanted }) else {
                failure = "The answer must contain exactly one file, \(wanted)."
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                continue
            }
            // A comment that says "not implemented", or a file that never registers the screen, is not an answer (BUG-053):
            // the second try gets the reason and more effort, and a screen that is still a stub is reported as failed.
            if let problem = PrototypeAudit.stubProblem(id: screen.id, content: file.content) {
                failure = "\(wanted) is not a finished screen: \(problem). Write the complete screen with everything the plan lists for it."
                if effort == "low" { effort = "medium" }
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                stage(.log("\(wanted) was a stub (\(problem)); asking again"))
                continue
            }
            // A loader that clears its own container shows nothing and throws nothing (BUG-062): the first answer is sent back with
            // the reason; the second is saved as it is, because the check is a text scan and the preview check has the last word.
            if let problem = PrototypeAudit.loadProblem(id: screen.id, content: file.content) {
                if attempt == 0 {
                    failure = "\(wanted) would stay empty: \(problem)"
                    stage(.log("\(wanted) would stay empty; asking again"))
                    continue
                }
                stage(.log("\(wanted) still looks like it would stay empty; the preview check will say"))
            }
            stage(.log("Saving \(wanted)"))
            try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: file.content)]), to: site)
            return
        }
    }

    /// The isolated view of one component, `components/<slug>.html`; the answer is tried twice (code mode, REQ-007).
    private static func buildComponent(root: URL, site: URL, plan: PrototypePlan, component: PrototypeFiles.Component,
                                       foundation: [PrototypeFiles.File], language: String,
                                       readLog: PrototypeEmbedded.ReadLog? = nil, record: @escaping Record,
                                       stage: @escaping Stage) async throws {
        let wanted = PrototypeFiles.componentPage(for: component.path)
        let slug = ((wanted as NSString).lastPathComponent as NSString).deletingPathExtension
        let screens = plan.screens.filter { component.screens.contains($0.name) }
        var failure: String?
        for attempt in 0..<2 {
            let change = try await generatedFiles(root: root, system: PrototypePrompts.componentSystem(language: language),
                                        prompt: PrototypePrompts.componentPrompt(plan: plan.json, component: component.path, page: wanted,
                                                                screens: screens, foundation: foundation, failure: failure),
                                        paths: [wanted], label: "prototype:component:\(slug)", effort: "low", reading: "the code",
                                        readLog: readLog, record: record, stage: stage)
            let files = change.files
            guard let file = files.first(where: { (try? PrototypeFiles.validate(path: $0.path)) == wanted }) else {
                failure = "The answer must contain exactly one file, \(wanted)."
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                continue
            }
            stage(.log("Saving \(wanted)"))
            try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: file.content)]), to: site)
            return
        }
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
    }

    /// Applies one reviewer request. A change that cannot apply is sent back to the assistant once with the reason.
    /// In `.code` mode `sources` name the implementation the prototype reconstructs, so the assistant reads
    /// them instead of requirement documents.
    ///
    /// A request that needs many files (translating the whole prototype, for example) cannot be answered in one run:
    /// the first run then lists the files in `remaining` and changes nothing itself, and each file is revised by a
    /// read-only run of its own, `concurrency` at a time, as the build writes its screens. Every run's change is checked
    /// in memory first; one `apply` at the end writes them all, so a cancelled or failed sweep leaves the site as it
    /// was. A file whose run failed twice is reported in the summary and stays as it is; if no file could be revised
    /// the request fails. `sweep` false never fans out (a request aimed at one screen or component, the source comparison).
    ///
    /// `sweepFiles` are the files the caller already knows the request needs (the fix round names them from the problems the
    /// preview reported): no first run decides that again, each file gets a run of its own at once. `runtimeErrors` travel with
    /// each of those runs, which fix what concerns their file and leave the rest to the others (BUG-062).
    ///
    /// An answer with no change that explains itself in `summary` is the assistant's reply, not an error: nothing is
    /// written (`written` is empty) and the summary says so.
    static func revise(root: URL, folder: URL, instruction: String, pick: Pick?, attachments: [(url: URL, note: String)] = [],
                       runtimeErrors: [String], language: String, mode: PrototypeFiles.Mode = .requirements, sources: [String] = [],
                       sweep: Bool = true, concurrency: Int = 4, target: Target? = nil,
                       sweepFiles: [String] = [], sweepEffort: String = "low",
                       record: @escaping Record, stage: @escaping Stage) async throws -> Outcome {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        var failure: String?
        var emptyAnswer = false
        for attempt in 0..<2 {
            let current = PrototypeFiles.read(site: site)
            let object: [String: Any]
            let change: PrototypeFiles.Change
            let summary: String
            if sweep && !sweepFiles.isEmpty {
                // The caller knows which files the request needs: no run decides that again (BUG-062).
                object = ["remaining": sweepFiles]
                change = PrototypeFiles.Change()
                summary = ""
            } else {
                let result = try await call(root: root, system: PrototypePrompts.reviseSystem(language: language),
                                            prompt: PrototypePrompts.revisePrompt(instruction: instruction, pick: pick, siteRelative: relative,
                                                                 files: current, runtimeErrors: runtimeErrors,
                                                                 priorFailure: failure,
                                                                 attachments: attachments.map { Attachment(path: relativePath($0.url, root: root), note: $0.note) },
                                                                 mode: mode, sources: sources, priorEmpty: emptyAnswer, target: target,
                                                                 fanOut: sweep),
                                            schema: PrototypeSchemas.reviseSchema, label: "prototype:revise", images: attachments.map(\.url),
                                            record: record, stage: stage)
                object = result.structured as? [String: Any] ?? [:]
                change = PrototypeFiles.change(from: result.structured)
                summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0.content) })
            var touched = Set<String>()
            for path in change.files.map(\.path) + change.edits.map(\.path) + change.deletes {
                if let normal = try? PrototypeFiles.validate(path: path) { touched.insert(normal) }
            }
            let targets = sweep
                ? Array(PrototypePrompts.sweepTargets(object["remaining"], siteRelative: relative, existing: Set(existing.keys), touched: touched)
                    .prefix(maxSweepFiles))
                : []
            guard !change.isEmpty || !targets.isEmpty else {
                // Nothing to write. An explanation is an answer; silence is not.
                if !summary.isEmpty {
                    return Outcome(summary: summary + "\n\nNo files were changed.", screens: [], assumptions: [], written: [])
                }
                failure = "it had no summary, no change and no files in `remaining`. Make the change the request asks for; " +
                    "if nothing needs to change, say why in `summary`."
                emptyAnswer = true
                if attempt == 1 { throw PrototypeFiles.Failure.edits(["The assistant answered with nothing: no change and no explanation."]) }
                continue
            }
            emptyAnswer = false
            do {
                // Checked in memory: a change that cannot apply is sent back before any run of the sweep is paid for.
                if !change.isEmpty { _ = try PrototypeFiles.applying(change, to: existing) }
            } catch let error as PrototypeFiles.Failure {
                failure = error.localizedDescription
                if attempt == 1 { throw error }
                continue
            }

            var merged = change
            var report = ""
            if !targets.isEmpty {
                stage(.step("Revising \(targets.count) file\(targets.count == 1 ? "" : "s"), \(max(1, concurrency)) at a time"))
                // What the preview reported goes to every run: each fixes what concerns its file and leaves the rest to the others.
                let fileInstruction = runtimeErrors.isEmpty ? instruction
                    : instruction + "\n\nWhat the preview reported (fix what concerns this file; the other runs handle the other files):\n"
                    + runtimeErrors.map { "- \($0)" }.joined(separator: "\n")
                let changes = SweepChanges()
                var failed: [(path: String, problem: String)] = []
                var finished = 0
                try await sideBySide(targets, concurrency: concurrency, work: { path in
                    let one = try await reviseFile(root: root, siteRelative: relative,
                                                   file: PrototypeFiles.File(path: path, content: existing[path] ?? ""),
                                                   instruction: fileInstruction, language: language, effort: sweepEffort,
                                                   record: record, stage: scoped(stage, label: path, status: false))
                    changes.set(path, one)
                }, done: { path, problem in
                    finished += 1
                    if let problem {
                        failed.append((path, problem))
                        stage(.log("Could not revise \(path): \(problem)"))
                    } else {
                        stage(.log(changes.change(for: path)?.isEmpty == false ? "Revised \(path)" : "No change needed in \(path)"))
                    }
                    stage(.status("Revised \(finished) of \(targets.count) files"))
                })
                var revised = 0
                for path in targets {
                    guard let one = changes.change(for: path), !one.isEmpty else { continue }
                    merged.files += one.files
                    merged.edits += one.edits
                    revised += 1
                }
                if revised == 0 && change.isEmpty && !failed.isEmpty {
                    throw PrototypeFiles.Failure.edits(failed.prefix(5).map { "\($0.path): \($0.problem)" })
                }
                let unchanged = targets.count - revised - failed.count
                report = "Revised \(revised) of \(targets.count) files"
                    + (unchanged > 0 ? "; \(unchanged) needed no change" : "")
                    + (failed.isEmpty ? "." : "; could not revise " + failed.map(\.path).joined(separator: ", ")
                        + " (they are unchanged; ask again to retry them).")
                if merged.isEmpty {
                    return Outcome(summary: [summary, report, "No files were changed."].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                   screens: [], assumptions: [], written: [])
                }
            }
            do {
                stage(.step("Saving the change"))
                let written = try PrototypeFiles.apply(merged, to: site)
                let fallback = "Updated \(written.joined(separator: ", "))"
                let text = [summary.isEmpty && report.isEmpty ? fallback : summary, report].filter { !$0.isEmpty }.joined(separator: "\n\n")
                return Outcome(summary: text, screens: object["screens"] as? [String] ?? [], assumptions: [], written: written)
            } catch let error as PrototypeFiles.Failure {
                failure = error.localizedDescription
                if attempt == 1 { throw error }
            }
        }
        throw PrototypeFiles.Failure.edits([failure ?? "The change could not be applied."])
    }

    /// The most files one sweep revises; the rest of a longer list is dropped (a prototype has far fewer).
    static let maxSweepFiles = 100

    /// The changes of a sweep, written by the runs that finish side by side.
    private final class SweepChanges: @unchecked Sendable {
        private let lock = NSLock()
        private var changes: [String: PrototypeFiles.Change] = [:]
        func set(_ path: String, _ change: PrototypeFiles.Change) { lock.lock(); changes[path] = change; lock.unlock() }
        func change(for path: String) -> PrototypeFiles.Change? { lock.lock(); defer { lock.unlock() }; return changes[path] }
    }

    /// One file of a sweep: a run that owns `file`, answers for it alone and is tried twice. An answer that
    /// changes nothing is a result (the request does not affect the file); a change that cannot apply to the file is
    /// sent back once with the reason, then the file fails.
    private static func reviseFile(root: URL, siteRelative: String, file: PrototypeFiles.File, instruction: String, language: String,
                                   effort: String = "low", record: @escaping Record, stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: PrototypePrompts.reviseSystem(language: language),
                                        prompt: PrototypePrompts.sweepPrompt(instruction: instruction, siteRelative: siteRelative, file: file, priorFailure: failure),
                                        schema: PrototypeSchemas.reviseSchema, label: "prototype:revise:\(file.path)", effort: effort, record: record, stage: stage)
            var change = PrototypeFiles.change(from: result.structured)
            // The run owns one file: whatever it says about another one, or a delete, is not applied.
            change.files = change.files.filter { (try? PrototypeFiles.validate(path: $0.path)) == file.path }
            change.edits = change.edits.filter { (try? PrototypeFiles.validate(path: $0.path)) == file.path }
            change.deletes = []
            if change.isEmpty { return change }
            do {
                _ = try PrototypeFiles.applying(change, to: [file.path: file.content])
                return change
            } catch let error as PrototypeFiles.Failure {
                failure = error.localizedDescription
                if attempt == 1 { throw error }
            }
        }
        throw PrototypeFiles.Failure.edits([failure ?? "The change could not be applied."])
    }

    /// SPEC.md for the export: screens, states, transitions, data, rules and traceability to the sources.
    static func specification(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, language: String,
                              record: @escaping Record, stage: @escaping Stage) async throws -> String {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        let system = manifest.mode == .code ? PrototypePrompts.codeSpecSystem : PrototypePrompts.specSystem
        let result = try await call(root: root, system: system,
                                    prompt: PrototypePrompts.specPrompt(manifest: manifest, siteRelative: relative, language: language),
                                    schema: nil, label: "prototype:spec", record: record, stage: stage)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CLICompletion.Failure.invalidOutput(AssistantProviderRegistry.defaultTool, "the specification is empty") }
        return text
    }

}
