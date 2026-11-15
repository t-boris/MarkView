import Foundation

// The research maps of a window (AR-14 step 3): the shipping ResearchMapController, ResearchJobs and ResearchMap run over real map files
// and real folders, with a stand-in window (`StubWindow`) that holds the tabs. No assistant is started and nothing is shown.

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

@MainActor
final class StubWindow: ResearchHost {
    struct Tab {
        let id = UUID()
        var url: URL
        var text: String
        var modified: Bool
    }

    var root: URL?
    var tabs: [Tab] = []
    var selected = 0
    var events: [String] = []
    var opened: [(url: URL, line: Int?, endLine: Int?)] = []
    var researchRoot: URL? { root }
    var semanticDatabase: SemanticDatabase? { nil }

    func tab(_ file: URL) -> Tab? { tabs.first { $0.url.standardizedFileURL == file.standardizedFileURL } }

    func researchTab(for file: URL) -> ResearchTabText? {
        tab(file).map { ResearchTabText(text: $0.text, isModified: $0.modified) }
    }

    func researchTabSaved(_ file: URL, text: String) {
        guard let index = tabs.firstIndex(where: { $0.url.standardizedFileURL == file.standardizedFileURL }) else { return }
        tabs[index].text = text
        tabs[index].modified = false
        events.append("saved")
    }

    func researchEditorFile(documentID: UUID?, event: String) -> URL? {
        if let documentID { return tabs.first { $0.id == documentID }?.url }
        return tabs.indices.contains(selected) ? tabs[selected].url : nil
    }

    func researchWatchOpenFiles() { events.append("watch") }
    func openFile(_ url: URL) { opened.append((url, nil, nil)) }
    func openFile(_ url: URL, line: Int?, endLine: Int?) { opened.append((url, line, endLine)) }
    func refreshFileTree() { events.append("refresh") }
    func saveBeforeResearch(_ file: URL, action: String) -> Bool { true }
    func researchDocumentChanged(_ file: URL, content: String, applyToEdited: (String) -> String?) {}
}

let fm = FileManager.default
let sandbox = fm.temporaryDirectory.appendingPathComponent("research-map-controller-tests-\(UUID().uuidString)", isDirectory: true)
try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)

func write(_ text: String, to url: URL) {
    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

func parsed(_ text: String) -> ResearchMap? {
    if case .success(let map) = ResearchMap.parse(text) { return map }
    return nil
}

func snapshot(_ reply: ResearchMapController.Reply?) -> [String: Any] {
    guard let reply, let object = try? JSONSerialization.jsonObject(with: Data(reply.json.utf8)) as? [String: Any] else { return [:] }
    return object
}

func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

/// A map in a fresh project: the root node and the `docs/notes.md` the sources point at.
@MainActor
func makeProject(_ name: String, complete: Bool = true) -> (project: URL, map: URL, window: StubWindow, controller: ResearchMapController, tasks: TaskBag) {
    let project = sandbox.appendingPathComponent(name, isDirectory: true)
    let map = project.appendingPathComponent("docs/research/map.md")
    var model = ResearchMap.new(id: "map-\(name)", question: "How does login work?", created: "2026-01-01", targets: [], attachments: [])
    if complete { model.markComplete() }
    write(model.markdown(), to: map)
    write("line 1\nline 2\nline 3\nline 4\nline 5\n", to: project.appendingPathComponent("docs/notes.md"))
    let window = StubWindow()
    window.root = project
    let tasks = TaskBag()
    return (project, map, window, ResearchMapController(host: window, tasks: tasks), tasks)
}

@MainActor
func run() async {
    print("=== Research maps of a window (AR-14 step 3) ===")

    // 1. The single writer of a map file.
    print("\n-- the map file")
    do {
        let env = makeProject("writer")
        check(env.controller.text(of: env.map) == read(env.map), "with no tab the map's text is the disk's")
        let added = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Sessions") }
        var text = ""
        if case .done(let done) = added { text = done }
        check(text == read(env.map) && parsed(text)?.nodes.contains { $0.title == "Sessions" } == true, "a change is written to the file at once and reported as done")
        check(env.window.events.isEmpty, "with no tab open no tab is told anything")

        env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
        _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Tokens") }
        check(env.window.tab(env.map)?.text == read(env.map) && env.window.tab(env.map)?.modified == false && env.window.events == ["saved"],
              "the tab that holds the map takes the new text as saved")

        // A tab behind the disk (another editor saved less than two seconds ago): the change goes onto the disk text.
        var external = parsed(read(env.map))!
        _ = try? external.addChild(parent: "n1", title: "Saved elsewhere")
        write(external.markdown(), to: env.map)
        _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "After external") }
        let titles = parsed(read(env.map))?.nodes.map(\.title) ?? []
        check(titles.contains("Saved elsewhere") && titles.contains("After external"), "a tab behind the disk never overwrites what another editor saved")

        // A tab with unsaved edits: the change goes onto the text of the tab.
        var edited = parsed(read(env.map))!
        _ = try? edited.addChild(parent: "n1", title: "Typed in the editor")
        env.window.tabs[0].text = edited.markdown()
        env.window.tabs[0].modified = true
        check(env.controller.text(of: env.map) == edited.markdown(), "a tab with unsaved edits is the map's text")
        _ = env.controller.update(env.map) { _ = try $0.addChild(parent: "n1", title: "Then by the AI") }
        let merged = parsed(read(env.map))?.nodes.map(\.title) ?? []
        check(merged.contains("Typed in the editor") && merged.contains("Then by the AI") && env.window.tab(env.map)?.modified == false,
              "a change keeps what was typed in the tab, and the map is then saved")

        let before = read(env.map)
        let tabBefore = env.window.tab(env.map)?.text
        if case .rejected(let reason) = env.controller.update(env.map, { _ = try $0.delete(id: "no-such-node") }) {
            check(!reason.isEmpty && read(env.map) == before && env.window.tab(env.map)?.text == tabBefore, "a refused change names the reason and leaves the file and the tab as they were")
        } else {
            check(false, "a refused change is reported as rejected")
        }
        let eventsBefore = env.window.events.count
        if case .done(let same) = env.controller.update(env.map, { _ in }) {
            check(same == before && read(env.map) == before && env.window.events.count == eventsBefore, "a change that changes nothing writes nothing")
        } else {
            check(false, "a no-op change is done")
        }
        if case .unreadable = env.controller.update(sandbox.appendingPathComponent("missing.md"), { _ in }) {
            check(true, "a map file that is gone is unreadable")
        } else {
            check(false, "a map file that is gone is unreadable")
        }
        let notAMap = env.project.appendingPathComponent("notes-only.md")
        write("just text\n", to: notAMap)
        if case .unreadable(let why) = env.controller.update(notAMap, { _ in }) {
            check(!why.isEmpty && read(notAMap) == "just text\n", "a file that is not a map is unreadable and untouched")
        } else {
            check(false, "a file that is not a map is unreadable")
        }
    }

    // 2. The page.
    print("\n-- the page's actions")
    do {
        let env = makeProject("page")
        env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
        let documentID = env.window.tabs[0].id

        check(env.controller.handleAction("snapshot", payload: [:], documentID: UUID()) == nil, "an action for a tab that is closed is dropped")
        check(env.controller.handleAction("no-such-action", payload: [:], documentID: documentID) == nil, "an unknown action is dropped")
        check(env.window.events.contains("watch"), "an action asks the window to watch the open files for outside edits")

        let first = env.controller.handleAction("snapshot", payload: [:], documentID: documentID)
        let shot = snapshot(first)
        check(shot["ok"] as? Bool == true && (shot["nodes"] as? [[String: Any]])?.count == 1 && first?.content == read(env.map)
              && (shot["markdown"] as? String) == read(env.map),
              "the snapshot carries the nodes and the text of the tab for the Source view")

        let added = snapshot(env.controller.handleAction("addChild", payload: ["parent": "n1", "title": "Sessions"], documentID: documentID))
        let createdID = added["created"] as? String ?? ""
        check(!createdID.isEmpty && parsed(read(env.map))?.node(createdID)?.title == "Sessions", "Add child writes the node and tells the page which one to select")

        let updated = snapshot(env.controller.handleAction("update", payload: ["id": createdID, "tags": ["auth"], "description": "How sessions end."], documentID: documentID))
        let node = parsed(read(env.map))?.node(createdID)
        check(node?.tags == ["auth"] && node?.description == "How sessions end." && updated["notice"] as? String == "", "Update sets what the page sends and leaves the rest")

        let badPosition = snapshot(env.controller.handleAction("moveVisual", payload: ["id": createdID, "x": "left", "y": 1], documentID: documentID))
        check(badPosition["notice"] as? String == "That position is not valid.", "a position that is not a number is refused at the boundary")
        _ = env.controller.handleAction("moveVisual", payload: ["id": createdID, "x": 120, "y": 80], documentID: documentID)
        check(parsed(read(env.map))?.node(createdID)?.x == 120 && parsed(read(env.map))?.node(createdID)?.y == 80, "a position is stored on the node")

        _ = env.controller.handleAction("addChild", payload: ["parent": "n1", "title": "Tokens"], documentID: documentID)
        let tokens = parsed(read(env.map))?.nodes.first { $0.title == "Tokens" }?.id ?? ""
        let linked = snapshot(env.controller.handleAction("link", payload: ["from": createdID, "to": tokens], documentID: documentID))
        check((linked["links"] as? [[String: Any]])?.count == 1, "Link adds a connection to the snapshot")
        let unlinked = snapshot(env.controller.handleAction("unlink", payload: ["from": createdID, "to": tokens], documentID: documentID))
        check((unlinked["links"] as? [[String: Any]])?.isEmpty == true, "Unlink removes it")
        _ = env.controller.handleAction("move", payload: ["id": tokens, "parent": createdID], documentID: documentID)
        check(parsed(read(env.map))?.node(tokens)?.parent == createdID, "Move makes a node the child of the one the arrow ends on")
        let refused = snapshot(env.controller.handleAction("delete", payload: ["id": "nope"], documentID: documentID))
        check(!(refused["notice"] as? String ?? "").isEmpty, "a refused action shows its reason as the notice")
        _ = env.controller.handleAction("delete", payload: ["id": tokens], documentID: documentID)
        check(parsed(read(env.map))?.node(tokens) == nil, "Delete removes the node")
        check(env.window.tab(env.map)?.text == read(env.map) && env.window.tab(env.map)?.modified == false, "the tab holds the map as the actions left it")

        // Actions that would start an assistant refuse first, and start nothing.
        let nothing = { env.controller.jobs.jobs.isEmpty && env.tasks.activeCount == 0 }
        let noNote = snapshot(env.controller.handleAction("correct", payload: ["id": createdID, "note": "  "], documentID: documentID))
        check(noNote["notice"] as? String == "Say what is wrong with this node." && nothing(), "Correct without a note starts no job")
        let badExport = snapshot(env.controller.handleAction("export", payload: ["kind": "docx"], documentID: documentID))
        check(badExport["notice"] as? String == "Choose Markdown report or PDF." && nothing(), "an export that is not Markdown or PDF starts no job")
        let gone = snapshot(env.controller.handleAction("develop", payload: ["id": "n99", "direction": ""], documentID: documentID))
        check(gone["notice"] as? String == "That node no longer exists." && nothing(), "Expand topic on a node that is gone starts no job")
        let noLanguage = snapshot(env.controller.handleAction("translate", payload: ["language": " ", "mode": "copy"], documentID: documentID))
        check(noLanguage["notice"] as? String == "Choose a language." && nothing(), "Translate without a language starts no job")

        // Sources of findings.
        let traversal = snapshot(env.controller.handleAction("open", payload: ["source": "../outside.txt"], documentID: documentID))
        check(traversal["notice"] as? String == "Only files inside the project can be opened." && env.window.opened.isEmpty, "a source outside the project is not opened")
        let absolute = snapshot(env.controller.handleAction("open", payload: ["source": "/etc/hosts"], documentID: documentID))
        check(absolute["notice"] as? String == "Only files inside the project can be opened." && env.window.opened.isEmpty, "an absolute source path is not opened")
        let missing = snapshot(env.controller.handleAction("open", payload: ["source": "docs/missing.md"], documentID: documentID))
        check((missing["notice"] as? String ?? "").contains("does not exist in the project") && env.window.opened.isEmpty, "a source that is not a file says so")
        let badWeb = snapshot(env.controller.handleAction("open", payload: ["source": "http://not a url"], documentID: documentID))
        check(badWeb["notice"] as? String == "That web address is not valid.", "a web address that is not valid is refused")
        let okay = snapshot(env.controller.handleAction("open", payload: ["source": "docs/notes.md:2-4"], documentID: documentID))
        check(okay["notice"] as? String == "" && env.window.opened.count == 1 && env.window.opened[0].url.lastPathComponent == "notes.md"
              && env.window.opened[0].line == 2 && env.window.opened[0].endLine == 4, "a project file with a line range opens at that range")
    }

    // 3. What a job hands to the next snapshot.
    print("\n-- notes from the jobs")
    do {
        let env = makeProject("notes")
        let key = env.map.standardizedFileURL.path
        env.controller.jobCreated[key] = "n2"
        env.controller.jobNotice[key] = "Report saved."
        func shot(_ text: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(env.controller.snapshotJSON(text: text, file: env.map).utf8)) as? [String: Any]) ?? [:]
        }
        let first = shot(read(env.map))
        let second = shot(read(env.map))
        check(first["created"] as? String == "n2" && first["notice"] as? String == "Report saved.", "the next snapshot carries the node and the notice a job left")
        check(second["created"] as? String == "" && second["notice"] as? String == "", "and only that one: they are used up")
        check(shot("not a map")["ok"] as? Bool == false, "text that is not a map gets the page's unreadable snapshot")
    }

    // 4. A map the app left researching.
    print("\n-- an interrupted map")
    do {
        let env = makeProject("interrupted", complete: false)
        env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
        let id = env.window.tabs[0].id
        check(parsed(read(env.map))?.status == .researching, "a new map says it is researching")
        let reply = snapshot(env.controller.handleAction("snapshot", payload: [:], documentID: id))
        check(parsed(read(env.map))?.status == .incomplete && reply["status"] as? String == "incomplete"
              && (reply["incomplete"] as? String) == "the research was interrupted", "with no job working on it the map becomes incomplete, so Continue is offered")

        let stopped = makeProject("stopped", complete: false)
        stopped.window.tabs = [.init(url: stopped.map, text: read(stopped.map), modified: false)]
        _ = stopped.controller.handleAction("cancel", payload: [:], documentID: stopped.window.tabs[0].id)
        check(parsed(read(stopped.map))?.incompleteReason == "stopped", "Stop on a map no job works on says it was stopped")

        // With a job working on the map, nothing is settled.
        let running = makeProject("running", complete: false)
        running.window.tabs = [.init(url: running.map, text: read(running.map), modified: false)]
        running.controller.jobs.launch(kind: .mapDevelop, file: running.map, title: "Expand topic: x") { job in
            job.update("Writing the map")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return nil
        }
        _ = await waitUntil { running.controller.jobs.mapJobInfo(for: running.map)?.step == "Writing the map" }
        let shot = snapshot(running.controller.handleAction("snapshot", payload: [:], documentID: running.window.tabs[0].id))
        check(parsed(read(running.map))?.status == .researching && (shot["job"] as? [String: Any])?["kind"] as? String == "develop"
              && (shot["job"] as? [String: Any])?["step"] as? String == "Writing the map", "while a job works on it the map stays researching and the snapshot names the job and its step")
        running.tasks.cancelAll()
        _ = await waitUntil { running.controller.jobs.jobs.isEmpty }
    }

    // 5. A picture for a node.
    print("\n-- a picture for a node")
    do {
        let env = makeProject("picture")
        env.window.tabs = [.init(url: env.map, text: read(env.map), modified: false)]
        let id = env.window.tabs[0].id
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        let failure = await env.controller.attachImage(["id": "n1", "name": "pic.png", "data": png], documentID: id)
        let node = parsed(read(env.map))?.node("n1")
        check(failure == "" && node?.image == "images/pic.png"
              && fm.fileExists(atPath: env.map.deletingLastPathComponent().appendingPathComponent("images/pic.png").path),
              "a picture is saved into images/ beside the map and set on the node")
        check(env.window.tab(env.map)?.text == read(env.map), "and the tab shows the node with it")
        let unreadable = await env.controller.attachImage(["id": "n1", "name": "x.png", "data": "!!!"], documentID: id)
        check(unreadable == "The picture could not be read.", "data that is not a picture is refused with the reason")
        let notPicture = await env.controller.attachImage(["id": "n1", "name": "x.png", "data": Data("hello".utf8).base64EncodedString()], documentID: id)
        check(notPicture == "Use a PNG, JPEG, GIF or WebP picture.", "a file of another kind is refused")
        let noNode = await env.controller.attachImage(["id": "", "name": "x.png", "data": png], documentID: id)
        check(noNode == "That node no longer exists.", "a picture for no node is refused")
        let closed = await env.controller.attachImage(["id": "n1", "name": "y.png", "data": png], documentID: UUID())
        check(closed == "" && parsed(read(env.map))?.node("n1")?.image == "images/pic.png", "a picture for a tab that is closed changes nothing")
    }

    // 6. The jobs' tasks belong to the window.
    print("\n-- jobs and the window's task bag")
    do {
        let env = makeProject("jobs")
        let jobs = env.controller.jobs
        var finished: [String] = []
        jobs.launch(kind: .mapDevelop, file: env.map, title: "Expand topic: a") { job in
            job.update("Thinking")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            finished.append("first")
            return "Developing the branch stopped."
        }
        jobs.launch(kind: .mapDescribe, file: env.map, title: "Expand description: b") { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            finished.append("second")
            return nil
        }
        let ids = jobs.jobs.map(\.id)
        check(ids.count == 2 && jobs.isRunning(on: env.map) && ids.allSatisfy { env.tasks.contains(key: "research.job.\($0)") },
              "every job's task is in the window's bag")
        check(jobs.mapJobInfo(for: env.map)?.kind == "develop" && jobs.mapJobInfo(for: env.map)?.label == "Expand topic: a", "the map view is told about the first job on the map")
        let busy = jobs.developMap(file: env.map, node: "n1", direction: "")
        check(busy == "An AI job is already working on this map; develop the branch when it has finished.", "a second action on a map a job works on is refused")

        // The person's own Stop (the jobs bar): one job.
        jobs.cancel(ids[0])
        check(await waitUntil { jobs.jobs.count == 1 } && finished == ["first"] && jobs.message == "Developing the branch stopped.",
              "Cancel in the jobs bar ends that job only, and its message is shown")
        // Closing the folder or the window: everything.
        env.tasks.cancelAll()
        check(await waitUntil { jobs.jobs.isEmpty } && finished.sorted() == ["first", "second"], "cancelling the window's bag stops every job that is left")
        check(!jobs.isRunning(on: env.map), "and the map is free for the next action")

        let again = makeProject("again")
        again.controller.jobs.launch(kind: .mapDevelop, file: again.map, title: "one") { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return nil
        }
        again.controller.jobs.launch(kind: .mapDescribe, file: again.map, title: "two") { _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            return nil
        }
        again.controller.jobs.cancelJobs(on: again.map)
        check(await waitUntil { again.controller.jobs.jobs.isEmpty }, "Stop on a map ends every job working on it")
        again.tasks.cancelAll()
    }

    // 7. The files a research reads.
    print("\n-- the files a research reads")
    do {
        let project = sandbox.appendingPathComponent("scope", isDirectory: true)
        let outside = sandbox.appendingPathComponent("scope-outside", isDirectory: true)
        write("# a", to: project.appendingPathComponent("docs/a.md"))
        write("let x = 1", to: project.appendingPathComponent("docs/sub/b.swift"))
        write("secret", to: outside.appendingPathComponent("secret.md"))
        try? Data([0x00, 0x01, 0x02, 0x00]).write(to: project.appendingPathComponent("docs/blob.bin"))
        try? fm.createSymbolicLink(at: project.appendingPathComponent("docs/escape.md"), withDestinationURL: outside.appendingPathComponent("secret.md"))
        let found = await ResearchScope.targetFiles(root: project, targets: [project.appendingPathComponent("docs")])
        check(found == ["docs/a.md", "docs/sub/b.swift"], "a folder target expands to its readable text files, never a binary or a link out of the project (found: \(found))")
        let single = await ResearchScope.targetFiles(root: project, targets: [project.appendingPathComponent("docs/a.md"), outside.appendingPathComponent("secret.md")])
        check(single == ["docs/a.md"], "a file target is kept, one outside the project is not")
        let listed = await ResearchScope.files(root: project, always: ["docs/a.md", "attached.md"])
        check(listed.contains("docs/a.md") && listed.contains("attached.md") && listed.filter { $0 == "docs/a.md" }.count == 1,
              "the files of a research always include its targets and attachments, once")
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task { @MainActor in
    await run()
    semaphore.signal()
}
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
}
try? fm.removeItem(at: sandbox)

print("\nResearch map controller summary: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
