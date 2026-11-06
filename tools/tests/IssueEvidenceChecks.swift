// Checks the delivery evidence rules (MarkView/Models/IssueLifecycleEvidence.swift) against DEC-007, DEC-012, REQ-002 criterion 2
// and REQ-005 criterion 1 of docs/features/issue-lifecycle-management.
import Foundation

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func minutes(_ n: Double) -> Date { t0.addingTimeInterval(n * 60) }
let sources = [EvidenceSource.available("git"), .available("GitHub checks"), .available("GitHub releases")]
let code = ["MarkView/Models/IssueLifecycle.swift", "docs/features/x/overview.md"]

func unit(_ ref: WorkRef, merged: Date? = minutes(10), head: String = "aaa1111", paths: [String]? = code, checks: CheckState? = nil,
          association: WorkAssociation = .explicit, closedUnmerged: Bool = false) -> WorkUnit {
    WorkUnit(ref: ref, headSHA: head, mergedAt: merged, closedUnmerged: closedUnmerged, changedPaths: paths,
             checks: checks ?? .passed(sha: head), association: association)
}
func verdict(_ work: [WorkUnit], release: Bool = false, releases: [WorkRef: ReleaseState] = [:], since: Date? = nil,
             sources: [EvidenceSource] = sources) -> DeliveryVerdict {
    DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: work, releaseRequired: release, releases: releases, since: since))
}
func isComplete(_ v: DeliveryVerdict) -> Bool { v.isComplete }
func isIncomplete(_ v: DeliveryVerdict) -> Bool { if case .incomplete = v { return true } else { return false } }
func isUnknown(_ v: DeliveryVerdict) -> Bool { if case .unknown = v { return true } else { return false } }

let pr1 = WorkRef.pullRequest(1), pr2 = WorkRef.pullRequest(2), c1 = WorkRef.commit("1234567890abcdef")

// MARK: Completion needs merged work with passing checks (DEC-007)

check("a merged unit with passing checks completes", isComplete(verdict([unit(pr1)])))
check("the summary names the unit", verdict([unit(pr1)]).lines.first?.contains("PR #1") == true)
check("a direct commit on main counts", isComplete(verdict([unit(c1, head: "1234567890abcdef")])))
check("no work at all is not completion", isIncomplete(verdict([])))
check("an unmerged pull request is not completion", isIncomplete(verdict([unit(pr1, merged: nil)])))
check("a pull request closed without merging counts for nothing", isIncomplete(verdict([unit(pr1, merged: nil, closedUnmerged: true)])))
check("a closed-unmerged unit does not block a merged one", isComplete(verdict([unit(pr1), unit(pr2, merged: nil, closedUnmerged: true)])))
check("every associated unit must be merged", isIncomplete(verdict([unit(pr1), unit(pr2, merged: nil)])))
check("the unmerged unit is named", verdict([unit(pr1), unit(pr2, merged: nil)]).lines.contains { $0.contains("PR #2") && $0.contains("not merged") })
check("a failed check blocks", isIncomplete(verdict([unit(pr1, checks: .failed(sha: "aaa1111"))])))
check("a running check blocks", isIncomplete(verdict([unit(pr1, checks: .pending(sha: "aaa1111"))])))
check("a commit without any workflow run is unknown, not a pass", isUnknown(verdict([unit(pr1, checks: .noRuns(sha: "aaa1111"))])))
check("unreadable checks are unknown", isUnknown(verdict([unit(pr1, checks: .unknown("rate limited"))])))

// MARK: Stale evidence (REQ-005 criterion 1, plan I-4 "changed commit heads")

check("checks of an older commit do not count for a moved head",
      isIncomplete(verdict([unit(pr1, head: "bbb2222", checks: .passed(sha: "aaa1111"))])))
check("the stale head is named", verdict([unit(pr1, head: "bbb2222", checks: .passed(sha: "aaa1111"))]).lines.contains { $0.contains("older commit") })

// MARK: Documentation-only work is not implementation work (DEC-012)

check("a docs-only commit is not implementation work", isIncomplete(verdict([unit(c1, paths: ["docs/features/x/overview.md", "tasks/todo.md"])])))
check("a docs-only commit does not block real work", isComplete(verdict([unit(pr1), unit(c1, merged: minutes(11), paths: ["README.md"], checks: .noRuns(sha: "aaa1111"))])))
check("docs paths", DocumentationPaths.isDocumentation("docs/a.md") && DocumentationPaths.isDocumentation("tasks/x") && DocumentationPaths.isDocumentation("CLAUDE.md"))
check("code paths", !DocumentationPaths.isDocumentation("MarkView/Models/A.swift") && !DocumentationPaths.isDocumentation("project.yml") && !DocumentationPaths.isDocumentation(".github/workflows/x.yml"))
check("a unit with an unreadable file list is unknown", isUnknown(verdict([unit(pr1, paths: nil)])))
check("an empty file list is not documentation-only", !unit(pr1, paths: []).isDocumentationOnly)

// MARK: A required release (DEC-007, DEC-012)

check("with a release required and delivered it completes",
      isComplete(verdict([unit(pr1)], release: true, releases: [pr1: .delivered(tag: "v5.36.0")])))
check("the release is in the summary", verdict([unit(pr1)], release: true, releases: [pr1: .delivered(tag: "v5.36.0")]).lines.first?.contains("v5.36.0") == true)
check("merged and green but unreleased stays unfinished", isIncomplete(verdict([unit(pr1)], release: true, releases: [pr1: .pending])))
check("the missing release is named", verdict([unit(pr1)], release: true, releases: [pr1: .pending]).lines.contains { $0.contains("release") })
check("a release that could not be determined is unknown", isUnknown(verdict([unit(pr1)], release: true, releases: [pr1: .unknown("compare failed")])))
check("a release never collected is unknown", isUnknown(verdict([unit(pr1)], release: true)))
check("no release is asked for when not required", isComplete(verdict([unit(pr1)], release: false, releases: [pr1: .pending])))
check("every unit needs its release",
      isIncomplete(verdict([unit(pr1), unit(c1, head: "ccc3333")], release: true, releases: [pr1: .delivered(tag: "v1"), c1: .pending])))

// MARK: Unavailable and ambiguous sources are never a pass (REQ-005 criterion 1)

check("an unavailable source makes it unknown", isUnknown(verdict([unit(pr1)], sources: [.available("git"), .unavailable("GitHub", "not signed in")])))
check("the reason is kept", verdict([unit(pr1)], sources: [.unavailable("GitHub", "not signed in")]).lines.first?.contains("not signed in") == true)
check("a definite gap is reported as incomplete even when a source is down",
      isIncomplete(verdict([unit(pr1, merged: nil)], sources: [.unavailable("GitHub", "offline")])))
check("an ambiguously associated unit never completes",
      !isComplete(verdict([unit(pr1, association: .ambiguous("#294 is linked by two features"))])))
check("an ambiguous unit is reported as unknown", isUnknown(verdict([unit(pr1, association: .ambiguous("shared #294"))])) || isIncomplete(verdict([unit(pr1, association: .ambiguous("shared #294"))])))
check("an ambiguous unit does not count as merged work even when the rest is fine",
      !isComplete(verdict([unit(pr1, association: .ambiguous("shared"))])))
check("an ambiguous unit beside a clear one still blocks", !isComplete(verdict([unit(pr1), unit(pr2, association: .ambiguous("shared"))])))

// MARK: A reopened issue needs new work (Q-003, DEC-009)

check("work merged before the reopening does not complete it again", isIncomplete(verdict([unit(pr1, merged: minutes(10))], since: minutes(20))))
check("work merged after the reopening does", isComplete(verdict([unit(pr1, merged: minutes(10)), unit(pr2, merged: minutes(30), head: "ddd4444")], since: minutes(20))))
check("no start time asks for nothing more", isComplete(verdict([unit(pr1)], since: nil)))

// MARK: Association (DEC-012)

check("feature folder names the feature", WorkAssociationRules.mentionsFeature("feat: x\n\ndocs/features/issue-lifecycle-management/overview.md", slug: "issue-lifecycle-management", issues: []))
check("a longer slug is not the feature", !WorkAssociationRules.mentionsFeature("docs/features/issue-lifecycle-management-2/x", slug: "issue-lifecycle-management", issues: []))
check("a Feature trailer names the feature", WorkAssociationRules.mentionsFeature("feat: research map\n\nBody.\n\nFeature: issue-lifecycle-management\n", slug: "issue-lifecycle-management", issues: []))
check("a trailer is case-insensitive and tolerates spaces", WorkAssociationRules.mentionsFeature("x\n  feature:   s  \ny", slug: "S", issues: []))
check("a trailer of a longer slug is not the feature", !WorkAssociationRules.mentionsFeature("x\nFeature: s-2\n", slug: "s", issues: []))
check("a trailer in the middle of a line is not a trailer", !WorkAssociationRules.mentionsFeature("see Feature: s for details", slug: "s", issues: []))
check("an issue number of the feature names it", WorkAssociationRules.mentionsFeature("Fixes #294", slug: "s", issues: [294]))
check("another number does not", !WorkAssociationRules.mentionsFeature("Fixes #2940", slug: "s", issues: [294]))
check("a bug key names the bug", WorkAssociationRules.mentionsBug("fix: BUG-065 styles", key: "BUG-065", issues: []))
check("a longer bug key is another bug", !WorkAssociationRules.mentionsBug("fix: BUG-0651", key: "BUG-065", issues: []))
check("a bug key matches without case", WorkAssociationRules.mentionsBug("bug-065", key: "BUG-065", issues: []))
check("a quoted feature slug in a PR description names the feature", WorkAssociationRules.mentionsFeature("Complete UI Studio (`ui-studio`) REQ-001", slug: "ui-studio", issues: []))
check("a longer quoted feature slug does not name another feature", !WorkAssociationRules.mentionsFeature("`ui-studio-other`", slug: "ui-studio", issues: []))
check("abbreviated batch names every bug", ["BUG-012", "BUG-013", "BUG-014"].allSatisfy { WorkAssociationRules.mentionsBug("fix: BUG-012/013/014", key: $0, issues: []) })
check("abbreviated batch does not match a partial number", !WorkAssociationRules.mentionsBug("fix: BUG-012/0131", key: "BUG-013", issues: []))
check("an anchor is not an issue number", !WorkAssociationRules.mentionsIssueNumber("see a#12 and &#12;", in: [12]))
let split = WorkAssociationRules.exclusiveNumbers([1, 2], claimedByOthers: [2, 3])
check("a number another issue also links is shared", split.exclusive == [1] && split.shared == [2])

// Explicit project requirements, including an operator's documented override of old checklist defaults.
let policyData = Data(#"{"items":[{"id":"pr","mode":"require"},{"id":"ci","mode":"require"}]}"#.utf8)
let requiredPolicy = ProjectDeliveryPolicy.read(definition: policyData, guide: nil)
check("project policy requires the configured PR and CI", requiredPolicy.pullRequestRequired && requiredPolicy.checksRequired)
check("missing policy uses the standard PR and CI requirements", ProjectDeliveryPolicy.read(definition: nil, guide: nil).pullRequestRequired && ProjectDeliveryPolicy.read(definition: nil, guide: nil).checksRequired)
let askPolicy = Data(#"{"items":[{"id":"pr","mode":"ask"}]}"#.utf8)
check("ask before PR does not silently skip the PR", ProjectDeliveryPolicy.read(definition: askPolicy, guide: nil).pullRequestRequired)
let directGuide = "## Commits go straight to main (operator)\nUntil further notice, commit directly to `main` and push it.\n\n## CI is switched off (operator)\nUntil further notice, do not wait for CI."
let directPolicy = ProjectDeliveryPolicy.read(definition: policyData, guide: directGuide)
check("explicit operator rules override outdated PR and CI settings", !directPolicy.pullRequestRequired && !directPolicy.checksRequired)
let skipPR = Data(#"{"items":[{"id":"pr","mode":"skip"}]}"#.utf8)
let requiredGuide = "## Git Workflow\n- Never commit to main directly for anything else.\n- Open a pull request into main."
check("an explicit project rule requiring PR overrides a skipped checklist item", ProjectDeliveryPolicy.read(definition: skipPR, guide: requiredGuide).pullRequestRequired)
check("an AGENTS.md rule requiring a PR is respected", ProjectDeliveryPolicy.read(definition: skipPR, guide: "The most important rule: every feature and bug fix goes through a pull request.").pullRequestRequired)
let unconfirmedPR = WorkUnit(ref: .pullRequest(41), headSHA: "sha", mergedAt: minutes(10), changedPaths: ["app.swift"],
                             checks: .passed(sha: "sha"), pullRequestVerified: false)
let unresolvedPR = DeliveryEvaluator.evaluate(DeliveryInput(sources: sources, work: [unconfirmedPR], releaseRequired: false, pullRequestRequired: true))
check("a required PR must be confirmed by GitHub", !unresolvedPR.isComplete)
let negativeGuide = "Never commit directly to main. CI may be switched off in other projects."
let stillRequired = ProjectDeliveryPolicy.read(definition: policyData, guide: negativeGuide)
check("a casual or negative mention does not override requirements", stillRequired.pullRequestRequired && stillRequired.checksRequired)

// MARK: Reading git and GitHub output

let log = "\u{1e}aaa111\u{1f}2026-11-05T10:00:00+00:00\u{1f}feat: x\n\ndocs/features/x\n\u{1f}\nMarkView/A.swift\ndocs/x.md\n\u{1e}bbb222\u{1f}2026-11-05T11:00:00+00:00\u{1f}docs: y\n\u{1f}\nREADME.md\n"
let commits = GitWorkLog.commits(from: log)
check("git log records are split", commits.count == 2 && commits[0].sha == "aaa111" && commits[1].sha == "bbb222")
check("files and message are kept apart", commits[0].paths == ["MarkView/A.swift", "docs/x.md"] && commits[0].message.contains("docs/features/x"))
check("a commit without code files is docs", commits[1].paths.allSatisfy(DocumentationPaths.isDocumentation))
check("git arguments ask for names and the separators", GitWorkLog.arguments(ref: "origin/main").contains("--name-only"))

let allGreen = Data(#"[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]"#.utf8)
check("all runs green passes", RunsVerdict.state(runsJSON: allGreen, sha: "s") == .passed(sha: "s"))
check("a failed run fails", RunsVerdict.state(runsJSON: Data(#"[{"status":"completed","conclusion":"failure"}]"#.utf8), sha: "s") == .failed(sha: "s"))
check("a running run is pending", RunsVerdict.state(runsJSON: Data(#"[{"status":"in_progress","conclusion":""},{"status":"completed","conclusion":"success"}]"#.utf8), sha: "s") == .pending(sha: "s"))
check("no runs is noRuns, not a pass", RunsVerdict.state(runsJSON: Data("[]".utf8), sha: "s") == .noRuns(sha: "s"))
check("garbage is unknown", { if case .unknown = RunsVerdict.state(runsJSON: Data("nope".utf8), sha: "s") { return true } else { return false } }())
check("a failed run beats a running one", RunsVerdict.state(runsJSON: Data(#"[{"status":"in_progress"},{"status":"completed","conclusion":"failure"}]"#.utf8), sha: "s") == .failed(sha: "s"))
check("rollup SUCCESS passes", RunsVerdict.state(rollup: "SUCCESS", sha: "s") == .passed(sha: "s"))
check("rollup PENDING is pending", RunsVerdict.state(rollup: "PENDING", sha: "s") == .pending(sha: "s"))
check("rollup absent is noRuns", RunsVerdict.state(rollup: nil, sha: "s") == .noRuns(sha: "s"))

// MARK: The project's release rule comes from its definition of done

let dod = { (mode: String) in Data(#"{"items":[{"id":"branch","mode":"skip"},{"id":"deploy","mode":"\#(mode)"}]}"#.utf8) }
check("deploy required", ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("require")))
check("deploy skipped", !ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("skip")))
check("deploy ask-me is not a requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: dod("ask")))
check("no file, no requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: nil))
check("damaged file, no requirement", !ReleaseRequirement.isRequired(definitionOfDoneJSON: Data("{".utf8)))

finish("evidence")
