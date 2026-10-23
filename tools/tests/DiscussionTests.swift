import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

@MainActor func run() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = DiscussionStore()
    check(store.create(title: "Offline mode") == nil, "no project, no discussion")
    store.setRoot(root)
    check(store.create(title: "   ") == nil, "an empty title is refused")
    let slug = store.create(title: "Offline mode for the editor!")
    check(slug == "offline-mode-for-the-editor", "slug from the title: \(String(describing: slug))")
    check(store.create(title: "Offline mode for the editor") == "offline-mode-for-the-editor-2", "slugs stay unique")

    let turn = store.addTurn(slug!, question: "Which data must work offline?", answer: "Documents and the index.",
                             followUps: ["How do conflicts resolve?"], decisions: ["Documents only", "documents only", "  "],
                             openQuestions: ["Sync back when online?"])
    check(turn?.id == 1, "first turn is 1")
    let discussion = store.discussions.first { $0.slug == slug }!
    check(discussion.items(.decision).count == 1 && discussion.items(.question).count == 1, "decisions are deduplicated, blanks dropped")
    let note = try? String(contentsOf: store.noteURL(slug!, turn: 1)!, encoding: .utf8)
    check(note?.hasPrefix("# Which data must work offline?") == true && note?.contains("- How do conflicts resolve?") == true, "the answer is a note with the follow-ups")
    check(store.addTurn(slug!, question: "Q2", answer: "A2", followUps: [], decisions: [], openQuestions: [])?.id == 2, "turns count up")

    let decisionID = store.discussions.first { $0.slug == slug }!.items(.question)[0].id
    store.move(slug!, item: decisionID, to: .decision)
    store.edit(slug!, item: decisionID, text: "Sync back when online: yes")
    store.addItem(slug!, kind: .rejected, text: "Full database copy")
    let edited = store.discussions.first { $0.slug == slug }!
    check(edited.items(.decision).count == 2 && edited.items(.rejected).count == 1 && edited.items(.question).isEmpty, "items move between kinds and can be added")
    check(edited.items.first { $0.id == decisionID }?.text == "Sync back when online: yes", "an item can be edited")
    store.remove(slug!, item: decisionID)
    check(store.discussions.first { $0.slug == slug }!.items.count == 2, "an item can be removed")

    let context = store.discussions.first { $0.slug == slug }!.context()
    check(context.contains("Q1: Which data must work offline?") && context.contains("## Decided") && context.contains("Full database copy"), "the context lists answers, decisions and rejected options")
    check(Discussion(slug: "x", title: "x", createdAt: Date(), updatedAt: Date()).context() == "(nothing discussed yet)", "an empty discussion says so")

    let again = DiscussionStore()
    again.setRoot(root)
    check(again.discussions.count == 2 && again.discussions.first { $0.slug == slug }?.turns.count == 2, "a second store reads what was saved")
    check(String(data: (try? Data(contentsOf: again.folder(slug!)!.appendingPathComponent("discussion.json"))) ?? Data(), encoding: .utf8)?.contains("Documents and the index.") == true, "the file holds the answer")

    store.delete(slug!)
    check(!FileManager.default.fileExists(atPath: store.folder(slug!)!.path) && store.discussions.count == 1, "delete removes the folder")

    var long = Discussion(slug: "l", title: "l", createdAt: Date(), updatedAt: Date())
    for n in 1...10 { long.turns.append(DiscussionTurn(id: n, question: "q\(n)", answer: String(repeating: "x", count: 6_000), createdAt: Date())) }
    check(long.context(answerBudget: 12_000).count < 14_500 && long.context().contains("Q10:"), "a long discussion keeps the newest turns inside the budget")
}

// The prompt and the answer parser.
let d = Discussion(slug: "s", title: "Offline mode", createdAt: Date(), updatedAt: Date())
let prompt = DiscussionPrompt.prompt(discussion: d, question: "What about sync?", language: "Write in German.")
check(prompt.contains("# Discussion: Offline mode") && prompt.contains("What about sync?") && prompt.contains("Write in German."), "the prompt carries the title, the question and the language line")
let parsed = DiscussionPrompt.parse(structured: ["answer": " Use a queue. ", "decisions": ["A", " "], "open_questions": ["B"], "follow_ups": ["1", "2", "3", "4", "5"]], text: "")
check(parsed?.answer == "Use a queue." && parsed?.decisions == ["A"] && parsed?.openQuestions == ["B"] && parsed?.followUps.count == 4, "structured answer: trimmed, blanks dropped, follow-ups capped")
check(DiscussionPrompt.parse(structured: nil, text: "Plain text answer")?.answer == "Plain text answer", "plain text is accepted when the schema was skipped")
check(DiscussionPrompt.parse(structured: ["answer": ""], text: "  ") == nil, "nothing to show is nil")

MainActor.assumeIsolated { run() }
print(failures == 0 ? "All discussion checks passed." : "\(failures) discussion check(s) failed.")
exit(failures == 0 ? 0 : 1)
