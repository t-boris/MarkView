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

print(failures == 0 ? "All discovery checks passed." : "\(failures) discovery check(s) failed.")
exit(failures == 0 ? 0 : 1)
