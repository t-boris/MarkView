// Behaviour of the shipping ProjectOperationsStore when it needs the person's decision (AR-22): it asks through the prompter it was
// given, never through an alert of its own. The store, the discovery service, the operations file, the run history and the scanner are
// the shipping code, over real temporary projects; the assistant of discovery is a script of canned answers and the person is a
// `ScriptedPrompts`. Not covered here: starting a run (it starts a terminal and asks the system for notification permission) and
// cancelling one, so the "Run" and "Cancel operation" answers are checked by the app probe, not here.
import Foundation

@MainActor
@main enum ProjectOperationsStoreTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
    }

    /// Polls `condition` until it holds or `seconds` have passed.
    static func wait(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Time for a decision that should do nothing to have done it, had it been going to.
    static func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

    static func project(_ name: String, in base: URL, operations: [ProjectOperation] = []) throws -> URL {
        let folder = ProjectOperationDiscovery.canonical(base.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "# \(name)\nBuild with make.\n".write(to: folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "{\"scripts\":{\"build\":\"make\"}}".write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        if !operations.isEmpty {
            var document = ProjectOperationsDocument()
            document.operations = operations
            try ProjectOperationsFile.write(document, root: folder)
        }
        return folder
    }

    static func stored(_ folder: URL) throws -> [ProjectOperation] { try ProjectOperationsFile.read(root: folder).operations }

    static func main() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("operations-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let domain = ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? domain)
        defer {
            try? FileManager.default.removeItem(at: base)
            UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? domain)
        }

        try await runApproval(base)
        try await adoptDiscovered(base)
        try await proposals(base)

        if failures > 0 { print("\(failures) check(s) FAILED"); exit(1) }
        print("Project operations store checks passed")
    }

    // MARK: - Run: the person is asked first, and anything but Run starts nothing

    static func runApproval(_ base: URL) async throws {
        let build = ProjectOperation(id: "build", label: "Build the app", kind: "build", command: "echo built", cwd: ".")
        let folder = try project("run", in: base, operations: [build])
        let operationsFile = ProjectOperationsFile.url(root: folder)
        let before = try Data(contentsOf: operationsFile)
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await wait { store.operations.map(\.id) == ["build"] }, "the store reads the operations of the project")

        prompts.script = [.press("Cancel")]
        store.run(id: "build")
        check(await wait { prompts.asked.count == 1 }, "starting an operation asks first")
        let question = prompts.asked[0]
        check(question.title == "Run Build the app?" && question.buttons == ["Cancel", "Run"],
              "with the title and the two buttons it always had, the safe one first (\(question.title) \(question.buttons))")
        check(question.detail.hasPrefix("Command:\necho built\n\nWorking directory:\n\(folder.path)")
              && question.detail.contains("New or changed since your last run on this machine.") && question.detail.hasSuffix("User-added operation."),
              "that names the command, the folder and what is new about it")
        await settle()
        check(store.runs.isEmpty && store.lastRuns.isEmpty && store.state(id: "build") == nil && TerminalSession.started.isEmpty,
              "Cancel starts no run and keeps no record of one")
        check((try? ProjectOperationHistory.load(root: folder))?.isEmpty == true, "and writes nothing to the run history")

        prompts.script = [.dismiss]
        store.run(id: "build")
        check(await wait { prompts.asked.count == 2 }, "an operation can be started again once the first question is answered")
        await settle()
        check(store.runs.isEmpty && TerminalSession.started.isEmpty, "a window that cannot answer starts no run and waits for nothing")

        store.run(id: "build")
        check(await wait { prompts.asked.count == 3 }, "and a question nobody answers does not block the next start")
        await settle()
        check(store.runs.isEmpty && TerminalSession.started.isEmpty, "a question with no answer left starts nothing either")
        check(try Data(contentsOf: operationsFile) == before, "the operations file is untouched by all three")
    }

    // MARK: - Adopt the discovered command

    static func adoptDiscovered(_ base: URL) async throws {
        var deploy = ProjectOperation(id: "deploy", label: "Deploy", kind: "deploy", command: "make deploy-by-hand", cwd: ".",
                                      origin: "discovered", discovered: .init(command: "make deploy", cwd: "."))
        deploy.discoveredFields = deploy.currentFields
        let folder = try project("adopt", in: base, operations: [deploy])
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await wait { store.operations.count == 1 }, "the store reads the operation")

        prompts.script = [.press("Keep current")]
        store.adoptDiscovered(id: "deploy")
        check(prompts.asked.last == UserPrompt(
                title: "Adopt the discovered command?", detail: "Command:\nmake deploy\n\nWorking directory:\n.",
                buttons: ["Keep current", "Adopt discovered"]), "adopting asks what the command would become")
        var commandOnDisk = try stored(folder)[0].command
        check(commandOnDisk == "make deploy-by-hand", "Keep current changes nothing")

        prompts.script = [.dismiss]
        store.adoptDiscovered(id: "deploy")
        commandOnDisk = try stored(folder)[0].command
        check(prompts.asked.count == 2 && commandOnDisk == "make deploy-by-hand", "no answer changes nothing either")

        prompts.script = [.press("Adopt discovered")]
        store.adoptDiscovered(id: "deploy")
        check(await wait { (try? stored(folder)[0].command) == "make deploy" }, "Adopt discovered writes the discovered command to the file")
        check(await wait { store.operations.first?.command == "make deploy" }, "and the store shows it")
    }

    // MARK: - Proposals: accept, keep and reject

    /// The answers of the two discovery rounds that propose one command found on the web.
    static func discoveryAnswers(command: String) -> [[String: Any]] {
        [["operations": [Any](),
          "notDetermined": [["label": "Deploy to production", "kind": "deploy", "environment": "", "reason": "not in the files",
                             "investigated": "README.md"]]],
         ["operations": [["id": "", "label": "Deploy to production", "kind": "deploy", "environment": "", "target": "",
                          "command": command, "cwd": ".", "nodeNames": [Any](), "prerequisites": [Any](),
                          "sources": [["kind": "web", "location": "https://example.com/deploy", "line": 0]],
                          "remoteTrigger": false] as [String: Any]],
          "notDetermined": [Any]()]]
    }

    static func discover(_ store: ProjectOperationsStore, command: String) async -> Bool {
        StandInAssistant.answers = discoveryAnswers(command: command)
        store.discover(nodes: [])
        return await wait { store.discoveryPhase == nil && store.discoveryReport != nil }
    }

    static func proposals(_ base: URL) async throws {
        let folder = try project("proposals", in: base)
        let prompts = ScriptedPrompts()
        let store = ProjectOperationsStore.forRoot(folder, prompts: prompts)
        check(await discover(store, command: "./deploy.sh --prod"), "discovery proposes the command that only the web names")
        check(store.discoveryReport?.proposals.map(\.command) == ["./deploy.sh --prod"] && store.operations.isEmpty,
              "as a proposal, not as an operation")

        prompts.script = [.press("Keep as proposal")]
        store.acceptProposal(index: 0)
        check(prompts.asked.last?.title == "Add externally sourced operation?" && prompts.asked.last?.buttons == ["Keep as proposal", "Accept operation"]
              && prompts.asked.last?.detail.hasPrefix("Deploy to production\n\n./deploy.sh --prod\n\nSource: https://example.com/deploy") == true,
              "accepting asks first, naming the command and where it came from (\(prompts.asked.last?.detail ?? ""))")
        var onDisk = try stored(folder)
        check(store.discoveryReport?.proposals.count == 1 && store.operations.isEmpty && onDisk.isEmpty, "Keep as proposal changes nothing")
        prompts.script = [.dismiss]
        store.acceptProposal(index: 0)
        onDisk = try stored(folder)
        check(store.discoveryReport?.proposals.count == 1 && onDisk.isEmpty, "no answer changes nothing either")

        prompts.script = [.press("Accept operation")]
        store.acceptProposal(index: 0)
        check(store.discoveryReport?.proposals.isEmpty == true, "Accept operation takes the proposal off the list")
        check(await wait { (try? stored(folder).map(\.command)) == ["./deploy.sh --prod"] }, "and writes the operation to the file")

        // Reject: the command is not proposed again on this machine.
        check(await discover(store, command: "./deploy-eu.sh"), "a second discovery proposes another command")
        check(store.discoveryReport?.proposals.map(\.command) == ["./deploy-eu.sh"], "as a proposal")
        prompts.script = [.press("Keep proposal")]
        store.rejectProposal(index: 0)
        check(prompts.asked.last == UserPrompt(
                title: "Reject this proposed command?",
                detail: "./deploy-eu.sh\n\nThe same command will not be proposed again on this machine.", buttons: ["Keep proposal", "Reject"]),
              "rejecting asks first")
        check(store.discoveryReport?.proposals.count == 1, "Keep proposal keeps it")
        prompts.script = [.dismiss]
        store.rejectProposal(index: 0)
        check(store.discoveryReport?.proposals.count == 1, "no answer keeps it too")
        prompts.script = [.press("Reject")]
        store.rejectProposal(index: 0)
        check(store.discoveryReport?.proposals.isEmpty == true, "Reject takes it off the list")
        check(await discover(store, command: "./deploy-eu.sh") && store.discoveryReport?.proposals.isEmpty == true,
              "and a later discovery does not propose the same command again")
    }
}
