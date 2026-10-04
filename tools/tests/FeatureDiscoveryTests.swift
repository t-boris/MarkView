import Foundation

// Checks the discovery rules of a feature (MarkView/Models/FeatureModels.swift): when discovery is
// done, the order of the open questions, and the readiness condition. Compiled by
// tools/tests/feature-discovery-tests.sh together with FeatureModels.swift and FrontMatter.swift.

/// Bug discussion parsing lives in FeatureIntake.swift, which needs the whole app; the checks
/// here never read a bug report.
enum FeatureAssistant {
    static func bugSections(_ body: String) -> [(heading: String, text: String)] { [] }
}

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

func feature(front: String, questions: [(id: String, status: String, priority: String)]) -> Feature {
    let (fm, body) = FrontMatter.split("---\n\(front)\n---\n\n# T\n")
    var feature = Feature(slug: "t", folder: URL(fileURLWithPath: "/tmp/t"), front: fm, overviewBody: body)
    feature.objects[.question] = questions.map { q in
        let (qf, qb) = FrontMatter.split("---\ntype: question\nid: \(q.id)\nstatus: \(q.status)\npriority: \(q.priority)\n---\n\n## Question\n\nQ\n")
        return FeatureObject(kind: .question, id: q.id, url: URL(fileURLWithPath: "/tmp/t/questions/\(q.id).md"), front: qf, body: qb)
    }
    return feature
}

// A fresh feature: nothing asked, no estimate — discovery has not run.
let fresh = feature(front: "title: T\nstatus: exploring", questions: [])
check(!fresh.isUnderstood, "fresh feature is not understood")
check(fresh.openQuestions.isEmpty, "fresh feature has no open question")

// The intake asked three questions: not understood while any is open.
let asked = feature(front: "title: T\nstatus: exploring\nquestions_left: \"3\"",
                    questions: [("Q-001", "open", "normal"), ("Q-002", "open", "blocking"), ("Q-003", "answered", "normal")])
check(!asked.isUnderstood, "open questions keep discovery running")
check(asked.openQuestions.map(\.id) == ["Q-002", "Q-001"], "blocking questions come first")
check(!asked.discoveryDone, "discovery is not done while a question is open")

// Every question settled, the AI expects none: done — whatever the dimensions say.
let done = feature(front: "title: T\nstatus: exploring\nquestions_left: \"0\"\nunderstanding:\n  Problem: known\n  Security: unknown",
                   questions: [("Q-001", "answered", "normal"), ("Q-002", "deferred", "blocking")])
check(done.isUnderstood, "settled questions and questions_left 0 end discovery")
check(done.discoveryDone, "discoveryDone follows")
check(done.readinessConditions.first { $0.name == "Feature understood" }.map { $0.met } == true, "readiness: feature understood met")

// Every question settled but the AI expects more: not done.
let more = feature(front: "title: T\nstatus: exploring\nquestions_left: \"2\"",
                   questions: [("Q-001", "answered", "normal")])
check(!more.isUnderstood, "questions_left above 0 keeps discovery open")
check(more.discoveryDone, "but the round is over (nothing open) so leaving Explore approves")
check(more.readinessConditions.first { $0.name == "Feature understood" }.map { !$0.met } == true, "readiness: not met while the AI expects more")

// A feature from before this rule: every dimension known or n/a, no estimate.
var legacyFront = "title: T\nstatus: review\nunderstanding:\n"
for dimension in FeatureVocabulary.understanding { legacyFront += "  \(dimension): \(dimension == "Security" ? "n/a" : "known")\n" }
let legacy = feature(front: legacyFront, questions: [("Q-001", "answered", "normal")])
check(legacy.isUnderstood, "legacy feature with every dimension known counts as understood")

// Quick feature: no questions, questions_left 0.
let quick = feature(front: "title: T\nstatus: ready\nintake: quick\nquestions_left: \"0\"", questions: [])
check(quick.isUnderstood, "quick feature is understood at once")

// BUG-023: review convergence — decisions written into requirements, settled findings remembered.
func object(_ kind: FeatureObjectKind, _ id: String, _ front: String, _ body: String = "") -> FeatureObject {
    let (fm, b) = FrontMatter.split("---\ntype: \(kind.rawValue)\nid: \(id)\n\(front)\n---\n\n\(body)")
    return FeatureObject(kind: kind, id: id, url: URL(fileURLWithPath: "/tmp/t/\(id).md"), front: fm, body: b)
}

let requirementBody = "## Statement\n\nOld rule.\n\n## Acceptance Criteria\n\n- [x] Kept\n- [ ] Old\n\n## Notes\n\nKeep me.\n"
let rewritten = FeatureObject.replacingSection("Statement", in: requirementBody, with: "New rule.")
check(rewritten.contains("## Statement\n\nNew rule.\n\n## Acceptance Criteria"), "a section's text is replaced in place")
check(!rewritten.contains("Old rule."), "the old section text is gone")
check(rewritten.contains("## Notes\n\nKeep me."), "other sections stay")
let lastReplaced = FeatureObject.replacingSection("Notes", in: requirementBody, with: "Changed.")
check(lastReplaced.hasSuffix("## Notes\n\nChanged.\n") && lastReplaced.contains("- [ ] Old"), "the last section is replaced up to the end")
let appended = FeatureObject.replacingSection("Statement", in: "## Acceptance Criteria\n\n- [ ] A\n", with: "S.")
check(appended.hasSuffix("## Statement\n\nS.\n") && appended.hasPrefix("## Acceptance Criteria"), "a missing section is appended")
check(FeatureObject.acceptanceCriteria(in: requirementBody).map(\.done) == [true, false], "criteria are read from a body")

var decided = feature(front: "title: T\nstatus: review", questions: [])
decided.objects[.decision] = [object(.decision, "DEC-001", "status: proposed"),
                              object(.decision, "DEC-002", "status: accepted\napplied: 2026-10-04"),
                              object(.decision, "DEC-003", "status: rejected"),
                              object(.decision, "DEC-004", "status: accepted")]
decided.objects[.finding] = [object(.finding, "F-001", "status: resolved", "## Resolution\n\nAI: write X into REQ-001.\n"),
                             object(.finding, "F-002", "status: resolved\nresolved_by: DEC-004", "## Resolution\n\nSee DEC-004.\n"),
                             object(.finding, "F-003", "status: resolved\napplied: 2026-10-04", "## Resolution\n\nDone.\n"),
                             object(.finding, "F-004", "status: dismissed", "## Resolution\n\nNo.\n")]
check(decided.settlementsToApply.map(\.id) == ["DEC-001", "DEC-004", "F-001"],
      "pending: decisions in force and text-only resolutions not yet applied")

let resolved = object(.finding, "F-001", "status: resolved", "## Finding\n\nX\n\n## Resolution\n\nAI: do Y — see DEC-001.\n")
check(resolved.settlement == "AI: do Y — see DEC-001.", "a resolved finding carries its resolution")
check(object(.finding, "F-002", "status: dismissed\ndismissed_reason: gone").settlement == "dismissed: gone", "a dismissed finding carries its reason")
check(object(.finding, "F-003", "status: open").settlement.isEmpty, "an open finding is not settled")

print(failures == 0 ? "All discovery checks passed." : "\(failures) discovery check(s) failed.")
exit(failures == 0 ? 0 : 1)
