import Foundation

// Standalone checks for MarkView/Models/PullRequestHistory.swift (BUG-034).
// Run through tools/tests/pull-request-history-tests.sh.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        print("FAIL: \(message)")
    }
}

/// Stands in for the `gh pr list` call and counts how often it is started.
final class FakeGH: @unchecked Sendable {
    private(set) var calls = 0
    let result: PullRequestHistory.Fetched
    init(status: Int32 = 0, stdout: String = "[]") { result = (status, stdout) }
    func run() async -> PullRequestHistory.Fetched {
        calls += 1
        return result
    }
}

let listing = """
[{"number":7,"title":"Add X-Ray","body":"Why it exists","url":"https://github.com/o/r/pull/7","mergedAt":"2026-09-01T00:00:00Z","mergeCommit":{"oid":"abc"}},
 {"number":8,"title":"Fix it","body":null,"url":"https://github.com/o/r/pull/8","mergedAt":null,"mergeCommit":null}]
"""

// Integration off: gh is never started, and the context says no PR data was available.
let off = FakeGH(stdout: listing)
let offSection = await PullRequestHistory.section(enabled: false) { await off.run() }
check(off.calls == 0, "integration off: gh pr list must not be started")
check(offSection.text.contains("PR data unavailable"), "integration off: the context says no PR data was available")
check(offSection.text.contains("turned off"), "integration off: the context says why")
check(offSection.text.contains("Do not invent PRs"), "integration off: the agent is told not to invent PRs")
check(offSection.urls.isEmpty, "integration off: no pull request URL may be cited")
check(!offSection.text.contains("Add X-Ray"), "integration off: no pull request data reaches the context")

// Integration on: gh runs once and its pull requests are listed with their URLs.
let on = FakeGH(stdout: listing)
let onSection = await PullRequestHistory.section(enabled: true) { await on.run() }
check(on.calls == 1, "integration on: gh pr list runs exactly once")
check(onSection.text.hasPrefix("\n\nRead-only pull requests:\n"), "integration on: the pull requests are listed")
check(onSection.text.contains("Add X-Ray") && onSection.text.contains("Why it exists"), "integration on: titles and bodies are included")
check(onSection.urls == ["https://github.com/o/r/pull/7", "https://github.com/o/r/pull/8"], "integration on: the listed URLs may be cited")
check(!onSection.text.contains("PR data unavailable"), "integration on: no unavailable note when the list was read")

// Integration on but gh fails or answers nonsense: the unavailable note, never an invented list.
for (name, fake) in [("gh missing", FakeGH(status: -1, stdout: "")), ("gh error", FakeGH(status: 1, stdout: "[]")),
                     ("not JSON", FakeGH(stdout: "oops")), ("not a list", FakeGH(stdout: "{\"a\":1}"))] {
    let section = await PullRequestHistory.section(enabled: true) { await fake.run() }
    check(fake.calls == 1, "\(name): gh was asked once")
    check(section.text == "\n\n" + PullRequestHistory.unavailableNote, "\(name): the unavailable note")
    check(section.urls.isEmpty, "\(name): no URLs")
}
check(PullRequestHistory.unavailableNote != PullRequestHistory.integrationOffNote, "the two notes tell different reasons")

// An empty list is a real answer: no pull requests.
let empty = await PullRequestHistory.section(enabled: true) { (0, "[]") }
check(empty.text.hasSuffix("\nNo pull requests found."), "an empty list says no pull requests were found")

// Bounds are unchanged: 50 records, bodies cut to 1600 characters, valid JSON kept.
let body = String(repeating: "b", count: 2000)
let many = "[" + (1...60).map { "{\"number\":\($0),\"title\":\"t\",\"body\":\"\(body)\",\"url\":\"https://github.com/o/r/pull/\($0)\"}" }
    .joined(separator: ",") + "]"
let bounded = await PullRequestHistory.section(enabled: true) { (0, many) }
check(bounded.urls.count == 50, "at most 50 pull requests are listed")
let json = bounded.text.replacingOccurrences(of: "\n\nRead-only pull requests:\n", with: "")
let records = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]]
check(records?.count == 50, "the bounded list is still valid JSON")
check(records?.allSatisfy { ($0["body"] as? String)?.count == 1600 } == true, "bodies are cut to 1600 characters")

if failures == 0 {
    print("pull request history: all checks passed")
} else {
    print("pull request history: \(failures) check(s) failed")
    exit(1)
}
