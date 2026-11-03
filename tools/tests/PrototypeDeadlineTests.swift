import CryptoKit
import Foundation

@main enum PrototypeDeadlineTests {
    static func main() async throws {
        try await requirementsMode()
        try await codeMode()
        try await widgetsMode()
        try await sweepMode()
        try await stubMode()
    }

    /// A screen that comes back as a stub (BUG-053): a comment-only file is not saved; the second try is told why and
    /// runs at medium effort; a screen that is still a stub is reported as failed and no file is written for it.
    static func stubMode() async throws {
        let fm = FileManager.default
        func build(_ variant: String) async throws -> (PrototypeAI.Built, URL) {
            await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: variant)
            let root = fm.temporaryDirectory.appendingPathComponent("mv-prototype-stub-" + UUID().uuidString)
            let folder = PrototypeFiles.folder(root: root, slug: "fixture")
            try fm.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
            let built = try await PrototypeAI.build(root: root, folder: folder, brief: "One screen", sources: [], language: "",
                                                    record: { _ in }, stage: { _ in })
            return (built, PrototypeFiles.site(of: folder).appendingPathComponent("screens/home.js"))
        }
        let once = try await build("stub-once")
        defer { try? fm.removeItem(at: once.1.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        precondition(once.0.screens == ["Home"] && once.0.failed.isEmpty, "the retry produced the screen: \(once.0.screens) \(once.0.failed)")
        precondition((try? String(contentsOf: once.1, encoding: .utf8))?.contains("App.register") == true, "the real screen was saved")
        let calls = await CLICompletion.audit.calls["prototype:screen:home"]
        let prompt = await CLICompletion.audit.prompts["prototype:screen:home"] ?? ""
        let effort = await CLICompletion.audit.efforts["prototype:screen:home"]
        precondition(calls == 2, "a stub is asked again once: \(String(describing: calls))")
        precondition(prompt.contains("is not a finished screen") && prompt.contains("the file has no code, only comments or nothing"), "the retry says why: \(prompt.suffix(300))")
        precondition(effort == "medium", "the retry runs at medium effort: \(String(describing: effort))")

        let always = try await build("stub-always")
        defer { try? fm.removeItem(at: always.1.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        precondition(always.0.screens.isEmpty && always.0.failed == ["Home"], "a screen that stays a stub is failed: \(always.0.screens) \(always.0.failed)")
        precondition(!fm.fileExists(atPath: always.1.path), "no file is written for a stub")
        let again = await CLICompletion.audit.calls["prototype:screen:home"]
        precondition(again == 2, "two tries, no more: \(String(describing: again))")
        print("Prototype stub screens: a comment-only screen is asked again once with the reason, a stub that stays is reported as failed and not saved.")
    }

    /// A request for many files (BUG-051): the first run lists them, each file is revised by a run of its own, and one
    /// write at the end applies them all. Partial failure, retry, an explanation without a change, silence, a prototype
    /// fix round and cancellation are each checked on a five-file site.
    static func sweepMode() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mv-prototype-sweep-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let folder = PrototypeFiles.folder(root: root, slug: "fixture")
        let site = PrototypeFiles.site(of: folder)
        let original = ["index.html": "<h1>Fixture title</h1>\n<!--SCREENS-->\n", "app.js": "window.App = {};",
                        "data.js": "window.DB = {};", "styles.css": "body { color: black; }",
                        "screens/home.js": "App.register({id: 'home'});"]
        func reset() throws {
            try? fm.removeItem(at: root)
            for (path, text) in original {
                let url = site.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            // The copied originals are never read, revised or listed.
            let kept = site.appendingPathComponent("original/theme.css")
            try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "a { color: red; }".write(to: kept, atomically: true, encoding: .utf8)
        }
        func files() -> [String: String] { Dictionary(uniqueKeysWithValues: PrototypeFiles.read(site: site).map { ($0.path, $0.content) }) }
        let stages = Phases()
        let events: PrototypeAI.Stage = { event in if case .log(let text) = event { stages.add(text) } else if case .step(let text) = event { stages.add(text) } }
        func revise(sweep: Bool = true, concurrency: Int = 2) async throws -> PrototypeAI.Outcome {
            try await PrototypeAI.revise(root: root, folder: folder, instruction: "Convert all preview to English", pick: nil,
                                         runtimeErrors: [], language: "", sweep: sweep, concurrency: concurrency,
                                         record: { _ in }, stage: events)
        }

        // 1. Five listed files: three revised (one after a retry), one needs nothing, one fails; the rest of the site is as it was.
        await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: "sweep")
        try reset()
        let outcome = try await revise()
        precondition(outcome.written == ["data.js", "index.html", "styles.css"], "written: \(outcome.written)")
        precondition(outcome.summary.hasPrefix("Listed the files.\n\nRevised 3 of 5 files; 1 needed no change; could not revise screens/home.js"),
                     "summary: \(outcome.summary)")
        let after = files()
        precondition(after["index.html"]?.contains("Titre du fixture") == true && after["index.html"]?.contains("WRONG") == false,
                     "a run owns its file: \(after["index.html"] ?? "")")
        precondition(after["styles.css"] == "body { color: navy; }" && after["data.js"] == "window.DB = { ok: 1 };")
        precondition(after["app.js"] == original["app.js"] && after["screens/home.js"] == original["screens/home.js"],
                     "a delete or a failed run left a file changed")
        let theme = try String(contentsOf: site.appendingPathComponent("original/theme.css"), encoding: .utf8)
        precondition(theme == "a { color: red; }")
        let labels = await CLICompletion.audit.labels
        precondition(labels == ["prototype:revise", "prototype:revise:index.html", "prototype:revise:app.js", "prototype:revise:data.js",
                                "prototype:revise:styles.css", "prototype:revise:screens/home.js"],
                     "one run per listed file, the ghost, the repeat and the outside path dropped: \(labels.sorted())")
        let filePrompt = await CLICompletion.audit.prompts["prototype:revise:index.html"] ?? ""
        precondition(filePrompt.contains("revises one file of it, `index.html`") && filePrompt.contains("=== index.html ===\n<h1>Fixture title</h1>")
                     && filePrompt.hasSuffix("Reviewer's request:\nConvert all preview to English"), "the file run is given its file whole")
        let efforts = await CLICompletion.audit.efforts
        precondition(efforts["prototype:revise:index.html"] == "low", "file runs are low effort")
        precondition(stages.all.contains("Could not revise screens/home.js: fixture: home cannot be revised")
                     && stages.all.contains("No change needed in app.js") && stages.all.contains("Revised data.js"), "progress lines: \(stages.all)")

        // 2. A fix round never fans out: the same listing is only an explanation, nothing is written.
        await CLICompletion.audit.reset(); try reset()
        let fix = try await revise(sweep: false)
        precondition(fix.written.isEmpty && fix.summary == "Listed the files.\n\nNo files were changed." && files() == original, "fix round: \(fix.summary)")
        let fixLabels = await CLICompletion.audit.labels
        precondition(fixLabels == ["prototype:revise"], "a fix round starts no per-file run")

        // 3. Every file run fails: the request fails and the site is as it was.
        await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: "sweep-all-fail"); try reset()
        do {
            _ = try await revise()
            preconditionFailure("a sweep in which no file could be revised must fail")
        } catch let error as PrototypeFiles.Failure {
            precondition(error.localizedDescription.contains("index.html") && error.localizedDescription.contains("failed"), "\(error.localizedDescription)")
        }
        precondition(files()["index.html"] == original["index.html"] && files()["styles.css"] == original["styles.css"])

        // 4. An answer without a change that explains itself is a reply, not an error.
        await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: "explain"); try reset()
        let explained = try await revise()
        precondition(explained.written.isEmpty && explained.summary == "The prototype is already in English.\n\nNo files were changed.",
                     "\(explained.summary)")
        let explainLabels = await CLICompletion.audit.labels
        precondition(explainLabels == ["prototype:revise"])

        // 5. Silence is an error, and the second attempt says why it is asked again.
        await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: "silent"); try reset()
        do {
            _ = try await revise()
            preconditionFailure("an answer with no change and no summary must fail")
        } catch let error as PrototypeFiles.Failure {
            precondition(error.localizedDescription.contains("no change and no explanation"), "\(error.localizedDescription)")
        }
        let again = await CLICompletion.audit.prompts["prototype:revise"] ?? ""
        precondition(again.contains("Your previous answer was empty:") && !again.contains("could not be applied"), "retry text for an empty answer")

        // 6. Cancelling in the middle of a sweep writes nothing.
        await CLICompletion.audit.reset(); await CLICompletion.audit.set(variant: "sweep-slow"); try reset()
        let task = Task { try await revise() }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("a cancelled sweep must not finish")
        } catch is CancellationError {}
        precondition(files() == original, "a cancelled sweep changed the site")
        await CLICompletion.audit.set(variant: "")
        print("Prototype sweep: a request for many files is revised file by file (retry, partial failure, no change, cancel), written once; an explanation is a reply, silence an error; fix rounds never fan out.")
    }

    /// The original policy check: every stage runs without a wall-clock limit.
    static func requirementsMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-prototype-deadline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = PrototypeFiles.folder(root: root, slug: "fixture")
        try FileManager.default.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "One screen", sources: [], language: "",
            record: { _ in }, stage: { _ in })
        precondition(built.screens == ["Home"] && built.failed.isEmpty && built.gaps.isEmpty && built.components.isEmpty,
                     "requirements mode has no gaps or components, whatever the planner filled in: \(built.gaps)")
        let screen = PrototypeFiles.site(of: folder).appendingPathComponent("screens/home.js")
        precondition(FileManager.default.fileExists(atPath: screen.path))
        _ = try await PrototypeAI.revise(root: root, folder: folder, instruction: "Revise title", pick: nil,
            runtimeErrors: [], language: "", record: { _ in }, stage: { _ in })
        let contents = try String(contentsOf: PrototypeFiles.site(of: folder).appendingPathComponent("index.html"), encoding: .utf8)
        precondition(contents.contains("Revised fixture") && contents.contains("screens/home.js"))
        let manifest = PrototypeFiles.Manifest(title: "Fixture", slug: "fixture", brief: "", sources: [])
        let spec = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest,
            language: "", record: { _ in }, stage: { _ in })
        precondition(spec.contains("Fixture specification"))
        let labels = await CLICompletion.audit.labels
        precondition(labels == ["prototype:plan", "prototype:foundation:shell", "prototype:foundation:styles", "prototype:foundation:data",
                                "prototype:screen:home", "prototype:revise", "prototype:spec"])
        let planPrompt = await CLICompletion.audit.prompts["prototype:plan"] ?? ""
        precondition(planPrompt.contains("requirement sources") && !planPrompt.contains("Reconstruct"))
        print("Prototype deadline policy: plan, the three foundation parts, saved screen, revision and specification complete without wall-clock limits.")
    }

    /// Code mode (Previews from Existing Code): the build reads a fixture web app, carries its gaps and evidence
    /// through the prompts and the result, and leaves every file outside `docs/prototypes/` untouched (REQ-001).
    static func codeMode() async throws {
        await CLICompletion.audit.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-prototype-code-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func put(_ path: String, _ content: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("package.json", "{\"name\":\"fixture\",\"main\":\"main.js\",\"devDependencies\":{\"electron\":\"30.0.0\"}}")
        try put("main.js", "const { app } = require('electron'); app.whenReady();")
        try put("src/index.html", "<html><body><h1>Orders</h1><table id=\"orders\"></table><button id=\"export\">Export</button></body></html>")
        try put("src/app.js", "fetch('/api/orders'); document.getElementById('export').onclick = () => window.electron.saveFile();\n"
                 + String(repeating: "// filler line keeps this file above the 2 KB coverage threshold\n", count: 40))
        try put("src/styles.css", ":root { --accent: #0a84ff; } h1 { color: var(--accent); }")
        try put("src/toolbar.html", "<nav><button>Export</button></nav>")
        try put("README.md", "# Fixture\n")
        try put("node_modules/left-pad/index.js", "module.exports = s => s;")

        let before = try checksums(root: root)
        precondition(before.count == 8, "the fixture tree has eight files, found \(before.count)")

        let folder = PrototypeFiles.folder(root: root, slug: "orders")
        try fm.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let scope = PrototypeAI.CodeScope(apps: [.init(path: "", label: "fixture", isElectron: true)])
        let phases = Phases()
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "", sources: ["src"], language: "",
            mode: .code, codeScope: scope, record: { _ in }, stage: { event in
                if case .phase(let text) = event { phases.add(text) }
            })
        precondition(built.title == "Fixture Orders" && built.screens == ["Orders"] && built.failed.isEmpty)
        precondition(built.gaps == CLICompletion.codeGaps + [
            "Component src/ghost.vue named by the plan was not found in the sources",
            "Component src/phantom.html marked in the files was not found in the sources",
            "Could not isolate component src/toolbar.html: the toolbar has no source file to read",
            "Coverage: the build named or read 1 of 1 UI source files of 2 KB or more (100%, 2 KB of 2 KB).",
        ], "the build carries the plan's gaps, the components without a source file and the one it could not isolate: \(built.gaps)")
        precondition(built.assumptions == ["Prices are in EUR"])
        precondition(phases.first == "Step 1 of 4 · Reading the code and planning the screens", "\(phases.first ?? "")")
        precondition(phases.last == "Step 4 of 4 · Isolating the source components", "\(phases.last ?? "")")
        let site = PrototypeFiles.site(of: folder)
        precondition(fm.fileExists(atPath: site.appendingPathComponent("screens/orders.js").path))

        // Components (REQ-007): the planned template and the toolbar found by its marker; the isolated page of the
        // first exists and is linked, the second has none and is a gap. The ghost the plan named and the phantom
        // the markup named have no source file: neither is linked.
        precondition(built.components == [
            PrototypeFiles.Component(path: "src/index.html", label: "index", screens: ["Orders"], page: "components/src-index-html.html"),
            PrototypeFiles.Component(path: "src/toolbar.html", label: "toolbar", screens: ["Orders"], page: nil),
        ], "components from the plan and the markup, with the isolated page: \(built.components)")
        let isolated = try String(contentsOf: site.appendingPathComponent("components/src-index-html.html"), encoding: .utf8)
        precondition(isolated.contains("Orders alone") && isolated.contains("data-mv-component=\"src/index.html\""))
        precondition(!fm.fileExists(atPath: site.appendingPathComponent("components/src-toolbar-html.html").path))
        let componentPrompt = await CLICompletion.audit.prompts["prototype:component:src-index-html"] ?? ""
        precondition(componentPrompt.contains("component `src/index.html` as `components/src-index-html.html`")
                     && componentPrompt.contains("- Orders: screens/orders.js\n"), "the component writer gets the page, the screens and the source")
        let componentSystem = await CLICompletion.audit.systems["prototype:component:src-index-html"] ?? ""
        precondition(componentSystem.contains("isolated view of a source component"))

        // The prompts: the code is the reference, the inventory lists the scope only, the Electron hint is there,
        // the screen writer gets its evidence, and the foundation is asked for the original tokens.
        let prompts = await CLICompletion.audit.prompts
        let systems = await CLICompletion.audit.systems
        let plan = prompts["prototype:plan"] ?? ""
        precondition(systems["prototype:plan"]?.contains("`evidence`") == true && systems["prototype:plan"]?.contains("`gaps`") == true)
        precondition(plan.contains("- src\n") && plan.contains("src/ (4 files,") && plan.contains("- app.js (") && plan.contains("- styles.css (")
                     && plan.contains("- index.html ("), "the inventory lists the scope's folder with its files")
        precondition(!plan.contains("package.json") && !plan.contains("node_modules") && !plan.contains("main.js"), "inventory is limited to the selected scope")
        precondition(plan.contains("Electron renderer: only the browser part is in scope"))
        precondition(!plan.contains("fetch('/api/orders')"), "the inventory never inlines file content")
        let screen = prompts["prototype:screen:orders"] ?? ""
        precondition(screen.contains("- src/index.html\n- src/app.js\n- src/styles.css\n") && screen.contains("no network request"))
        precondition(screen.contains(PrototypeAI.componentRule) && screen.contains("as the plan names them:\n- src/index.html\n")
                     && !screen.contains("ghost"), "the screen writer is told to mark the components that exist, not the ghost")
        precondition(systems["prototype:plan"]?.contains("`components`") == true, "the planner is asked for the components")
        precondition(prompts["prototype:foundation:shell"]?.contains("reproduce the original design tokens") == true)
        precondition(prompts["prototype:foundation:styles"]?.contains("reproduce the original design tokens") == true)
        precondition(prompts["prototype:foundation:data"]?.contains("reproduce the original design tokens") == true)

        // The app's own stylesheet is copied unchanged, linked before the prototype's styles.css, kept out of what the
        // assistant reads, and the writers are told it is there (BUG-050).
        let copiedStyles = site.appendingPathComponent("original/src/styles.css")
        precondition((try? String(contentsOf: copiedStyles, encoding: .utf8)) == ":root { --accent: #0a84ff; } h1 { color: var(--accent); }",
                     "the original stylesheet is copied unchanged")
        let indexHTML = try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8)
        let originalLink = indexHTML.range(of: "<link rel=\"stylesheet\" href=\"original/src/styles.css\">")
        let ownLink = indexHTML.range(of: "href=\"styles.css\"")
        precondition(originalLink != nil && ownLink != nil && originalLink!.lowerBound < ownLink!.lowerBound,
                     "index.html links the original stylesheet before styles.css: \(indexHTML)")
        precondition(!PrototypeFiles.read(site: site).contains { $0.path.hasPrefix("original/") }, "the assistant is not shown the copied originals")
        for label in ["prototype:foundation:shell", "prototype:foundation:data", "prototype:screen:orders"] {
            precondition(prompts[label]?.contains("already copied into the prototype unchanged") == true && prompts[label]?.contains("src/styles.css") == true,
                         "\(label) is told about the copied stylesheet")
        }

        // Revision and specification in code mode name the sources and the gaps.
        _ = try await PrototypeAI.revise(root: root, folder: folder, instruction: "Revise title", pick: nil,
            runtimeErrors: [], language: "", mode: .code, sources: ["src"], record: { _ in }, stage: { _ in })
        let revise = await CLICompletion.audit.prompts["prototype:revise"] ?? ""
        precondition(revise.contains("reconstruction of the existing interface implemented in the project's source code in `src`"))
        precondition(!revise.contains("requirements come from the project's documents"))
        var manifest = PrototypeFiles.Manifest(title: built.title, slug: "orders", brief: "", sources: ["src"], mode: .code, gaps: built.gaps)
        manifest.version = 1
        _ = try await PrototypeAI.specification(root: root, folder: folder, manifest: manifest, language: "", record: { _ in }, stage: { _ in })
        let spec = await CLICompletion.audit.prompts["prototype:spec"] ?? ""
        precondition(spec.contains("Reconstruction: sources, evidence, known gaps") && spec.contains(CLICompletion.codeGaps[1]))
        let specSystem = await CLICompletion.audit.systems["prototype:spec"] ?? ""
        precondition(specSystem.contains("never present simulated behaviour"))

        // Nothing outside docs/prototypes/ changed, and the prototype landed inside it.
        let after = try checksums(root: root)
        precondition(after == before, "source files changed: \(after.filter { before[$0.key] != $0.value }.keys.sorted())")
        precondition(PrototypeFiles.read(site: PrototypeFiles.site(of: folder)).map(\.path).contains("screens/orders.js"))
        print("Prototype code mode: the fixture app is reconstructed with its gaps, evidence and components; every file outside docs/prototypes/ is unchanged.")

        try await syncFromCode(root: root, folder: folder, scope: scope, before: before)
    }

    /// A window of docked widgets (BUG-050): the shell is told about widgets and modals, the host lists them, widgets
    /// and the host run at medium effort, a component that is a widget or modal screen gets its isolated page without
    /// the assistant, the original stylesheet is copied and the coverage is reported.
    static func widgetsMode() async throws {
        await CLICompletion.audit.reset()
        await CLICompletion.audit.set(variant: "widgets")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mv-prototype-widgets-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func put(_ path: String, _ content: String) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try put("src/index.html", "<html><body><table id=\"orders\"></table></body></html>")
        try put("src/toolbar.html", "<nav><button>Settings</button></nav>")
        try put("src/app.js", "render();\n" + String(repeating: "// filler line keeps this file above the 2 KB coverage threshold\n", count: 40))
        try put("src/styles.css", ":root { --accent: #0a84ff; }")
        let folder = PrototypeFiles.folder(root: root, slug: "desk")
        try fm.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let milestones = Phases()
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "", sources: ["src"], language: "", mode: .code,
            codeScope: PrototypeAI.CodeScope(apps: [.init(path: "", label: "desk", isElectron: false)]), record: { _ in },
            stage: { event in if case .milestone(let text) = event { milestones.add(text) } })
        precondition(built.screens == ["Workspace", "Order list", "Settings"] && built.failed.isEmpty, "the host, the widget and the modal are built: \(built.screens)")
        let site = PrototypeFiles.site(of: folder)

        // The shell and the styles part are told what the plan contains and that the original styles are loaded.
        let systems = await CLICompletion.audit.systems
        precondition(systems["prototype:foundation:shell"]?.contains("App.renderScreen(id, extra)") == true
                     && systems["prototype:foundation:shell"]?.contains("`embedded: true`") == true, "the shell is asked for the widget API")
        precondition(systems["prototype:foundation:styles"]?.contains("small bridge") == true
                     && systems["prototype:foundation:styles"]?.contains("design tokens as CSS variables") == false, "styles.css is a bridge, not a design system")

        // The host lists its widgets (a name the plan does not know is dropped), the widgets know they are embedded.
        let prompts = await CLICompletion.audit.prompts
        precondition(prompts["prototype:screen:workspace"]?.contains("HOST of the window") == true
                     && prompts["prototype:screen:workspace"]?.contains("- order-list — Order list (/widgets/order-list)") == true
                     && prompts["prototype:screen:workspace"]?.contains("- settings — Settings (/modals/settings)") == true
                     && prompts["prototype:screen:workspace"]?.contains("ghost") == false, "the host prompt lists the widgets and the modal")
        precondition(prompts["prototype:screen:order-list"]?.contains("rendered inside another screen") == true
                     && prompts["prototype:screen:order-list"]?.contains("HOST of the window") == false, "the widget prompt")
        precondition(prompts["prototype:screen:settings"]?.contains("in the host's dialog") == true, "the modal prompt")
        let efforts = await CLICompletion.audit.efforts
        precondition(efforts["prototype:screen:workspace"] == "medium" && efforts["prototype:screen:order-list"] == "medium"
                     && efforts["prototype:screen:settings"] == "medium", "hosts, widgets and modals run at medium effort: \(efforts)")

        // The original stylesheet is copied and linked; both components are isolated without the assistant.
        let index = try String(contentsOf: site.appendingPathComponent("index.html"), encoding: .utf8)
        precondition(index.contains("href=\"original/src/styles.css\""), "index.html links the original stylesheet")
        let labels = await CLICompletion.audit.labels
        precondition(!labels.contains { $0.hasPrefix("prototype:component:") }, "no assistant run isolates a widget or a modal: \(labels.sorted())")
        precondition(built.components.map(\.path) == ["src/index.html", "src/toolbar.html"]
                     && built.components.map(\.page) == ["components/src-index-html.html", "components/src-toolbar-html.html"],
                     "both components have an isolated page: \(built.components)")
        let page = try String(contentsOf: site.appendingPathComponent("components/src-index-html.html"), encoding: .utf8)
        precondition(page.contains("App.renderScreen(\"order-list\")") && page.contains("<script src=\"../screens/order-list.js\">")
                     && page.contains("href=\"../original/src/styles.css\"") && page.contains("data-mv-component=\"src/index.html\""),
                     "the isolated page mounts the widget alone: \(page)")

        // Coverage: src/app.js is named by the host, so the one UI source file of 2 KB or more is covered.
        precondition(built.coverage?.covered == 1 && built.coverage?.total == 1, "coverage: \(String(describing: built.coverage))")
        precondition(milestones.all.contains { $0.hasPrefix("Coverage: the build named or read 1 of 1") }, "the conversation gets the coverage figure")
        print("Prototype widgets: the host, a widget and a modal are built at medium effort; their pages need no assistant; coverage is reported.")
    }

    /// "Sync from code" (REQ-006, DEC-005): the same build runs again against the current code and replaces the
    /// live site, the previous version stays restorable, a failed sync restores it, and no source file changes.
    static func syncFromCode(root: URL, folder: URL, scope: PrototypeAI.CodeScope, before: [String: String]) async throws {
        let fm = FileManager.default
        let site = PrototypeFiles.site(of: folder)
        // The studio snapshots every accepted version; v1 is the creation.
        try PrototypeFiles.snapshot(folder: folder, version: 1)
        var manifest = PrototypeFiles.Manifest(title: "Fixture Orders", slug: "orders", brief: "", sources: ["src"], mode: .code)
        manifest.version = 1

        // A requirements-mode prototype cannot be synced.
        var refused = false
        do {
            var plain = manifest
            plain.mode = .requirements
            _ = try await PrototypeAI.sync(root: root, folder: folder, manifest: plain, codeScope: scope, language: "", record: { _ in }, stage: { _ in })
        } catch { refused = true }
        precondition(refused, "sync refuses a requirements-mode prototype")
        let untouched = try String(contentsOf: site.appendingPathComponent("screens/orders.js"), encoding: .utf8)
        precondition(untouched.contains("<h1>Orders</h1>"), "a refused sync changes nothing")

        // The code changed: the sync reconstructs it again into site/, v1 keeps the earlier files.
        await CLICompletion.audit.reset()
        await CLICompletion.audit.set(variant: "synced")
        let steps = Phases()
        let synced = try await PrototypeAI.sync(root: root, folder: folder, manifest: manifest, codeScope: scope, language: "",
            record: { _ in }, stage: { event in
                if case .step(let text) = event { steps.add(text) }
                if case .phase(let text) = event { steps.add(text) }
            })
        precondition(synced.title == "Fixture Orders (synced)" && synced.screens == ["Orders"], "\(synced.title) \(synced.screens)")
        precondition(synced.components.map(\.path) == ["src/index.html", "src/toolbar.html"] && synced.components[0].page != nil, "the sync records the components again")
        precondition(steps.first == "Clearing the previous files (kept as v1)", "\(steps.first ?? "")")
        let live = try String(contentsOf: site.appendingPathComponent("screens/orders.js"), encoding: .utf8)
        let kept = try String(contentsOf: PrototypeFiles.versionFolder(of: folder, 1).appendingPathComponent("screens/orders.js"), encoding: .utf8)
        precondition(live.contains("Orders (synced)") && kept.contains("<h1>Orders</h1>") && !kept.contains("synced"), "the live site is the new reconstruction, v1 the old one")
        let labels = await CLICompletion.audit.labels
        precondition(labels.contains("prototype:plan") && labels.contains("prototype:screen:orders") && labels.contains("prototype:component:src-index-html"),
                     "a sync runs the same stages as creation: \(labels.sorted())")
        let plan = await CLICompletion.audit.prompts["prototype:plan"] ?? ""
        precondition(plan.contains("- src\n") && plan.contains("Electron renderer"), "the sync plans with the same sources and scope hints")
        try PrototypeFiles.snapshot(folder: folder, version: 2)
        manifest.version = 2
        precondition(fm.fileExists(atPath: PrototypeFiles.versionFolder(of: folder, 1).appendingPathComponent("index.html").path)
                     && fm.fileExists(atPath: PrototypeFiles.versionFolder(of: folder, 2).appendingPathComponent("components/src-index-html.html").path),
                     "both versions are kept")

        // A sync whose planner fails leaves the prototype as it was: the live site is v2 again.
        await CLICompletion.audit.set(variant: "failing")
        var failed = false
        do {
            _ = try await PrototypeAI.sync(root: root, folder: folder, manifest: manifest, codeScope: scope, language: "", record: { _ in }, stage: { _ in })
        } catch {
            failed = error.localizedDescription.contains("the planner could not read the code")
        }
        precondition(failed, "the failed sync reports the planner's error")
        let restored = try String(contentsOf: site.appendingPathComponent("screens/orders.js"), encoding: .utf8)
        precondition(restored.contains("Orders (synced)") && fm.fileExists(atPath: site.appendingPathComponent("components/src-index-html.html").path),
                     "a failed sync restores the previous version's files")
        await CLICompletion.audit.set(variant: "")

        let after = try checksums(root: root)
        precondition(after == before, "a sync changed source files: \(after.filter { before[$0.key] != $0.value }.keys.sorted())")
        print("Prototype sync from code: the reconstruction runs again into a new version, v1 stays, a failed sync restores the live site; no source file changed.")
    }

    /// Collects the build phases from the `@Sendable` stage closure.
    final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
        var first: String? { lock.lock(); defer { lock.unlock() }; return items.first }
        var last: String? { lock.lock(); defer { lock.unlock() }; return items.last }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    /// SHA-256 of every file under `root` except the prototype storage, by relative path.
    static func checksums(root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let base = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        for case let url as URL in walker {
            let path = String(url.standardizedFileURL.path.dropFirst(base.count))
            if path == PrototypeFiles.storageFolder || path.hasPrefix(PrototypeFiles.storageFolder + "/") { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            out[path] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}
