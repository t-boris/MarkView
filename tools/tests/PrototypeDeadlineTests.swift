import CryptoKit
import Foundation

@main enum PrototypeDeadlineTests {
    static func main() async throws {
        try await requirementsMode()
        try await codeMode()
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
        precondition(labels == ["prototype:plan", "prototype:foundation:shell", "prototype:foundation:data",
                                "prototype:screen:home", "prototype:revise", "prototype:spec"])
        let planPrompt = await CLICompletion.audit.prompts["prototype:plan"] ?? ""
        precondition(planPrompt.contains("requirement sources") && !planPrompt.contains("Reconstruct"))
        print("Prototype deadline policy: plan, both foundations, saved screen, revision and specification complete without wall-clock limits.")
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
        try put("src/app.js", "fetch('/api/orders'); document.getElementById('export').onclick = () => window.electron.saveFile();")
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
        precondition(plan.contains("- src\n") && plan.contains("- src/app.js (") && plan.contains("- src/styles.css (") && plan.contains("- src/index.html ("))
        precondition(!plan.contains("package.json") && !plan.contains("node_modules") && !plan.contains("main.js"), "inventory is limited to the selected scope")
        precondition(plan.contains("Electron renderer: only the browser part is in scope"))
        precondition(!plan.contains("fetch('/api/orders')"), "the inventory never inlines file content")
        let screen = prompts["prototype:screen:orders"] ?? ""
        precondition(screen.contains("- src/index.html\n- src/app.js\n- src/styles.css\n") && screen.contains("no network request"))
        precondition(screen.contains(PrototypeAI.componentRule) && screen.contains("as the plan names them:\n- src/index.html\n")
                     && !screen.contains("ghost"), "the screen writer is told to mark the components that exist, not the ghost")
        precondition(systems["prototype:plan"]?.contains("`components`") == true, "the planner is asked for the components")
        precondition(prompts["prototype:foundation:shell"]?.contains("reproduce the original design tokens") == true)
        precondition(prompts["prototype:foundation:data"]?.contains("reproduce the original design tokens") == true)

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
