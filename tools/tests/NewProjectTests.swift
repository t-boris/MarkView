// Checks the rules of Start a Project from Scratch (MarkView/Models/Workspace/NewProject.swift) against
// DEC-009, DEC-010, DEC-015, DEC-016, DEC-018, DEC-019 and DEC-023.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
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
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
