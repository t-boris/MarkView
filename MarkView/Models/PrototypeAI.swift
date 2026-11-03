import CoreGraphics
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
        /// The element's box in the preview, in points from the top left of the visible page.
        var rect = CGRect.zero
        /// Code mode: the source component of the element or its nearest marked ancestor
        /// (`data-mv-component`, REQ-007); nil when no ancestor carries a marker.
        var component: String? = nil
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
        private var thinkingTicks = 0
        /// What the assistant reads, for the status line ("the requirements" or "the code").
        private let reading: String

        init(root: URL, reading: String = "the requirements", emit: @escaping Stage) {
            self.emit = emit
            self.reading = reading
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
                emit(.status("Reading \(reading) (\(reads) file\(reads == 1 ? "" : "s") so far)"))
            case .search(let query):
                emit(.log("Searching for “\(query.prefix(60))”"))
            case .run(let command):
                emit(.log("Running \(command.prefix(80))"))
            case .webSearch, .webFetch:
                break
            case .thinking:
                if !thinking { emit(.log("Thinking")) }
                thinking = true
                thinkingTicks += 1
                let base = reads == 0 ? "Thinking" : "Designing the screens"
                // The CLI reports reasoning every ~1,500 characters, so a long phase still visibly moves.
                emit(.status(thinkingTicks > 1 ? "\(base) — about \(thinkingTicks * 3 / 2)K characters of reasoning" : base))
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

    private static func strings() -> [String: Any] { ["type": "array", "items": ["type": "string"]] }

    static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "assumptions": strings(),
            // Code mode: behaviour of the original the prototype cannot reproduce. Empty in requirements mode.
            "gaps": strings(),
            "roles": strings(),
            "entities": ["type": "array", "items": [
                "type": "object",
                "properties": ["name": ["type": "string"], "fields": strings(), "notes": ["type": "string"]],
                "required": ["name", "fields", "notes"], "additionalProperties": false,
            ]],
            "screens": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"], "name": ["type": "string"], "route": ["type": "string"],
                    "purpose": ["type": "string"], "data": strings(), "actions": strings(),
                    "states": strings(), "rules": strings(), "requirements": strings(),
                    // Code mode: the source files read for the screen. Empty in requirements mode.
                    "evidence": strings(),
                    // Code mode: the component files among the evidence (REQ-007). Empty in requirements mode.
                    "components": strings(),
                ],
                "required": ["id", "name", "route", "purpose", "data", "actions", "states", "rules", "requirements", "evidence",
                             "components"],
                "additionalProperties": false,
            ]],
        ],
        "required": ["title", "summary", "assumptions", "gaps", "roles", "entities", "screens"], "additionalProperties": false,
    ]

    /// The answer of the foundation and screen runs: a summary and whole files.
    static let filesSchema: [String: Any] = [
        "type": "object",
        "properties": ["summary": ["type": "string"], "files": ["type": "array", "items": fileSchema]],
        "required": ["summary", "files"], "additionalProperties": false,
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

    static func planSystem(language: String) -> String {
        """
        You plan a clickable prototype of a product that a team approves before any implementation starts. Read the \
        requirement sources with your tools, then answer with the plan only; the screens are written afterwards by \
        engineers who will NOT see the requirements, so each screen entry must carry everything they need.

        Answer with the JSON object: `title` (short product name), `summary` (what the prototype shows, two sentences), \
        `assumptions` (decisions the requirements did not make), `roles` (who uses it and what each role may do), \
        `entities` (name, fields with types, notes such as statuses and relations), and `screens`: at most 10, each with \
        `id` (short lowercase words joined by dashes), `name`, `route` (hash route such as /tickets or /tickets/:id), \
        `purpose`, `data` (what it shows, field by field), `actions` (every control and exactly what it does, with \
        validation and permission rules), `states` (empty, loading, error and special states), `rules` (business rules \
        the screen demonstrates) and `requirements` (the requirements it covers, quoted or referenced). Put modal \
        flows inside the screen that opens them, not in screens of their own. Use the vocabulary of the requirements. \
        Do not invent features the requirements do not ask for.\(language)
        """
    }

    static func planPrompt(brief: String, sources: [String]) -> String {
        let list = sources.isEmpty ? "the whole project folder" : sources.map { "- \($0)" }.joined(separator: "\n")
        return """
        Plan the prototype of the product described by these requirement sources (files or folders, relative to the \
        project root; read all of them, and any code or documents they refer to):
        \(list)

        What the reviewer asks for:
        \(brief.isEmpty ? "A complete prototype of everything the sources describe." : brief)
        """
    }

    /// The planning run of code mode (Previews from Existing Code): the selected implementation is the
    /// reference, every screen maps to a real view of the code and names its evidence, and what the
    /// prototype cannot reproduce is listed as gaps (REQ-001, DEC-001).
    static func codePlanSystem(language: String) -> String {
        """
        You plan a clickable prototype that reconstructs an EXISTING web interface from its source code, so a team \
        can review and edit a faithful stand-in for what is implemented today. The selected implementation is the \
        reference: read its sources with your tools (routes, pages, views, components, templates, stylesheets, \
        navigation, state and event handlers) and plan screens that reproduce its layout, styling, navigation and \
        interactions. Do not design a new interface, and do not add screens, controls or features the code does not \
        have. The screens are written afterwards by engineers who see only the plan and the files you name, so each \
        screen entry must carry everything they need.

        Answer with the JSON object: `title` (the product's name as the code shows it), `summary` (what the prototype \
        reproduces, two sentences), `assumptions` (what the code left you to decide, such as the data a backend would \
        return), `roles` (users and permissions the code distinguishes, if any), `entities` (from the code's models, \
        types, stores or API payloads: name, fields with types, notes), `gaps` (behaviour of the original that the \
        prototype cannot reproduce and must simulate: backend and network calls, authentication, Electron preload or \
        `ipcRenderer` calls, native dialogs, file system and OS access, third-party widgets; one sentence each, naming \
        the source file), and `screens`: at most 10, each with `id` (short lowercase words joined by dashes), `name`, \
        `route` (the real route or view path of the code, as a hash route such as /orders or /orders/:id), `purpose`, \
        `data` (what it shows, field by field, as the code renders it), `actions` (every control and exactly what it \
        does in the code, with validation and permission rules), `states` (empty, loading, error and special states \
        the code handles), `rules` (business rules the code enforces on that screen), `requirements` (what the code \
        establishes for the screen: the component, template or view it reproduces, one sentence each), `evidence` \
        (the source files you read for this screen, relative to the project root) and `components` (the component \
        files among the evidence that the screen reproduces: React, Vue, Svelte or Angular component files, or the \
        template or HTML file of a plain page; the same relative paths, only files you have read). Every screen maps \
        to a real route, page, view or window of the code. Put modal flows inside the screen that opens them. Use the \
        labels and vocabulary of the code's own UI. An Electron app is in scope only as its renderer, the browser part: \
        the main process is not reproduced, and every `window.electron`, `window.api` or `ipcRenderer` call is \
        simulated and listed in `gaps`.\(language)
        """
    }

    /// Code mode: how the files link what they reproduce to the source components (REQ-007, DEC-005). Part of
    /// the foundation, screen and component prompts, so every marker rests on a file the assistant has read.
    static let componentRule = "Mark every element that reproduces a source component with the attribute " +
        "`\(PrototypeFiles.componentMarker)=\"<path>\"` on the outermost element it reproduces, where <path> is the component " +
        "file relative to the project root exactly as the plan names it (a React, Vue, Svelte or Angular component file, or " +
        "the template or HTML file of a plain page). A component nested in another keeps its own marker. Only mark what you " +
        "have read in the sources: never invent a marker, and leave an element unmarked when you cannot tell which file it " +
        "comes from."

    /// The code-mode planning prompt: the sources (or the whole project), the detected apps as hints, the
    /// inventory of web-interface files (paths and sizes only; the assistant reads them with its tools).
    static func codePlanPrompt(brief: String, sources: [String], scope: CodeScope, inventory: PrototypeFiles.Inventory) -> String {
        var out = "Reconstruct the existing web interface implemented by these sources (files or folders, relative to the " +
            "project root; read them with your tools and follow their imports to the components, templates, styles and " +
            "routes they use):\n"
        if sources.isEmpty {
            out += "- the whole project folder: find the web interface in it yourself\n"
        } else {
            for source in sources { out += "- \(source)\n" }
        }
        if !scope.apps.isEmpty {
            out += "\nWeb applications detected in the project (hints to where the interface lives; the sources above are the scope):\n"
            for app in scope.apps {
                let path = app.path.isEmpty ? "." : app.path
                var kind = "web application"
                if app.isElectron {
                    kind = "Electron renderer: only the browser part is in scope; `window.electron`/`ipcRenderer` calls must " +
                        "be simulated and listed as gaps"
                }
                out += "- \(path) (\(app.label)) — \(kind)\n"
            }
        }
        if inventory.isEmpty {
            out += "\nNo web-interface files (HTML, CSS, JavaScript, TypeScript, Vue, Svelte) were found in the scope by name; " +
                "look for the interface yourself and list in `gaps` what you could not find.\n"
        } else {
            out += "\nWeb-interface files in the scope (\(inventory.entries.count) listed; read the ones you need, never guess " +
                "their content):\n"
            out += inventory.lines.joined(separator: "\n") + "\n"
        }
        out += "\nWhat the reviewer asks for:\n"
        out += brief.isEmpty ? "A faithful reconstruction of everything the sources implement." : brief
        return out
    }

    /// The data contract both foundation parts rely on, so they can be written at the same time.
    private static let dataContract = """
    The `DB` contract (generic, so the shell and the screens can be written without seeing data.js): \
    `DB.list(entity, {q, filter, sort, dir, page, pageSize})` returns `{items, total, page, pageSize}`; \
    `DB.get(entity, id)`; `DB.create(entity, record)`; `DB.update(entity, id, patch)`; `DB.remove(entity, id)`; \
    `DB.reset()`; `DB.user` helpers are not part of it. `entity` is the entity's `name` exactly as in the plan. \
    Domain functions (metrics, status changes, rules) are extra functions on `DB` with clear names.
    """

    static func dataSystem(language: String) -> String {
        craft + """


        You write data.js, the fake backend of the prototype. The shell and the screens are written at the same time by \
        other engineers, so follow this contract exactly. \(dataContract)
        data.js defines the global `DB`: the entities of the plan with realistic seed data (compact: 6 to 12 records per \
        entity, long and short values, every status represented, dates relative to now), the generic functions above, and \
        the domain functions the plan's rules and screens need. State is kept in memory and in localStorage; \
        `DB.reset()` restores the seed. Enforce the rules of the plan (validation, status changes, permissions by role \
        where the plan says so). Keep the file under 60 KB.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: data.js).\(language)
        """
    }

    static func shellSystem(language: String) -> String {
        craft + """


        You write the shell of the prototype: the files every screen builds on. The data backend (data.js) and the \
        screens are written at the same time by other engineers, using only what you document, so the API must be \
        complete and exact. \(dataContract) Do not write data.js.
        Write these files:
        - index.html: `<div id="app"></div>`, `<link rel="stylesheet" href="styles.css">`, then the scripts `data.js` and \
        `app.js`, then the exact comment `<!--SCREENS-->` on its own line (the screen scripts are inserted there), then \
        `<script>App.start()</script>`. No inline styles or other scripts.
        - styles.css: the design system (tokens as CSS variables, layout shell, and classes for buttons, cards, tables, \
        forms and fields with error text, badges, tabs, toolbars, modals, toasts, skeleton loading, empty states, \
        pagination). Screens use these classes and add only their own small rules. Keep it under 20 KB.
        - app.js: the global `App`. It starts with a header comment documenting the API for the screen authors, then \
        provides: `App.register({id, route, title, render(ctx)})` where route may have `:params` and `render` returns an \
        element or an HTML string (`ctx` has `params`, `query`, `user`, `proto`); a hash router with Back support and an \
        unknown-route redirect to the first screen; the shell (header and navigation built from the plan's screens, the \
        current screen highlighted); `App.h(tag, attrs, ...children)` for building elements; `App.navigate(path)`; \
        `App.toast(message, kind)`; `App.modal({title, body, actions})`; `App.confirm(message)` returning a promise; \
        `App.addStyles(css)`; `App.user()` and `App.can(permission)` with a "Signed in as" switch for the roles of the \
        plan; `App.load(fn)` that shows the skeleton for about 350 ms before rendering. The toolbar "Prototype" menu has \
        "Force empty state", "Force error state" (both exposed as `ctx.proto.empty` and `ctx.proto.error`, and \
        `App.load` shows the error card with Retry when it is on) and "Reset demo data" (calls `DB.reset()`). A route \
        whose screen is not registered (yet) shows the panel "This screen is still being built." The screens of the \
        plan are listed in `App.plan` (id, name, route) for the navigation.
        Answer with the JSON object: `summary` (one sentence) and `files` (path and full content).\(language)
        """
    }

    static func foundationPrompt(plan: String, failure: String?, mode: PrototypeFiles.Mode = .requirements) -> String {
        var out = "The plan of the prototype:\n\(plan)"
        if mode == .code {
            out += "\n\nThis prototype reconstructs an existing interface; the plan's `evidence` lists its source files. Read the " +
                "stylesheets, layout templates and navigation among them with your tools and reproduce the original design " +
                "tokens (colours, fonts, spacing, radii), shell layout and navigation instead of inventing a design system. " +
                "The entities and the seed data mirror what the code renders; what the original gets from a backend or " +
                "native APIs is simulated. " + componentRule
        }
        if let failure { out += "\n\nYour previous answer was not usable:\n\(failure)\nWrite the files again, complete." }
        return out
    }

    static func screenSystem(language: String) -> String {
        craft + """


        You write ONE screen of a prototype whose foundation already exists. Other engineers write the other screens at \
        the same time, so touch only your file. Write `screens/<id>.js` (the id is given): a self-contained script that \
        calls `App.register({id, route, title, render(ctx)})` as documented in app.js, uses the `DB` functions and the \
        CSS classes that exist, and implements everything the plan lists for the screen: every data field, every \
        action with its validation and permission rules, every state. Make links to other screens with their hash \
        routes (`#/route`). If you need a data function that `DB` lacks, define it in your own file (`DB.name = …`) \
        with a name starting with your screen id. Screen-specific CSS goes through `App.addStyles`. Do not edit other \
        files and do not change global behaviour.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: path and full content).\(language)
        """
    }

    static func screenPrompt(plan: String, screen: PlannedScreen, foundation: [PrototypeFiles.File], failure: String?,
                             mode: PrototypeFiles.Mode = .requirements) -> String {
        var out = "The plan of the whole prototype:\n\(plan)\n\nThe foundation files (the API you build on):\n"
        for file in foundation { out += "\n=== \(file.path) ===\n\(file.content)\n" }
        out += "\nWrite the screen `\(screen.id)` (\(screen.name), route \(screen.route)) as `screens/\(screen.id).js`."
        if mode == .code {
            out += "\n\nThis prototype reconstructs an existing interface. Reproduce the original screen, not a redesign: "
            if screen.evidence.isEmpty {
                out += "find its source files with your tools (the plan's `requirements` name the view) and copy their markup " +
                    "structure, class names, labels, CSS tokens and interactions as closely as the foundation allows."
            } else {
                out += "read these source files with your tools and copy their markup structure, class names, labels, CSS " +
                    "tokens and interactions as closely as the foundation allows:\n"
                for path in screen.evidence { out += "- \(path)\n" }
            }
            out += "\nWhat the original gets from a backend, the Electron main process or native APIs is simulated with " +
                "`DB` and sample data; the standalone rules still apply (no network request, no framework download).\n\n"
            out += componentRule
            if !screen.components.isEmpty {
                out += "\nThe component files of this screen, as the plan names them:\n"
                for path in screen.components { out += "- \(path)\n" }
            }
        }
        if let failure { out += "\n\nYour previous answer was not usable:\n\(failure)" }
        return out
    }

    /// Code mode: the isolated view of one component (REQ-007 criterion 4), written after the screens.
    static func componentSystem(language: String) -> String {
        craft + """


        You write ONE page of a prototype whose foundation and screens already exist: the isolated view of a source \
        component, `components/<name>.html` (the path is given). The page shows only that component, rendered with \
        simulated data, so a reviewer can look at it on its own and edit it like a screen. It lives one folder below \
        the prototype's root, so it loads the shared files with relative paths (`../styles.css`, `../data.js`, \
        `../app.js`, and the `../screens/<id>.js` scripts that build the component's markup); it does not call \
        `App.start()` and does not show the shell navigation. Render the component into `<main id="component">` with \
        the markup, class names and the `\(PrototypeFiles.componentMarker)` marker the screens use for it: reuse the \
        screen's rendering code where it is reachable (a function on `App` or `DB`, or the registered screen's \
        `render`), otherwise copy the component's markup from the screen into the page's own script. Show a short \
        caption with the component's source path above it. Do not edit other files.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: path and full content).\(language)
        """
    }

    static func componentPrompt(plan: String, component: String, page: String, screens: [PlannedScreen],
                                foundation: [PrototypeFiles.File], failure: String?) -> String {
        var out = "The plan of the whole prototype:\n\(plan)\n\nThe foundation files (the API you build on):\n"
        for file in foundation { out += "\n=== \(file.path) ===\n\(file.content)\n" }
        out += "\nWrite the isolated view of the component `\(component)` as `\(page)`."
        if screens.isEmpty {
            out += "\nNo screen script names it: read the component's source file with your tools and reproduce its markup, " +
                "class names and labels with the foundation's CSS classes."
        } else {
            out += "\nThe screens that render it (read their scripts with your tools and reuse their markup for the component):\n"
            for screen in screens { out += "- \(screen.name): screens/\(screen.id).js\n" }
        }
        out += "\nRead the component's source file `\(component)` with your tools as well, so the view shows the whole " +
            "component (every state its props or inputs allow) with plausible simulated data."
        if let failure { out += "\n\nYour previous answer was not usable:\n\(failure)" }
        return out
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

    /// An image the reviewer sent with the request: where it is (relative to the project root) and what it is.
    struct Attachment: Equatable {
        var path: String
        var note: String
    }

    static func revisePrompt(instruction: String, pick: Pick?, siteRelative: String, files: [PrototypeFiles.File],
                             runtimeErrors: [String], priorFailure: String?, attachments: [Attachment] = [],
                             mode: PrototypeFiles.Mode = .requirements, sources: [String] = []) -> String {
        var out: String
        if mode == .code {
            var scope = "the project's own source code"
            if !sources.isEmpty { scope = "the project's source code in " + sources.map { "`\($0)`" }.joined(separator: ", ") }
            out = "The prototype lives in `\(siteRelative)/` (relative to the project root). It is a reconstruction of the " +
                "existing interface implemented in \(scope); read those sources when the request touches a look or behaviour " +
                "they define, and keep the reconstruction faithful where the request does not ask for a change.\n\n"
        } else {
            out = "The prototype lives in `\(siteRelative)/` (relative to the project root). Its requirements come from the project's documents; read them when the request touches behaviour they define.\n\n"
        }
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
            if let component = pick.component, !component.isEmpty {
                out += "\nsource component: \(component) (the element or its nearest marked ancestor reproduces this file)"
            }
        }
        if !attachments.isEmpty {
            out += "\n\nImages the reviewer sent (open each one with your Read tool before you answer; they show what the request means):\n"
                + attachments.map { "- \($0.path): \($0.note)" }.joined(separator: "\n")
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

    /// The specification of a code-mode prototype: the change is described against the original sources.
    static let codeSpecSystem = """
    You write the implementation specification that travels with an approved prototype reconstructed from the \
    project's existing web interface and edited during review. A developer who has not seen the prototype must be \
    able to change the real product from the specification and the prototype files. Read the prototype files and \
    the original sources with your tools; state only what they show, and never present simulated behaviour as a \
    verified reproduction of the original. Answer with the Markdown document only: no preface, no code fence around it.
    """

    /// The SPEC.md request for the export. Requirements mode is unchanged; code mode traces screens to the
    /// sources and adds the reconstruction section with the known gaps (REQ-001, REQ-002).
    static func specPrompt(manifest: PrototypeFiles.Manifest, siteRelative relative: String, language: String) -> String {
        let decisions = manifest.history.map { "- v\($0.version): \($0.instruction.isEmpty ? "initial build" : $0.instruction) → \($0.summary)" }
            .joined(separator: "\n")
        if manifest.mode == .code {
            let sources = manifest.sources.isEmpty ? "- the project folder" : manifest.sources.map { "- \($0)" }.joined(separator: "\n")
            let assumptions = manifest.assumptions.isEmpty ? "(none)" : manifest.assumptions.map { "- \($0)" }.joined(separator: "\n")
            let gaps = manifest.gaps.isEmpty ? "(none)" : manifest.gaps.map { "- \($0)" }.joined(separator: "\n")
            return """
            Write SPEC.md for the approved prototype "\(manifest.title)" (version \(manifest.version)). The prototype files are in \
            `\(relative)/`. It is a reconstruction of the existing interface implemented in these sources (relative to the \
            project root; read them to verify what the prototype reproduces):
            \(sources)

            Sections, in this order:
            1. Purpose and users (as the code and the prototype show them).
            2. Screens: for each, its route, purpose, the data it shows, every control and what it does, and its empty, loading, error and permission states.
            3. Navigation and flows: the transitions between screens as a table (from, trigger, to, condition).
            4. Data model: entities, fields, types, relations, validation rules and the sample data shape used by data.js.
            5. Business rules and behaviours the prototype demonstrates (numbered, testable statements).
            6. Source traceability: a table of source file or view → screens and rules that reproduce it, and parts of the sources not reproduced.
            7. Decisions made during review (below), and assumptions the code did not settle.
            8. Reconstruction: sources, evidence, known gaps — the sources the prototype was reconstructed from, the source files that served as evidence for each screen, and the known gaps (below): behaviour of the original that the prototype simulates or lacks. Mark what is simulated; do not present it as verified reproduction.
            9. Out of scope for the prototype, and what the real implementation keeps that the prototype replaced (backend, authentication, Electron main process, native integrations).

            Decisions made during review:
            \(decisions.isEmpty ? "(none)" : decisions)

            Assumptions recorded at the first build:
            \(assumptions)

            Known gaps recorded at the first build:
            \(gaps)\(language)
            """
        }
        return """
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
    }

    // MARK: - Runs

    /// One structured run. `record` receives the finished run for the usage counter.
    private static func call(root: URL, system: String, prompt: String, schema: [String: Any]?, label: String,
                             effort: String = "medium", images: [URL] = [], reading: String = "the requirements",
                             record: @escaping Record, stage: @escaping Stage) async throws -> CLICompletion.Result {
        var request = CLICompletion.Request(project: root, prompt: prompt, systemPrompt: system, readableFolder: root)
        request.images = images
        request.jsonSchema = schema
        request.effort = effort
        // A prototype's work varies with the requirements and provider. Keep it running until
        // completion, a provider error or the studio's Stop action, rather than discarding it at a deadline.
        request.timeout = nil
        request.label = label
        stage(.log("Started the assistant"))
        let tracker = ProgressTracker(root: root, reading: reading, emit: stage)
        let result = try await CLICompletion.run(request, onActivity: { tracker.handle($0) })
        stage(.log("The assistant finished"))
        await record(result)
        return result
    }

    // MARK: - Staged build

    /// The plan of a build: what the screens are, and the whole plan as JSON for the later runs.
    struct Plan {
        var json: String
        var title: String
        var summary: String
        var assumptions: [String]
        /// Behaviour the prototype cannot reproduce (code mode), plus the screens dropped past `maxScreens`.
        var gaps: [String]
        var screens: [PlannedScreen]

        static let maxScreens = 10

        init(structured: Any?) throws {
            guard let object = structured as? [String: Any],
                  let raw = object["screens"] as? [[String: Any]], !raw.isEmpty else {
                throw CLICompletion.Failure.invalidOutput(.claude, "the plan has no screens")
            }
            var seen = Set<String>()
            var screens: [PlannedScreen] = []
            var normalised = raw.prefix(Self.maxScreens).map { $0 }
            for (index, item) in normalised.enumerated() {
                let name = item["name"] as? String ?? "Screen \(index + 1)"
                var id = Self.slug(item["id"] as? String ?? name)
                if id.isEmpty { id = "screen-\(index + 1)" }
                var unique = id, n = 2
                while seen.contains(unique) { unique = "\(id)-\(n)"; n += 1 }
                seen.insert(unique)
                normalised[index]["id"] = unique
                let evidence = (item["evidence"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // Component paths are normalised here, so the screen writer marks exactly what the manifest records.
                var components: [String] = []
                for raw in item["components"] as? [String] ?? [] {
                    if let path = PrototypeFiles.componentPath(raw), !components.contains(path) { components.append(path) }
                }
                normalised[index]["components"] = components
                screens.append(PlannedScreen(id: unique, name: name, route: item["route"] as? String ?? "/" + unique,
                                             purpose: item["purpose"] as? String ?? "", evidence: evidence, components: components))
            }
            var plan = object
            plan["screens"] = normalised
            let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
            json = String(decoding: data, as: UTF8.self)
            title = object["title"] as? String ?? "Prototype"
            summary = object["summary"] as? String ?? ""
            assumptions = object["assumptions"] as? [String] ?? []
            var gaps = (object["gaps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if raw.count > Self.maxScreens {
                // A plan past the cap is cut without asking; the reviewer must know what is missing.
                let dropped = raw.dropFirst(Self.maxScreens).enumerated().map { pair -> String in
                    pair.element["name"] as? String ?? "screen \(Self.maxScreens + pair.offset + 1)"
                }
                gaps.append("The plan listed \(raw.count) screens and only the first \(Self.maxScreens) are built; not built: " +
                            dropped.joined(separator: ", ") + ".")
            }
            self.gaps = gaps
            self.screens = screens
        }

        /// Lowercase words joined by dashes: safe as the name of `screens/<id>.js`.
        static func slug(_ text: String) -> String {
            text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
                .split(separator: "-").prefix(5).joined(separator: "-")
        }
    }

    struct Built {
        var title: String
        var summary: String
        var assumptions: [String]
        var screens: [String]
        var failed: [String]
        /// Known reconstruction gaps (code mode; a plan cut at `Plan.maxScreens` adds one in any mode).
        var gaps: [String] = []
        /// Code mode: the source components the files reproduce, with their isolated pages (REQ-007).
        var components: [PrototypeFiles.Component] = []
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
        let steps = mode == .code ? 4 : 3

        stage(.phase("Step 1 of \(steps) · Reading \(reading) and planning the screens"))
        stage(.status("Reading \(reading)"))
        let system: String
        let prompt: String
        if mode == .code {
            let inventory = PrototypeFiles.inventory(root: root, sources: sources)
            system = codePlanSystem(language: language)
            prompt = codePlanPrompt(brief: brief, sources: sources, scope: codeScope, inventory: inventory)
        } else {
            system = planSystem(language: language)
            prompt = planPrompt(brief: brief, sources: sources)
        }
        let planned = try await call(root: root, system: system, prompt: prompt, schema: planSchema, label: "prototype:plan",
                                     reading: reading, record: record, stage: scoped(stage, label: nil, status: true))
        let plan = try Plan(structured: planned.structured)
        stage(.plan(title: plan.title, summary: plan.summary, assumptions: plan.assumptions, screens: plan.screens))

        stage(.phase("Step 2 of \(steps) · Building the shell, styles and sample data (two parts at once)"))
        stage(.status("Writing the shell and the data"))
        async let shell = foundationPart(root: root, plan: plan, system: foundationShell(language), label: "shell",
                                         allowed: ["index.html", "styles.css", "app.js"], required: ["index.html", "app.js"],
                                         mode: mode, record: record, stage: scoped(stage, label: "Shell", status: false))
        async let data = foundationPart(root: root, plan: plan, system: dataSystem(language: language), label: "data",
                                        allowed: ["data.js"], required: ["data.js"],
                                        mode: mode, record: record, stage: scoped(stage, label: "Data", status: false))
        var shellChange = try await shell
        let dataChange = try await data
        for index in shellChange.files.indices where shellChange.files[index].path == "index.html" {
            shellChange.files[index].content = PrototypeFiles.insertScreenScripts(into: shellChange.files[index].content,
                                                                                  ids: plan.screens.map(\.id)) ?? shellChange.files[index].content
        }
        stage(.step("Saving the foundation"))
        try PrototypeFiles.apply(PrototypeFiles.Change(files: shellChange.files + dataChange.files), to: site)
        stage(.milestone("The shell, navigation and sample data for \(plan.screens.count) screens; the screens follow."))

        stage(.phase("Step 3 of \(steps) · Writing the screens"))
        let foundation = PrototypeFiles.read(site: site).filter { ["app.js", "data.js", "styles.css"].contains($0.path) }
        var failed: [String] = []
        for screen in plan.screens { stage(.screen(id: screen.id, state: .queued)) }
        try await sideBySide(plan.screens, concurrency: concurrency, work: { screen in
            stage(.screen(id: screen.id, state: .writing))
            try await buildScreen(root: root, site: site, plan: plan, screen: screen, foundation: foundation,
                                  language: language, mode: mode, record: record,
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
        var gaps = plan.gaps
        var components: [PrototypeFiles.Component] = []
        if mode == .code {
            stage(.phase("Step 4 of 4 · Isolating the source components"))
            components = PrototypeFiles.components(in: site, screens: screenRefs(plan.screens))
            if components.isEmpty {
                stage(.step("No source component is named by the plan or marked in the files; nothing to isolate"))
            } else {
                for component in components { stage(.component(path: component.path, state: .queued)) }
                stage(.status("Writing the isolated component views"))
                try await sideBySide(components, concurrency: concurrency, work: { component in
                    stage(.component(path: component.path, state: .writing))
                    try await buildComponent(root: root, site: site, plan: plan, component: component, foundation: foundation,
                                             language: language, record: record,
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
                components = PrototypeFiles.components(in: site, screens: screenRefs(plan.screens))
            }
        }
        let built = plan.screens.map(\.name).filter { !failed.contains($0) }
        return Built(title: plan.title, summary: plan.summary, assumptions: plan.assumptions, screens: built, failed: failed,
                     gaps: gaps, components: components)
    }

    private static func foundationShell(_ language: String) -> String { shellSystem(language: language) }

    /// One part of the foundation: the answer is tried twice; `allowed` are the files it may write, `required` must be there.
    /// A shell answer must also contain the `<!--SCREENS-->` line.
    private static func foundationPart(root: URL, plan: Plan, system: String, label: String, allowed: Set<String>,
                                       required: [String], mode: PrototypeFiles.Mode, record: @escaping Record,
                                       stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: system,
                                        prompt: foundationPrompt(plan: plan.json, failure: failure, mode: mode),
                                        schema: filesSchema, label: "prototype:foundation:\(label)", effort: "low",
                                        record: record, stage: stage)
            var change = PrototypeFiles.change(from: result.structured)
            change.files = change.files.filter { allowed.contains($0.path) }
            let missing = required.filter { name in !change.files.contains { $0.path == name } }
            var problem: String?
            if !missing.isEmpty {
                problem = "These files are required: \(missing.joined(separator: ", "))."
            } else if let html = change.files.first(where: { $0.path == "index.html" })?.content,
                      PrototypeFiles.insertScreenScripts(into: html, ids: []) == nil {
                problem = "index.html lacks the line <!--SCREENS--> where the screen scripts go."
            }
            guard let problem else { return change }
            failure = problem
            if attempt == 1 { throw PrototypeFiles.Failure.edits([problem]) }
        }
        throw PrototypeFiles.Failure.edits([failure ?? "The foundation could not be written."])
    }

    /// One screen: a run that answers with `screens/<id>.js`; the answer is tried twice.
    private static func buildScreen(root: URL, site: URL, plan: Plan, screen: PlannedScreen, foundation: [PrototypeFiles.File],
                                    language: String, mode: PrototypeFiles.Mode, record: @escaping Record,
                                    stage: @escaping Stage) async throws {
        let wanted = "screens/\(screen.id).js"
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: screenSystem(language: language),
                                        prompt: screenPrompt(plan: plan.json, screen: screen, foundation: foundation,
                                                             failure: failure, mode: mode),
                                        schema: filesSchema, label: "prototype:screen:\(screen.id)", effort: "low", record: record, stage: stage)
            let files = PrototypeFiles.change(from: result.structured).files
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

    /// The isolated view of one component, `components/<slug>.html`; the answer is tried twice (code mode, REQ-007).
    private static func buildComponent(root: URL, site: URL, plan: Plan, component: PrototypeFiles.Component,
                                       foundation: [PrototypeFiles.File], language: String, record: @escaping Record,
                                       stage: @escaping Stage) async throws {
        let wanted = PrototypeFiles.componentPage(for: component.path)
        let slug = ((wanted as NSString).lastPathComponent as NSString).deletingPathExtension
        let screens = plan.screens.filter { component.screens.contains($0.name) }
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: componentSystem(language: language),
                                        prompt: componentPrompt(plan: plan.json, component: component.path, page: wanted,
                                                                screens: screens, foundation: foundation, failure: failure),
                                        schema: filesSchema, label: "prototype:component:\(slug)", effort: "low", reading: "the code",
                                        record: record, stage: stage)
            let files = PrototypeFiles.change(from: result.structured).files
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
    static func revise(root: URL, folder: URL, instruction: String, pick: Pick?, attachments: [(url: URL, note: String)] = [],
                       runtimeErrors: [String], language: String, mode: PrototypeFiles.Mode = .requirements, sources: [String] = [],
                       record: @escaping Record, stage: @escaping Stage) async throws -> Outcome {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: reviseSystem(language: language),
                                        prompt: revisePrompt(instruction: instruction, pick: pick, siteRelative: relative,
                                                             files: PrototypeFiles.read(site: site), runtimeErrors: runtimeErrors,
                                                             priorFailure: failure,
                                                             attachments: attachments.map { Attachment(path: relativePath($0.url, root: root), note: $0.note) },
                                                             mode: mode, sources: sources),
                                        schema: reviseSchema, label: "prototype:revise", images: attachments.map(\.url),
                                        record: record, stage: stage)
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
                              record: @escaping Record, stage: @escaping Stage) async throws -> String {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        let system = manifest.mode == .code ? codeSpecSystem : specSystem
        let result = try await call(root: root, system: system,
                                    prompt: specPrompt(manifest: manifest, siteRelative: relative, language: language),
                                    schema: nil, label: "prototype:spec", record: record, stage: stage)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CLICompletion.Failure.invalidOutput(.claude, "the specification is empty") }
        return text
    }

    // MARK: - Export

    enum ExportFailure: LocalizedError {
        case zip(String)
        var errorDescription: String? { if case .zip(let detail) = self { return "Could not create the archive: \(detail)" } else { return nil } }
    }

    /// README.md of the export package. A code-mode prototype is presented as a reconstruction of the
    /// existing interface with its known gaps, never as the original itself.
    static func readme(manifest: PrototypeFiles.Manifest) -> String {
        if manifest.mode == .code {
            var scope = "the project's existing web interface"
            if !manifest.sources.isEmpty { scope += " in " + manifest.sources.map { "`\($0)`" }.joined(separator: ", ") }
            var out = """
            # \(manifest.title) — approved prototype (v\(manifest.version))

            - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
            - `SPEC.md` — screens, states, flows, data, rules, source traceability and the reconstruction notes.
            - `CHANGES.md` — the review requests that shaped this version.

            The prototype is a reconstruction of \(scope), edited during review: it shows the agreed behaviour and \
            look of the change, not the original code. Implement the change in the existing code to match it; where \
            the prototype and SPEC.md differ, ask before choosing.

            """
            if manifest.gaps.isEmpty {
                out += "\nNo reconstruction gaps were recorded at generation.\n"
            } else {
                out += "\nKnown reconstruction gaps (behaviour of the original that the prototype simulates or lacks; they are " +
                    "not part of the change):\n"
                for gap in manifest.gaps { out += "- \(gap)\n" }
            }
            return out
        }
        return """
        # \(manifest.title) — approved prototype (v\(manifest.version))

        - `prototype/index.html` — open it in a browser; it is self-contained and needs no server.
        - `SPEC.md` — screens, states, flows, data, rules and requirement traceability.
        - `CHANGES.md` — the review requests that shaped this version.

        The prototype is the agreed behaviour and look. Implement the product to match it; where the prototype and \
        SPEC.md differ, ask before choosing.

        """
    }

    /// Packs `prototype/` (the live site), `SPEC.md`, `CHANGES.md` and `README.md` into
    /// `<root>/.dde/exports/prototypes/<slug>-v<version>.zip` (`PrototypeFiles.exportArchive`) and returns it.
    /// The archive is a derived binary, so it lives outside the committed prototype folder (DEC-006).
    static func packageArchive(root: URL, folder: URL, manifest: PrototypeFiles.Manifest, spec: String) throws -> URL {
        let fm = FileManager.default
        let name = "\(manifest.slug)-v\(manifest.version)"
        let archive = PrototypeFiles.exportArchive(root: root, slug: manifest.slug, version: manifest.version)
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

        try readme(manifest: manifest).write(to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
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
