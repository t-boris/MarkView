import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): turning a goal in words into a scenario. This file holds what needs no AI call: the
// schema of the answer, the prompt, and the reading and checking of what the AI wrote. The call itself is QAGenerator. Foundation only;
// checked on its own by tools/tests/qa-tests.sh.

struct QAGenerationRequest {
    var goal: String
    var appKind: QAAppKind
    /// The applications the person named (DEC-018); none means one default application. The AI never writes applications.
    var apps: [QAApp] = []
    /// The environments the person already defined; the AI never writes targets or logins.
    var targets: [QATarget] = []
    /// Users the person already named, in their words ("buyer", "seller").
    var actorNames: [String] = []
    /// Ids of the scenarios that already exist, so the new one gets its own.
    var existingIDs: Set<String> = []
    var now: Date = Date()
}

struct QAGenerationResult {
    var scenario: QAScenario
    /// What was wrong with the shape of the answer.
    var parseProblems: [String]
    /// What stops the scenario the AI wrote from running (a missing target is not the AI's to fix and is left out).
    var problems: [QAProblem]

    var isClean: Bool { parseProblems.isEmpty && problems.isEmpty }
    var messages: [String] { parseProblems + problems.map(\.message) }
}

enum QAGeneration {
    static let maxNodes = 80
    static let maxEdges = 200
    static let maxActors = 10
    static let maxApps = 6

    // MARK: Schema

    /// The answer's JSON Schema. Strict: every property is required, so an absent value is an empty string (or 0), as in UI Studio.
    static var schema: [String: Any] {
        func string() -> [String: Any] { ["type": "string"] }
        func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
        func integer() -> [String: Any] { ["type": "integer"] }
        func object(_ properties: [String: Any]) -> [String: Any] { ["type": "object", "properties": properties] }
        let node = object([
            "id": string(),
            "kind": choice(QANodeKind.allCases.map(\.rawValue)),
            "title": string(),
            "detail": string(),
            "actor": string(),
            "app": string(),
            "changesData": choice(["yes", "no", "unknown"]),
            "conditionKind": choice([""] + QAConditionKind.allCases.map(\.rawValue)),
            "conditionEstablish": string(),
            "conditionVerify": string(),
            "faultUrlPattern": string(),
            "faultMode": choice(["", "fail", "delay", "status"]),
            "faultStatus": integer(),
            "faultMilliseconds": integer(),
        ])
        return object([
            "title": string(),
            "baselineEstablish": string(),
            "baselineVerify": string(),
            "actors": ["type": "array", "items": object(["id": string(), "name": string(), "app": string(), "createTestAccount": ["type": "boolean"]])],
            "start": string(),
            "nodes": ["type": "array", "items": node],
            "edges": ["type": "array", "items": object(["from": string(), "to": string(), "label": string()])],
        ])
    }

    // MARK: Prompt

    static func systemPrompt(_ appKind: QAAppKind) -> String {
        let surface: String
        switch appKind {
        case .web:
            surface = """
            The application under test is a web application, driven in a browser like a person does: open pages, click, fill fields, read what is shown. \
            A network condition (a failed or slow request) can be injected into the page: use conditionKind networkFault or delay with faultUrlPattern, \
            a part of the request address, and a faultMode.
            """
        case .nativeMacOS:
            surface = """
            The application under test is a native macOS application, driven like a person does: menus, buttons, fields, windows. There are no web \
            addresses and no way to inject network faults, so a condition is conditionKind state or data, described in words.
            """
        }
        return """
        You are a senior QA engineer. You turn a testing goal into a branching end-to-end test scenario that a person can read, edit and run.
        \(surface)

        The scenario is a graph of steps (nodes) joined by edges. Rules:
        - Node kinds: action (an actor does something), check (what must hold now; detail states a verifiable expectation), alternative (a fork: \
        a different choice or input than the main line), failure (an error or odd situation that can happen: a decline, a timeout, missing rights).
        - Write the main line first, from the start step to its last check. Then add the alternatives and failures where they branch off, each \
        followed by the check that states the expected result. Every branch ends in a check.
        - No loops: an edge never leads back to a step already on its line. A step may have several outgoing edges (the branches). \
        Use `label` on an edge to say why the line forks.
        - Ids are short and plain: letters, digits, - and _ (for example n1, n2, a1, f1, c1). Every id is unique. `start` is the first step.
        - actor: the id of the actor who does an action or sees a check. Define one actor per independent user or session. Do not invent \
        passwords or any credentials: the person supplies logins. Set createTestAccount to true only for an actor who has to be created for the test.
        - app: the product can have several applications, listed in the request by id. Set each actor's `app` to the application that player uses. \
        Set a step's `app` only when it happens in another application than its actor's (a player who works in two), otherwise leave it empty. \
        Cover the flows between the applications: what one player does in one application and what another player sees in another.
        - changesData: yes when the step creates, changes or deletes data in the application (submitting a form, paying, approving), no when it only \
        reads or navigates, unknown when you cannot tell.
        - condition (conditionKind, conditionEstablish, conditionVerify): only for an alternative or a failure that needs the application to be \
        brought into a particular situation. conditionEstablish says how, conditionVerify says how to confirm it holds before the branch runs. \
        Leave the condition fields empty (conditionKind "", other strings empty, numbers 0) where there is none.
        - baselineEstablish / baselineVerify: the checks are run one after another and each starts from the same state. When the steps change \
        data, say how the application is brought back to that state (for example a reset call, a seed script, deleting the records the steps \
        created) in baselineEstablish, and how to confirm it in baselineVerify. Leave both empty when no reset is needed.
        - Cover the realistic variations of the goal: wrong or missing input, rights, errors, slow answers, what the other actor sees. A typical \
        scenario has 8 to 25 steps. Do not pad it.
        - Base the scenario on the real application. If you can read its files, look at its screens, routes, roles and messages and use them; \
        never invent a feature you cannot find. Say in `detail` when something is an assumption.
        - Write titles and details in the language of the goal. Ids and enumerated values stay in English.
        """
    }

    static func prompt(_ request: QAGenerationRequest) -> String {
        var lines = ["Goal of the test:", request.goal.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if request.apps.count > 0 {
            lines.append("Applications of the product (id, name, what it is judged as):")
            for app in request.apps { lines.append("- \(app.id): \(app.name) [\(app.profile.title.lowercased())]") }
            lines.append("")
        }
        if !request.targets.isEmpty {
            lines.append("Environments the person defined, with where each application runs:")
            for target in request.targets {
                let places = request.apps.isEmpty ? Array(target.locations.keys.sorted()) : request.apps.map(\.id)
                let where_ = places.compactMap { id -> String? in
                    guard let location = target.locations[id] else { return nil }
                    let place = location.url ?? location.application.map { "\($0.name) (\($0.bundleIdentifier))" } ?? "unspecified"
                    return request.apps.count > 1 ? "\(id) at \(place)" : place
                }.joined(separator: "; ")
                lines.append("- \(target.name) [\(target.kind.rawValue)]: \(where_.isEmpty ? "unspecified" : where_)")
            }
            lines.append("")
        }
        if !request.actorNames.isEmpty { lines += ["Users the person named: " + request.actorNames.joined(separator: ", "), ""] }
        lines.append("Return the scenario as the structured answer.")
        return lines.joined(separator: "\n")
    }

    /// The prompt for one more try: the same request, the answer that was given and what was wrong with it.
    static func retryPrompt(base: String, previous: String, result: QAGenerationResult) -> String {
        base + "\n\nYour previous answer:\n" + previous + "\n\nProblems found in it:\n"
            + result.messages.map { "- " + $0 }.joined(separator: "\n") + "\n\nReturn the whole scenario again with these corrected."
    }

    // MARK: Reading the answer

    static func parse(_ structured: Any?, request: QAGenerationRequest) -> QAGenerationResult {
        var parseProblems: [String] = []
        let apps = request.apps.isEmpty ? [QAApp(id: "app", name: "Application")] : request.apps
        var scenario = QAScenario(id: "", title: "", goal: request.goal, appKind: request.appKind, apps: apps, targets: request.targets, created: request.now, updated: request.now)
        func finish() -> QAGenerationResult {
            if scenario.title.isEmpty {
                scenario.title = String(request.goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
                parseProblems.append("The scenario has no title.")
            }
            scenario.id = QAStore.newScenarioID(title: scenario.title, existing: request.existingIDs)
            let fixable = scenario.problems().filter { $0.kind != .noTarget && $0.kind != .incompleteTarget }
            return QAGenerationResult(scenario: scenario, parseProblems: parseProblems, problems: fixable)
        }
        guard let root = structured as? [String: Any] else {
            parseProblems.append("The answer is not a scenario object.")
            return finish()
        }
        func text(_ value: Any?) -> String { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func number(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

        scenario.title = text(root["title"])
        let baselineEstablish = text(root["baselineEstablish"]), baselineVerify = text(root["baselineVerify"])
        if !baselineEstablish.isEmpty || !baselineVerify.isEmpty {
            scenario.baseline = QACondition(kind: .state, establish: baselineEstablish, verify: baselineVerify)
        }
        let start = text(root["start"])
        scenario.start = start.isEmpty ? nil : start

        let actorItems = (root["actors"] as? [Any]) ?? []
        if actorItems.count > maxActors { parseProblems.append("There are \(actorItems.count) actors; at most \(maxActors) are allowed.") }
        for (index, item) in actorItems.prefix(maxActors).enumerated() {
            guard let item = item as? [String: Any] else { parseProblems.append("Actor \(index + 1) is not an object."); continue }
            let id = text(item["id"])
            if !QAScenario.isValidID(id) { parseProblems.append("Actor \(index + 1) has the id \"\(id)\"; an id uses letters, digits, - and _.") }
            scenario.actors.append(QAActor(id: id, name: text(item["name"]).isEmpty ? id : text(item["name"]), app: text(item["app"]).isEmpty ? nil : text(item["app"]),
                                           createTestAccount: item["createTestAccount"] as? Bool == true))
        }

        let nodeItems = (root["nodes"] as? [Any]) ?? []
        if nodeItems.count > maxNodes { parseProblems.append("There are \(nodeItems.count) steps; at most \(maxNodes) are allowed.") }
        for (index, item) in nodeItems.prefix(maxNodes).enumerated() {
            guard let item = item as? [String: Any] else { parseProblems.append("Step \(index + 1) is not an object."); continue }
            let id = text(item["id"])
            guard let kind = QANodeKind(rawValue: text(item["kind"])) else {
                parseProblems.append("Step \(id): unknown kind \"\(text(item["kind"]))\" (action, check, alternative or failure).")
                continue
            }
            guard let changes = QADataChange(rawValue: text(item["changesData"])) else {
                parseProblems.append("Step \(id): changesData must be yes, no or unknown.")
                continue
            }
            var node = QANode(id: id, kind: kind, title: text(item["title"]), detail: text(item["detail"]),
                              actor: text(item["actor"]).isEmpty ? nil : text(item["actor"]), app: text(item["app"]).isEmpty ? nil : text(item["app"]), changesData: changes)
            let conditionKind = text(item["conditionKind"])
            if !conditionKind.isEmpty {
                if let kind = QAConditionKind(rawValue: conditionKind) {
                    var condition = QACondition(kind: kind, establish: text(item["conditionEstablish"]), verify: text(item["conditionVerify"]))
                    let pattern = text(item["faultUrlPattern"])
                    if !pattern.isEmpty {
                        let modeText = text(item["faultMode"])
                        if let mode = QAFault.Mode(rawValue: modeText) {
                            condition.fault = QAFault(urlPattern: pattern, mode: mode,
                                                      status: number(item["faultStatus"]) == 0 ? nil : number(item["faultStatus"]),
                                                      milliseconds: number(item["faultMilliseconds"]) == 0 ? nil : number(item["faultMilliseconds"]))
                        } else {
                            parseProblems.append("Step \(id): faultMode must be fail, delay or status.")
                        }
                    }
                    node.condition = condition
                } else {
                    parseProblems.append("Step \(id): unknown conditionKind \"\(conditionKind)\".")
                }
            }
            scenario.nodes.append(node)
        }

        let edgeItems = (root["edges"] as? [Any]) ?? []
        if edgeItems.count > maxEdges { parseProblems.append("There are \(edgeItems.count) connections; at most \(maxEdges) are allowed.") }
        for (index, item) in edgeItems.prefix(maxEdges).enumerated() {
            guard let item = item as? [String: Any] else { parseProblems.append("Connection \(index + 1) is not an object."); continue }
            let label = text(item["label"])
            scenario.edges.append(QAEdge(from: text(item["from"]), to: text(item["to"]), label: label.isEmpty ? nil : label))
        }
        return finish()
    }
}
