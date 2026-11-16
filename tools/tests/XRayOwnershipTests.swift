import Foundation

// Who owns the work the X-Ray starts (AR-19): the shipping ArchitectureStore (scan, analysis, explaining a link, describing a node) with its
// parts ChangeReviewStore (the pull-request X-Ray) and XRayFilterStore (filters and "I need to understand"), and the shipping
// CodeExplainStore and CodeNavigationStore, over real temporary git projects. The assistant is a stand-in that waits for the check to answer
// it, fail it, or cancel it, as the real one waits for its process. A start the store keeps; a restart replaces the work of the first and only
// the second lands; a stop or a failure leaves the run flag free for the next start; a project switch or the window's close cancels what is in
// flight and nothing is written after it (no save to the old project's database, no text in the new project's state).

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

@MainActor func waitFor(_ seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }
    return await condition()
}

func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

func git(_ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", folder.path, "-c", "user.name=Check", "-c", "user.email=check@example.com"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: arguments.joined(separator: " ")]) }
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xray-owner-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()

/// A small project in a git repository: main with one commit, a feature branch with another and an uncommitted edit.
func makeProject(_ name: String) throws -> URL {
    let root = scratch.appendingPathComponent(name, isDirectory: true)
    let sources = root.appendingPathComponent("Sources/App", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try "import Foundation\nstruct Model { var id = 1 }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
    try "import Foundation\nstruct ViewThing { let model = Model() }\n".write(to: sources.appendingPathComponent("ViewThing.swift"), atomically: true, encoding: .utf8)
    try "# \(name)\nA small app.\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["init", "-q", "-b", "main"], in: root)
    try git(["add", "-A"], in: root)
    try git(["commit", "-q", "-m", "first"], in: root)
    try git(["checkout", "-q", "-b", "feature"], in: root)
    try "import Foundation\nstruct Model { var id = 2; var name = \"m\" }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
    try git(["commit", "-q", "-am", "second"], in: root)
    try "import Foundation\nstruct Model { var id = 3; var name = \"m\" }\n".write(to: sources.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
    return root
}

/// The store has read the project: a snapshot, and no run holds the flag.
@MainActor func opened(_ store: ArchitectureStore) async -> Bool {
    await waitFor { store.snapshot != nil && !store.isBusy }
}

// MARK: - ArchitectureStore

@MainActor func architectureChecks() async throws {
    let alpha = try makeProject("alpha"), beta = try makeProject("beta")
    let db = SemanticDatabase(), db2 = SemanticDatabase()
    let store = ArchitectureStore()
    StandInAssistant.reset()

    store.open(root: alpha, db: db)
    check(await opened(store), "open shows the project after its scan")
    check(await waitFor { await db.snapshotSaves >= 1 }, "and the scan was saved to the project's database")
    check(await waitFor { store.review.prSources.contains { $0.id == "local" } }, "and the changes of the checkout are listed")

    // Stop: the assistant's call is cancelled, the run flag is free, the structure found so far stays.
    store.analyze(root: alpha, db: db)
    check(await waitFor { !StandInAssistant.waiting.isEmpty }, "an analysis asks the assistant")
    check(store.isBusy, "and holds the run flag while it waits")
    store.cancelAnalysis()
    check(await waitFor { StandInAssistant.waiting.isEmpty && !store.isBusy }, "Stop cancels the assistant's call and frees the run flag")
    check(!StandInAssistant.cancelled.isEmpty && store.status == nil && store.progressJSON() == "null", "and leaves no status or progress behind")

    // The next start resumes (the flag is free); a failing stage does not leave the flag stuck.
    let askedBefore = StandInAssistant.asked.count
    store.analyze(root: alpha, db: db)
    check(await waitFor { StandInAssistant.asked.count > askedBefore && !StandInAssistant.waiting.isEmpty }, "a new analysis starts after Stop")
    StandInAssistant.fail("xray")
    check(await waitFor { !store.isBusy && StandInAssistant.waiting.isEmpty }, "a stage that fails ends the run and frees the flag")
    check(store.error?.hasPrefix("Analysis failed") == true, "and says so (\(store.error ?? "no error"))")
    let afterFailure = StandInAssistant.asked.count
    store.analyze(root: alpha, db: db)
    check(await waitFor { StandInAssistant.asked.count > afterFailure }, "and the next analysis starts")

    // A project switch: the in-flight call is cancelled, nothing of the old project is written afterwards, the new project's run is its own.
    check(await waitFor { !StandInAssistant.waiting.isEmpty }, "the analysis waits for the assistant again")
    await pause(0.3)
    let savesBefore = await db.snapshotSaves
    let cancelledBefore = StandInAssistant.cancelled.count
    store.reset()
    check(!store.isBusy && store.snapshot == nil && store.rootPath == nil, "reset frees the run flag and drops the old project's snapshot")
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled.count > cancelledBefore }, "and cancels the call that was in flight")
    store.open(root: beta, db: db2)
    check(await opened(store), "the new project opens")
    await pause(0.5)
    check(await db.snapshotSaves == savesBefore, "nothing was saved to the old project's database after the switch")
    check(await db2.snapshotSaves >= 1, "the new project's scan went to its own database")
    check(store.snapshot?.view("modules")?.nodes.first { $0.kind == "root" }?.name == "beta", "and what the store shows is the new project's")

    // The run flag is a lease: the cancelled run of the old project ends after the reset and must not free the new run's flag.
    store.analyze(root: beta, db: db2)
    check(await waitFor { !StandInAssistant.waiting.isEmpty }, "an analysis of the new project waits")
    store.reset()
    let lease = store.beginRun()
    await pause(0.4)
    check(store.isBusy, "the cancelled run's end does not free the flag of the run that replaced it")
    store.endRun(lease)
    check(!store.isBusy, "and the new run frees it itself")

    // A link explained twice: the second question replaces the first, which must not mark the note finished.
    store.open(root: beta, db: db2)
    check(await opened(store), "the project opens again")
    guard let files = store.snapshot?.view("modules")?.nodes.filter({ $0.kind == "file" }), files.count >= 2 else {
        check(false, "the scan found the project's files"); return
    }
    let source = files[0].id, target = files[1].id
    let note = "modules|\(source)|\(target)"
    StandInAssistant.reset()
    store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: beta, db: db2)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-link"] }, "explaining a link asks the assistant")
    store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: beta, db: db2, fresh: true)
    check(await waitFor { StandInAssistant.cancelled == ["xray-link"] && StandInAssistant.waitingLabels() == ["xray-link"] }, "asking again cancels the first question and asks the assistant once more")
    await pause(0.4)
    check(store.edgeNotes[note]?.pending == true, "the cancelled question did not mark the note as answered")
    StandInAssistant.answer("xray-link", text: "The second answer.")
    check(await waitFor { store.edgeNotes[note]?.pending == false }, "the second question ends the note")
    check(store.edgeNotes[note]?.text == "The second answer.", "with its own answer")

    // A streamed answer refreshes the page once, and not after the project is closed.
    StandInAssistant.deltas["xray-link"] = ["a", "b", "c"]
    let revision = store.revision
    store.explainEdge(view: "modules", source: source, target: target, kind: "imports", label: nil, root: beta, db: db2, fresh: true)
    check(await waitFor { store.edgeNotes[note]?.text == "abc" }, "the streamed pieces are shown")
    check(store.revision > revision, "and the page was refreshed")
    store.reset()
    check(store.edgeNotes.isEmpty, "reset drops the notes of the old project")
    let afterReset = store.revision
    await pause(0.7)
    check(store.revision == afterReset, "no refresh of the page is left waiting after the reset")
    check(await waitFor { StandInAssistant.waiting.isEmpty }, "and the question was cancelled")

    // Describing a node: cancelled by the reset, nothing committed.
    StandInAssistant.reset()
    store.open(root: beta, db: db2)
    check(await opened(store), "the project opens once more")
    await pause(0.3)
    let describeSaves = await db2.snapshotSaves
    store.describe(viewId: "modules", nodeId: files[0].id, root: beta, db: db2)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-describe"] }, "describing a node asks the assistant")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled == ["xray-describe"] }, "reset cancels it")
    await pause(0.4)
    check(await db2.snapshotSaves == describeSaves && store.snapshot == nil, "and no description is committed after it")
    store.open(root: beta, db: db2)
    check(await opened(store), "the project opens after the reset")
    store.describe(viewId: "modules", nodeId: files[0].id, root: beta, db: db2)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-describe"] }, "and a node can be described again (nothing marks it as under way)")
    store.reset()
}

// MARK: - ChangeReviewStore

@MainActor func reviewChecks() async throws {
    let root = try makeProject("gamma")
    let db = SemanticDatabase()
    let store = ArchitectureStore()
    StandInAssistant.reset()
    store.open(root: root, db: db)
    check(await opened(store), "the project opens")
    let review = store.review
    check(await waitFor { review.prSources.contains { $0.id == "local" } }, "the pull-request X-Ray lists the checkout's changes")

    // The latest change started is the one that shows.
    review.showPR("local", root: root, db: db)
    review.showComparison(id: "cmp:HEAD~1", title: "vs the last commit", root: root, db: db)
    check(await waitFor { review.prOverlay != nil }, "a change is shown")
    await pause(0.6)
    check(review.prOverlay?.source.id == "cmp:HEAD~1", "of two loads started one after the other, the last one shows (\(review.prOverlay?.source.id ?? "none"))")

    // The latest day asked for is the one that shows.
    let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
    review.listHistory(day: String(today), root: root)
    review.listHistory(day: "1999-12-31", root: root)
    check(await waitFor { review.historyPicker?.state == "ready" }, "the commits of a day are listed")
    await pause(0.4)
    check(review.historyPicker?.day == "1999-12-31" && review.historyPicker?.commits.isEmpty == true, "of two days asked for one after the other, the last one shows")

    // A review in flight is cancelled by the reset: the flag is free, nothing is saved.
    review.showPR("local", root: root, db: db)
    check(await waitFor { review.prOverlay?.source.id == "local" && !store.isBusy }, "the checkout's changes are shown")
    review.reviewPR(root: root, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-pr-review"] }, "a review asks the assistant")
    check(store.isBusy, "and holds the run flag")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled == ["xray-pr-review"] }, "reset cancels the review")
    await pause(0.3)
    check(!store.isBusy && review.prOverlay == nil && store.status == nil, "and leaves the flag free, no change shown and no status")
    check(await db.reviewSaves == 0, "and nothing is saved to the database")

    // A review that is answered is shown and saved once; its finding is explained, and the close cancels that explanation.
    StandInAssistant.reset()
    store.open(root: root, db: db)
    check(await opened(store), "the project opens again")
    check(await waitFor { review.prSources.contains { $0.id == "local" } }, "its changes are listed again")
    review.showPR("local", root: root, db: db)
    check(await waitFor { review.prOverlay?.source.id == "local" && !store.isBusy }, "and shown")
    review.reviewPR(root: root, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-pr-review"] }, "the review asks again")
    let findings: [String: Any] = ["summary": "ok", "files": [[
        "path": "Sources/App/Model.swift", "verdict": "concern", "risk": "low", "summary": "s",
        "findings": [["line": 2, "severity": "warning", "message": "m"]],
    ]]]
    StandInAssistant.answer("xray-pr-review", structured: findings)
    check(await waitFor { review.prOverlay?.reviewed == true && !store.isBusy }, "the answered review is shown and the flag is free")
    check(await waitFor { await db.reviewSaves == 1 }, "and saved once")

    StandInAssistant.deltas["xray-finding"] = ["Because ", "of this."]
    review.explainFinding(path: "Sources/App/Model.swift", index: 0, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["xray-finding"] }, "explaining a finding asks the assistant")
    check(await waitFor { review.prOverlay?.files.first { $0.path == "Sources/App/Model.swift" }?.findings?.first?.explanation == "Because of this." }, "and shows the explanation as it streams")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled.contains("xray-finding") }, "reset cancels the explanation")
    await pause(0.5)
    check(await db.reviewSaves == 1, "and the review's marks are not saved from it after the reset")

    // The analysis of a change: cancelled by the reset, no status left.
    store.open(root: root, db: db)
    check(await opened(store), "the project opens a third time")
    check(await waitFor { review.prSources.contains { $0.id == "local" } }, "its changes are listed")
    review.showPR("local", root: root, db: db)
    check(await waitFor { review.prOverlay?.source.id == "local" && !store.isBusy }, "and shown")
    StandInAssistant.reset()
    review.analyzePR(root: root, db: db)
    check(await waitFor { !StandInAssistant.waiting.isEmpty }, "the analysis of a change asks the assistant")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty }, "reset cancels it")
    await pause(0.3)
    check(review.prOverlay == nil && store.status == nil, "and it leaves neither a change nor a status behind")
    review.showPR("local", root: root, db: db)
    store.reset()
}

// MARK: - XRayFilterStore

@MainActor func filterChecks() async throws {
    let root = try makeProject("delta")
    let db = SemanticDatabase()
    let store = ArchitectureStore()
    StandInAssistant.reset()
    store.open(root: root, db: db)
    check(await opened(store), "the project opens")
    let filters = store.filters
    let levels = ["strong", "none"]
    let first = ImportanceRater.Filter(id: "question", name: "Question", criterion: "where is the model", levels: levels)
    let second = ImportanceRater.Filter(id: "question", name: "Question", criterion: "how are views drawn", levels: levels)

    filters.understand(filter: first, root: root, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["understand-scope"] }, "a question asks the assistant")
    check(filters.understandingAnswers["question"]?.state == "loading", "and is shown as loading")
    filters.understand(filter: second, root: root, db: db)
    check(await waitFor { StandInAssistant.cancelled == ["understand-scope"] && StandInAssistant.waitingLabels() == ["understand-scope"] }, "asking again cancels the first question")
    await pause(0.4)
    check(filters.understandingAnswers["question"]?.question == "how are views drawn" && filters.understandingAnswers["question"]?.state == "loading",
          "the cancelled question did not fail the one that replaced it")
    filters.forgetRatings(filterId: "question", db: db)
    check(await waitFor { StandInAssistant.waiting.isEmpty }, "deleting the filter cancels its question")
    check(filters.understandingAnswers["question"] == nil, "and drops its answer")

    // A failing assistant ends the question as failed, not as stuck.
    StandInAssistant.reset()
    filters.understand(filter: first, root: root, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["understand-scope"] }, "a question asks once more")
    StandInAssistant.fail("understand-scope")
    check(await waitFor { StandInAssistant.waitingLabels() == ["understand"] || filters.understandingAnswers["question"]?.state == "failed" }, "the scope is only a hint: the answer is asked next")
    StandInAssistant.fail("understand")
    check(await waitFor { filters.understandingAnswers["question"]?.state == "failed" }, "a failing answer ends the question as failed")

    // The window's close.
    StandInAssistant.reset()
    filters.understand(filter: second, root: root, db: db)
    check(await waitFor { StandInAssistant.waitingLabels() == ["understand-scope"] }, "a question waits")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled == ["understand-scope"] }, "reset cancels it")
    check(filters.understandingAnswers.isEmpty, "and drops the old project's answers")

    // The one-off search: stopped by the reset, and a new one is not blocked by the old one's mark.
    StandInAssistant.reset()
    store.open(root: root, db: db)
    check(await opened(store), "the project opens again")
    guard let search = ImportanceRater.temporaryFilter(for: "payment flow") else { check(false, "a one-off filter is made"); return }
    filters.temporaryFilter = search
    filters.searchFilter(filterId: search.id, root: root, db: db)
    check(await waitFor { !StandInAssistant.waiting.isEmpty }, "a search asks the assistant")
    store.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && !StandInAssistant.cancelled.isEmpty }, "reset cancels it")
    store.open(root: root, db: db)
    check(await opened(store), "the project opens a third time")
    let asked = StandInAssistant.asked.count
    filters.searchFilter(filterId: search.id, root: root, db: db)
    check(await waitFor { StandInAssistant.asked.count > asked }, "and the search can be started again")
    store.reset()
}

// MARK: - CodeExplainStore

@MainActor func explainChecks() async throws {
    let root = try makeProject("epsilon")
    let directory = scratch.appendingPathComponent("explain", isDirectory: true)
    let path = "Sources/App/Model.swift"
    let explain = CodeExplainStore()
    StandInAssistant.reset()

    explain.explain(path: path, content: "struct Model {}\nvar a = 1\n", root: root, directory: directory, db: nil)
    check(await waitFor { StandInAssistant.waitingLabels() == ["explain-file"] }, "explaining a file asks the assistant")
    check(explain.working.contains(path), "and shows the file as under way")
    explain.reset()
    check(explain.working.isEmpty && explain.explanations.isEmpty, "reset drops what was under way")
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled == ["explain-file"] }, "and cancels the assistant's call")
    await pause(0.3)
    check((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty ?? true, "and no explanation is written after it")

    // The old project's call ends after the reset, while the same file is explained in the next project: it must not touch the new state.
    StandInAssistant.reset()
    explain.explain(path: path, content: "struct Model {}\nvar a = 1\n", root: root, directory: directory, db: nil)
    check(await waitFor { StandInAssistant.waitingLabels() == ["explain-file"] }, "a file is explained")
    explain.reset()
    explain.explain(path: path, content: "struct Model {}\nvar a = 1\n", root: root, directory: directory, db: nil)
    check(await waitFor { StandInAssistant.cancelled == ["explain-file"] && StandInAssistant.waitingLabels() == ["explain-file"] }, "and again in the next project: the first call is cancelled")
    await pause(0.4)
    check(explain.working.contains(path), "the cancelled call did not clear the new project's mark")
    let answer: [String: Any] = ["summary": "A model.", "sections": [["startLine": 1, "endLine": 2, "title": "Model", "explanation": "E", "importance": "normal"]]]
    StandInAssistant.answer("explain-file", structured: answer)
    check(await waitFor { explain.explanations[path]?.summary == "A model." && !explain.working.contains(path) }, "the second call's answer is shown and the mark is cleared")
    check((try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count == 1, "and cached once")
    explain.reset()
}

// MARK: - CodeNavigationStore

final class Events: @unchecked Sendable {
    var all: [[String: Any]] = []
    var paths: [String] = []
}

@MainActor func navigationChecks() async throws {
    let root = try makeProject("zeta")
    let file = root.appendingPathComponent("Sources/App/Model.swift")
    let navigation = CodeNavigationStore()
    let events = Events()
    let observer = NotificationCenter.default.addObserver(forName: .codeNavEvent, object: navigation, queue: .main) { note in
        if let json = note.userInfo?["json"] as? String, let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { events.all.append(object) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    StandInAssistant.reset()

    // Each name has one declaration, so the lookup goes straight to it: the file it opens tells which lookup answered.
    let opened = Events()
    let open: (URL, Int) -> Void = { url, _ in opened.paths.append(url.lastPathComponent) }
    navigation.goToDefinition(name: "Model", line: 1, url: file, path: "Sources/App/Model.swift", root: root, open: open)
    navigation.goToDefinition(name: "ViewThing", line: 1, url: file, path: "Sources/App/Model.swift", root: root, open: open)
    check(await waitFor { !opened.paths.isEmpty }, "a lookup answers")
    await pause(0.4)
    check(opened.paths == ["ViewThing.swift"], "of two lookups started one after the other only the last answers (\(opened.paths))")

    events.all = []
    navigation.findUsages(name: "Model", url: file, path: "Sources/App/Model.swift", root: root)
    navigation.reset()
    await pause(0.8)
    check(events.all.isEmpty, "a lookup under way when the window closes does not answer")

    navigation.ask(id: "q1", question: "why", snippet: "struct Model {}", start: 1, end: 1, path: "Sources/App/Model.swift", language: "swift",
                   history: [], url: file, root: root, db: nil)
    check(await waitFor { StandInAssistant.waitingLabels() == ["code-question"] }, "a question about code asks the assistant")
    navigation.stopAnswer(id: "q1")
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled == ["code-question"] }, "Stop cancels it")
    check(await waitFor { events.all.contains { $0["id"] as? String == "q1" && $0["stopped"] as? Bool == true } }, "and tells the viewer that it stopped")

    navigation.ask(id: "q2", question: "why", snippet: "struct Model {}", start: 1, end: 1, path: "Sources/App/Model.swift", language: "swift",
                   history: [], url: file, root: root, db: nil)
    check(await waitFor { StandInAssistant.waitingLabels() == ["code-question"] }, "another question asks")
    navigation.ask(id: "q2", question: "again", snippet: "struct Model {}", start: 1, end: 1, path: "Sources/App/Model.swift", language: "swift",
                   history: [], url: file, root: root, db: nil)
    check(await waitFor { StandInAssistant.cancelled.count == 2 && StandInAssistant.waitingLabels() == ["code-question"] }, "asking again with the same id replaces the first call")
    navigation.reset()
    check(await waitFor { StandInAssistant.waiting.isEmpty && StandInAssistant.cancelled.count == 3 }, "reset cancels what is left")
}

@MainActor func run() async throws {
    defer { try? FileManager.default.removeItem(at: scratch) }
    try await architectureChecks()
    try await reviewChecks()
    try await filterChecks()
    try await explainChecks()
    try await navigationChecks()
    print(failures == 0 ? "All X-Ray ownership checks passed." : "\(failures) X-Ray ownership check(s) failed.")
    try? FileManager.default.removeItem(at: scratch)
    exit(failures == 0 ? 0 : 1)
}

Task { do { try await run() } catch { print("FAIL \(error)"); try? FileManager.default.removeItem(at: scratch); exit(1) } }
RunLoop.main.run()
