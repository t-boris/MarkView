import AppKit
import Combine
import Foundation

// The window of a window-made-of-parts (AR-17): the shipping `WindowComposition` builds every part in one place, joins the parts that
// react to each other's events, and ends everything the window started when it closes, over the shipping `TaskBag`. The parts are
// stand-ins named like the real ones (`WindowCompositionStubs.swift`) that keep what they were given and record what the window asked of
// them; nothing is shown, started or typed.

var passed = 0
var failed = 0

func check(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("  ✓ \(label)")
    } else {
        failed += 1
        print("  ✗ FAIL: \(label)")
    }
}

/// Lets the Tasks a handler starts run.
func settle(_ seconds: Double = 0.2) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

/// The windows of the checks, kept alive as the app's manager is: a composition does not own the window it was made for.
@MainActor var windows: [StandInWindow] = []

/// The prompter the app gives a window (`AR-22`); the check asks whether the parts that ask the person were given this very one.
@MainActor let windowPrompts = ScriptedPrompts()

@MainActor
func makeComposition() -> (StandInWindow, WindowComposition) {
    Journal.reset()
    let window = StandInWindow()
    windows.append(window)
    let composition = WindowComposition(host: window, prompts: windowPrompts)
    return (window, composition)
}

@MainActor
func building() {
    print("-- the parts are built in one place, and only when they are used")
    let (window, composition) = makeComposition()
    check(Journal.built.count == 9 && Set(Journal.built) == ["project", "layout", "windowUI", "chrome", "requests", "theme", "tabs", "aiJobs", "gitClient"],
          "the plain parts, each once, are made with the composition (\(Journal.built))")
    check(composition.research === composition.research && composition.terminals === composition.terminals && composition.toolTabs === composition.toolTabs,
          "a part is made once, whoever asks")
    check(composition.terminals.project === composition.project && composition.terminals.tasks === composition.taskBag,
          "the terminals work on the window's own project and task bag")
    check(composition.terminals.host === window, "the window is handed to a part as its host, not found afterwards")
    check(composition.project.prompts as AnyObject === windowPrompts && composition.tabs.prompts as AnyObject === windowPrompts
          && composition.terminals.prompts as AnyObject === windowPrompts,
          "the parts that ask the person (the project, the tabs, the terminals) are given the prompter the app gave the window")
    check(composition.browser.prompts as AnyObject === windowPrompts && composition.codeXRay.prompts as AnyObject === windowPrompts
          && composition.insight.prompts as AnyObject === windowPrompts,
          "so are the parts made when first needed (the browser, the code and X-Ray, Recursive Insight)")
    check(composition.flow.terminals === composition.terminals && composition.flow.research === composition.research && composition.flow.gitClient === composition.gitClient,
          "the feature flow is given the window's terminals, research and Git client")
    check(composition.browser.terminals === composition.terminals && composition.browser.tabs === composition.tabs,
          "the browser is given the window's terminals and tabs")
    check(composition.toolTabs.features === composition.flow.features && composition.toolTabs.terminals === composition.terminals && composition.toolTabs.tabs === composition.tabs,
          "the tools are given the flow's feature store, the window's terminals and tabs")
    check(composition.research.project === composition.project && composition.codeXRay.project === composition.project
          && composition.insight.tasks === composition.taskBag && composition.translator.tasks === composition.taskBag
          && composition.fileOperations.tabs === composition.tabs,
          "research, the X-Ray, Insight, the translator and the file operations all share the window's project, task bag and tabs")

    let (_, fresh) = makeComposition()
    fresh.connect()
    check(Journal.built.contains("flow") && Journal.built.contains("codeXRay") && Journal.built.contains("terminals") && Journal.built.contains("research"),
          "joining the parts makes the ones it listens to (the feature flow, the X-Ray) and what they are made of")
    check(!Journal.built.contains("browser") && !Journal.built.contains("toolTabs") && !Journal.built.contains("fileOperations")
          && !Journal.built.contains("translator") && !Journal.built.contains("insight"),
          "a window that opens no browser, tool, translation, file operation or Insight does not pay for them")
}

@MainActor
func joining() async {
    print("-- the parts that react to each other's events are joined once")
    let (_, composition) = makeComposition()
    composition.connect()
    check(composition.terminals.polling === composition.polling && composition.tabs.polling === composition.polling && composition.project.fileTree.polling === composition.polling,
          "the window's polls are one scheduler, shared by the terminals, the tabs and the file tree")
    let project = composition.project
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("composition-project", isDirectory: true)
    project.rootNode = FileNode(url: root)

    composition.flow.gitHub.selectedRepo = GitHubRepo(slug: "o/r")
    check(composition.codeXRay.architecture.review.gitHubRepo == GitHubRepo(slug: "o/r"), "the repository the GitHub flow works with reaches the X-Ray")
    composition.flow.gitHub.selectedRepo = nil
    check(composition.codeXRay.architecture.review.gitHubRepo == nil, "and follows it when it goes")

    composition.tabs.emit(.saved(root.appendingPathComponent("docs/a.md")))
    check(composition.codeXRay.architecture.projectChanges == 1, "a file saved in the project is a change the code analysis refreshes from")
    composition.tabs.emit(.saved(FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere.md")))
    composition.tabs.emit(.saved(root.deletingLastPathComponent().appendingPathComponent("composition-project-other/b.md")))
    check(composition.codeXRay.architecture.projectChanges == 1, "a file saved outside the project, or beside it in a folder of a similar name, is not")
    composition.tabs.emit(.reloadedFromDisk)
    check(project.fileTree.refreshes == 1, "tabs that took what changed on disk refresh the file tree")
    let terminal = UUID()
    composition.tabs.emit(.terminalClosed(terminal))
    check(composition.terminals.closedTabTerminals == [terminal], "a closed terminal tab ends its shell")
    let session = InsightSession()
    composition.tabs.emit(.insightClosed(session))
    check(composition.insight.closed == [session.id], "a closed Insight tab ends its session")

    let git = composition.gitClient
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await settle()
    check(git.looks == 0, "coming back to the app does not look at Git in a folder that is no repository")
    git.isGitRepo = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await settle()
    check(git.looks == 1, "coming back to the app looks at the Git status again")
    git.isOperating = true
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    await settle()
    check(git.looks == 1, "but not while Git is working")

    project.fileTree.timerBeats.send()
    await settle()
    check(git.statusLooks == 0, "a beat of the file watcher looks at nothing while Git is working or the app is not in front")

    var changes = 0
    let listening = composition.changes.sink { changes += 1 }
    project.objectWillChange.send()
    composition.codeXRay.objectWillChange.send()
    check(changes == 2, "a change of the project or of the code analysis is one change of the window")
    listening.cancel()
}

@MainActor
func closing() async {
    print("-- closing the window ends what it started")
    let (_, composition) = makeComposition()
    composition.connect()
    _ = composition.browser
    _ = composition.toolTabs
    Journal.shutdown = []

    let stoppedFlag = Flag()
    let pending = Task { @MainActor in
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
        stoppedFlag.value = true
    }
    composition.taskBag.store(pending, for: "openFolder")
    composition.taskBag.store(Task { @MainActor in
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
    }, for: "wikilink:note")
    check(composition.taskBag.activeCount == 2, "the window's commands have work running")
    composition.polling.every(60, key: "watch") { }
    check(composition.polling.keys == ["watch"], "the window's polls run in its own scheduler")

    composition.close()
    check(Journal.shutdown == ["tabs", "project", "codeXRay", "flow", "browser", "toolTabs", "gitClient"],
          "every part ends its own work, tabs first and the Git client last (\(Journal.shutdown))")
    await settle()
    check(composition.taskBag.activeCount == 0 && pending.isCancelled && stoppedFlag.value, "no task of the window is left running")
    check(composition.polling.keys.isEmpty, "and no poll of the window is left scheduled")

    composition.tabs.emit(.reloadedFromDisk)
    composition.tabs.emit(.terminalClosed(UUID()))
    composition.flow.gitHub.selectedRepo = GitHubRepo(slug: "late/repo")
    check(composition.project.fileTree.refreshes == 0 && composition.terminals.closedTabTerminals.isEmpty
          && composition.codeXRay.architecture.review.gitHubRepo == nil, "a closed window no longer follows the events of its parts")
}

@MainActor final class Flag { var value = false }

@MainActor
enum WindowCompositionChecks {
    static func main() async {
        _ = NSApplication.shared
        building()
        await joining()
        await closing()
        print("Window composition summary: \(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

@main
struct WindowCompositionMain {
    static func main() async { await WindowCompositionChecks.main() }
}
