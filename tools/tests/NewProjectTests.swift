// Checks the rules of Start a Project from Scratch (MarkView/Models/NewProject.swift) against
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
let open = [Q(id: "Q-001", title: "Who uses it?", blocking: true), Q(id: "Q-002", title: "Colour scheme?", blocking: false)]
check("blocking question blocks", !ProjectConfirmation.canConfirm(goal: "Plan recipes", open: open))
check("blockers listed", ProjectConfirmation.blockers(open).map(\.id) == ["Q-001"])
check("non-blocking questions stay open", ProjectConfirmation.canConfirm(goal: "Plan recipes", open: [open[1]]))
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

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
