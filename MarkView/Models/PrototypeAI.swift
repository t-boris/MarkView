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

    /// Turns the assistant's activity (files read, searches, the answer growing) into events. The CLI reports
    /// from its own threads and for every token, so the answer is scanned for the file being written and the
    /// size line is throttled.
    final class ProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let emit: Stage
        private let rootPrefix: String
        private let onRead: (@Sendable (String) -> Void)?
        private var buffer = ""
        private var lastPath = ""
        private var lastSize = Date.distantPast
        private var thinking = false
        private var reads = 0
        private var thinkingTicks = 0
        /// What the assistant reads, for the status line ("the requirements" or "the code").
        private let reading: String

        init(root: URL, reading: String = "the requirements", onRead: (@Sendable (String) -> Void)? = nil, emit: @escaping Stage) {
            self.emit = emit
            self.onRead = onRead
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
                onRead?(short(path))
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

    private static func strings(_ description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "array", "items": ["type": "string"]]
        if let description { schema["description"] = description }
        return schema
    }

    /// The plan of both modes: one schema, so a strict provider sees the same contract. The code-mode fields
    /// (`gaps`, `evidence`, `components`) are required but described as empty in requirements mode, and
    /// `Plan` drops whatever the planner put there in that mode.
    static let planSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "assumptions": strings(),
            "gaps": strings("Behaviour of the original that the prototype cannot reproduce; empty unless reconstructing existing code."),
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
                    "evidence": strings("Source files read for the screen; empty unless reconstructing existing code."),
                    "components": strings("Component files among the evidence that the screen reproduces; empty unless reconstructing existing code."),
                    "embedded": ["type": "boolean",
                                 "description": "True for a widget of a docked window or a modal that a host screen lays out; false otherwise and in requirements mode."],
                    "hosts": strings("Ids of the widget and modal screens this screen lays out or opens, in layout order; empty unless it is a host."),
                ],
                "required": ["id", "name", "route", "purpose", "data", "actions", "states", "rules", "requirements", "evidence",
                             "components", "embedded", "hosts"],
                "additionalProperties": false,
            ]],
            "styles": strings("The original stylesheet files the interface loads, in import order; empty unless reconstructing existing code."),
            "themes": strings("Ids of the themes the original interface can switch between, in its own order; empty unless reconstructing existing code."),
            "defaultTheme": ["type": "string",
                             "description": "The id of the theme the original starts with; empty unless reconstructing existing code with themes."],
        ],
        "required": ["title", "summary", "assumptions", "gaps", "roles", "entities", "screens", "styles", "themes", "defaultTheme"],
        "additionalProperties": false,
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
            "remaining": ["type": "array", "items": ["type": "string"],
                          "description": "Paths of the files a request for many files needs, left for runs of their own; empty otherwise."],
        ],
        "required": ["summary", "screens", "files", "edits", "delete", "remaining"], "additionalProperties": false,
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
        the source file), `styles` (the original stylesheet files the interface loads, relative to the project root, in the \
        order its entry file, root component or HTML page imports or links them: global CSS, themes, variables, fonts and \
        the CSS of the widgets; only files of the front end you plan, seen in the listing, plain `.css` only; the \
        prototype loads them unchanged, and the stylesheets they import from installed packages come along, so the \
        screens must use the original class names), `themes` (when the interface lets the user switch themes: the ids of all \
        its themes as the application names them, in its own order, including the theme whose look is the base styles \
        with no attribute selector of its own; otherwise empty), `defaultTheme` (the id the application starts with, read \
        from its settings code; empty when unknown or without themes), and `screens`: at most \(Plan.maxCodeScreens), each \
        with `id` (short lowercase words joined by dashes), `name`, \
        `route` (the real route or view path of the code, as a hash route such as /orders or /orders/:id), `purpose`, \
        `data` (what it shows, field by field, as the code renders it), `actions` (every control and exactly what it \
        does in the code, with validation and permission rules), `states` (empty, loading, error and special states \
        the code handles), `rules` (business rules the code enforces on that screen), `requirements` (what the code \
        establishes for the screen: the component, template or view it reproduces, one sentence each), `evidence` \
        (the source files you read for this screen, relative to the project root) and `components` (the component \
        files among the evidence that the screen reproduces: React, Vue, Svelte or Angular component files, or the \
        template or HTML file of a plain page; the same relative paths, only files you have read). Every screen maps \
        to a real route, page, view or window of the code. When the selected folder holds more than one front end (a \
        legacy static page, a debug console or an admin page beside the application's main renderer), plan only the one \
        the application's main window loads, name the other front end in `gaps` with its folder, and neither plan its \
        screens nor list its stylesheets. Put small confirmation and alert dialogs inside the screen that opens them. A \
        window made of docked panels, widgets, panes or tabs (a trading desk, a dashboard, an editor workspace) has no \
        routes: give every widget that has its own source file an entry of its own with `embedded` true and the route \
        `/widgets/<id>`, and one host entry with `embedded` false whose `hosts` lists, in layout order, the ids of the \
        widgets it lays out as the original layout code arranges them (default layout, tabs, docking, toolbar). A modal, \
        drawer or overlay that is a substantial interface of its own (settings, a detail view, a wizard, an assistant) \
        and has its own source file gets an entry as well: `embedded` true, the route `/modals/<id>`, listed in `hosts` \
        after the widgets; the host opens it from the control that opens it in the code. Never merge several widgets or \
        modals into one entry and never plan one you have not read; keep the fields of such an entry to a line each, \
        its writer reads the source file itself. `embedded` is false and `hosts` empty on every ordinary screen. Use the \
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

    /// Code mode with the output language left on "Document language": a reconstruction keeps the labels of the original,
    /// so nothing is translated (BUG-052). The summary, assumptions and gaps are saved in the project's files, so they are
    /// English. An explicit output language replaces this rule (`languageNote`).
    static let sourceLanguageRule = "\n\nLanguage: copy every visible label, message, tooltip and placeholder from the source " +
        "exactly as the source writes it, in the source's own language; never translate them. Text the source does not provide " +
        "(sample data, the empty and error states you have to write) is in the language of the source's interface, English when " +
        "the source has no visible text. Set the `lang` attribute of index.html to that language. Write `summary`, `assumptions`, " +
        "`gaps` and the purpose of each screen in English. A request of the reviewer that asks for another language overrides all of this."

    /// The language part of every prompt of a run: the explicit one when the person chose an output language, the
    /// source's own language for a prototype made from code, nothing (the documents' language) for requirements.
    static func languageNote(explicit: String, mode: PrototypeFiles.Mode) -> String {
        explicit.isEmpty && mode == .code ? sourceLanguageRule : explicit
    }

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

    /// The shell contract both shell parts share: the markup/script part and the stylesheet part
    /// are written at the same time, so each must know exactly what the other provides.
    private static let shellContract = """
    The shell is split between engineers working at the same time: one writes index.html and app.js, \
    another writes styles.css, and the screens are written afterwards. styles.css provides the design \
    system — tokens as CSS variables and classes for the layout shell (`app-header`, `app-nav`, \
    `app-main`), buttons (`btn`, `btn-primary`, `btn-ghost`, `btn-danger`), cards (`card`, \
    `card-header`, `card-body`), tables (`table`), forms and fields with error text (`form`, `field`, \
    `input`, `select`, `field-error`), badges (`badge`, with status modifiers), tabs (`tabs`, `tab`, \
    `is-active`), toolbars (`toolbar`), modals (`modal`, `modal-card`, `modal-actions`), toasts \
    (`toast`, with kind modifiers), skeleton loading (`skeleton`), empty states (`empty`) and \
    pagination (`pagination`). index.html and app.js use exactly these class names and define no \
    styles of their own beyond `App.addStyles`.
    """

    /// What the shell must also provide when the plan has widget and modal screens that a host screen lays out (BUG-050).
    static let embeddedShellContract = """
    This plan has widget and modal screens (`embedded` true in the plan; the host screen's `hosts` lists them). A host \
    renders them; nobody navigates to them. So: `App.plan` carries `embedded` and `hosts` for every screen. The \
    navigation lists only screens whose `embedded` is false, and when exactly one such screen exists the shell shows \
    no navigation list, only a thin toolbar with the Prototype menu, and that screen fills the rest of the window \
    (`app-main` without padding, full height, no page scroll). `App.register` accepts `embedded: true`. \
    `App.renderScreen(id, extra)` renders a registered screen into a new element and returns it, always an element \
    (a string returned by `render` is wrapped): `ctx` is the one of a routed screen with `params: {}`, `query: {}` and \
    `embedded: true` plus the keys of `extra`. It works before and without `App.start()`, never throws, and returns \
    a panel saying that the widget is still being built, or failed, when the screen is not registered or its `render` \
    throws. Visiting the route of an embedded screen shows it alone in `app-main` through the same call. \
    `App.modal({title, body, actions})` accepts an element or an HTML string as `body`.
    """

    static func shellSystem(language: String, widgets: Bool = false) -> String {
        craft + """


        You write the markup and the script of the prototype's shell: the files every screen builds on. \
        The data backend (data.js), the stylesheet (styles.css) and the screens are written at the same \
        time by other engineers, using only what you document, so the API must be complete and exact. \
        \(dataContract) \(shellContract) Write only index.html and app.js — not styles.css, not data.js, \
        not any screen.
        Write these files:
        - index.html: `<div id="app"></div>`, `<link rel="stylesheet" href="styles.css">`, then the scripts `data.js` and \
        `app.js`, then the exact comment `<!--SCREENS-->` on its own line (the screen scripts are inserted there), then \
        `<script>App.start()</script>`. No inline styles or other scripts.
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
        plan are listed in `App.plan` (id, name, route) for the navigation. \(widgets ? embeddedShellContract + " " : "")Keep app.js under 60 KB.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly two files: index.html and app.js).\(language)
        """
    }

    static func stylesSystem(language: String, originals: Bool = false) -> String {
        if originals { return stylesBridgeSystem(language: language) }
        return craft + """


        You write styles.css, the design system of the prototype. The markup and script (index.html, app.js), the data \
        backend and the screens are written at the same time by other engineers, so the class names are fixed and you \
        must provide all of them. \(shellContract) Write only styles.css.
        styles.css holds the design tokens as CSS variables (colours, typography, spacing, radii, shadows), a reset, the \
        layout shell, and every class listed above in a light and a dark variant where the plan asks for one, plus \
        focus-visible and disabled states and a responsive layout down to a narrow window. Screens use these classes and \
        add only their own small rules through `App.addStyles`. Keep the file under 20 KB and write no JavaScript and no \
        HTML.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: styles.css).\(language)
        """
    }

    /// styles.css when the app's own stylesheets are loaded before it (BUG-050): only the bridge, not a design system.
    private static func stylesBridgeSystem(language: String) -> String {
        craft + """


        You write styles.css, the small bridge between the prototype's shell and the app's own stylesheets, which are \
        already copied into the prototype and loaded before styles.css. The markup and script (index.html, app.js), the \
        data backend and the screens are written at the same time by other engineers, so the class names are fixed. \
        \(shellContract) Write only styles.css.
        Do not write a design system and do not restyle anything the original stylesheets already style. Read their custom \
        properties, fonts and class names with your tools and write only what the original does not define for the \
        classes above: the layout shell (`app-header`, `app-nav`, `app-main`; a full-window `app-main` when the shell \
        has no navigation), toasts, skeleton loading, empty states, the Prototype menu and a modal frame that matches the \
        original's dialogs, each built from the original's own variables (`var(--…)`) so it blends in. Keep the file \
        under 8 KB and write no JavaScript and no HTML.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: styles.css).\(language)
        """
    }

    /// Code mode, when the app's own stylesheets were copied (BUG-050): what the writers must know about them.
    static func originalStylesNote(_ styles: [String]) -> String {
        guard !styles.isEmpty else { return "" }
        return "The original stylesheets are already copied into the prototype unchanged and index.html links them before styles.css " +
            "(project paths: \(styles.joined(separator: ", "))). Do not copy, restate or restyle them; read them with your tools and " +
            "use their class names, custom properties and fonts in the markup. styles.css only adds what they lack for the " +
            "prototype's own controls (the Prototype menu, toasts, skeletons, the shell around the screens), and is short."
    }

    static func foundationPrompt(plan: String, failure: String?, mode: PrototypeFiles.Mode = .requirements,
                                 originalStyles: [String] = []) -> String {
        var out = "The plan of the prototype:\n\(plan)"
        if mode == .code {
            out += "\n\nThis prototype reconstructs an existing interface; the plan's `evidence` lists its source files. Read the " +
                "stylesheets, layout templates and navigation among them with your tools and reproduce the original design " +
                "tokens (colours, fonts, spacing, radii), shell layout and navigation instead of inventing a design system. " +
                "The entities and the seed data mirror what the code renders; what the original gets from a backend or " +
                "native APIs is simulated. " + componentRule
            let note = originalStylesNote(originalStyles)
            if !note.isEmpty { out += "\n\n" + note }
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
        with a name starting with your screen id. Screen-specific CSS goes through `App.addStyles`. `App.load(fn)` returns \
        a container that shows a loading indicator and then holds what `fn` returns: return the content to show (an \
        element or an HTML string), never the container that `App.load` returned or an element that already contains \
        it, or the screen stays blank. Do not edit other files and do not change global behaviour.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: path and full content).\(language)
        """
    }

    /// A widget or modal of a docked window or a dialog flow: a screen a host lays out, not a page (BUG-050).
    static func isModal(_ screen: PlannedScreen) -> Bool { screen.route.hasPrefix("/modals/") }

    /// The effort of a screen run: a widget, a modal or a host is written from whole source files, so it gets more than a page.
    static func screenEffort(_ screen: PlannedScreen) -> String { screen.embedded || !screen.hosts.isEmpty ? "medium" : "low" }

    static func screenPrompt(plan: String, screen: PlannedScreen, foundation: [PrototypeFiles.File], failure: String?,
                             mode: PrototypeFiles.Mode = .requirements, originalStyles: [String] = [],
                             hosted: [PlannedScreen] = []) -> String {
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
            let note = originalStylesNote(originalStyles)
            if !note.isEmpty { out += note + "\n\n" }
            out += componentRule
            if !screen.components.isEmpty {
                out += "\nThe component files of this screen, as the plan names them:\n"
                for path in screen.components { out += "- \(path)\n" }
            }
            if screen.embedded {
                let kind = isModal(screen) ? "modal" : "widget"
                out += "\n\nThis screen is a \(kind) rendered inside another screen (`App.renderScreen('\(screen.id)')` in the host's " +
                    "\(isModal(screen) ? "dialog" : "panel")), not a page: register it with `embedded: true`, add no page header, no outer " +
                    "padding and no navigation, let it fill its container (height 100%, scrolling inside itself) and read `ctx.embedded`. " +
                    "Read the whole source file with your tools, not an excerpt, and every file of the same \(kind) that it imports " +
                    "(subcomponents, hooks, domain helpers, constants): reproduce every control, column, tab, toolbar, state, label and " +
                    "number format they define. Keep the data it needs in `DB` functions named with your screen id. Do not shorten it " +
                    "to a sample."
            }
            if !hosted.isEmpty {
                out += "\n\nThis screen is the HOST of the window. It lays out these screens, which other engineers write at the same " +
                    "time, by calling `App.renderScreen(id)` for each and placing the returned element in the panel, tab or dialog " +
                    "where the original puts it:\n"
                for item in hosted { out += "- \(item.id) — \(item.name) (\(item.route))\n" }
                out += "Reproduce the original arrangement as its layout code defines it (read that code with your tools: toolbar, " +
                    "default panel layout and sizes, tab groups, which widgets share a tab strip, what is visible at start). A " +
                    "docking library of the original is not available in the prototype: build the layout with CSS grid or flex and a " +
                    "small tab strip, using the original class names and the loaded stylesheets. Do not re-implement a widget or copy " +
                    "its markup. The screens under `/modals/` are opened with `App.modal({title, body: App.renderScreen(id)})` from " +
                    "the control that opens them in the original (toolbar button, menu item, double click); do not place them in " +
                    "the layout. The host registers with `embedded: false`, and the shell shows it at start."
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
        - `remaining`: for a request that needs changes in more than three files (translating, renaming or restyling \
        the whole prototype, for example), make no change yourself and list here the path of every file the request \
        needs, relative to the prototype folder. Each listed file is then revised by a run of its own, so you do not \
        need to read or rewrite them. Leave it empty for any other request.
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
                             mode: PrototypeFiles.Mode = .requirements, sources: [String] = [],
                             priorEmpty: Bool = false) -> String {
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
            if priorEmpty {
                out += "\n\nYour previous answer was empty: \(priorFailure)"
            } else {
                out += "\n\nYour previous answer could not be applied:\n\(priorFailure)\nAnswer again with edits whose `find` text matches the current files exactly once, or give whole files."
            }
        }
        out += "\n\nReviewer's request:\n\(instruction)"
        return out
    }

    /// The request of a run that revises one file of a prototype-wide change: the file is given whole, the other
    /// runs handle the other files. The run may read the rest of the prototype to keep the files consistent.
    static func sweepPrompt(instruction: String, siteRelative: String, file: PrototypeFiles.File, priorFailure: String?) -> String {
        var out = "The prototype lives in `\(siteRelative)/` (relative to the project root). The reviewer's request applies to the whole " +
            "prototype; this run revises one file of it, `\(file.path)`, and other runs revise the other files. Change this file only. " +
            "If the request does not affect it, leave `files`, `edits` and `delete` empty. Leave `remaining` empty.\n\n"
        out += "Change only what the request asks for. Keep identifiers, object keys, route names, element ids, class names and every " +
            "value that another file reads or compares with exactly as they are, so the files stay consistent with each other; read the " +
            "other files of the prototype with your tools when you need to check how something in this file is used. When many places " +
            "of the file change, answer with the whole new file in `files` (path `\(file.path)`); otherwise use `edits`.\n\n"
        out += "=== \(file.path) ===\n\(file.content)\n"
        if let priorFailure {
            out += "\n\nYour previous answer could not be applied:\n\(priorFailure)\nAnswer again with edits whose `find` text matches the file exactly once, or give the whole file."
        }
        out += "\n\nReviewer's request:\n\(instruction)"
        return out
    }

    /// The paths a revise answer left in `remaining` that name a file of the prototype, in the order given and
    /// without repeats. A path may carry the prototype folder as the prompt names it; a file the answer
    /// changed itself (`touched`) is not listed again, and a path that is not a file of the prototype is dropped.
    static func sweepTargets(_ raw: Any?, siteRelative: String, existing: Set<String>, touched: Set<String>) -> [String] {
        var out: [String] = []
        for item in (raw as? [Any] ?? []).compactMap({ $0 as? String }) {
            var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix(siteRelative + "/") { text = String(text.dropFirst(siteRelative.count + 1)) }
            guard let path = try? PrototypeFiles.validate(path: text), existing.contains(path), !touched.contains(path),
                  !out.contains(path) else { continue }
            out.append(path)
        }
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
                             readLog: PrototypeEmbedded.ReadLog? = nil,
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
        let tracker = ProgressTracker(root: root, reading: reading, onRead: readLog.map { log in { log.add($0) } }, emit: stage)
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
        /// Code mode: behaviour the prototype cannot reproduce and the plan components that have no source
        /// file. Any mode: the screens dropped past `maxScreens`.
        var gaps: [String]
        var screens: [PlannedScreen]
        /// Code mode: the original stylesheets the interface loads, project-relative and in import order; empty otherwise.
        var styles: [String]
        /// Code mode: the ids of the themes the original switches between and the one it starts with; empty otherwise.
        var themes: [String] = []
        var defaultTheme = ""

        static let maxScreens = 10
        /// A reconstruction of a window of docked widgets needs one entry per widget (BUG-050).
        static let maxCodeScreens = 40

        /// In `.code` mode the planner's gaps are kept and each screen's components are kept only when
        /// `sourceExists` finds their file, the others becoming gaps, so no link is invented (REQ-007). In
        /// `.requirements` mode there is no original to fall short of or link to: gaps and components the
        /// planner filled in anyway are dropped.
        init(structured: Any?, mode: PrototypeFiles.Mode = .requirements, sourceExists: (String) -> Bool = { _ in true }) throws {
            guard let object = structured as? [String: Any],
                  let raw = object["screens"] as? [[String: Any]], !raw.isEmpty else {
                throw CLICompletion.Failure.invalidOutput(.claude, "the plan has no screens")
            }
            var seen = Set<String>()
            var screens: [PlannedScreen] = []
            var missing: [String] = []
            let limit = mode == .code ? Self.maxCodeScreens : Self.maxScreens
            var normalised = raw.prefix(limit).map { $0 }
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
                if mode == .code {
                    for raw in item["components"] as? [String] ?? [] {
                        guard let path = PrototypeFiles.componentPath(raw), !components.contains(path) else { continue }
                        if sourceExists(path) {
                            components.append(path)
                        } else if !missing.contains(path) {
                            missing.append(path)
                        }
                    }
                }
                normalised[index]["components"] = components
                // Widgets and hosts exist in code mode only; a host's list is cut to the entries that exist, below.
                let embedded = mode == .code && item["embedded"] as? Bool == true
                normalised[index]["embedded"] = embedded
                screens.append(PlannedScreen(id: unique, name: name, route: item["route"] as? String ?? "/" + unique,
                                             purpose: item["purpose"] as? String ?? "", evidence: evidence, components: components,
                                             embedded: embedded, hosts: mode == .code ? (item["hosts"] as? [String] ?? []) : []))
            }
            let known = Set(screens.map(\.id))
            for index in screens.indices {
                var hosted: [String] = []
                for raw in screens[index].hosts {
                    let id = Self.slug(raw)
                    if known.contains(id), id != screens[index].id, !hosted.contains(id) { hosted.append(id) }
                }
                screens[index].hosts = hosted
                normalised[index]["hosts"] = hosted
            }
            // The planner's gaps belong to a reconstruction only; the writers see the same list as the manifest.
            let planned = mode == .code
                ? (object["gaps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                : []
            var plan = object
            plan["screens"] = normalised
            plan["gaps"] = planned
            var listed: [String] = []
            if mode == .code {
                for raw in object["styles"] as? [String] ?? [] {
                    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !path.isEmpty, !listed.contains(path) { listed.append(path) }
                }
            }
            plan["styles"] = listed
            styles = listed
            var themeIDs: [String] = []
            if mode == .code {
                for raw in object["themes"] as? [String] ?? [] {
                    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !id.isEmpty, !themeIDs.contains(id) { themeIDs.append(id) }
                }
            }
            themes = themeIDs
            defaultTheme = mode == .code ? (object["defaultTheme"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : ""
            plan["themes"] = themeIDs
            plan["defaultTheme"] = defaultTheme
            let data = try JSONSerialization.data(withJSONObject: plan, options: [.prettyPrinted, .sortedKeys])
            json = String(decoding: data, as: UTF8.self)
            title = object["title"] as? String ?? "Prototype"
            summary = object["summary"] as? String ?? ""
            assumptions = object["assumptions"] as? [String] ?? []
            var gaps = planned + missing.map { "Component \($0) named by the plan was not found in the sources" }
            if raw.count > limit {
                // A plan past the cap is cut without asking; the reviewer must know what is missing.
                let dropped = raw.dropFirst(limit).enumerated().map { pair -> String in
                    pair.element["name"] as? String ?? "screen \(limit + pair.offset + 1)"
                }
                gaps.append("The plan listed \(raw.count) screens and only the first \(limit) are built; not built: " +
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
        /// Known reconstruction gaps: code mode only, where they also name the components dropped for lack of a
        /// source file; a plan cut at `Plan.maxScreens` adds one in any mode.
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
        let steps = mode == .code ? 4 : 3

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
            system = codePlanSystem(language: language)
            prompt = codePlanPrompt(brief: brief, sources: sources, scope: codeScope, inventory: inventory)
        } else {
            system = planSystem(language: language)
            prompt = planPrompt(brief: brief, sources: sources)
        }
        let planned = try await call(root: root, system: system, prompt: prompt, schema: planSchema, label: "prototype:plan",
                                     reading: reading, record: record, stage: scoped(stage, label: nil, status: true))
        let plan = try Plan(structured: planned.structured, mode: mode, sourceExists: { PrototypeFiles.isSourceFile(root: root, path: $0) })
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

        stage(.phase("Step 2 of \(steps) · Building the shell, styles and sample data (three parts at once)"))
        stage(.status("Writing the shell, the styles and the data"))
        let hasWidgets = mode == .code && plan.screens.contains(where: \.embedded)
        async let shell = foundationPart(root: root, plan: plan, system: shellSystem(language: language, widgets: hasWidgets), label: "shell",
                                         allowed: ["index.html", "app.js"], required: ["index.html", "app.js"],
                                         mode: mode, originalStyles: originalStyles, record: record,
                                         stage: scoped(stage, label: "Shell", status: false))
        async let styles = foundationPart(root: root, plan: plan, system: stylesSystem(language: language, originals: !originalStyles.isEmpty), label: "styles",
                                          allowed: ["styles.css"], required: ["styles.css"],
                                          mode: mode, originalStyles: originalStyles, record: record,
                                          stage: scoped(stage, label: "Styles", status: false))
        async let data = foundationPart(root: root, plan: plan, system: dataSystem(language: language), label: "data",
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
    private static func foundationPart(root: URL, plan: Plan, system: String, label: String, allowed: Set<String>,
                                       required: [String], mode: PrototypeFiles.Mode, originalStyles: [String] = [],
                                       record: @escaping Record, stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: system,
                                        prompt: foundationPrompt(plan: plan.json, failure: failure, mode: mode,
                                                                 originalStyles: originalStyles),
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
                                    language: String, mode: PrototypeFiles.Mode, originalStyles: [String] = [],
                                    readLog: PrototypeEmbedded.ReadLog? = nil,
                                    record: @escaping Record, stage: @escaping Stage) async throws {
        let hosted = screen.hosts.compactMap { id in plan.screens.first { $0.id == id } }
        let wanted = "screens/\(screen.id).js"
        var failure: String?
        var effort = mode == .code ? screenEffort(screen) : "low"
        for attempt in 0..<2 {
            let result = try await call(root: root, system: screenSystem(language: language),
                                        prompt: screenPrompt(plan: plan.json, screen: screen, foundation: foundation,
                                                             failure: failure, mode: mode, originalStyles: originalStyles, hosted: hosted),
                                        schema: filesSchema, label: "prototype:screen:\(screen.id)",
                                        effort: effort, readLog: readLog,
                                        record: record, stage: stage)
            let files = PrototypeFiles.change(from: result.structured).files
            guard let file = files.first(where: { (try? PrototypeFiles.validate(path: $0.path)) == wanted }) else {
                failure = "The answer must contain exactly one file, \(wanted)."
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                continue
            }
            // A comment that says "not implemented", or a file that never registers the screen, is not an answer (BUG-053):
            // the second try gets the reason and more effort, and a screen that is still a stub is reported as failed.
            if let problem = PrototypeAudit.stubProblem(id: screen.id, content: file.content) {
                failure = "\(wanted) is not a finished screen: \(problem). Write the complete screen with everything the plan lists for it."
                effort = "medium"
                if attempt == 1 { throw PrototypeFiles.Failure.edits([failure!]) }
                stage(.log("\(wanted) was a stub (\(problem)); asking again"))
                continue
            }
            stage(.log("Saving \(wanted)"))
            try PrototypeFiles.apply(PrototypeFiles.Change(files: [PrototypeFiles.File(path: wanted, content: file.content)]), to: site)
            return
        }
    }

    /// The isolated view of one component, `components/<slug>.html`; the answer is tried twice (code mode, REQ-007).
    private static func buildComponent(root: URL, site: URL, plan: Plan, component: PrototypeFiles.Component,
                                       foundation: [PrototypeFiles.File], language: String,
                                       readLog: PrototypeEmbedded.ReadLog? = nil, record: @escaping Record,
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
                                        readLog: readLog, record: record, stage: stage)
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
    ///
    /// A request that needs many files (translating the whole prototype, for example) cannot be answered in one run:
    /// the first run then lists the files in `remaining` and changes nothing itself, and each file is revised by a
    /// read-only run of its own, `concurrency` at a time, as the build writes its screens. Every run's change is checked
    /// in memory first; one `apply` at the end writes them all, so a cancelled or failed sweep leaves the site as it
    /// was. A file whose run failed twice is reported in the summary and stays as it is; if no file could be revised
    /// the request fails. `sweep` false (the fix rounds after a preview error) never fans out.
    ///
    /// An answer with no change that explains itself in `summary` is the assistant's reply, not an error: nothing is
    /// written (`written` is empty) and the summary says so.
    static func revise(root: URL, folder: URL, instruction: String, pick: Pick?, attachments: [(url: URL, note: String)] = [],
                       runtimeErrors: [String], language: String, mode: PrototypeFiles.Mode = .requirements, sources: [String] = [],
                       sweep: Bool = true, concurrency: Int = 4,
                       record: @escaping Record, stage: @escaping Stage) async throws -> Outcome {
        let site = PrototypeFiles.site(of: folder)
        let relative = site.path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        var failure: String?
        var emptyAnswer = false
        for attempt in 0..<2 {
            let current = PrototypeFiles.read(site: site)
            let result = try await call(root: root, system: reviseSystem(language: language),
                                        prompt: revisePrompt(instruction: instruction, pick: pick, siteRelative: relative,
                                                             files: current, runtimeErrors: runtimeErrors,
                                                             priorFailure: failure,
                                                             attachments: attachments.map { Attachment(path: relativePath($0.url, root: root), note: $0.note) },
                                                             mode: mode, sources: sources, priorEmpty: emptyAnswer),
                                        schema: reviseSchema, label: "prototype:revise", images: attachments.map(\.url),
                                        record: record, stage: stage)
            let object = result.structured as? [String: Any] ?? [:]
            let change = PrototypeFiles.change(from: result.structured)
            let summary = (object["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = Dictionary(uniqueKeysWithValues: current.map { ($0.path, $0.content) })
            var touched = Set<String>()
            for path in change.files.map(\.path) + change.edits.map(\.path) + change.deletes {
                if let normal = try? PrototypeFiles.validate(path: path) { touched.insert(normal) }
            }
            let targets = sweep
                ? Array(sweepTargets(object["remaining"], siteRelative: relative, existing: Set(existing.keys), touched: touched)
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
                let changes = SweepChanges()
                var failed: [(path: String, problem: String)] = []
                var finished = 0
                try await sideBySide(targets, concurrency: concurrency, work: { path in
                    let one = try await reviseFile(root: root, siteRelative: relative,
                                                   file: PrototypeFiles.File(path: path, content: existing[path] ?? ""),
                                                   instruction: instruction, language: language, record: record,
                                                   stage: scoped(stage, label: path, status: false))
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
                                   record: @escaping Record, stage: @escaping Stage) async throws -> PrototypeFiles.Change {
        var failure: String?
        for attempt in 0..<2 {
            let result = try await call(root: root, system: reviseSystem(language: language),
                                        prompt: sweepPrompt(instruction: instruction, siteRelative: siteRelative, file: file, priorFailure: failure),
                                        schema: reviseSchema, label: "prototype:revise:\(file.path)", effort: "low", record: record, stage: stage)
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
