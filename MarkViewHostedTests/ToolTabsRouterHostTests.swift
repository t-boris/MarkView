import Foundation
import AppKit
import Darwin
import MarkViewCore
import XCTest
@testable import MarkView

@MainActor
private final class RoutingAssistant: AssistantPrompting {
    var assistantIsBusy = false
    private(set) var prompts: [(text: String, submit: Bool)] = []
    func sendToAssistant(_ prompt: String, submit: Bool) -> TerminalSession? {
        prompts.append((prompt, submit))
        return nil
    }
    func sendToAssistant(submit: Bool, to terminal: TerminalSession?, promptFor: (TerminalSession) -> String?) -> TerminalSession? { nil }
}

private final class DiscussionRunnerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [CLICompletion.Request] = []
    private var cancellations = 0
    func record(_ request: CLICompletion.Request) { lock.lock(); requests.append(request); lock.unlock() }
    func recordCancellation() { lock.lock(); cancellations += 1; lock.unlock() }
    var seen: [CLICompletion.Request] { lock.lock(); defer { lock.unlock() }; return requests }
    var cancellationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
}

extension EditorHostTests {
    @MainActor func testRealBrowserHostTabLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-routing-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        window.chrome.showCenter = false
        window.layout.workspaceArea = .work
        let browser = window.browser
        let first = browser.open(nil)
        XCTAssertEqual(first.agentName, "T1")
        XCTAssertEqual(window.tabs.openTabs.count, 1)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertTrue(window.chrome.showCenter)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertEqual(window.tabs.openTabs[0].url.deletingLastPathComponent().path, root.path)
        if case .browser(let session) = window.tabs.openTabs[0].kind {
            XCTAssertTrue(session === first)
        } else {
            XCTFail("The new tab must contain the browser session")
        }
        first.agentName = "Jira"
        let second = browser.open(nil)
        let third = browser.open(nil)
        XCTAssertEqual(second.agentName, "T1")
        XCTAssertEqual(third.agentName, "T2")
        XCTAssertEqual(browser.sessions.map(\.id), [first.id, second.id, third.id])
        window.chrome.showCenter = false
        window.layout.workspaceArea = .work
        browser.show(first)
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        browser.show(BrowserSession(url: nil, prompts: NoPrompts()))
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        let fourth = browser.open(nil, activate: false)
        XCTAssertEqual(fourth.agentName, "T3")
        XCTAssertEqual(window.tabs.activeTabIndex, 0)
        browser.browserSession(first, openInNewTab: try XCTUnwrap(URL(string: "http://127.0.0.1:1/new")))
        XCTAssertEqual(browser.sessions.count, 5)
        XCTAssertEqual(browser.sessions.last?.url?.path, "/new")
        XCTAssertEqual(window.tabs.activeTabIndex, 4)
    }

    @MainActor func testRealToolTabsRoutingAndProjectLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tool-routing-" + UUID().uuidString)
        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blank = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("blank.json"))
        defer { blank.composition.close() }
        blank.toolTabs.open(.git)
        XCTAssertTrue(blank.tabs.openTabs.isEmpty, "A tool cannot open without a project")
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: first, isDirectory: true)
        let router = window.toolTabs
        XCTAssertTrue(router.qa.assistants === window.terminals)
        let tools = ToolRegistry.shared.tools
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) opens once")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        for tool in tools {
            router.open(tool.id)
            XCTAssertEqual(window.tabs.openTabs.filter { $0.kind.toolID == tool.id }.count, 1, "\(tool.id.rawValue) is reused")
            XCTAssertEqual(window.tabs.activeTab?.kind.toolID, tool.id)
        }
        XCTAssertEqual(window.tabs.openTabs.count, tools.count)
        XCTAssertEqual(window.layout.workspaceArea, .files)
        XCTAssertTrue(window.chrome.showCenter)
        XCTAssertEqual(router.deployments.store.root, first)
        XCTAssertEqual(router.discussions.store.root, first)
        XCTAssertEqual(router.qa.root, first)
        XCTAssertNotNil(router.qa.run.bugFiler)
        XCTAssertTrue(router.qa.run.bugFiler === router.qa.archive.bugFiler)
        XCTAssertTrue(router.qa.run.runLinks is CockpitRunLinks)
        XCTAssertTrue(router.qa.archive.runLinks is CockpitRunLinks)
        guard let studioTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .uiStudio }),
              case .uiStudio(let studio) = studioTab.kind,
              let cockpitTab = window.tabs.openTabs.first(where: { $0.kind.toolID == .cockpit }),
              case .cockpit(let cockpit) = cockpitTab.kind else {
            XCTFail("UI Studio and Cockpit must carry their actual sessions")
            return
        }
        XCTAssertEqual(studio.root, first)
        XCTAssertEqual(cockpit.root, first)
        let cockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: cockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let reopened)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not reopen"); return }
        XCTAssertTrue(reopened === cockpit)
        let deploymentIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .deployments })
        window.tabs.closeTab(at: deploymentIndex)
        router.deployments.store.needsAttention.send()
        XCTAssertEqual(window.tabs.activeTab?.kind.toolID, .deployments)
        router.projectOpened(second)
        XCTAssertEqual(router.deployments.store.root, second)
        XCTAssertEqual(router.discussions.store.root, second)
        router.projectClosed()
        XCTAssertNil(router.deployments.store.root)
        XCTAssertNil(router.discussions.store.root)
        let oldCockpitIndex = try XCTUnwrap(window.tabs.openTabs.firstIndex { $0.kind.toolID == .cockpit })
        window.tabs.closeTab(at: oldCockpitIndex)
        router.open(.cockpit)
        guard case .cockpit(let renewed)? = window.tabs.activeTab?.kind else { XCTFail("Cockpit did not renew"); return }
        XCTAssertFalse(renewed === cockpit)
        await studio.close()
    }

    @MainActor func testRealDiscussionHostLifecycle() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-routing-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let suite = "discussion-routing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = ProjectContext(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"), settings: Settings(defaults))
        project.beginOpening(root)
        project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<500 {
                if condition() { return true }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        func expectEventually(_ condition: () -> Bool, line: UInt = #line) async throws {
            let reached = try await wait(condition)
            XCTAssertTrue(reached, "Expected condition was not reached", line: line)
        }
        let spy = DiscussionRunnerSpy()
        let notes = "\n```discussion-notes\n{\"decisions\": [\"Documents only\"], \"open_questions\": [\"Sync back?\"]}\n```"
        let answer: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, onDelta, onActivity in
            spy.record(request)
            onActivity?(.read("/project/Sources/App.swift"))
            onDelta?("Offline works ")
            onDelta?("for documents.")
            return try CLICompletion.Result(text: "Offline works for documents." + notes, structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        var opened = 0
        let host = DiscussionsHost(project: project, showTab: { opened += 1 }, runner: answer)
        defer { host.close() }
        host.projectOpened(root)
        let slug = try XCTUnwrap(host.store.create(title: "Offline mode", scope: "Sources"))
        host.ask(slug, question: "   ")
        XCTAssertNil(host.store.asking)
        host.ask(slug, question: "  Which data must work offline?  ")
        XCTAssertEqual(host.store.asking, slug)
        XCTAssertEqual(host.store.live?.question, "Which data must work offline?")
        host.ask(slug, question: "A second question")
        let finished = try await wait { host.store.asking == nil }
        XCTAssertTrue(finished)
        let discussion = try XCTUnwrap(host.store.discussions.first { $0.slug == slug })
        XCTAssertEqual(discussion.turns.count, 1)
        XCTAssertEqual(discussion.turns.first?.question, "Which data must work offline?")
        XCTAssertEqual(discussion.turns.first?.answer, "Offline works for documents.")
        XCTAssertEqual(discussion.items(.decision).map(\.text), ["Documents only"])
        XCTAssertEqual(discussion.items(.question).map(\.text), ["Sync back?"])
        XCTAssertNil(host.store.live)
        XCTAssertNil(host.store.lastError)
        let sent = try XCTUnwrap(spy.seen.first)
        XCTAssertEqual(spy.seen.count, 1)
        XCTAssertEqual(sent.label, "discussion")
        XCTAssertEqual(sent.effort, "medium")
        XCTAssertEqual(sent.timeout, 900)
        XCTAssertEqual(sent.systemPrompt, DiscussionPrompt.system)
        XCTAssertEqual(sent.project, root)
        XCTAssertEqual(sent.readableFolder, root)
        let away = try XCTUnwrap(host.store.create(title: "Outside", scope: outside.path))
        host.ask(away, question: "What is there?")
        try await expectEventually { host.store.asking == nil }
        XCTAssertEqual(spy.seen.last?.readableFolder, outside)
        XCTAssertEqual(spy.seen.last?.extraReadableFolders, [root])

        let silent = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            try CLICompletion.Result(text: "  \n", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        defer { silent.close() }
        silent.projectOpened(root)
        silent.ask(slug, question: "Anything?")
        try await expectEventually { silent.store.asking == nil }
        XCTAssertEqual(silent.store.lastError, "The assistant gave no answer.")
        XCTAssertEqual(silent.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let broken = DiscussionsHost(project: project, showTab: {}, runner: { _, _, _ in
            throw NSError(domain: "assistant", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        })
        defer { broken.close() }
        broken.projectOpened(root)
        broken.ask(slug, question: "Anything?")
        try await expectEventually { broken.store.asking == nil }
        XCTAssertEqual(broken.store.lastError, "boom")
        XCTAssertNil(broken.store.live)

        let stopSpy = DiscussionRunnerSpy()
        let lingering: AIOperation<CLICompletion.Request, CLICompletion.Result>.Runner = { request, delta, _ in
            stopSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { stopSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        }
        let stopping = DiscussionsHost(project: project, showTab: {}, runner: lingering)
        defer { stopping.close() }
        stopping.projectOpened(root)
        stopping.ask(slug, question: "Long one")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.stop()
        try await expectEventually { stopping.store.asking == nil }
        XCTAssertEqual(stopSpy.cancellationCount, 1)
        XCTAssertNil(stopping.store.live)
        XCTAssertNil(stopping.store.lastError)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        stopping.ask(slug, question: "Again")
        try await expectEventually { stopping.store.live?.text == "Partial " }
        stopping.projectClosed()
        try await expectEventually { stopSpy.cancellationCount == 2 }
        XCTAssertNil(stopping.store.root)
        XCTAssertNil(stopping.store.asking)
        stopping.projectOpened(root)
        XCTAssertEqual(stopping.store.discussions.first { $0.slug == slug }?.turns.count, 1)
        let closeSpy = DiscussionRunnerSpy()
        let closing = DiscussionsHost(project: project, showTab: {}, runner: { request, delta, _ in
            closeSpy.record(request)
            delta?("Partial ")
            do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { closeSpy.recordCancellation(); throw error }
            return try CLICompletion.Result(text: "late", structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
        })
        closing.projectOpened(root)
        closing.ask(slug, question: "Long one")
        try await expectEventually { closing.store.live?.text == "Partial " }
        closing.close()
        try await expectEventually { closeSpy.cancellationCount == 1 }

        let file = root.appendingPathComponent("Sources/App.swift")
        host.discuss(about: file)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(host.store.selected?.scope, "Sources/App.swift")
        XCTAssertEqual(host.store.selected?.title, "App.swift")
        let count = host.store.discussions.count
        host.discuss(about: file)
        XCTAssertEqual(host.store.discussions.count, count)
        host.discuss(about: outside)
        XCTAssertEqual(host.store.selected?.scope, outside.path)
        project.fileTree.rootNode = nil
        let countOpened = opened
        host.discuss(about: file)
        XCTAssertEqual(opened, countOpened)
    }

    @MainActor func testRealDeploymentHostApprovalAndAssistantRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deployment-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let assistant = RoutingAssistant()
        let host = DeploymentsHost(project: window.project, assistants: assistant, showTab: {})
        defer { host.close() }
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertTrue(assistant.prompts[0].submit)
        XCTAssertTrue(assistant.prompts[0].text.contains(root.lastPathComponent))
        assistant.assistantIsBusy = true
        host.analyzeWithAI()
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        host.projectOpened(root)
        host.store.add(DeploymentEnvironment(id: "prod", name: "Production", kind: .local))
        host.store.lastError = nil
        let prod = try XCTUnwrap(host.store.selected)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        XCTAssertEqual(host.store.lastError, "The assistant is still working.")
        assistant.assistantIsBusy = false
        host.askAssistant("missing", question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 1)
        host.askAssistant(prod, question: "Is it up?")
        XCTAssertEqual(assistant.prompts.count, 2)
        XCTAssertTrue(assistant.prompts[1].text.contains("Is it up?"))

        let polling = PollingScheduler()
        host.store.polling = polling
        host.store.autoRefresh = true
        XCTAssertEqual(polling.keys.count, 1)
        let command = "touch \(root.path)/never.txt"
        let asked = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 1)
        host.store.answer(false)
        guard case .denied = await asked.value else { return XCTFail("The refused command was not denied") }
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        let closing = Task { await host.store.run(command, on: prod, origin: "The assistant", purpose: "a test") }
        for _ in 0..<200 where host.store.approval == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(host.store.approval)
        host.close()
        guard case .denied = await closing.value else { return XCTFail("Closing did not deny the pending command") }
        XCTAssertNil(host.store.approval)
        XCTAssertEqual(host.store.tasks.activeCount, 0)
        XCTAssertTrue(polling.keys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("never.txt").path))
    }

    @MainActor func testRealStudioWindowServices() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("studio-services-" + UUID().uuidString)
        let root = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let note = root.appendingPathComponent("note.md")
        let stray = outside.appendingPathComponent("stray.md")
        try "Note".write(to: note, atomically: true, encoding: .utf8)
        try "Stray".write(to: stray, atomically: true, encoding: .utf8)
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: base.appendingPathComponent("recent.json"))
        defer { window.project.releaseDatabase(); window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let opened = try await window.project.openDatabase(at: root)
        XCTAssertTrue(opened)
        weak var database = window.project.database
        XCTAssertNotNil(database)
        window.toolTabs.open(.uiStudio)
        guard case .uiStudio(let studio)? = window.tabs.activeTab?.kind else { return XCTFail("UI Studio was not opened") }
        await window.tabs.openTextFile(note)
        await window.tabs.openTextFile(stray)
        XCTAssertTrue(studio.editorBuffers().isEmpty)
        for tab in window.tabs.openTabs where tab.isFileBacked {
            window.tabs.updateTabContent("Edited", documentID: tab.id)
        }
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"])
        window.project.fileTree.rootNode = FileNode(url: outside, isDirectory: true)
        XCTAssertEqual(studio.editorBuffers(), ["note.md": "Edited"], "The session retains its original root")
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        studio.recordUsage(10, 20, 0.5)
        studio.recordUsage(1, 2, 0.25)
        var usage = await window.project.database?.getUsageStats()
        for _ in 0..<200 where (usage?.totalJobs ?? 0) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
            usage = await window.project.database?.getUsageStats()
        }
        let stats = try XCTUnwrap(usage)
        XCTAssertEqual(stats.totalJobs, 2)
        XCTAssertEqual(stats.totalInputTokens, 11)
        XCTAssertEqual(stats.totalOutputTokens, 22)
        XCTAssertEqual(stats.totalCostCents, 75, accuracy: 0.001)
        studio.openFile(note)
        for _ in 0..<200 where window.tabs.activeTab?.url != note {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(window.tabs.activeTab?.url, note)
        studio.windowServices?.studioDidExportFeature("feature-one")
        XCTAssertEqual(window.layout.issuesFeature, "feature-one")
        XCTAssertTrue(studio.featureStore() === window.flow.features)
        await studio.close()
        window.toolTabs.uiStudio.close()
        window.project.releaseDatabase()
        for _ in 0..<200 where database != nil { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(database, "The temporary database must close before its folder is removed")
    }

    @MainActor func testRealPrototypeStudioRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prototype-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = WorkspaceManager(prompts: QAPlayerPrompts(), recentFilesURL: root.appendingPathComponent("recent.json"))
        defer { window.composition.close() }
        window.project.fileTree.rootNode = FileNode(url: root, isDirectory: true)
        let host = window.toolTabs.prototypes
        XCTAssertTrue(host.saved().isEmpty)
        let manifest = PrototypeFiles.Manifest(title: "Support Desk", slug: "support-desk", brief: "", sources: [], version: 3,
                                               approved: true, history: [.init(version: 3, instruction: "", summary: "", date: Date())])
        try PrototypeFiles.saveManifest(manifest, in: PrototypeFiles.folder(root: root, slug: manifest.slug))
        XCTAssertEqual(host.saved().map(\.label), ["Support Desk · v3 · approved"])

        host.openCreator(mode: .requirements)
        XCTAssertTrue(window.requests.showPrototypeCreator)
        XCTAssertEqual(window.requests.prototypeCreatorMode, .requirements)
        window.requests.showPrototypeCreator = false
        host.openCreator(mode: .code)
        XCTAssertFalse(window.requests.showPrototypeCreator)
        let studios = window.tabs.openTabs.filter { if case .uiStudio = $0.kind { return true }; return false }
        XCTAssertEqual(studios.count, 1)
        guard let studioTab = studios.first, case .uiStudio(let studio) = studioTab.kind else {
            return XCTFail("UI Studio was not opened")
        }

        host.openSaved(manifest.slug)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not opened") }
        let count = window.tabs.openTabs.count
        window.tabs.activeTabIndex = 0
        host.openSaved(manifest.slug)
        XCTAssertEqual(window.tabs.openTabs.count, count)
        guard case .prototype? = window.tabs.activeTab?.kind else { return XCTFail("Saved prototype was not selected") }

        host.create(title: "Admin", brief: "An admin console", sources: ["docs"])
        guard case .prototype(let created)? = window.tabs.activeTab?.kind else { return XCTFail("New prototype was not opened") }
        XCTAssertEqual(created.manifest.title, "Admin")
        XCTAssertEqual(created.manifest.brief, "An admin console")
        XCTAssertEqual(created.manifest.sources, ["docs"])
        host.create(title: "From code", brief: "", sources: [], mode: .code)
        XCTAssertEqual(window.tabs.openTabs.filter { if case .prototype = $0.kind { return true }; return false }.count, 2)
        await studio.close()
    }

}
