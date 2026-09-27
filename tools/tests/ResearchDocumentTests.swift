// Checks the research document format (MarkView/Models/ResearchDocument.swift) against REQ-002…005
// and DEC-006, DEC-007, DEC-008, DEC-013, DEC-014, DEC-016 and DEC-017.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}
let repo: Set<String> = ["README.md", "src/app.swift", "docs/guide.md"]
let exists: (String) -> Bool = { repo.contains($0) }
typealias R = ResearchDocument

// MARK: Path (DEC-006)

check("slug from question", R.slug("How do we replace App A with App B?") == "how-do-we-replace-app-a-with-app")
check("slug transliterates Cyrillic", R.slug("Как заменить приложение") == "kak-zamenit-prilozenie")
check("slug fallback", R.slug("???") == "research")
check("slug at most 60 chars", R.slug(String(repeating: "abcdefghij", count: 3) + " " + String(repeating: "x", count: 40)).count <= 60)
check("path date-slug", R.relativePath(question: "Why?", date: "2026-09-27", exists: { _ in false }) == "docs/research/2026-09-27-why.md")
let taken: Set<String> = ["docs/research/2026-09-27-why.md", "docs/research/2026-09-27-why-2.md"]
check("path collision suffix", R.relativePath(question: "Why", date: "2026-09-27", exists: { taken.contains($0) }) == "docs/research/2026-09-27-why-3.md")
check("id from path", R.id(forPath: "docs/research/2026-09-27-why-3.md") == "2026-09-27-why-3")

// MARK: Detection (DEC-007)

check("type research detected anywhere", R.isResearch("---\ntype: research\nid: x\n---\n\n# T\n"))
check("other type not research", !R.isResearch("---\ntype: bug\n---\n\n# T\n"))
check("no front matter not research", !R.isResearch("# type: research\n"))

// MARK: Answer parsing

let answer = R.parseAnswer("""
I will look at the files first.

## Summary

App B covers most needs.

## Findings

- [Project fact] Entry point is `src/app.swift:12`.
- [External fact] B supports SSO, see https://b.example.com/docs/sso.
  Second line of the same finding.
1. [AI inference] Migration takes 2 weeks.

## Recommendations

Start with a pilot.

## Sources

- ignored, the app builds Sources
""")
check("narration dropped", answer.summary == "App B covers most needs.")
check("three findings", answer.findings.count == 3)
check("continuation joined", answer.findings[1].contains("Second line"))
check("recommendations", answer.recommendations == "Start with a pilot.")
check("cut-off answer is summary", R.parseAnswer("partial thoughts").summary == "partial thoughts")

// MARK: Labels (REQ-004)

check("project fact with existing path kept", R.checkedFinding("[Project fact] Entry is src/app.swift:12.", pathExists: exists) == ("[Project fact] Entry is src/app.swift:12.", false))
check("project fact with backticked path kept", !R.checkedFinding("[Project fact] See `README.md`", pathExists: exists).relabelled)
check("project fact without path relabelled", R.checkedFinding("[Project fact] It uses SwiftUI.", pathExists: exists).text.hasPrefix("[AI inference] It uses SwiftUI."))
check("project fact with missing path relabelled", R.checkedFinding("[Project fact] See src/missing.swift", pathExists: exists).relabelled)
check("external fact with URL kept", !R.checkedFinding("[External fact] B has SSO (https://b.example.com/sso).", pathExists: exists).relabelled)
check("external fact without URL relabelled", R.checkedFinding("[External fact] B is popular.", pathExists: exists).text.contains("no source URL cited"))
check("unlabelled relabelled", R.checkedFinding("Plain claim", pathExists: exists).text.hasPrefix("[AI inference] Plain claim"))
check("two labels relabelled", R.checkedFinding("[Project fact] [AI inference] x README.md", pathExists: exists).text.contains("more than one label"))
check("bold label normalised", R.checkedFinding("**[Open assumption]** Users want it", pathExists: exists) == ("[Open assumption] Users want it", false))
check("inference and assumption need no source", !R.checkedFinding("[AI inference] likely", pathExists: exists).relabelled)
check("URLs trimmed", R.citedURLs("see (https://a.example.com/x).") == ["https://a.example.com/x"])
check("URL with parentheses kept", R.citedURLs("https://en.wikipedia.org/wiki/A_(b)") == ["https://en.wikipedia.org/wiki/A_(b)"])
check("paths only existing", R.citedPaths("src/app.swift and e.g. foo/bar.md and docs/guide.md:3", pathExists: exists) == ["src/app.swift", "docs/guide.md"])

// MARK: New document (DEC-008, DEC-016)

var run = R.Run(question: "Replace A with B?", answer: answer)
run.filesRead = ["README.md"]
run.webQueries = ["app B SSO support"]
let doc = R.newDocument(id: "2026-09-27-replace", title: "Replace A with B?", created: "2026-09-27", run: run, pathExists: exists)
let (front, body) = FrontMatter.split(doc)
check("front type", front.string("type") == "research")
check("front status complete", front.string("status") == "complete")
check("front web_queries", front.strings("web_queries") == ["app B SSO support"])
check("front question", front.string("question") == "Replace A with B?")
check("sections in order", ["# Replace", "## Question", "## Summary", "## Findings", "## Recommendations", "## Sources"]
    .map { body.range(of: $0)!.lowerBound }.sorted() == ["# Replace", "## Question", "## Summary", "## Findings", "## Recommendations", "## Sources"].map { body.range(of: $0)!.lowerBound })
check("every finding labelled", body.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count == 3)
check("inference note on relabel", !body.contains("labelled as inference"))
check("sources list cited and read files", body.contains("- `src/app.swift`") && body.contains("- `README.md`"))
check("sources list URL", body.contains("<https://b.example.com/docs/sso>"))
check("sources list web search", body.contains("- \"app B SSO support\""))
var failed = run
failed.incomplete = "cancelled after 3:10; web search unavailable"
let partial = R.newDocument(id: "x", title: "T", created: "2026-09-27", run: failed, pathExists: exists)
check("incomplete status", FrontMatter.split(partial).0.string("status") == "incomplete")
check("incomplete callout at top", FrontMatter.split(partial).1.hasPrefix("# T\n\n> ⚠️ Incomplete: cancelled"))
var empty = R.Run(question: "Q", answer: R.Answer())
empty.noProjectFiles = true
let emptyDoc = R.newDocument(id: "e", title: "Q", created: "2026-09-27", run: empty, pathExists: exists)
check("empty repo summary says no project facts", emptyDoc.contains("## Summary\n\nNo project facts were available"))

// MARK: Follow-ups and retries (DEC-005, DEC-013, DEC-014)

check("first follow-up is 1", R.nextFollowUpNumber(doc) == 1)
var follow = R.Run(question: "What about cost?", answer: R.Answer(summary: "Cheaper.", findings: ["[AI inference] 20% less"], recommendations: ""))
follow.incomplete = "the assistant stopped: timed out after 20 min"
let f1 = R.followUpSection(number: 1, date: "2026-09-28", retryOf: nil, run: follow, pathExists: exists)
let userEdited = doc.replacingOccurrences(of: "Start with a pilot.", with: "Start with a pilot. (my note)")
let withF1 = R.appending(f1, to: userEdited, webQueries: ["b pricing"])!
check("earlier content and user edits unchanged", FrontMatter.split(withF1).1.hasPrefix(FrontMatter.split(userEdited).1.trimmingCharacters(in: .newlines)))
check("delimiter and heading", withF1.contains("\n\n---\n\n## Follow-up 1: What about cost? (2026-09-28)\n\n> ⚠️ Incomplete:"))
check("follow-up subsections", withF1.contains("### Findings") && withF1.contains("### Recommendations") && withF1.contains("### Sources"))
check("status incomplete after failed follow-up", FrontMatter.split(withF1).0.string("status") == "incomplete")
check("web queries merged", FrontMatter.split(withF1).0.strings("web_queries") == ["app B SSO support", "b pricing"])
let secs = R.sections(withF1)
check("two sections", secs.map(\.name) == ["original research", "Follow-up 1"])
check("follow-up question parsed", secs[1].question == "What about cost?")
check("original question from front matter", secs[0].question == "Replace A with B?")
check("unresolved is follow-up 1", R.unresolved(secs).map(\.name) == ["Follow-up 1"])
check("next number 2", R.nextFollowUpNumber(withF1) == 2)
var retry = R.Run(question: "What about cost?", answer: R.Answer(summary: "Cheaper by 20%.", findings: [], recommendations: ""))
let failedRetry = { () -> String in var r = retry; r.incomplete = "cancelled"; return R.followUpSection(number: 2, date: "2026-09-28", retryOf: "Follow-up 1", run: r, pathExists: exists) }()
let withF2 = R.appending(failedRetry, to: withF1, webQueries: [])!
check("failed retry keeps incomplete", FrontMatter.split(withF2).0.string("status") == "incomplete")
check("retry reference parsed", R.sections(withF2)[2].retryOf == "Follow-up 1")
let f3 = R.followUpSection(number: 3, date: "2026-09-28", retryOf: "Follow-up 2", run: retry, pathExists: exists)
let withF3 = R.appending(f3, to: withF2, webQueries: [])!
check("retry of a retry resolves the chain", FrontMatter.split(withF3).0.string("status") == "complete")
check("earlier incomplete callouts stay", withF3.components(separatedBy: "> ⚠️ Incomplete:").count == 3)
check("front matter otherwise unchanged", FrontMatter.split(withF3).0.string("question") == "Replace A with B?")
let incompleteOriginal = R.appending(R.followUpSection(number: 1, date: "d", retryOf: "original research", run: retry, pathExists: exists), to: partial, webQueries: [])!
check("retry of original research completes it", FrontMatter.split(incompleteOriginal).0.string("status") == "complete")
check("lossy front matter refused", R.appending(f1, to: "---\ntype: research\n# comment\n---\n\nbody\n", webQueries: []) == nil)

// MARK: Comments (DEC-017)

let commented = """
---
type: research
status: complete
web_queries: []
---

# Title

## Summary

App B covers **most** needs.

## Findings

- [Project fact] Entry point is [app](src/app.swift).
- [AI inference] Migration takes 2 weeks.

### Detail

Deep detail text.

## Recommendations

Start with a pilot.
"""
func sectionText(_ passage: String) -> String? {
    R.enclosingSection(of: passage, in: commented).map { String(commented[$0]) }
}
check("phrase in Summary -> Summary", sectionText("covers most needs")?.hasPrefix("## Summary") == true)
check("section ends before next heading", sectionText("covers most needs")?.contains("## Findings") == false)
check("smallest section wins", sectionText("Deep detail")?.hasPrefix("### Detail") == true)
check("rendered link text matches", sectionText("Entry point is app")?.hasPrefix("## Findings") == true)
check("selection across items matches", sectionText("Entry point is app. [AI inference] Migration takes")?.hasPrefix("## Findings") == true)
check("parent includes subsection", sectionText("Migration takes 2 weeks. Detail Deep detail")?.hasPrefix("## Findings") == true)
check("typographic quotes and dashes match plain ones", sectionText("Start with a pilot") != nil
    && R.plain("It doesn’t — “really”… work") == R.plain("It doesn't - \"really\"... work"))
check("unknown passage", sectionText("not in the document") == nil)
check("front matter never matched", sectionText("web_queries") == nil)
let range = R.enclosingSection(of: "Migration takes 2 weeks", in: commented)!
check("range is the Findings section with Detail", String(commented[range]).contains("### Detail"))
let summaryRange = R.enclosingSection(of: "covers most needs", in: commented)!
let revised = R.replacing(summaryRange, in: commented, with: "## Summary\n\nApp B covers all needs except SSO.\n", webQueries: ["q1"])!
check("revised section replaced", revised.contains("## Summary\n\nApp B covers all needs except SSO.\n\n## Findings"))
check("other sections unchanged", revised.hasSuffix("## Recommendations\n\nStart with a pilot.\n"))
check("comment web queries recorded", FrontMatter.split(revised).0.strings("web_queries") == ["q1"])
let lastRange = R.enclosingSection(of: "Start with a pilot", in: commented)!
check("last section replaced with trailing newline", R.replacing(lastRange, in: commented, with: "## Recommendations\n\nPilot first.", webQueries: [])!.hasSuffix("## Recommendations\n\nPilot first.\n"))
let checked = R.checkingLabels(in: "## Findings\n\n- [Project fact] no path here\n- unlabelled\n\n## Recommendations\n\n- do it\n- [External fact] claim", pathExists: exists)
check("revised Findings relabelled", checked.contains("- [AI inference] no path here *(labelled as inference: no repository file cited)*"))
check("revised unlabelled finding relabelled", checked.contains("- [AI inference] unlabelled"))
check("plain recommendation untouched", checked.contains("- do it"))
check("labelled item outside Findings checked", checked.contains("- [AI inference] claim *(labelled as inference: no source URL cited)*"))

print(failures == 0 ? "All research document checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
