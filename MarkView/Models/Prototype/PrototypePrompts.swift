import CoreGraphics
import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif
/// Every prompt of the prototype assistant: the system and user texts of the plan, the foundation, the screens, the components, the
/// revisions and the specification. They only build text from their arguments; the runs that send them are in `PrototypeAI`.
enum PrototypePrompts {
    typealias PlannedScreen = PrototypeAI.PlannedScreen
    typealias Pick = PrototypeAI.Pick
    typealias Target = PrototypeAI.Target
    typealias CodeScope = PrototypeAI.CodeScope
    typealias ScreenUpdate = PrototypeAI.ScreenUpdate
    typealias Attachment = PrototypeAI.Attachment

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
        from its settings code; empty when unknown or without themes), and `screens`: at most \(PrototypePlan.maxCodeScreens), each \
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

    /// Code mode: a reconstruction keeps the labels of the original, so nothing is translated (BUG-052). The summary,
    /// assumptions and gaps are saved in the project's files, so they are English. The global output language does not
    /// replace this rule: it is meant for explanations and documents, and with it set to Russian every label of an
    /// English application came out in Russian (BUG-057).
    static let sourceLanguageRule = "\n\nLanguage: copy every visible label, message, tooltip and placeholder from the source " +
        "exactly as the source writes it, in the source's own language; never translate them. Text the source does not provide " +
        "(sample data, the empty and error states you have to write) is in the language of the source's interface, English when " +
        "the source has no visible text. Set the `lang` attribute of index.html to that language. Write `summary`, `assumptions`, " +
        "`gaps` and the purpose of each screen in English. A request of the reviewer that asks for another language overrides all of this."

    /// The language part of every prompt of a run: the source's own language for a prototype made from code, whatever
    /// the output language setting says (BUG-057); for requirements the explicit output language the person chose, or
    /// nothing (the documents' language).
    static func languageNote(explicit: String, mode: PrototypeFiles.Mode) -> String {
        mode == .code ? sourceLanguageRule : explicit
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
    another writes styles.css, and the screens are written afterwards. \(classContract) index.html and app.js use \
    exactly these class names and define no styles of their own beyond `App.addStyles`.
    """

    /// The classes styles.css provides, for every shell.
    private static let classContract = """
    styles.css provides the design \
    system — tokens as CSS variables and classes for the layout shell (`app-header`, `app-nav`, \
    `app-main`), buttons (`btn`, `btn-primary`, `btn-ghost`, `btn-danger`), cards (`card`, \
    `card-header`, `card-body`), tables (`table`), forms and fields with error text (`form`, `field`, \
    `input`, `select`, `field-error`), badges (`badge`, with status modifiers), tabs (`tabs`, `tab`, \
    `is-active`), toolbars (`toolbar`), modals (`modal`, `modal-card`, `modal-actions`), toasts \
    (`toast`, with kind modifiers), skeleton loading (`skeleton`), empty states (`empty`) and \
    pagination (`pagination`).
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
    The box that holds a widget in a host (a panel body) is a flex or grid cell with `min-height:0` inside a box that has \
    a definite height, and the element `App.renderScreen` returns fills it: a widget whose own CSS sizes its body with \
    `flex:1` or `height:100%` collapses to 0 px, and its content is cut off, inside a box of automatic height. \
    `App.modal({title, body, actions})` accepts an element or an HTML string as `body`.
    """

    /// `ownsStructure`: MarkView writes the page structure (a prototype from code, BUG-060), so the writers are told it is not theirs.
    static func shellSystem(language: String, widgets: Bool = false, ownsStructure: Bool = false) -> String {
        craft + """


        You write the markup and the script of the prototype's shell: the files every screen builds on. \
        The data backend (data.js), the stylesheet (styles.css) and the screens are written at the same \
        time by other engineers, using only what you document, so the API must be complete and exact. \
        \(dataContract) \(shellContract) \(ownsStructure ? PrototypeShellStructure.contract + " " : "")Write only index.html and app.js — not styles.css, not data.js, \
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

    static func stylesSystem(language: String, originals: Bool = false, ownsStructure: Bool = false) -> String {
        if originals { return stylesBridgeSystem(language: language, ownsStructure: ownsStructure) }
        return craft + """


        You write styles.css, the design system of the prototype. The markup and script (index.html, app.js), the data \
        backend and the screens are written at the same time by other engineers, so the class names are fixed and you \
        must provide all of them. \(shellContract) \(ownsStructure ? PrototypeShellStructure.contract + " " : "")Write only styles.css.
        styles.css holds the design tokens as CSS variables (colours, typography, spacing, radii, shadows), a reset, the \
        layout shell, and every class listed above in a light and a dark variant where the plan asks for one, plus \
        focus-visible and disabled states and a responsive layout down to a narrow window. Screens use these classes and \
        add only their own small rules through `App.addStyles`. Keep the file under 20 KB and write no JavaScript and no \
        HTML.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: styles.css).\(language)
        """
    }

    /// Requirements mode (BUG-056): styles.css for the shell MarkView writes itself, while the seed and the screens are written.
    static func runtimeStylesSystem(language: String) -> String {
        craft + """


        You write styles.css, the design system of the prototype. The shell (index.html, app.js) and the data runtime are \
        MarkView's own and already exist; the sample data and the screens are written at the same time by other engineers, \
        so the class names are fixed and you must provide all of them. \(classContract) The shell builds this markup:
        \(PrototypeRuntime.shellMarkup)
        styles.css holds the design tokens as CSS variables (colours, typography, spacing, radii, shadows), a reset, the \
        shell above, and every class listed in a light and a dark variant where the plan asks for one, plus focus-visible \
        and disabled states, status modifiers for `badge` that fit the plan's statuses, and a responsive layout down to a \
        narrow window. Screens use these classes and add only their own small rules through `App.addStyles`. Keep the \
        file under 20 KB and write no JavaScript and no HTML. Do not read any file: the plan is all you need.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: styles.css).\(language)
        """
    }

    /// Requirements mode (BUG-056): seed.js, the records the built-in `DB` starts with.
    static func seedSystem(language: String) -> String {
        craft + """


        You write seed.js, the sample records of the prototype. The data runtime (data.js, the global `DB`) is MarkView's \
        own and already exists; the screens are written at the same time by other engineers who know only the plan, so \
        every name must be the plan's exactly.
        seed.js is one statement: `DB.seed({ "<entity name>": [ { … }, … ], … });` with every entity of the plan under its \
        `name` exactly. Each record has a short string `id` (such as "t-104") and the plan's fields, each named as the plan \
        writes it before any type or note (`priority (Low/Medium/High)` gives `priority`). A field that refers to another \
        record holds that record's `id`. Write 5 to 8 records per entity: realistic and varied, long and short values, \
        every status and option of the plan represented, consistent references. Dates are `DB.days(n)` (an ISO date-time \
        n days from today, negative for the past) or `DB.days(n, hour)`, never fixed dates. Only data and `DB.days` calls: \
        no functions, no other statements. Keep the file under 30 KB. Do not read any file: the plan is all you need.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: seed.js).\(language)
        """
    }

    /// Requirements mode (BUG-056): what a screen writer must know about the parts written at the same time.
    static let runtimeScreenNote = """
    app.js and data.js are MarkView's runtime; their documented API is above and is all there is. styles.css (the classes \
    the app.js header lists) and seed.js (the records: every entity of the plan under its exact name, fields named exactly \
    as the plan writes them, string ids, references by id) are written at the same time as your screen: do not look for \
    them, rely on the plan's names, and render a missing field or reference gracefully. The domain rules your screen \
    needs (validation, status changes, totals, permissions with `App.allow`) belong in your own file. Wrap every list and \
    detail load in `App.load`, so loading and the forced error state work, and show `App.empty` for an empty result.
    """

    /// styles.css when the app's own stylesheets are loaded before it (BUG-050): only the bridge, not a design system.
    private static func stylesBridgeSystem(language: String, ownsStructure: Bool) -> String {
        craft + """


        You write styles.css, the small bridge between the prototype's shell and the app's own stylesheets, which are \
        already copied into the prototype and loaded before styles.css. The markup and script (index.html, app.js), the \
        data backend and the screens are written at the same time by other engineers, so the class names are fixed. \
        \(shellContract) \(ownsStructure ? PrototypeShellStructure.contract + " " : "")Write only styles.css.
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
        it, or the screen stays blank. Do not clear or replace the children of the element the container is appended to \
        (`root.replaceChildren(...)`, `root.innerHTML = ...`), in the callback or in a function it calls: that removes the \
        container from the page and the screen stays blank. Build the content in a new element and return it. \
        Do not edit other files and do not change global behaviour.
        Answer with the JSON object: `summary` (one sentence) and `files` (exactly one file: path and full content).\(language)
        """
    }

    /// A widget or modal of a docked window or a dialog flow: a screen a host lays out, not a page (BUG-050).
    static func isModal(_ screen: PlannedScreen) -> Bool { screen.route.hasPrefix("/modals/") }

    /// Evidence files of a widget, modal or host that add up to this many bytes are large enough to need the strongest effort.
    static let largeSourceBytes = 40_000

    /// The effort of a screen run: a widget, a modal or a host is written from whole source files, so it gets more than a page,
    /// and one whose evidence files add up to `largeSourceBytes` or more gets the most: with "medium" the OptionDesk widget (84 KB)
    /// came back as a 9 KB look-alike (BUG-059).
    static func screenEffort(_ screen: PlannedScreen, sourceBytes: Int = 0) -> String {
        guard screen.embedded || !screen.hosts.isEmpty else { return "low" }
        return sourceBytes >= largeSourceBytes ? "high" : "medium"
    }

    /// The size of a screen's evidence files that exist under `root`; what is missing counts as nothing.
    static func evidenceBytes(_ screen: PlannedScreen, root: URL) -> Int {
        screen.evidence.reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            return total + ((attributes?[.size] as? Int) ?? 0)
        }
    }


    static func screenPrompt(plan: String, screen: PlannedScreen, foundation: [PrototypeFiles.File], failure: String?,
                             mode: PrototypeFiles.Mode = .requirements, originalStyles: [String] = [],
                             hosted: [PlannedScreen] = [], update: ScreenUpdate? = nil, note: String? = nil) -> String {
        var out = "The plan of the whole prototype:\n\(plan)\n\nThe foundation files (the API you build on):\n"
        for file in foundation { out += "\n=== \(file.path) ===\n\(file.content)\n" }
        if let note { out += "\n\(note)\n" }
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
                    "where the original puts it."
                // A separate statement: a long chain of + makes the Swift 6.0 type checker give up.
                out += " Give every panel that receives a widget a definite height (a grid or flex cell with `min-height:0` inside a " +
                    "container that has a height) and let the returned element fill it (`height:100%`): a widget whose original CSS " +
                    "sizes its body with `flex:1` collapses to 0 px, and its content is cut off, inside a panel of automatic height:\n"
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
        if mode == .code, let update {
            out += "\n\nThis is an UPDATE of a screen that already exists: the code changed after the prototype was last synced. "
            if !update.changed.isEmpty {
                out += "These source files changed since then; read them first:\n"
                for path in update.changed { out += "- \(path)\n" }
            }
            if !update.removed.isEmpty {
                out += "These source files no longer exist; drop what depended only on them:\n"
                for path in update.removed { out += "- \(path)\n" }
            }
            out += "The current prototype screen is `\(update.current)`: read it, and keep everything the changes do not touch as it is. " +
                "Write the complete screen again, not a patch. The shell, the styles and the sample data (`data.js`, the `DB` object) are NOT " +
                "rewritten by this update: use what they already provide, and when the changed code needs sample data or a field that `DB` " +
                "does not have, define it inside this screen's script instead of relying on a change to `data.js`."
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


    static func revisePrompt(instruction: String, pick: Pick?, siteRelative: String, files: [PrototypeFiles.File],
                             runtimeErrors: [String], priorFailure: String?, attachments: [Attachment] = [],
                             mode: PrototypeFiles.Mode = .requirements, sources: [String] = [],
                             priorEmpty: Bool = false, target: Target? = nil, fanOut: Bool = true) -> String {
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
        if let target {
            out += "\n\n" + targetParagraph(target, siteRelative: siteRelative, mode: mode)
        }
        // A request that is not split across runs cannot be declined into `remaining`: nothing would ever revise those files (BUG-062).
        if !fanOut {
            out += "\n\nThis request is answered in this one run: make every change it needs in this answer, whatever the number of " +
                "files, and leave `remaining` empty."
        }
        out += "\n\nReviewer's request:\n\(instruction)"
        return out
    }

    /// The scope of a request the reviewer aimed at a screen or a source component: the target, the files that implement it, and the
    /// rule that the change stays inside it unless the request says otherwise (REQ-008).
    static func targetParagraph(_ target: Target, siteRelative: String, mode: PrototypeFiles.Mode) -> String {
        switch target {
        case .screen(let id, let name):
            return "The reviewer aimed this request at one screen: \"\(name)\", implemented in `\(siteRelative)/screens/\(id).js`. " +
                "Limit the change to that screen's script. Touch another file only when the request cannot be done without a shared " +
                "change (the shell, the styles or the sample data), and say which file and why in your summary; do not change other " +
                "screens unless the request says so."
        case .component(let path, let label, let page, let screens):
            var out = "The reviewer aimed this request at one source component: \"\(label)\" (`\(path)`). "
            if mode == .code {
                out += "Its source file `\(path)` is what the prototype reproduces; read it when the request touches its look or behaviour. "
            }
            out += "Every element that reproduces it carries `data-mv-component=\"\(path)\"`"
            if !screens.isEmpty {
                out += " in the screens \(screens.map { "\"\($0)\"" }.joined(separator: ", "))"
            }
            if let page { out += ", and its isolated view is `\(siteRelative)/\(page)`" }
            out += ". Change those elements, wherever they appear, and nothing else unless the request says otherwise; if a shared file " +
                "must change, say which one and why in your summary."
            return out
        }
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
}
