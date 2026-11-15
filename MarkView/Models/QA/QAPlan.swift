import Foundation
import CryptoKit

// End-to-End QA (feature end-to-end-qa, REQ-002, REQ-003, DEC-002, DEC-011): what a run of the selected branches against one target
// would do before and during the check, so the person can approve exactly that. The plan is derived from the scenario, never
// stored; its fingerprint ties an approval to the plan it was given for. Foundation (and CryptoKit for the fingerprint) only;
// checked on its own by tools/tests/qa-tests.sh.

/// One thing the run does to the environment before the checks: the sign-ins, the accounts it creates, the baseline and the conditions.
struct QAPreparationStep: Equatable, Identifiable {
    enum Kind: String {
        case login
        case createAccount
        case baseline
        case condition
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String = ""
    var actor: String? = nil
    var app: String? = nil
    var branch: String? = nil
    var node: String? = nil
    var changesData: QADataChange
    /// True when the run brings the condition about itself (a network fault or a delay is injected into the page); false when it is
    /// brought about by following the written instructions.
    var automated: Bool = false
    /// True when a person brings it about before the check and confirms it; the run does not try (`QACondition.manual`).
    var manual: Bool = false
}

/// Something that stops the plan from being approved, or only deserves a look.
struct QAPlanProblem: Equatable {
    enum Kind: String {
        case noTarget
        case unknownTarget
        case scenarioUnsound
        case targetIncomplete
        case noBranch
        case loginNotSaved
        case loginHostMismatch
        case actorWithoutAccess
        case noBaseline
    }
    var kind: Kind
    var subject: String
    var message: String
    var blocks: Bool
}

/// A step that needs a yes of its own: it changes data on production, or a person has to do it first.
struct QAConfirmation: Equatable, Identifiable {
    var id: String
    var title: String
    var reason: String
    /// The person does this themselves and says when it is done; the run then goes on without doing it.
    var manual: Bool = false
}

struct QAExecutionPlan: Equatable {
    var scenarioID: String
    var target: QATarget?
    var branches: [QABranch]
    var preparation: [QAPreparationStep]
    var problems: [QAPlanProblem]
    var confirmations: [QAConfirmation]
    /// Hash of everything that decides what the run does; any change to it makes an earlier approval void.
    var fingerprint: String

    var isProduction: Bool { target?.kind == .production }
    var blockingProblems: [QAPlanProblem] { problems.filter(\.blocks) }
    var canBeApproved: Bool { target != nil && !branches.isEmpty && blockingProblems.isEmpty }
}

enum QAPlanner {
    /// `savedLogins` are the logins the browser's store holds (host and user name, never passwords).
    static func make(_ scenario: QAScenario, targetID: String?, savedLogins: Set<QALoginReference>) -> QAExecutionPlan {
        var problems: [QAPlanProblem] = []
        func problem(_ kind: QAPlanProblem.Kind, _ subject: String, _ message: String, blocks: Bool = true) {
            problems.append(QAPlanProblem(kind: kind, subject: subject, message: message, blocks: blocks))
        }

        // The target.
        var target: QATarget?
        if scenario.targets.isEmpty {
            problem(.noTarget, scenario.id, "The scenario has no environment yet: add local, development or production.")
        } else if let targetID, let found = scenario.target(targetID) {
            target = found
        } else if targetID != nil {
            problem(.unknownTarget, targetID ?? "", "The chosen environment is not in the scenario.")
        } else {
            problem(.noTarget, scenario.id, "Choose the environment to check.")
        }

        // The scenario itself, without the problems of environments that were not chosen.
        for item in scenario.problems() {
            switch item.kind {
            case .noTarget: continue
            case .incompleteTarget:
                if item.subject == target?.id { problem(.targetIncomplete, item.subject, item.message) }
            default:
                problem(.scenarioUnsound, item.subject, item.message)
            }
        }

        // The branches.
        let selection = scenario.selectedBranches()
        let branches = selection.found
        if branches.isEmpty { problem(.noBranch, scenario.id, "Choose at least one branch to check.") }

        // The players the branches use.
        var preparation: [QAPreparationStep] = []
        var involved: [String] = []
        for branch in branches { for actor in scenario.actors(in: branch) where !involved.contains(actor) { involved.append(actor) } }
        if scenario.appKind == .nativeMacOS, let target {
            var attachedPlayers: [String: Int] = [:]
            for id in involved {
                guard let actor = scenario.actors.first(where: { $0.id == id }),
                      let app = actor.app ?? (scenario.apps.count == 1 ? scenario.apps[0].id : nil),
                      let application = target.locations[app]?.application,
                      application.effectiveStartupPolicy == .attach else { continue }
                attachedPlayers[application.bundleIdentifier, default: 0] += 1
            }
            for (identifier, count) in attachedPlayers where count > 1 {
                problem(.scenarioUnsound, identifier, "Multiple players cannot share an attached application: \(identifier).")
            }
        }
        for id in involved {
            guard let actor = scenario.actors.first(where: { $0.id == id }) else { continue }
            let app = actor.app ?? (scenario.apps.count == 1 ? scenario.apps[0].id : nil)
            let attaching = scenario.appKind == .nativeMacOS && app.flatMap { target?.locations[$0]?.application?.effectiveStartupPolicy } == .attach
            if attaching {
                problem(.actorWithoutAccess, actor.id, "\(actor.name) uses the current application session. No automatic sign-in or account creation will run.", blocks: false)
                continue
            }
            if let login = actor.login {
                if !savedLogins.contains(login) {
                    problem(.loginNotSaved, actor.id, "\(actor.name): the login \(login.username) for \(login.host) is not saved in the browser's passwords.")
                }
                if scenario.appKind != .nativeMacOS, let target, let app, let host = hostOf(target.locations[app]?.url),
                   normalized(login.host) != host {
                    problem(.loginHostMismatch, actor.id, "\(actor.name): the saved login is for \(login.host), but \(target.name) runs on \(host).")
                }
                // API authentication is an explicit saved request; choosing credentials must not send an implicit login request.
                if scenario.appKind != .api {
                    preparation.append(QAPreparationStep(id: "login:\(actor.id)", kind: .login, title: "\(actor.name) signs in as \(login.username)",
                                                         detail: login.host, actor: actor.id, app: app, changesData: .no))
                }
            } else if actor.createTestAccount {
                preparation.append(QAPreparationStep(id: "account:\(actor.id)", kind: .createAccount, title: "Create a test account for \(actor.name)",
                                                     detail: "An account that exists only for this test, created through the application's own sign-up.",
                                                     actor: actor.id, app: app, changesData: .yes))
            } else {
                problem(.actorWithoutAccess, actor.id, "\(actor.name) has no saved login and no test account: they act without signing in.", blocks: false)
            }
        }

        // The baseline and the condition of each branch.
        let changesData = branches.contains { branch in branch.nodes.contains { id in scenario.node(id).map { $0.kind != .check && $0.changesData != .no } ?? false } }
        if let baseline = scenario.baseline {
            for branch in branches {
                preparation.append(QAPreparationStep(id: "baseline:\(branch.id)", kind: .baseline,
                                                     title: baseline.isManual ? "You bring the application to its baseline" : "Bring the application to its baseline",
                                                     detail: baseline.establish, branch: branch.id, changesData: .yes, manual: baseline.isManual))
            }
        } else if branches.count > 1 && changesData {
            problem(.noBaseline, scenario.id, "The checks change data and the scenario does not say how to restore the baseline between them: a check starts from what the one before left.", blocks: false)
        }
        for branch in branches {
            for (node, condition) in scenario.conditions(of: branch) {
                let automated = condition.kind == .networkFault || condition.kind == .delay
                preparation.append(QAPreparationStep(id: "condition:\(branch.id):\(node)", kind: .condition, title: scenario.node(node)?.title ?? node,
                                                     detail: condition.establish, branch: branch.id, node: node, changesData: condition.changesData, automated: automated,
                                                     manual: condition.isManual))
            }
        }

        // What needs a yes of its own on production.
        var confirmations: [QAConfirmation] = []
        // What a person has to do first is confirmed on every target: the run cannot do it and must not pretend it did.
        for step in preparation where step.manual {
            confirmations.append(QAConfirmation(id: step.id, title: "\(step.title): \(step.detail)", reason: "MarkView cannot do this through the application's pages. Do it yourself, then say it is done.",
                                                manual: true))
        }
        if target?.kind == .production {
            for step in preparation where step.changesData != .no && !step.manual {
                confirmations.append(QAConfirmation(id: step.id, title: step.title,
                                                    reason: step.changesData == .yes ? "It changes data on production." : "It may change data on production."))
            }
            var seen = Set<String>()
            for branch in branches {
                for id in branch.nodes where seen.insert(id).inserted {
                    if let node = scenario.node(id), needsConfirmation(node) {
                        confirmations.append(QAConfirmation(id: "node:\(id)", title: node.title,
                                                            reason: node.changesData == .yes ? "It changes data on production." : "It may change data on production."))
                    }
                }
            }
        }

        return QAExecutionPlan(scenarioID: scenario.id, target: target, branches: branches, preparation: preparation, problems: problems, confirmations: confirmations,
                               fingerprint: fingerprint(scenario, target: target, branches: branches))
    }

    /// An action that does something and is not known to leave data alone. A check only looks.
    static func needsConfirmation(_ node: QANode) -> Bool { node.kind != .check && node.changesData != .no }

    // MARK: Fingerprint

    /// A hash of what decides what a run does: the steps, players, applications, the chosen environment, the baseline and the chosen
    /// branches. Titles, goals, review requirements, other environments and dates are left out: changing them changes nothing the run does.
    static func fingerprint(_ scenario: QAScenario, target: QATarget?, branches: [QABranch]) -> String {
        struct Executable: Encodable {
            var id: String
            var appKind: QAAppKind
            var apps: [String]
            var actors: [QAActor]
            var nodes: [QANode]
            var edges: [QAEdge]
            var start: String?
            var baseline: QACondition?
            var target: QATarget?
            var branches: [String]
        }
        var nodes = scenario.nodes
        for index in nodes.indices { nodes[index].title = "" }   // a title is a label
        let value = Executable(id: scenario.id, appKind: scenario.appKind, apps: scenario.apps.map(\.id).sorted(), actors: scenario.actors.map { actor in
            var actor = actor; actor.name = ""; return actor
        }, nodes: nodes, edges: scenario.edges, start: scenario.start, baseline: scenario.baseline, target: target, branches: branches.map(\.id).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Hosts

    /// The same rule as the browser's passwords: lower case, without a leading `www.`.
    static func normalized(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    static func hostOf(_ address: String?) -> String? {
        guard let address, let host = URL(string: address)?.host, !host.isEmpty else { return nil }
        return normalized(host)
    }
}
