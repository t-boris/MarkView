import Foundation
import MarkViewCore
import XCTest
@testable import MarkView

extension EditorHostTests {
    @MainActor func testNewProjectDraftRules() throws {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        // MARK: Draft (DEC-015, DEC-019)

        var draft = ProjectDraft(idea: "A recipe planner for families\nwith shopping lists")
        check("new draft clarifies", draft.stage == .clarifying && !draft.filesWritten && !draft.gitInitialized && draft.createdPath == nil)
        check("title from first line of the idea", draft.displayTitle == "A recipe planner for families")
        draft.title = "Family Recipe Planner"
        check("title from the specification", draft.displayTitle == "Family Recipe Planner")
        check("empty idea is untitled", ProjectDraft(idea: "  \n").displayTitle == "Untitled project")
        check("long first line shortened", ProjectDraft(idea: String(repeating: "x", count: 80)).displayTitle.count == 61)
        draft.stage = .creating
        draft.createdPath = "/tmp/family-recipe-planner"
        draft.lastError = "git failed"
        let encoded = try! JSONEncoder().encode(draft)
        let decoded = try! JSONDecoder().decode(ProjectDraft.self, from: encoded)
        check("draft round-trips", decoded == draft)
        check("stopped creation offers retry", decoded.resumeDescription.contains("retry"))

        // MARK: Names (DEC-009, DEC-010)

        check("folder name from title", ProjectNaming.suggestedFolderName("Family Recipe Planner!") == "family-recipe-planner")
        check("folder name transliterates", ProjectNaming.suggestedFolderName("Планировщик рецептов") == "planirovsik-receptov")
        check("folder name fallback", ProjectNaming.suggestedFolderName("???") == "new-project")
        check("folder name at most six words", ProjectNaming.suggestedFolderName("a b c d e f g h") == "a-b-c-d-e-f")
        check("valid folder name", ProjectNaming.folderNameProblem("My Project") == nil)
        check("empty folder name", ProjectNaming.folderNameProblem("  ") != nil)
        check("slash in folder name", ProjectNaming.folderNameProblem("a/b") != nil)
        check("colon in folder name", ProjectNaming.folderNameProblem("a:b") != nil)
        check("hidden folder name", ProjectNaming.folderNameProblem(".secret") != nil)
        check("dot-dot folder name", ProjectNaming.folderNameProblem("..") != nil)
        check("padded folder name", ProjectNaming.folderNameProblem(" a") != nil)
        check("valid repo name", ProjectNaming.repoNameProblem("family-recipe_planner.v2") == nil)
        check("repo name with space", ProjectNaming.repoNameProblem("my repo") != nil)
        check("repo name ending .git", ProjectNaming.repoNameProblem("x.git") != nil)
        check("repo name too long", ProjectNaming.repoNameProblem(String(repeating: "a", count: 101)) != nil)
        check("repo name from folder", ProjectNaming.suggestedRepoName("My Project (v2)") == "My-Project-v2")
        check("repo name fallback", ProjectNaming.suggestedRepoName("ÅÅ") == "new-project")

        // MARK: Confirmation gate (DEC-016)

        typealias Q = ProjectConfirmation.OpenQuestion
        let openQuestions = [Q(id: "Q-001", title: "Who uses it?", blocking: true), Q(id: "Q-002", title: "Colour scheme?", blocking: false)]
        check("blocking question blocks", !ProjectConfirmation.canConfirm(goal: "Plan recipes", open: openQuestions))
        check("blockers listed", ProjectConfirmation.blockers(openQuestions).map(\.id) == ["Q-001"])
        check("non-blocking questions stay open", ProjectConfirmation.canConfirm(goal: "Plan recipes", open: [openQuestions[1]]))
        check("goal required", !ProjectConfirmation.canConfirm(goal: " ", open: []))

        // MARK: Foundation (DEC-023)

        let readme = ProjectFoundation.readme(title: "Family Recipe Planner", idea: "Plan meals.", problem: "Shopping is chaotic.", scope: "",
                                              specificationPath: "docs/features/family-recipe-planner",
                                              requirements: [(id: "REQ-001", title: "Weekly plan")], openQuestions: [(id: "Q-002", title: "Colour scheme?")])
        check("readme title", readme.hasPrefix("# Family Recipe Planner\n\nPlan meals.\n"))
        check("readme links the specification", readme.contains("(docs/features/family-recipe-planner/overview.md)"))
        check("readme lists requirements", readme.contains("- REQ-001 Weekly plan"))
        check("readme lists open questions", readme.contains("### Open questions\n\n- Q-002 Colour scheme?"))
        check("readme omits empty scope", !readme.contains("## Scope"))
        let overview = "# App\n\n## Idea\n\nPlan meals.\n\n## Problem\n\nChaos.\n\n## Scope\n"
        check("overview idea section", ProjectFoundation.section("Idea", of: overview) == "Plan meals.")
        check("overview empty scope", ProjectFoundation.section("Scope", of: overview) == "")
        check("overview missing section", ProjectFoundation.section("Users", of: overview) == "")
        check("gitignore excludes MarkView metadata", ProjectFoundation.gitignore.contains(".dde/"))

        // MARK: Origin (DEC-010)

        check("no origin", OriginState.of(currentURL: nil, target: "boris/app") == .none)
        check("empty origin", OriginState.of(currentURL: "\n", target: "boris/app") == .none)
        check("same origin https", OriginState.of(currentURL: "https://github.com/Boris/App.git", target: "boris/app") == .same)
        check("same origin ssh", OriginState.of(currentURL: "git@github.com:boris/app.git", target: "boris/app") == .same)
        check("other GitHub origin", OriginState.of(currentURL: "git@github.com:boris/other.git", target: "boris/app") == .other("git@github.com:boris/other.git"))
        check("non-GitHub origin", OriginState.of(currentURL: "https://gitlab.com/boris/app.git", target: "boris/app") == .other("https://gitlab.com/boris/app.git"))

        // MARK: Publication (DEC-018, DEC-019)

        check("changed files", GitPublication.changedFiles(porcelainZ: "?? README.md\0?? docs/a.md\0R  new.md\0old.md\0?? with space.md\0") == ["README.md", "docs/a.md", "new.md", "with space.md"])
        check("non-ASCII and arrow names", GitPublication.changedFiles(porcelainZ: "?? Документ.md\0?? a -> b.md\0") == ["Документ.md", "a -> b.md"])
        check("no changes", GitPublication.changedFiles(porcelainZ: "").isEmpty)
        let ls = "abc123\trefs/heads/main\ndef456\trefs/heads/dev\n"
        check("remote head", GitPublication.remoteHead(lsRemote: ls, branch: "main") == "abc123")
        check("missing remote branch", GitPublication.remoteHead(lsRemote: ls, branch: "feature") == nil)
        check("published", GitPublication.isPublished(localHead: "abc123", remoteHead: "abc123", upstream: "origin/main", branch: "main"))
        check("behind is not published", !GitPublication.isPublished(localHead: "fff", remoteHead: "abc123", upstream: "origin/main", branch: "main"))
        check("untracked branch is not published", !GitPublication.isPublished(localHead: "abc123", remoteHead: "abc123", upstream: "", branch: "main"))
        check("not pushed is not published", !GitPublication.isPublished(localHead: "abc123", remoteHead: nil, upstream: "", branch: "main"))
        let record = GitHubConnectionRecord(owner: "boris", name: "app", visibility: "private", createdByMarkView: true,
                                            committed: true, pushed: false, updated: Date(timeIntervalSince1970: 0))
        check("record slug", record.slug == "boris/app")
        check("record round-trips", (try? JSONDecoder().decode(GitHubConnectionRecord.self, from: JSONEncoder().encode(record))) == record)

        // The record is a schema-versioned store (AR-36): a record the previous version wrote still loads; one that cannot be read is
        // never taken for "no record" (a second repository could be created) and is never replaced without a backup.
        let projectRoot = StoreFixture.folder("github-record")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let recordFile = GitHubConnectionRecord.url(root: projectRoot)
        check("no record: missing", { if case .missing = GitHubConnectionRecord.load(root: projectRoot) { return true } else { return false } }())
        let legacyRecord = """
        {
          "committed" : true,
          "createdByMarkView" : true,
          "name" : "app",
          "owner" : "boris",
          "pushed" : false,
          "updated" : "1970-01-01T00:00:00Z",
          "visibility" : "private"
        }
        """
        StoreFixture.write(legacyRecord, to: recordFile)
        check("legacy record: it loads intact", GitHubConnectionRecord.load(root: projectRoot).value == record)
        var pushedRecord = record
        pushedRecord.pushed = true
        try pushedRecord.save(root: projectRoot)
        check("legacy record: the next save writes the envelope", StoreFixture.envelope(recordFile)?.schema == 1 && GitHubConnectionRecord.load(root: projectRoot).value == pushedRecord)
        StoreFixture.write("{ \"owner\": ", to: recordFile)
        let unreadable = GitHubConnectionRecord.load(root: projectRoot)
        check("damaged record: it is a problem, not a missing record", unreadable.value == nil && unreadable.problem?.contains("github-connection.json") == true)
        check("damaged record: loading leaves it as it is", StoreFixture.bytes(recordFile) == Data("{ \"owner\": ".utf8) && StoreFixture.backups(of: recordFile).isEmpty)
        try record.save(root: projectRoot)
        check("damaged record: a save keeps the old bytes in a dated backup",
              StoreFixture.backups(of: recordFile).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: recordFile)[0]) == Data("{ \"owner\": ".utf8))
        StoreFixture.write(StoreFixture.newerFile(payload: #"{"owner":"x"}"#), to: recordFile)
        var refusedNewer = false
        do { try record.save(root: projectRoot) } catch SchemaStoreError.newerSchemaVersion { refusedNewer = true } catch {}
        check("newer record: it is a problem and a save is refused", GitHubConnectionRecord.load(root: projectRoot).isNewerSchema && refusedNewer)

        // The unfinished-project drafts are a schema-versioned store (AR-36). The legacy fixture is the draft.json the previous version wrote.
        MainActor.assumeIsolated {
            func settle(_ condition: () -> Bool) -> Bool {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if condition() { return true }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                }
                return condition()
            }
            let draftsFolder = StoreFixture.folder("project-drafts")
            defer { try? FileManager.default.removeItem(at: draftsFolder) }
            let legacyID = UUID()
            let legacyDraft = draftsFolder.appendingPathComponent("\(legacyID.uuidString)/draft.json")
            StoreFixture.write("""
            {
              "created" : "2026-11-01T09:00:00Z",
              "filesWritten" : false,
              "gitInitialized" : false,
              "id" : "\(legacyID.uuidString)",
              "idea" : "A recipe planner",
              "slug" : "recipes",
              "stage" : "confirmed",
              "title" : "Recipe Planner",
              "updated" : "2026-11-02T09:00:00Z"
            }
            """, to: legacyDraft)
            let brokenID = UUID()
            let brokenDraft = draftsFolder.appendingPathComponent("\(brokenID.uuidString)/draft.json")
            StoreFixture.write("{ \"id\": ", to: brokenDraft)

            let drafts = ProjectDraftStore(folder: draftsFolder)
            check("legacy draft: it is listed with its stage and title", settle { drafts.drafts.count == 1 }
                  && drafts.draft(legacyID)?.title == "Recipe Planner" && drafts.draft(legacyID)?.stage == .confirmed && drafts.draft(legacyID)?.slug == "recipes")
            check("legacy draft: reading leaves both files as written", StoreFixture.envelope(legacyDraft) == nil && StoreFixture.bytes(brokenDraft) == Data("{ \"id\": ".utf8)
                  && StoreFixture.backups(of: brokenDraft).isEmpty)
            var resumed = drafts.draft(legacyID)!
            resumed.stage = .creating
            let saved = Task { try await drafts.save(resumed) }
            check("legacy draft: a save writes the envelope", settle { StoreFixture.envelope(legacyDraft)?.schema == 1 } && StoreFixture.backups(of: legacyDraft).isEmpty)
            _ = saved
            let again = ProjectDraftStore(folder: draftsFolder)
            check("legacy draft: the envelope reloads with the new stage", settle { again.drafts.count == 1 } && again.draft(legacyID)?.stage == .creating)
            let rewritten = Task { var changed = ProjectDraft(idea: "x"); changed.id = brokenID; try await again.save(changed) }
            _ = rewritten
            check("damaged draft: a save over it keeps the old bytes in a dated backup", settle { StoreFixture.envelope(brokenDraft)?.schema == 1 }
                  && StoreFixture.backups(of: brokenDraft).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: brokenDraft)[0]) == Data("{ \"id\": ".utf8))

            // The folder is read again on request; asking twice at once is one read that ends with the folder as it is (the second replaces the first).
            let extraID = UUID()
            StoreFixture.write("""
            {
              "created" : "2026-11-03T09:00:00Z",
              "filesWritten" : false,
              "gitInitialized" : false,
              "id" : "\(extraID.uuidString)",
              "idea" : "A budget tracker",
              "stage" : "clarifying",
              "title" : "Budget",
              "updated" : "2026-11-03T09:00:00Z"
            }
            """, to: draftsFolder.appendingPathComponent("\(extraID.uuidString)/draft.json"))
            check("reload: a draft written to the folder is not listed before the folder is read again", drafts.draft(extraID) == nil)
            drafts.reload()
            drafts.reload()
            check("reload: two requests at once end with the new draft listed", settle { drafts.draft(extraID)?.title == "Budget" })
        }

    }

    @MainActor func testDiscussionStoreRules() {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
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
        let prompt = DiscussionPrompt.prompt(discussion: d, question: "What about sync?", scope: "Folder Sources/Sync", language: "Write in German.")
        check(prompt.contains("# Discussion: Offline mode") && prompt.contains("What about sync?") && prompt.contains("Write in German.") && prompt.contains("Folder Sources/Sync"), "the prompt carries the title, the question, the scope and the language line")
        check(DiscussionPrompt.system.contains("```mermaid") && DiscussionPrompt.system.contains("discussion-notes"), "the system prompt names the visuals and the notes block")
        let reply = """
        Short answer.

        ```mermaid
        flowchart LR
          A --> B
        ```

        ```discussion-notes
        {"decisions": ["Use a queue", " "], "open_questions": ["Who owns retries?"]}
        ```
        """
        let parsed = DiscussionPrompt.parse(reply)
        check(parsed?.answer.hasSuffix("```") == true && parsed?.answer.contains("discussion-notes") == false, "the notes block is removed from what is shown, the diagram stays")
        check(parsed?.decisions == ["Use a queue"] && parsed?.openQuestions == ["Who owns retries?"], "decisions and open questions are read from the notes block")
        check(DiscussionPrompt.parse("Just text, no notes.")?.answer == "Just text, no notes." && DiscussionPrompt.parse("Just text, no notes.")?.decisions.isEmpty == true, "an answer without notes is still an answer")
        check(DiscussionPrompt.parse("Text\n```discussion-notes\n{broken")?.answer == "Text" && DiscussionPrompt.parse("Text\n```discussion-notes\n{broken")?.decisions.isEmpty == true, "a broken notes block is dropped, not shown")
        check(DiscussionPrompt.parse("   ") == nil && DiscussionPrompt.parse("```discussion-notes\n{}\n```") == nil, "nothing to show is nil")
        check(DiscussionPrompt.status(read: "/a/b/Models/File.swift") == "Reading File.swift", "status line for a file being read")

        // Scope.
        @MainActor func scopeChecks() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("discussion-scope-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = DiscussionStore()
            store.setRoot(root)
            let slug = store.create(title: "Sync", scope: "Sources/Sync")!
            check(store.selected?.scopeLabel == "Sync" && store.selected?.scope == "Sources/Sync", "a discussion remembers its scope")
            store.setScope(slug, to: "")
            check(store.selected?.scopeLabel == "Whole project", "an empty scope is the whole project")
            store.setScope(slug, to: "README.md")
            let again = DiscussionStore()
            again.setRoot(root)
            check(again.selected?.scope == "README.md", "the scope is saved")
        }
        scopeChecks()

        // The file of each discussion is a schema-versioned store (AR-36): a discussion saved before it still loads, one that cannot be read
        // stays on disk and its folder name stays taken, a newer one is never replaced.
        @MainActor func storeChecks() {
            let root = StoreFixture.folder("discussion-store")
            defer { try? FileManager.default.removeItem(at: root) }
            let base = DiscussionStore.base(root: root)
            let legacy = base.appendingPathComponent("offline/discussion.json")
            StoreFixture.write("""
            {
              "createdAt" : "2026-11-01T10:00:00Z",
              "items" : [ { "id" : "A1", "kind" : "decision", "text" : "Documents only", "turn" : 1 } ],
              "scope" : "Sources/Sync",
              "slug" : "offline",
              "title" : "Offline mode",
              "turns" : [ { "answer" : "Documents and the index.", "createdAt" : "2026-11-01T10:05:00Z", "followUps" : ["How do conflicts resolve?"], "id" : 1, "question" : "Which data?" } ],
              "updatedAt" : "2026-11-01T10:05:00Z"
            }
            """, to: legacy)
            let damaged = base.appendingPathComponent("broken/discussion.json")
            StoreFixture.write("{ \"slug\": \"broken\", \"turns\": [", to: damaged)
            let newer = base.appendingPathComponent("future/discussion.json")
            let newerText = StoreFixture.newerFile(payload: #"{"slug":"future"}"#)
            StoreFixture.write(newerText, to: newer)

            let store = DiscussionStore()
            store.setRoot(root)
            let loaded = store.discussions.first { $0.slug == "offline" }
            check(store.discussions.count == 1 && loaded?.title == "Offline mode" && loaded?.turns.first?.answer == "Documents and the index."
                  && loaded?.items.first?.text == "Documents only" && loaded?.scope == "Sources/Sync", "legacy file: the discussion loads intact")
            check(StoreFixture.envelope(legacy) == nil, "legacy file: it is left as written until a change is saved")
            check(store.lastError?.contains("\"broken\"") == true && store.lastError?.contains("\"future\"") == true && store.lastError?.contains("newer") == true,
                  "unreadable files: the problems are shown, one per file")
            check(StoreFixture.bytes(damaged) == Data("{ \"slug\": \"broken\", \"turns\": [".utf8) && StoreFixture.bytes(newer) == Data(newerText.utf8),
                  "unreadable files: loading leaves them as they are")

            store.rename("offline", to: "Offline mode, renamed")
            check(StoreFixture.envelope(legacy)?.schema == 1 && StoreFixture.backups(of: legacy).isEmpty, "legacy file: the next change writes the envelope, with no backup")
            let again = DiscussionStore()
            again.setRoot(root)
            check(again.discussions.first?.title == "Offline mode, renamed" && again.discussions.first?.turns.count == 1, "legacy file: the envelope reloads")

            check(store.create(title: "Broken") == "broken-2" && store.create(title: "Future") == "future-2",
                  "unreadable files: a new discussion never takes the folder of one that cannot be read")
            check(StoreFixture.bytes(damaged) == Data("{ \"slug\": \"broken\", \"turns\": [".utf8) && StoreFixture.backups(of: damaged).isEmpty, "unreadable files: still untouched")
        }
        storeChecks()

        run()
    }

    @MainActor func testFeatureStoreSchemaCompatibility() async {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let suiteName = "feature-schema-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let isolatedSettings = Settings(defaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fm = FileManager.default

        func write(_ text: String, to url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

        func schemaLines(_ text: String) -> Int { text.components(separatedBy: "\nschema:").count - 1 }

        @MainActor
        func run() async {
            let project = fm.temporaryDirectory.appendingPathComponent("feature-schema-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: project) }
            let features = project.appendingPathComponent("docs/features")
            let bugs = project.appendingPathComponent("docs/bugs")

            // Files written before the schema existed.
            let legacyOverview = "---\ntitle: Legacy\nstatus: draft\n---\n\n# Legacy\n\nOld overview.\n"
            let legacyRequirement = "---\ntype: requirement\nid: REQ-001\nfeature: legacy\ntitle: Old requirement\nstatus: draft\n---\n\nThe old text.\n"
            let legacyBug = "---\ntype: bug\nid: BUG-001\ntitle: Old bug\nstatus: open\nseverity: high\n---\n\n# Old bug\n\nIt crashes.\n"
            // Files of a newer schema.
            let futureOverview = "---\ntitle: Future\nstatus: draft\nschema: 99\nnew_field: kept\n---\n\n# Future\n\nNewer overview.\n"
            let futureRequirement = "---\ntype: requirement\nid: REQ-002\nfeature: legacy\ntitle: New requirement\nstatus: draft\nschema: 99\n---\n\nNewer text.\n"
            let futureBug = "---\ntype: bug\nid: BUG-002\ntitle: New bug\nstatus: open\nschema: 99\nextra: kept\n---\n\n# New bug\n\nText.\n"
            let futurePlan = "---\ntype: plan\nfeature: future\ntitle: Plan\nschema: 99\n---\n\n# Plan\n"

            let legacyOverviewURL = features.appendingPathComponent("legacy/overview.md")
            let legacyRequirementURL = features.appendingPathComponent("legacy/requirements/REQ-001.md")
            let futureRequirementURL = features.appendingPathComponent("legacy/requirements/REQ-002.md")
            let futureOverviewURL = features.appendingPathComponent("future/overview.md")
            let futurePlanURL = features.appendingPathComponent("future/implementation/plan.md")
            let legacyBugURL = bugs.appendingPathComponent("BUG-001-old-bug.md")
            let futureBugURL = bugs.appendingPathComponent("BUG-002-new-bug.md")
            write(legacyOverview, to: legacyOverviewURL)
            write(legacyRequirement, to: legacyRequirementURL)
            write(futureRequirement, to: futureRequirementURL)
            write(futureOverview, to: futureOverviewURL)
            write(futurePlan, to: futurePlanURL)
            write(legacyBug, to: legacyBugURL)
            write(futureBug, to: futureBugURL)

            let store = FeatureStore(settings: isolatedSettings)
            store.setup(root: project)
            store.reloadSync()
            defer { store.reset() }

            print("-- reading")
            check(store.feature("legacy")?.status == "draft" && store.feature("future")?.status == "draft", "both features load, whatever their schema")
            check(store.feature("legacy")?.object("REQ-001") != nil && store.bugs.count == 2, "objects and bugs load, whatever their schema")
            check(read(legacyOverviewURL) == legacyOverview && read(legacyRequirementURL) == legacyRequirement && read(legacyBugURL) == legacyBug,
                  "loading leaves a file written before the schema as it is")

            print("-- a file written before the schema")
            store.updateFeature("legacy") { front, _ in front.set("status", "review") }
            check(read(legacyOverviewURL) == "---\ntitle: Legacy\nstatus: review\nschema: 1\n---\n\n# Legacy\n\nOld overview.\n",
                  "an overview gets the schema on its next write and nothing else changes")
            store.updateFeature("legacy") { front, _ in front.set("status", "ready") }
            check(schemaLines(read(legacyOverviewURL)) == 1, "a second write keeps one schema line")
            store.update("REQ-001", in: "legacy") { front, _ in front.set("status", "approved") }
            check(read(legacyRequirementURL).contains("status: approved\n") && read(legacyRequirementURL).contains("\nschema: 1\n")
                  && schemaLines(read(legacyRequirementURL)) == 1 && read(legacyRequirementURL).hasSuffix("---\n\nThe old text.\n"),
                  "an object gets the schema on its next write")
            let wrote = store.updateBug(legacyBugURL) { front, _ in front.set("status", "fixing") }
            check(wrote && read(legacyBugURL) == "---\ntype: bug\nid: BUG-001\ntitle: Old bug\nstatus: fixing\nseverity: high\nschema: 1\n---\n\n# Old bug\n\nIt crashes.\n",
                  "a bug report gets the schema on its next write and nothing else changes")
            check(store.lastError == nil, "none of these writes is an error")

            print("-- new files")
            let created = store.create(.requirement, in: "legacy", title: "Brand new", body: "Text.\n", provenance: "test")
            check(created.map { read($0.url).contains("\nschema: 1\n") } == true, "a new object carries the schema")
            let slug = store.createFeature(title: "Fresh idea", idea: "An idea.")
            check(slug.map { read(features.appendingPathComponent($0 + "/overview.md")).contains("\nschema: 1\n") } == true, "a new feature carries the schema")

            print("-- a file of a newer schema")
            store.lastError = nil
            store.updateFeature("future") { front, _ in front.set("status", "review") }
            check(read(futureOverviewURL) == futureOverview, "an overview of a newer schema is not rewritten")
            check(store.lastError?.contains("newer MarkView") == true, "and the store says why: \(store.lastError ?? "no error")")
            store.lastError = nil
            store.update("REQ-002", in: "legacy") { front, _ in front.set("status", "approved") }
            check(read(futureRequirementURL) == futureRequirement && store.lastError?.contains("newer MarkView") == true, "an object of a newer schema is not rewritten")
            store.lastError = nil
            let refused = store.updateBug(futureBugURL) { front, _ in front.set("status", "fixing") }
            check(!refused && read(futureBugURL) == futureBug && store.lastError?.contains("newer MarkView") == true, "a bug report of a newer schema is not rewritten")
            store.lastError = nil
            store.updateMany(["REQ-001", "REQ-002"], in: "legacy") { _, front, _ in front.set("owner", "Boris") }
            check(read(futureRequirementURL) == futureRequirement && read(legacyRequirementURL).contains("owner: Boris\n"),
                  "many at once: the object of the older schema is written, the newer one is left")
            check(store.lastError?.contains("newer MarkView") == true, "and the one that was left is reported")
            store.lastError = nil
            store.savePlan("future", title: "Plan", issues: [], epic: nil)
            check(read(futurePlanURL) == futurePlan && store.lastError?.contains("newer MarkView") == true, "a plan of a newer schema is not rewritten")
        }
        await run()
    }

    @MainActor func testNewProjectCloseCancelsWork() async {
        func check(_ condition: Bool, _ message: String, line: UInt = #line) {
            XCTAssertTrue(condition, message, line: line)
        }
        let suiteName = "new-project-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let isolatedSettings = Settings(defaults)
        let draftFolder = FileManager.default.temporaryDirectory.appendingPathComponent("new-project-drafts-" + UUID().uuidString)
        let draftStore = ProjectDraftStore(folder: draftFolder)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: draftFolder)
        }
        @MainActor
        func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }

        /// What the jobs wrote, and which ones were cut off.
        @MainActor
        final class Log {
            var written: [String] = []
            var cancelled: [String] = []
            /// The folder the store had when a job woke up and read it through its assistant (nil: a folder is not open, which a new draft never has).
            var woke: [String] = []

            func work(_ label: String, nanoseconds: UInt64) -> @MainActor (FeatureAssistant) async -> Void {
                return { [self] assistant in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    // The way every AI step reads the store once more after its call.
                    _ = assistant.store.root
                    woke.append(label)
                    if Task.isCancelled {
                        cancelled.append(label)
                        return
                    }
                    written.append(label)
                }
            }
        }

        @MainActor
        func startAndRestart() async {
            print("-- a job started through the assistant")
            let flow = NewProjectFlow(settings: isolatedSettings, drafts: draftStore)
            let log = Log()
            check(flow.assistant.start("explore:a", log.work("a", nanoseconds: 300_000_000)), "the job starts")
            check(flow.store.jobs.isRunning("explore:a"), "it runs under its key in the store's jobs")
            check(!flow.assistant.start("explore:a", log.work("again", nanoseconds: 10_000_000)), "a second start of the key is refused")
            check(flow.assistant.error?.contains("already running") == true, "and says the step is already running")
            check(flow.assistant.start("decide:a", log.work("other", nanoseconds: 10_000_000)), "another key runs beside it")
            check(await waitUntil { log.written.contains("a") && log.written.contains("other") }, "both finish and write")
            check(!log.written.contains("again"), "the refused work never ran")
            check(await waitUntil { !flow.store.jobs.isRunning("explore:a") }, "a finished job leaves its key free")
            check(flow.assistant.start("explore:a", log.work("a2", nanoseconds: 10_000_000)), "the same key starts again")
            check(await waitUntil { log.written.contains("a2") }, "and writes")
        }

        @MainActor
        func closeEndsTheJobs() async {
            print("-- the sheet closes while a job runs")
            let flow = NewProjectFlow(settings: isolatedSettings, drafts: draftStore)
            let log = Log()
            check(flow.assistant.start("explore:slow", log.work("slow", nanoseconds: 5_000_000_000)), "a slow job starts")
            flow.close()
            check(!flow.store.jobs.isRunning("explore:slow"), "closing frees its key at once")
            check(await waitUntil(1) { log.cancelled == ["slow"] }, "the job is cut off without waiting for its call")
            check(log.written.isEmpty, "a cut off job writes nothing")
            check(flow.assistant.start("explore:slow", log.work("again", nanoseconds: 10_000_000)), "the same key starts again after a close")
            check(await waitUntil { log.written == ["again"] }, "and writes")
        }

        @MainActor
        func closeEndsTheStep() async {
            print("-- the sheet closes while a step is started")
            var fired = 0
            let open = NewProjectFlow(settings: isolatedSettings, drafts: draftStore)
            open.startDiscard { fired += 1 }
            check(await waitUntil { fired == 1 }, "a step that is not cut off runs to its end")
            let closed = NewProjectFlow(settings: isolatedSettings, drafts: draftStore)
            closed.startDiscard { fired += 10 }
            closed.close()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(fired == 1, "a step that the close cut off does not report its end")
        }

        @MainActor
        func storeOutlivesTheSheet() async {
            print("-- the sheet is gone before the job wakes")
            let log = Log()
            weak var weakFlow: NewProjectFlow?
            weak var weakStore: FeatureStore?
            do {
                let flow = NewProjectFlow(settings: isolatedSettings, drafts: draftStore)
                weakFlow = flow
                weakStore = flow.store
                flow.assistant.start("explore:late", log.work("late", nanoseconds: 400_000_000))
                flow.close()
            }
            check(weakFlow == nil, "the flow is released when the sheet lets go of it")
            check(weakStore != nil, "the store is still there for the job in flight")
            check(await waitUntil { log.woke == ["late"] }, "the cut off job wakes and reads its store without a trap")
            check(log.cancelled == ["late"], "and sees that it was cut off")
            check(await waitUntil { weakStore == nil }, "the store is released once the job has ended")
        }
        await startAndRestart()
        await closeEndsTheJobs()
        await closeEndsTheStep()
        await storeOutlivesTheSheet()
    }
}

extension EditorHostTests {
    @MainActor func testFeatureStoresUseIndependentSettings() throws {
        let nameA = "feature-store-isolation-a-" + UUID().uuidString
        let nameB = "feature-store-isolation-b-" + UUID().uuidString
        let defaultsA = UserDefaults(suiteName: nameA)!
        let defaultsB = UserDefaults(suiteName: nameB)!
        let settingsA = Settings(defaultsA), settingsB = Settings(defaultsB)
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("feature-store-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let first = FeatureStore(settings: settingsA), second = FeatureStore(settings: settingsB)
        defer {
            first.reset()
            second.reset()
            defaultsA.removePersistentDomain(forName: nameA)
            defaultsB.removePersistentDomain(forName: nameB)
            try? FileManager.default.removeItem(at: project)
        }
        first.setup(root: project)
        first.activeSlug = "fixture"
        let projectID = String(ContentHash.of(project.standardizedFileURL.path).prefix(12))
        let key = Setting.featureActive(project: projectID)
        XCTAssertEqual(settingsA.stored(key), "fixture")
        XCTAssertNil(settingsB.stored(key))
        second.setup(root: project)
        XCTAssertNil(second.activeSlug)
    }
}
