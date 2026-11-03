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
        precondition(built.screens == ["Home"] && built.failed.isEmpty && built.gaps.isEmpty)
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
        try put("README.md", "# Fixture\n")
        try put("node_modules/left-pad/index.js", "module.exports = s => s;")

        let before = try checksums(root: root)
        precondition(before.count == 7, "the fixture tree has seven files, found \(before.count)")

        let folder = PrototypeFiles.folder(root: root, slug: "orders")
        try fm.createDirectory(at: PrototypeFiles.site(of: folder), withIntermediateDirectories: true)
        let scope = PrototypeAI.CodeScope(apps: [.init(path: "", label: "fixture", isElectron: true)])
        let phases = Phases()
        let built = try await PrototypeAI.build(root: root, folder: folder, brief: "", sources: ["src"], language: "",
            mode: .code, codeScope: scope, record: { _ in }, stage: { event in
                if case .phase(let text) = event { phases.add(text) }
            })
        precondition(built.title == "Fixture Orders" && built.screens == ["Orders"] && built.failed.isEmpty)
        precondition(built.gaps == CLICompletion.codeGaps, "the build carries the plan's gaps: \(built.gaps)")
        precondition(built.assumptions == ["Prices are in EUR"])
        precondition(phases.first == "Step 1 of 3 · Reading the code and planning the screens", "\(phases.first ?? "")")
        precondition(fm.fileExists(atPath: PrototypeFiles.site(of: folder).appendingPathComponent("screens/orders.js").path))

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
        print("Prototype code mode: the fixture app is reconstructed with its gaps and evidence; every file outside docs/prototypes/ is unchanged.")
    }

    /// Collects the build phases from the `@Sendable` stage closure.
    final class Phases: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
        var first: String? { lock.lock(); defer { lock.unlock() }; return items.first }
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
