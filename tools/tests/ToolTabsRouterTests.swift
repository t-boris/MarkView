import AppKit
import Foundation

/// The tools of a window (`AR-14` step 10) on the shipping `ToolTabsRouter` and hosts, with the real tabs controller, panels, deployment
/// store and discussion store of a temporary project: every tool of `ToolRegistry` opens once and is shown again instead of twice, the
/// stores read the project when the folder opens or closes, the UI Studio and Cockpit tabs carry the sessions the hosts build, and an
/// answer in a discussion streams, ends, is stopped, and ends with the folder and the window. The assistant run is a script.
@main
enum ToolTabsRouterChecks {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        }
    }

    /// A folder of its own for one check, removed afterwards.
    static func folder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tool-tabs-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }

    // MARK: Fakes of what the window gives the tools

    @MainActor
    final class FakeProject: ProjectProviding {
        var root: URL?
        var database: SemanticDatabase?
        var aiProject: URL? { root }
        var linkedFolderURLs: [URL] { [] }
        var searchRoots: [URL] { root.map { [$0] } ?? [] }
        init(root: URL?) { self.root = root }
        func relativePath(of url: URL) -> String {
            guard let root else { return url.path }
            let prefix = root.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        func markdownFiles(in folder: URL) -> [URL] { [] }
        func cacheDirectory(for url: URL) -> URL { url.deletingLastPathComponent() }
        func refreshFileTree() {}
        func containerRoot(for url: URL) -> URL? { root }
    }

    @MainActor
    final class FakeAssistants: AssistantProviding, AssistantPrompting {
        var currentAssistant: CLICompletion.Assistant? { nil }
        var sessions: [TerminalSession] = []
        var shownID: UUID?
        var assistantIsBusy = false
        private(set) var prompts: [(text: String, submit: Bool)] = []
        func liveModelReported(_ model: String, terminalID: UUID) {}
        func openAITerminal(_ profile: TerminalProfile, resuming: Bool, model: String?) -> TerminalSession? { nil }
        func showAIConsole() {}
        func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
            prompts.append((prompt, submit))
            return nil
        }
        func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? { nil }
    }

    @MainActor
    final class FakeWindow: ToolTabsWindow {
        var hostWindow: NSWindow? { nil }
        private(set) var openedFiles: [URL] = []
        private(set) var shownFeatures: [String?] = []
        func openFile(_ url: URL) { openedFiles.append(url) }
        func showFeatureContext(_ slug: String?) { shownFeatures.append(slug) }
        func showAIConsole() {}
    }

    @MainActor
    final class FakeTools: ToolOpening {
        private(set) var opened: [ToolID] = []
        func open(_ id: ToolID) { opened.append(id) }
    }

    @MainActor
    struct Rig {
        let project: FakeProject
        let window = FakeWindow()
        let assistants = FakeAssistants()
        let tabs = TabsController(prompts: NoPrompts())
        let layout = PanelLayout(defaults: UserDefaults(suiteName: "tool-tabs-\(UUID().uuidString)")!)
        let chrome = WindowChrome(defaults: UserDefaults(suiteName: "tool-tabs-\(UUID().uuidString)")!)
        let requests = WindowRequests()
        let features = FeatureStore()
        let router: ToolTabsRouter

        init(root: URL?) {
            project = FakeProject(root: root)
            router = ToolTabsRouter(window: window, project: project, tabs: tabs, layout: layout, chrome: chrome, requests: requests,
                                    features: features, assistants: assistants)
        }

        func tabs(of id: ToolID) -> [OpenTab] { tabs.openTabs.filter { $0.kind.toolID == id } }
    }

    @MainActor
    static func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: The router

    @MainActor
    static func routerChecks() async {
        let root = folder("router")
        defer { try? FileManager.default.removeItem(at: root) }

        let blank = Rig(root: nil)
        blank.router.open(.git)
        check(blank.tabs.openTabs.isEmpty, "a tool does not open without a folder")

        let rig = Rig(root: root)
        let router = rig.router
        check(router.qa.assistants === rig.assistants, "the QA model asks the window's assistants")
        let tools = ToolRegistry.shared.tools
        for tool in tools {
            router.open(tool.id)
            check(rig.tabs(of: tool.id).count == 1, "\(tool.id.rawValue): one tab after the first open")
            check(rig.tabs.activeTab?.kind.toolID == tool.id, "\(tool.id.rawValue): the opened tab is the active one")
        }
        check(rig.tabs.openTabs.count == tools.count, "every tool of the registry has a tab (\(rig.tabs.openTabs.count) of \(tools.count))")
        for tool in tools {
            router.open(tool.id)
            check(rig.tabs(of: tool.id).count == 1, "\(tool.id.rawValue): the second open shows the tab, it does not add one")
            check(rig.tabs.activeTab?.kind.toolID == tool.id, "\(tool.id.rawValue): the second open brings the tab forward")
        }
        check(rig.tabs.openTabs.count == tools.count, "no tool opened twice")
        check(rig.layout.workspaceArea == .files && rig.chrome.showCenter, "opening a tool shows the files area and the center")

        check(router.deployments.store.root == root, "the Deployments store reads the project")
        check(router.discussions.store.root == root, "the Discussions store reads the project")
        check(router.qa.attachedRoot == root, "the QA model is attached to the project")
        check(router.qa.run.bugFiler != nil && router.qa.run.bugFiler === router.qa.archive.bugFiler, "QA files its bugs through one filer")
        check(router.qa.run.runLinks is CockpitRunLinks && router.qa.archive.runLinks is CockpitRunLinks, "QA cleanup is given the Cockpit's links to runs")

        guard case .uiStudio(let studio)? = rig.tabs(of: .uiStudio).first?.kind else { return check(false, "UI Studio tab carries a session") }
        check(studio.started && studio.root == root, "the UI Studio session of the tab was started on the project")
        guard case .cockpit(let cockpit)? = rig.tabs(of: .cockpit).first?.kind else { return check(false, "Cockpit tab carries a session") }
        check(cockpit.root == root, "the Cockpit session is the project's")

        // The Cockpit keeps its session across a closed tab; a new project ends it.
        rig.tabs.closeTab(at: rig.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit }!)
        check(rig.tabs(of: .cockpit).isEmpty, "the Cockpit tab closes")
        router.open(.cockpit)
        guard case .cockpit(let again)? = rig.tabs(of: .cockpit).first?.kind else { return check(false, "Cockpit tab reopens") }
        check(again === cockpit && cockpit.runsLoaded == 1, "a reopened Cockpit tab shows the same session, with its runs read again")

        // The Deployments store asks for its tab when an approval waits.
        rig.tabs.closeTab(at: rig.tabs.openTabs.firstIndex { $0.kind.toolID == .deployments }!)
        check(rig.tabs(of: .deployments).isEmpty, "the Deployments tab closes")
        router.deployments.store.needsAttention.send()
        check(rig.tabs(of: .deployments).count == 1 && rig.tabs.activeTab?.kind.toolID == .deployments, "a waiting approval brings the Deployments tab back")

        // The folder opens and closes under the stores, tabs or none.
        let other = folder("router-other")
        defer { try? FileManager.default.removeItem(at: other) }
        router.projectOpened(other)
        check(router.deployments.store.root == other && router.discussions.store.root == other, "an opened folder is read by the stores without their tabs")
        router.projectClosed()
        check(router.deployments.store.root == nil && router.discussions.store.root == nil, "a closed folder is forgotten by the stores")
        check(cockpit.projectClosed, "the Cockpit session ends with the project")
        rig.tabs.closeTab(at: rig.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit }!)
        router.open(.cockpit)
        guard case .cockpit(let renewed)? = rig.tabs(of: .cockpit).first?.kind else { return check(false, "Cockpit tab after the project closed and reopened") }
        check(renewed !== again, "a Cockpit opened after the project closed gets a session of its own")
    }

    // MARK: UI Studio

    @MainActor
    static func uiStudioChecks() async {
        let root = folder("studio")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = Rig(root: root)
        let database = SemanticDatabase()
        rig.project.database = database
        rig.router.open(.uiStudio)
        guard case .uiStudio(let session)? = rig.tabs(of: .uiStudio).first?.kind else { return check(false, "UI Studio tab carries a session") }

        let note = root.appendingPathComponent("note.md")
        try? "# Note\n".write(to: note, atomically: true, encoding: .utf8)
        let outside = folder("studio-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let stray = outside.appendingPathComponent("stray.md")
        try? "# Stray\n".write(to: stray, atomically: true, encoding: .utf8)
        await rig.tabs.openTextFile(note)
        await rig.tabs.openTextFile(stray)
        check(session.editorBuffers().isEmpty, "a file that was not edited is not a buffer")
        for tab in rig.tabs.openTabs where tab.isFileBacked {
            rig.tabs.updateTabContent("# Edited\n", documentID: tab.id)
        }
        check(session.editorBuffers() == ["note.md": "# Edited\n"], "the unsaved text of the project's files reaches the session by project path (\(session.editorBuffers()))")

        session.recordUsage(10, 20, 0.5)
        session.recordUsage(1, 2, 0.25)
        var written = 0
        for _ in 0..<1000 where written < 2 {
            written = await database.usage.count
            if written < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        let usage = await database.usage
        check(usage.count == 2 && usage.contains { $0.input == 10 && $0.output == 20 && $0.cents == 50 },
              "the session's usage is added to the project's counter (\(usage))")

        session.openFile(note)
        check(rig.window.openedFiles == [note], "a file the session shows opens in the window")
        session.featureExportDelegate?.studioDidExportFeature("feature-one")
        check(rig.window.shownFeatures == ["feature-one"], "an exported feature is shown beside the document")
        check(session.featureStore() === rig.features, "the session reads the window's features")
    }

    // MARK: Deployments

    @MainActor
    static func deploymentsChecks() async {
        let root = folder("deployments")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = Rig(root: root)
        let host = rig.router.deployments
        host.analyzeWithAI()
        check(rig.assistants.prompts.count == 1 && rig.assistants.prompts[0].submit && rig.assistants.prompts[0].text.contains(root.lastPathComponent),
              "Ask AI to find where it runs hands the assistant the project")
        rig.assistants.assistantIsBusy = true
        host.analyzeWithAI()
        check(rig.assistants.prompts.count == 1 && host.store.lastError == "The assistant is still working.", "a busy assistant is not asked again")

        host.projectOpened(root)
        host.store.add(DeploymentEnvironment(id: "prod", name: "Production", kind: .local))
        host.store.lastError = nil
        let prod = host.store.selected ?? ""
        host.askAssistant(prod, question: "Is it up?")
        check(rig.assistants.prompts.count == 1 && host.store.lastError == "The assistant is still working.", "a question about an environment waits for a busy assistant")
        rig.assistants.assistantIsBusy = false
        host.askAssistant("missing", question: "Is it up?")
        check(rig.assistants.prompts.count == 1, "a question about an unknown environment is not sent")
        host.askAssistant(prod, question: "Is it up?")
        check(rig.assistants.prompts.count == 2 && rig.assistants.prompts[1].text.contains("Is it up?"), "a question about an environment goes to the assistant with the question")

        // The window closes: the auto-refresh, the waits and a request still asking the person end with it (AR-19).
        let polling = PollingScheduler()
        host.store.polling = polling
        host.store.autoRefresh = true
        check(polling.keys.count == 1, "the auto-refresh is one job of the scheduler")
        let asked = Task { await host.store.run("touch \(root.path)/never.txt", on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(host.store.approval != nil && host.store.tasks.activeCount == 1, "a request waiting for the person holds one timer, and no more")
        host.store.answer(false)
        if case .denied = await asked.value {} else { check(false, "a refused command is not run") }
        check(host.store.tasks.activeCount == 0, "an answered request leaves no timer behind")
        let closing = Task { await host.store.run("touch \(root.path)/never.txt", on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(host.store.approval != nil, "the next request waits")
        rig.router.close()
        if case .denied = await closing.value {} else { check(false, "a request still waiting when the window closes counts as no") }
        check(host.store.approval == nil && host.store.tasks.activeCount == 0 && polling.keys.isEmpty,
              "closing the window leaves no request on screen, no timer and no auto-refresh")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("never.txt").path), "and the command did not run")
    }

    // MARK: Prototype Studio

    @MainActor
    static func prototypeChecks() async {
        let root = folder("prototypes")
        defer { try? FileManager.default.removeItem(at: root) }
        let rig = Rig(root: root)
        let host = rig.router.prototypes
        check(host.saved().isEmpty, "no prototype is saved in a new project")

        let folderURL = PrototypeFiles.folder(root: root, slug: "support-desk")
        let manifest = PrototypeFiles.Manifest(title: "Support Desk", slug: "support-desk", brief: "", sources: [], version: 3, approved: true,
                                               history: [.init(version: 3, instruction: "", summary: "", date: Date())])
        try? PrototypeFiles.saveManifest(manifest, in: folderURL)
        check(host.saved().map(\.label) == ["Support Desk · v3 · approved"], "a saved prototype is listed by its title, version and state (\(host.saved().map(\.label)))")

        host.openCreator(mode: .requirements)
        check(rig.requests.showPrototypeCreator && rig.requests.prototypeCreatorMode == .requirements, "New Prototype shows the creator sheet")
        rig.requests.showPrototypeCreator = false
        host.openCreator(mode: .code)
        check(!rig.requests.showPrototypeCreator && rig.tabs(of: .uiStudio).count == 1, "New Prototype from Code opens UI Studio on the real application")

        host.openSaved("support-desk")
        check(rig.tabs.openTabs.contains { if case .prototype = $0.kind { return true } else { return false } }, "a saved prototype opens in its own tab")
        let count = rig.tabs.openTabs.count
        rig.tabs.activeTabIndex = 0
        host.openSaved("support-desk")
        check(rig.tabs.openTabs.count == count, "a prototype that is open is shown again, not opened twice")
        check({ if case .prototype = rig.tabs.activeTab?.kind { return true } else { return false } }(), "the prototype tab is brought forward")

        host.create(title: "Admin", brief: "An admin console", sources: ["docs"])
        guard case .prototype(let created)? = rig.tabs.activeTab?.kind else { return check(false, "a new prototype opens in a tab") }
        check(created.manifest.title == "Admin" && created.manifest.brief == "An admin console" && created.manifest.sources == ["docs"], "a new prototype is built from the title, the brief and the sources")
        host.create(title: "From code", brief: "", sources: [], mode: .code)
        check(rig.tabs.openTabs.filter { if case .prototype = $0.kind { return true } else { return false } }.count == 2,
              "existing code is not reconstructed: no prototype tab for it")
    }

    // MARK: Discussions

    typealias Runner = AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner

    final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [CLICompletion.Request] = []
        private var cancelled = false
        func saw(_ request: CLICompletion.Request) { lock.lock(); requests.append(request); lock.unlock() }
        var seen: [CLICompletion.Request] { lock.lock(); defer { lock.unlock() }; return requests }
        func sawCancel() { lock.lock(); cancelled = true; lock.unlock() }
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func answering(_ spy: Spy, text: String) -> Runner {
        { request, onDelta, onActivity in
            spy.saw(request)
            onActivity?(.read("/project/Sources/App.swift"))
            onDelta?("Offline works ")
            onDelta?("for documents.")
            return CLICompletion.Result(text: text)
        }
    }

    /// An assistant that writes a part of an answer and then goes on until it is cancelled.
    static func lingering(_ spy: Spy) -> Runner {
        { request, onDelta, _ in
            spy.saw(request)
            onDelta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { spy.sawCancel(); throw error }
            return CLICompletion.Result(text: "late")
        }
    }

    @MainActor
    static func discussionChecks() async {
        let root = folder("discussions")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = folder("discussions-outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        let project = FakeProject(root: root)
        let tools = FakeTools()

        // An answer: streamed, parsed, and kept as a turn with its decisions and open questions.
        let spy = Spy()
        let notes = "\n```discussion-notes\n{\"decisions\": [\"Documents only\"], \"open_questions\": [\"Sync back?\"]}\n```"
        let host = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: answering(spy, text: "Offline works for documents." + notes))
        host.projectOpened(root)
        let slug = host.store.create(title: "Offline mode", scope: "Sources")!
        host.ask(slug, question: "   ")
        check(host.store.asking == nil, "an empty question is not asked")
        host.ask(slug, question: "  Which data must work offline?  ")
        check(host.store.asking == slug && host.store.live?.question == "Which data must work offline?", "a question being answered shows at once")
        host.ask(slug, question: "A second question")
        check(await waitUntil { host.store.asking == nil }, "the answer ends")
        let turn = host.store.discussions.first { $0.slug == slug }?.turns.first
        check(host.store.discussions.first?.turns.count == 1 && turn?.question == "Which data must work offline?" && turn?.answer == "Offline works for documents.",
              "one answer becomes one turn, the question asked while answering is dropped")
        check(host.store.discussions.first?.items(.decision).map(\.text) == ["Documents only"] && host.store.discussions.first?.items(.question).map(\.text) == ["Sync back?"],
              "the answer's decisions and open questions are kept")
        check(host.store.live == nil && host.store.lastError == nil, "a finished answer leaves nothing live")
        let sent = spy.seen
        check(sent.count == 1 && sent[0].label == "discussion" && sent[0].effort == "medium" && sent[0].timeout == 900
              && sent[0].systemPrompt == DiscussionPrompt.system && sent[0].project == root && sent[0].readableFolder == root,
              "the assistant reads the project, read-only, with the discussion's own system prompt")

        // A conversation about something outside the project reads that folder and the project.
        let away = host.store.create(title: "Outside", scope: outside.path)!
        host.ask(away, question: "What is there?")
        check(await waitUntil { host.store.asking == nil }, "the second answer ends")
        let last = spy.seen.last
        check(last?.readableFolder == outside && last?.extraReadableFolders == [root], "a conversation outside the project reads that folder and the project")

        // The assistant says nothing, or fails.
        let silent = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: answering(Spy(), text: "  \n"))
        silent.projectOpened(root)
        silent.ask(slug, question: "Anything?")
        check(await waitUntil { silent.store.asking == nil }, "an empty answer ends")
        check(silent.store.lastError == "The assistant gave no answer." && silent.store.discussions.first { $0.slug == slug }?.turns.count == 1, "an empty answer is an error, not a turn")
        let broken = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: { _, _, _ in throw NSError(domain: "assistant", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"]) })
        broken.projectOpened(root)
        broken.ask(slug, question: "Anything?")
        check(await waitUntil { broken.store.asking == nil }, "a failed answer ends")
        check(broken.store.lastError == "boom" && broken.store.live == nil, "a failed answer shows why")

        // Stop: what was written is dropped, no turn is added.
        let stopSpy = Spy()
        let stopping = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: lingering(stopSpy))
        stopping.projectOpened(root)
        stopping.ask(slug, question: "Long one")
        check(await waitUntil { stopping.store.live?.text == "Partial " }, "a part of the answer shows while it is written")
        stopping.stop()
        check(await waitUntil { stopping.store.asking == nil }, "stopping ends the answer")
        check(stopSpy.wasCancelled && stopping.store.live == nil && stopping.store.lastError == nil
              && stopping.store.discussions.first { $0.slug == slug }?.turns.count == 1, "a stopped answer is cancelled, quiet and not kept")
        stopping.ask(slug, question: "Again")
        check(await waitUntil { stopping.store.live?.text == "Partial " }, "a question can be asked again after a stop")

        // The folder closes under the answer: it ends with it, and nothing of it reaches the next folder.
        stopping.projectClosed()
        check(await waitUntil { stopSpy.wasCancelled } && stopping.store.root == nil && stopping.store.asking == nil, "an answer ends with the folder")
        stopping.projectOpened(root)
        check(stopping.store.asking == nil && stopping.store.discussions.first { $0.slug == slug }?.turns.count == 1, "the folder opened again has the turns that were kept, and no answer")

        // The window closes under the answer.
        let spyClosing = Spy()
        let closing = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: lingering(spyClosing))
        closing.projectOpened(root)
        closing.ask(slug, question: "Long one")
        check(await waitUntil { closing.store.live?.text == "Partial " }, "an answer is being written when the window closes")
        closing.close()
        check(await waitUntil { spyClosing.wasCancelled }, "closing the window cancels the answer being written")

        // Discuss: a discussion about a file or a folder, in the Discussions tab.
        let discuss = DiscussionsHost(project: project, showTab: { tools.open(.discussions) }, runner: answering(Spy(), text: "x"))
        discuss.projectOpened(root)
        let file = root.appendingPathComponent("Sources/App.swift")
        discuss.discuss(about: file)
        check(tools.opened == [.discussions], "Discuss opens the Discussions tab")
        check(discuss.store.selected?.scope == "Sources/App.swift" && discuss.store.selected?.title == "App.swift", "a file of the project is discussed by its project path")
        let count = discuss.store.discussions.count
        discuss.discuss(about: file)
        check(discuss.store.discussions.count == count, "a discussion that has no turns yet is reused")
        discuss.discuss(about: outside)
        check(discuss.store.selected?.scope == outside.path, "a folder outside the project is discussed by its full path")
        let noProject = DiscussionsHost(project: FakeProject(root: nil), showTab: { tools.open(.discussions) }, runner: answering(Spy(), text: "x"))
        let opened = tools.opened.count
        noProject.discuss(about: file)
        check(tools.opened.count == opened, "nothing is discussed without a project")
    }

    @MainActor
    static func main() async {
        await routerChecks()
        await uiStudioChecks()
        await deploymentsChecks()
        await prototypeChecks()
        await discussionChecks()
        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) check(s) failed\n".utf8))
            exit(1)
        }
        print("ToolTabsRouter: every tool opens once, the hosts keep their sessions and records, and an answer ends with its stop, its folder and its window")
    }
}
