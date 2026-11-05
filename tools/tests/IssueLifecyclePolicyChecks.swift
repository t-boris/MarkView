// Checks the shared transition rules (MarkView/Models/IssueLifecycle.swift) against REQ-001 criteria 2–3, REQ-002 criteria 1–5,
// REQ-003 criterion 3 and DEC-007…DEC-011, DEC-013 of docs/features/issue-lifecycle-management.
import Foundation

let person = LifecycleActor.human("Boris")
let agent = LifecycleActor.ai("claude-code", session: "s1")
let app = LifecycleActor.system("MarkView")

let handedOff = StartEvidence.handoff(tool: "Claude Code", at: Date())
let delivered = DeliveryVerdict.complete(summary: ["PR #1 merged", "checks passed"])
let notDelivered = DeliveryVerdict.incomplete(missing: ["PR #2 is not merged"])

func req(_ kind: IssueKind = .feature, from: String, to: String, actor: LifecycleActor, reason: String? = nil, force: Bool = false,
         start: StartEvidence? = nil, delivery: DeliveryVerdict = .notCollected, acceptance: AcceptanceEvidence? = nil,
         regression: RegressionEvidence? = nil, cancellation: CancellationEvidence? = nil) -> TransitionRequest {
    TransitionRequest(kind: kind, issue: kind == .feature ? "f" : "BUG-001", from: from, to: to, actor: actor, reason: reason, force: force,
                      evidence: LifecycleEvidence(start: start, delivery: delivery, acceptance: acceptance, regression: regression,
                                                  cancellation: cancellation))
}
func decision(_ r: TransitionRequest) -> TransitionDecision { LifecyclePolicy.decide(r) }
func isAllowed(_ d: TransitionDecision) -> Bool { if case .allowed = d { return true } else { return false } }
func isRejected(_ d: TransitionDecision) -> Bool { if case .rejected = d { return true } else { return false } }
func rejection(_ d: TransitionDecision) -> Rejection? { if case .rejected(let r) = d { return r } else { return nil } }
func bypassed(_ d: TransitionDecision) -> [LifecycleCondition]? { if case .overridden(_, let b) = d { return b } else { return nil } }
func basisKind(_ d: TransitionDecision) -> TransitionKind? {
    switch d {
    case .allowed(let b), .overridden(let b, _): return b.kind
    default: return nil
    }
}

// MARK: Vocabulary stays separate (REQ-002 criterion 3)

check("feature statuses are the existing vocabulary", LifecycleVocabulary.statuses(.feature) == FeatureVocabulary.featureStatuses)
check("bug statuses are the existing vocabulary", LifecycleVocabulary.statuses(.bug) == ["open", "fixing", "fixed", "closed"])
check("a bug status is not a feature status", isRejected(decision(req(.bug, from: "open", to: "implementing", actor: person))))
check("unknown target status is refused even when forced",
      isRejected(decision(req(from: "ready", to: "done", actor: person, reason: "x", force: true))))
check("same status is no change", decision(req(from: "ready", to: "ready", actor: agent)) == .noChange)
check("status text is normalised", isAllowed(decision(req(from: " Ready ", to: "IMPLEMENTING", actor: app, start: handedOff))))

// MARK: Starting needs start evidence (REQ-002 criterion 1)

check("system starts on a recorded handoff", isAllowed(decision(req(from: "ready", to: "implementing", actor: app, start: handedOff))))
check("handoff start is a start", basisKind(decision(req(from: "ready", to: "implementing", actor: app, start: handedOff))) == .start)
check("no start evidence, no implementing", rejection(decision(req(from: "ready", to: "implementing", actor: app)))?.missing == [.startEvidence])
check("a session attached counts as start evidence",
      isAllowed(decision(req(from: "ready", to: "implementing", actor: agent, start: .attached(session: "s1", at: Date())))))
check("an AI without start evidence cannot start work", isRejected(decision(req(from: "ready", to: "implementing", actor: agent))))
check("a person starting by hand without evidence is refused", isRejected(decision(req(from: "ready", to: "implementing", actor: person))))
check("bug: handoff starts fixing", isAllowed(decision(req(.bug, from: "open", to: "fixing", actor: app, start: handedOff))))
check("bug: no evidence, no fixing", rejection(decision(req(.bug, from: "open", to: "fixing", actor: agent)))?.missing == [.startEvidence])
check("a failed handoff rolls the bug back to open for anyone", isAllowed(decision(req(.bug, from: "fixing", to: "open", actor: app))))
check("an idea cannot jump to implementing", isRejected(decision(req(from: "idea", to: "implementing", actor: app, start: handedOff))))

// MARK: Completion needs delivery evidence (REQ-002 criterion 2, DEC-007)

check("implementing → implemented on complete delivery",
      isAllowed(decision(req(from: "implementing", to: "implemented", actor: app, delivery: delivered))))
check("completion is a completion", basisKind(decision(req(from: "implementing", to: "implemented", actor: app, delivery: delivered))) == .completion)
check("incomplete delivery does not complete",
      rejection(decision(req(from: "implementing", to: "implemented", actor: app, delivery: notDelivered)))?.missing == [.deliveryEvidence])
check("unknown delivery does not complete",
      isRejected(decision(req(from: "implementing", to: "implemented", actor: app, delivery: .unknown(reasons: ["GitHub unreachable"])))))
check("an uncollected verdict does not complete", isRejected(decision(req(from: "implementing", to: "implemented", actor: app))))
check("an AI is held to the same delivery rule",
      isRejected(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: notDelivered))))
check("an AI completes when MarkView's evidence says complete",
      isAllowed(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: delivered))))
check("work done outside a handoff may complete from ready", isAllowed(decision(req(from: "ready", to: "implemented", actor: app, delivery: delivered))))
check("the rejection explains itself", (rejection(decision(req(from: "implementing", to: "implemented", actor: agent, delivery: notDelivered)))?.hints.joined().contains("PR #2 is not merged")) == true)
check("bug: fixing → fixed on delivery", isAllowed(decision(req(.bug, from: "fixing", to: "fixed", actor: app, delivery: delivered))))
check("bug: open → fixed on delivery of work done elsewhere", isAllowed(decision(req(.bug, from: "open", to: "fixed", actor: app, delivery: delivered))))
check("bug: fixed without delivery is refused", isRejected(decision(req(.bug, from: "fixing", to: "fixed", actor: agent, delivery: notDelivered))))
check("a feature cannot go from implementing to verified", isRejected(decision(req(from: "implementing", to: "verified", actor: person))))

// MARK: The override is the person's and needs a reason (Q-002, REQ-002 criterion 4)

let forced = decision(req(from: "implementing", to: "implemented", actor: person, reason: "Shipped by hand, CI is down", force: true,
                          delivery: notDelivered))
check("a person can force a completion with a reason", bypassed(forced) == [.deliveryEvidence])
check("a forced transition is not silently allowed", !isAllowed(forced))
check("force without a reason is refused",
      rejection(decision(req(from: "implementing", to: "implemented", actor: person, reason: "  ", force: true)))?.missing == [.reason])
check("force with no reason at all is refused", isRejected(decision(req(from: "implementing", to: "implemented", actor: person, force: true))))
check("an AI can never force", isRejected(decision(req(from: "implementing", to: "implemented", actor: agent, reason: "I said so", force: true))))
check("the system can never force", isRejected(decision(req(from: "implementing", to: "implemented", actor: app, reason: "auto", force: true))))
check("force that the rules allow anyway is not an override",
      isAllowed(decision(req(from: "implementing", to: "implemented", actor: person, reason: "ok", force: true, delivery: delivered))))
check("a person can force a jump outside the table",
      bypassed(decision(req(from: "idea", to: "verified", actor: person, reason: "Imported", force: true))) == [.listedTransition])
check("a forced jump is of the unlisted kind", basisKind(decision(req(from: "idea", to: "verified", actor: person, reason: "r", force: true))) == .unlisted)
check("a forced start bypasses the start evidence",
      bypassed(decision(req(from: "ready", to: "implementing", actor: person, reason: "I began by hand", force: true))) == [.startEvidence])
check("forced acceptance is a person's bypass of nothing when the person accepts",
      isAllowed(decision(req(from: "implemented", to: "verified", actor: person, reason: "checked", force: true))))
check("a refused request says how to continue", (rejection(decision(req(from: "ready", to: "implementing", actor: person)))?.hints.isEmpty) == false)

// MARK: Acceptance (DEC-008)

check("a person accepts an implemented feature", isAllowed(decision(req(from: "implemented", to: "verified", actor: person))))
check("acceptance is an acceptance", basisKind(decision(req(from: "implemented", to: "verified", actor: person))) == .acceptance)
check("an AI accepts with evidence and every criterion ticked",
      isAllowed(decision(req(from: "implemented", to: "verified", actor: agent,
                             acceptance: AcceptanceEvidence(text: "Ran the suites: 12 passed", criteriaAllTicked: true)))))
check("an AI without ticked criteria cannot accept",
      rejection(decision(req(from: "implemented", to: "verified", actor: agent,
                             acceptance: AcceptanceEvidence(text: "Looks fine", criteriaAllTicked: false))))?.missing == [.acceptanceEvidence])
check("an AI with empty evidence text cannot accept",
      isRejected(decision(req(from: "implemented", to: "verified", actor: agent, acceptance: AcceptanceEvidence(text: "  ", criteriaAllTicked: true)))))
check("an AI with no evidence cannot accept", isRejected(decision(req(from: "implemented", to: "verified", actor: agent))))
check("the system never accepts", isRejected(decision(req(from: "implemented", to: "verified", actor: app))))
check("bug: a person closes a fixed bug", isAllowed(decision(req(.bug, from: "fixed", to: "closed", actor: person))))
check("bug: an AI closes a fixed bug with evidence text only",
      isAllowed(decision(req(.bug, from: "fixed", to: "closed", actor: agent, acceptance: AcceptanceEvidence(text: "Reproduced no more", criteriaAllTicked: false)))))
check("bug: an AI cannot close a fixed bug without evidence", isRejected(decision(req(.bug, from: "fixed", to: "closed", actor: agent))))

// MARK: Regression reopens the original (Q-003, DEC-009)

check("a person reopens a verified feature with a reason", isAllowed(decision(req(from: "verified", to: "implementing", actor: person, reason: "Crash in 5.36"))))
check("reopening is a reopen", basisKind(decision(req(from: "verified", to: "implementing", actor: person, reason: "r"))) == .reopen)
check("a person must give a reason to reopen", rejection(decision(req(from: "implemented", to: "implementing", actor: person)))?.missing == [.reason])
check("an AI reopens only on a regression bug",
      isAllowed(decision(req(from: "implemented", to: "implementing", actor: agent, regression: .bug(id: "BUG-050")))))
check("an AI without the regression bug cannot reopen", rejection(decision(req(from: "implemented", to: "implementing", actor: agent)))?.missing == [.regressionEvidence])
check("the system reopens on a regression bug", isAllowed(decision(req(from: "verified", to: "implementing", actor: app, regression: .bug(id: "BUG-050")))))
check("a failing check alone is no regression evidence", isRejected(decision(req(from: "implemented", to: "implementing", actor: app, delivery: notDelivered))))
check("bug: fixed reopens to open on a regression", isAllowed(decision(req(.bug, from: "fixed", to: "open", actor: agent, regression: .bug(id: "BUG-051")))))
check("bug: closed reopens to open for a person with a reason", isAllowed(decision(req(.bug, from: "closed", to: "open", actor: person, reason: "Back again"))))
check("bug: an AI cannot reopen a closed bug without evidence", isRejected(decision(req(.bug, from: "closed", to: "open", actor: agent))))
check("a person can take an acceptance back", isAllowed(decision(req(from: "verified", to: "implemented", actor: person, reason: "Acceptance was premature"))))

// MARK: Cancellation is not completion (DEC-013)

check("archiving a feature is open to a person and an AI",
      isAllowed(decision(req(from: "draft", to: "archived", actor: person))) && isAllowed(decision(req(from: "draft", to: "archived", actor: agent))))
check("archived before completion is a cancellation", basisKind(decision(req(from: "draft", to: "archived", actor: person))) == .cancellation)
check("archived after completion keeps the completion", basisKind(decision(req(from: "verified", to: "archived", actor: person))) == .archive)
check("the system does not archive", isRejected(decision(req(from: "draft", to: "archived", actor: app))))
check("a person unarchives with a reason", isAllowed(decision(req(from: "archived", to: "draft", actor: person, reason: "Back on the roadmap"))))
check("bug: a duplicate closes with its original named",
      isAllowed(decision(req(.bug, from: "open", to: "closed", actor: agent, cancellation: .duplicate(of: "BUG-002")))))
check("bug: a close without a fix is a cancellation",
      basisKind(decision(req(.bug, from: "open", to: "closed", actor: agent, cancellation: .duplicate(of: "BUG-002")))) == .cancellation)
check("bug: already fixed on main closes the bug but is a cancellation, not a completion",
      isAllowed(decision(req(.bug, from: "open", to: "closed", actor: app, cancellation: .alreadyFixed("fixed by 1a2b3c4"))))
      && basisKind(decision(req(.bug, from: "open", to: "closed", actor: app, cancellation: .alreadyFixed("fixed by 1a2b3c4")))) == .cancellation)
check("bug: an AI cannot close an open bug without evidence", isRejected(decision(req(.bug, from: "open", to: "closed", actor: agent))))
check("bug: a person closes without a fix only with a reason", isRejected(decision(req(.bug, from: "open", to: "closed", actor: person))))
check("bug: a person closes without a fix with a reason", isAllowed(decision(req(.bug, from: "open", to: "closed", actor: person, reason: "Works as designed"))))

// MARK: Spec stages keep their freedom (existing flows)

check("spec stages move freely for the system", isAllowed(decision(req(from: "review", to: "resolving", actor: app))))
check("an AI sets the stages the tools always allowed it", isAllowed(decision(req(from: "exploring", to: "draft", actor: agent))))
check("an AI does not set resolving", isRejected(decision(req(from: "review", to: "resolving", actor: agent))))
check("a spec move is a spec step", basisKind(decision(req(from: "draft", to: "review", actor: person))) == .spec)
check("restart goes back to idea", isAllowed(decision(req(from: "ready", to: "idea", actor: app))))
check("a failed handoff rolls the feature back", isAllowed(decision(req(from: "implementing", to: "ready", actor: app))))
check("a person rolls implementing back with a reason", isAllowed(decision(req(from: "implementing", to: "ready", actor: person, reason: "Paused"))))

// MARK: Unknown state (REQ-005)

check("a hand-written status outside the vocabulary is unknown state for an AI",
      isRejected(decision(req(from: "in-progress", to: "implemented", actor: agent, delivery: delivered))))
check("and for the system", isRejected(decision(req(from: "done", to: "verified", actor: app))))
check("a person moves it with a reason", bypassed(decision(req(from: "done", to: "implemented", actor: person, reason: "Normalise", force: true))) == [.listedTransition])
check("an empty status is unknown too", isRejected(decision(req(from: "", to: "implementing", actor: app, start: handedOff))))

// MARK: Rejections change nothing and explain (REQ-001 criterion 3)

let refused = rejection(decision(req(from: "ready", to: "implemented", actor: agent)))
check("a rejection names what is missing", refused?.missing == [.deliveryEvidence])
check("a rejection has a message", refused?.message.isEmpty == false)

// MARK: Next steps for the AI context (REQ-003 criterion 2)

let steps = LifecyclePolicy.nextSteps(kind: .feature, status: "implementing", actor: .ai, evidence: LifecycleEvidence(delivery: notDelivered))
check("implementing offers completion and rollback", Set(steps.map(\.to)) == ["implemented", "ready", "archived"])
check("the completion step lists what is missing", steps.first { $0.to == "implemented" }?.unmet == [.deliveryEvidence])
check("a step the actor may not make has no needs", steps.first { $0.to == "ready" }?.needs == nil)
let bugSteps = LifecyclePolicy.nextSteps(kind: .bug, status: "fixing", actor: .ai, evidence: LifecycleEvidence(delivery: delivered))
check("a bug in fixing can be fixed when delivered", bugSteps.first { $0.to == "fixed" }?.unmet == [])

finish("policy")
