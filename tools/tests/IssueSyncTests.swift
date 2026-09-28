// Checks the link resolution, eligibility and report rules of Sync (MarkView/Models/IssueSync.swift)
// against REQ-002…REQ-004 and DEC-001, DEC-005, DEC-006, DEC-008, DEC-010 of
// docs/features/sync-documented-status-to-github-issues.
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition { print("ok  \(name)") } else { failures += 1; print("FAIL \(name)") }
}

let origin = "t-boris/MarkView"
func t(_ number: Int, _ repo: String = origin) -> IssueSyncTarget { IssueSyncTarget(repo: repo, number: number) }
func feature(_ id: String, _ status: String, fields: [String] = [], texts: [String] = []) -> IssueSyncItem {
    IssueSyncItem(kind: .feature, id: id, title: id, status: status, fieldValues: fields, texts: texts)
}
func bug(_ id: String, _ status: String, fields: [String] = [], texts: [String] = []) -> IssueSyncItem {
    IssueSyncItem(kind: .bug, id: id, title: id, status: status, fieldValues: fields, texts: texts)
}
func targets(_ item: IssueSyncItem) -> [IssueSyncTarget] { IssueSyncLinks.references(of: item, origin: origin).map(\.target) }

// MARK: Explicit references (REQ-002, DEC-001, DEC-006)

check("field #n resolves to origin", targets(feature("f", "", fields: ["#36"])) == [t(36)])
check("field bare number resolves to origin", targets(feature("f", "", fields: ["12"])) == [t(12)])
check("field owner/repo#n", targets(feature("f", "", fields: ["t-boris/MarkView#7"])) == [t(7)])
check("field full issue URL", targets(feature("f", "", fields: ["https://github.com/t-boris/MarkView/issues/9"])) == [t(9)])
check("field several values in one string", targets(feature("f", "", fields: ["#1, #2"])) == [t(1), t(2)])
check("repository compared without case", t(5, "T-Boris/markview") == t(5))
check("text issue URL resolves", targets(feature("f", "", texts: ["See https://github.com/t-boris/MarkView/issues/40 here"])) == [t(40)])
check("text URL with comment anchor", targets(feature("f", "", texts: ["https://github.com/t-boris/MarkView/issues/41#issuecomment-1"])) == [t(41)])
check("text 'issue #n' is not a link", targets(feature("f", "", texts: ["Fixes issue #12 and #13"])).isEmpty)
check("text PR URL is not an issue reference", targets(feature("f", "", texts: ["https://github.com/t-boris/MarkView/pull/51"])).isEmpty)
check("duplicates across fields and text kept once",
      targets(feature("f", "", fields: ["#3", "3"], texts: ["https://github.com/t-boris/MarkView/issues/3"])) == [t(3)])
check("item linked to several issues keeps each",
      targets(feature("f", "", fields: ["#1", "#2"], texts: ["https://github.com/t-boris/MarkView/issues/4"])) == [t(1), t(2), t(4)])
let pullField = IssueSyncLinks.fieldReferences(["https://github.com/t-boris/MarkView/pull/8"], origin: origin)
check("field PR URL is a pull link", pullField.count == 1 && pullField[0].isPullLink && pullField[0].target == t(8))

// MARK: Plan: other repositories, pull links, unlinked (DEC-006, DEC-010)

let plan = IssueSyncPlan(items: [
    feature("done-a", "implemented", fields: ["#10"]),
    feature("wip", "implementing", fields: ["#10", "#11"]),
    bug("BUG-001", "fixed", fields: ["#12"]),
    bug("BUG-002", "closed", fields: ["upstream/MarkView#5"]),
    feature("text-only", "verified", texts: ["issue #99"]),
    feature("pr-link", "archived", fields: ["https://github.com/t-boris/MarkView/pull/20"]),
    feature("fork", "implemented", texts: ["https://github.com/someone/MarkView/issues/3"]),
], origin: origin)
check("lookups are unique origin issues in order", plan.lookups == [t(10), t(11), t(12)])
check("other repository skipped", plan.known[t(5, "upstream/MarkView")] == .otherRepository)
check("fork is another repository", plan.known[t(3, "someone/MarkView")] == .otherRepository)
check("PR link skipped as pull request", plan.known[t(20)] == .pullRequest)
let unlinkedPairs = plan.pairs.filter { $0.target == nil }.map { plan.items[$0.item].id }
check("text-only item is the only unlinked one", unlinkedPairs == ["text-only"])
check("rejected-only items get no unlinked row", !unlinkedPairs.contains("BUG-002") && !unlinkedPairs.contains("pr-link"))

// MARK: Eligibility (REQ-003, DEC-005, owner answer on bugs)

check("feature statuses done", ["implemented", "verified", "archived", " Implemented "].allSatisfy { feature("f", $0).isDone })
check("feature earlier statuses not done", ["", "idea", "ready", "implementing", "done"].allSatisfy { !feature("f", $0).isDone })
check("bug fixed/closed done", bug("b", "fixed").isDone && bug("b", "closed").isDone)
check("bug open/fixing not done", !bug("b", "open").isDone && !bug("b", "fixing").isDone)
check("shared issue with an unfinished item is not closed", {
    if case .outcome(let o) = plan.decide(t(10), remote: .issue(open: true)) { return o.kind == .skipped && o.detail.contains("wip (implementing)") }
    return false
}())
check("issue of a fixed bug closes", plan.decide(t(12), remote: .issue(open: true)) == .close)
check("closed issue is unchanged, never reopened", plan.decide(t(12), remote: .issue(open: false)) == .outcome(.alreadyClosed))
check("number that is a PR is skipped", plan.decide(t(12), remote: .pullRequest) == .outcome(.pullRequest))
check("missing issue is skipped", plan.decide(t(12), remote: .notFound) == .outcome(.notFound))
check("lookup failure is failed with message", plan.decide(t(12), remote: .failed("HTTP 403")) == .outcome(IssueSyncOutcome(kind: .failed, detail: "HTTP 403")))

// MARK: GitHub answers

check("open issue parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"open"}"#) == .issue(open: true))
check("closed issue parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"closed","state_reason":"completed"}"#) == .issue(open: false))
check("pull request parsed", IssueSyncRemote.parse(json: #"{"number":1,"state":"open","pull_request":{"url":"x"}}"#) == .pullRequest)
check("garbage is a failure", { if case .failed = IssueSyncRemote.parse(json: "<html>") { return true }; return false }())
check("404 is not found", IssueSyncRemote.failure(message: "gh: Not Found (HTTP 404)") == .notFound)
check("410 is not found", IssueSyncRemote.failure(message: "gh: This issue was deleted (HTTP 410)") == .notFound)
check("403 is a failure, not 'not found'",
      IssueSyncRemote.failure(message: "gh: Resource not accessible by integration (HTTP 403)") != .notFound)
check("403 message kept", IssueSyncRemote.failure(message: "HTTP 403: Forbidden") == .failed("HTTP 403: Forbidden"))
check("write access allows closing", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"WRITE"}"#, repo: origin) == nil)
check("triage access allows closing", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"TRIAGE"}"#, repo: origin) == nil)
check("read access blocks the run", IssueSyncPreflight.permissionProblem(json: #"{"viewerPermission":"READ"}"#, repo: origin) != nil)

// MARK: Report (REQ-004, DEC-008, DEC-010)

var outcomes = plan.known
outcomes[t(10)] = IssueSyncOutcome(kind: .skipped, detail: "not done yet: wip (implementing)")
outcomes[t(11)] = .alreadyClosed
outcomes[t(12)] = .closed
let report = IssueSyncReport(plan: plan, outcomes: outcomes)
check("one row per item–issue pair plus unlinked", report.rows.count == plan.pairs.count && report.rows.count == 8)
check("shared issue counted once", report.count(.skipped) == 4)  // #10, #20, upstream#5, someone#3
check("closed counted", report.count(.updated) == 1)
check("unchanged counted", report.count(.unchanged) == 1)
check("unlinked counted apart", report.unlinkedCount == 1)
check("both items of a shared issue have rows", report.rows.filter { $0.target == t(10) }.map(\.item.id) == ["done-a", "wip"])
check("closed rows come first after failures", report.linkedRows.first?.outcome == .closed)
check("summary", report.summary == "1 closed · 1 unchanged · 4 skipped · 1 unlinked")
check("preflight error report has no rows", IssueSyncReport(origin: origin, error: "Not signed in").rows.isEmpty)
check("label in origin is #n", t(12).label(origin: origin) == "#12")
check("label elsewhere names the repo", t(5, "upstream/MarkView").label(origin: origin) == "upstream/markview#5")

print(failures == 0 ? "All issue sync checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
