import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-001): turning a goal in words into a scenario. This file holds what needs no AI call: the
// schema of the answer, the prompt, and the reading and checking of what the AI wrote. The call itself is QAGenerator. Foundation only;
// checked on its own by tools/tests/qa-tests.sh.

struct QAGenerationRequest {
    var goal: String
    var clarifications: [QAClarification] = []
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
    /// The scenario the new one starts from ("Based on"): the goal then says what changes.
    var base: QAScenario? = nil
    /// Files the person attached, as chosen. The model turns them into `attachmentPaths` before the prompt is written.
    var attachments: [URL] = []
    /// The attached files as paths relative to the project folder, images included.
    var attachmentPaths: [String] = []
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
            "conditionManual": ["type": "boolean"],
            "faultUrlPattern": string(),
            "faultMethod": string(),
            "faultMode": choice(["", "fail", "delay", "status"]),
            "faultStatus": integer(),
            "faultMilliseconds": integer(),
        ])
        return object([
            "title": string(),
            "summary": string(),
            "baselineEstablish": string(),
            "baselineVerify": string(),
            "baselineManual": ["type": "boolean"],
            "actors": ["type": "array", "items": object(["id": string(), "name": string(), "app": string(), "createTestAccount": ["type": "boolean"]])],
            "start": string(),
            "nodes": ["type": "array", "items": node],
            "edges": ["type": "array", "items": object(["from": string(), "to": string(), "label": string()])],
        ])
    }

    static func schema(for kind: QAAppKind) -> [String: Any] {
        var result = schema
        if kind == .api,
           var properties = result["properties"] as? [String: Any],
           var nodes = properties["nodes"] as? [String: Any],
           var items = nodes["items"] as? [String: Any],
           var fields = items["properties"] as? [String: Any] {
            fields["api"] = ["type": "string"]
            items["properties"] = fields; nodes["items"] = items
            properties["nodes"] = nodes; result["properties"] = properties
        }
        return result
    }

    // MARK: Prompt

    static func systemPrompt(_ appKind: QAAppKind) -> String {
        let surface: String
        switch appKind {
        case .web:
            surface = """
            The application under test is a web application, driven in a browser like a person does: open pages, click, fill fields, read what is shown. \
            A network condition (a failed or slow request) can be injected into the page: use conditionKind networkFault or delay with faultUrlPattern, \
            a literal part of the request address (no placeholders), and a faultMode. Set faultMethod to GET, POST, PUT, PATCH, DELETE, HEAD or OPTIONS to affect only that HTTP method, or leave it empty for all methods. For a failed send, use POST so loading the same resource still works.
            """
        case .api: return apiSystemPrompt
        case .nativeMacOS:
            surface = """
            The application under test is a native macOS application, driven like a person does: menus, buttons, fields, windows. There are no web \
            addresses and no way to inject network faults, so a condition is conditionKind state or data, described in words.
            """
        }
        return """
        Include `summary`: 2–3 concise sentences in the goal’s language describing purpose, participants, flow and checks, grounded in the scenario rather than quoting the request.
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
        - condition (conditionKind, conditionEstablish, conditionVerify, conditionManual): only for an alternative or a failure that needs the \
        application to be brought into a particular situation. conditionEstablish says how, conditionVerify says how to confirm it holds before \
        the branch runs. Leave the condition fields empty (conditionKind "", other strings empty, numbers 0, conditionManual false) where there is none.
        - What does the work: the assistant that runs the checks has only the application's own pages, like a person with a browser. It can click, \
        fill forms, sign up, sign in and delete things the pages let it delete. It cannot restore a snapshot, run a script or an API call of its own, \
        reach a database or an operator tool, or change the environment. So a condition or a baseline is written for the pages only when the pages \
        can do it. When it needs anything else, set conditionManual / baselineManual to true and write the establish text as the instruction for \
        the person, who is asked to do it and say when it is done before each check. Do not write a manual baseline or condition for something the \
        scenario can avoid: prefer steps that work with whatever data exists, or that create their own data through the pages.
        - baselineEstablish / baselineVerify / baselineManual: the checks are run one after another and each starts from the same state. When the \
        steps change data and the pages can bring the application back (for example deleting the records the steps created), say how in \
        baselineEstablish and how to confirm it in baselineVerify. Leave both empty, and baselineManual false, when no reset is needed or when \
        a reset would need more than the pages. An actor with createTestAccount true starts with no account: the run creates it through the \
        application's own sign-up, so never describe an existing account, a seeded environment or supplied logins for that actor.
        - Cover the realistic variations of the goal: wrong or missing input, rights, errors, slow answers, what the other actor sees. A typical \
        scenario has 8 to 25 steps. Do not pad it.
        - Base the scenario on the real application. If you can read its files, look at its screens, routes, roles and messages and use them; \
        never invent a feature you cannot find. Say in `detail` when something is an assumption.
        - Write titles and details in the language of the goal. Ids and enumerated values stay in English.
        """
    }

    private static let apiSystemPrompt = #"""
    You are a senior backend QA engineer. Propose a branching HTTP/REST end-to-end scenario for the person's goal, grounded in the project's actual API.
    Read the attached OpenAPI/Swagger files, API documentation, routes, request validation, auth handlers and tests with your file tools first. Infer methods, paths, required headers, payloads, authentication and status/body expectations from that evidence. Never invent endpoints. If contracts are unavailable, explain what is needed in the step detail; leave api empty so validation flags it for correction. Do not execute requests or modify the backend during generation.
    Use the structured schema. Nodes: action, check, alternative, failure. Edges connect node ids; start is the first id. No cycles, all nodes reachable. Every path ends in a check. Include a main flow and meaningful negative/permission/input cases supported by the API. A request expecting 400/401/403/404 passes when that is the documented expected result.
    Define one actor per independent API client. Actors have id, name, app (one of the supplied application ids), createTestAccount=false. Authentication and account creation are EXPLICIT request steps, never implicit preparation. Credentials use {{username}} and {{password}} filled from the chosen saved login; never write secrets. Each actor/service has isolated cookies and captured variables, reset between branches. Keep a create/read/update/delete flow on the same actor/service; values are not shared across actors or services.
    Each executable node has `api`: a STRING containing a JSON object in exactly this format:
    {"method":"POST","path":"/items","headers":[{"name":"Content-Type","value":"application/json"}],"body":"{\"name\":\"QA item\"}","statuses":[201],"assertions":[{"pointer":"/name","equals":"\"QA item\""}],"captures":[{"name":"itemId","pointer":"/id","secret":false}],"timeoutSeconds":20}
    Paths are relative to the service base URL (a leading slash starts at the host root), or absolute on the same origin. Use {{itemId}} in later paths, headers and bodies. For a safely escaped JSON value use {{itemId.json}} without surrounding quotes; {{username.json}} and {{password.json}} work the same way in JSON login bodies. Capture a token with secret=true, then use a header Authorization: Bearer {{token}}. JSON paths are RFC 6901 pointers, including array indexes (/items/0/id). `equals` is a JSON literal encoded as a string. Include expected statuses on EVERY request and exact body assertions where meaningful. Captures require that the path exists. Timeouts are 1..120 seconds.
    A check may send a read-only GET/HEAD/OPTIONS request, or use path="" to assert the SAME actor/service's previous response without sending again. POST/PUT/PATCH/DELETE must be action nodes marked changesData=yes or unknown, never checks or read-only nodes. Alternative/failure marker nodes can have api=""; use a following check or action to execute the actual request. All action and check nodes need a valid api object. A marker with no request does no work. Put prose explaining intent and sources in detail, and a concise label in title.
    Prefer self-contained flows that create unique data and clean up after themselves. If an external reset is needed, baselineManual=true with baselineEstablish as instructions for the person; otherwise leave baselineEstablish and baselineVerify empty and baselineManual=false. Do not use networkFault/delay injection: failures must come from actual requests or a manually prepared service condition. Empty conditionKind, conditionEstablish, conditionVerify, faultUrlPattern, faultMode, faultMethod; conditionManual=false; faultStatus and faultMilliseconds=0 unless a manual state/data condition is essential.
    Include `summary`: 2–3 concise sentences describing purpose, clients/services and response checks in the goal's language. Do not quote the request.
    Write titles/details in the goal's language. Ids are plain ASCII letters, digits, hyphens, underscores (max 40). Return 8..25 useful steps when the goal warrants it, without padding. The person reviews and edits the proposed requests before approving a run. Never store passwords, API keys or tokens in request JSON: use saved-login placeholders and secret captures.
    """#

    static func prompt(_ request: QAGenerationRequest) -> String {
        var lines = [request.base == nil ? "Goal of the test:" : "What the new scenario must do, or what changes compared with the base scenario:",
                     request.goal.trimmingCharacters(in: .whitespacesAndNewlines), ""]
        if let base = request.base, let json = try? QAStore.encoder.encode(base), let text = String(data: json, encoding: .utf8) {
            lines += ["Base scenario (the person wants a similar one). Keep its structure, steps and wording wherever the goal does not change them,",
                      "and change what the goal asks for. Return a whole new scenario, not a patch:", text, ""]
        }
        if !request.attachmentPaths.isEmpty {
            lines.append("Material the person attached (read each file with your tools; images are screens or designs of the product):")
            lines += request.attachmentPaths.map { "- " + $0 }
            lines.append("")
        }
        if !request.clarifications.isEmpty {
            lines.append("The author answered these discovery questions. Respect these answers rather than guessing:")
            for item in request.clarifications { lines.append("Q: \(item.question)\nA: \(item.answer)") }
        }
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
            if scenario.summary != nil { scenario.summarySource = QASummary.source(scenario) }
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
        let summary = text(root["summary"])
        scenario.summary = summary.isEmpty ? nil : String(summary.prefix(1400))
        scenario.clarifications = request.clarifications.isEmpty ? nil : request.clarifications
        let baselineEstablish = text(root["baselineEstablish"]), baselineVerify = text(root["baselineVerify"])
        if !baselineEstablish.isEmpty || !baselineVerify.isEmpty {
            scenario.baseline = QACondition(kind: .state, establish: baselineEstablish, verify: baselineVerify, manual: root["baselineManual"] as? Bool == true ? true : nil)
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
                    var condition = QACondition(kind: kind, establish: text(item["conditionEstablish"]), verify: text(item["conditionVerify"]),
                                                manual: item["conditionManual"] as? Bool == true ? true : nil)
                    let pattern = text(item["faultUrlPattern"])
                    if !pattern.isEmpty {
                        let modeText = text(item["faultMode"])
                        if let mode = QAFault.Mode(rawValue: modeText) {
                            condition.fault = QAFault(urlPattern: pattern, mode: mode,
                                                      status: number(item["faultStatus"]) == 0 ? nil : number(item["faultStatus"]),
                                                      milliseconds: number(item["faultMilliseconds"]) == 0 ? nil : number(item["faultMilliseconds"]),
                                                      method: text(item["faultMethod"]).isEmpty ? nil : text(item["faultMethod"]).uppercased())
                        } else {
                            parseProblems.append("Step \(id): faultMode must be fail, delay or status.")
                        }
                    }
                    node.condition = condition
                } else {
                    parseProblems.append("Step \(id): unknown conditionKind \"\(conditionKind)\".")
                }
            }
            if request.appKind == .api {
                let source = text(item["api"])
                if !source.isEmpty {
                    do { node.api = try JSONDecoder().decode(QAAPIRequest.self, from: Data(source.utf8)) }
                    catch { parseProblems.append("Step \(id): api must contain a complete QAAPIRequest JSON object.") }
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


/// Pure prompt/parse layer for discussion before generation.
enum QADiscovery {
    struct Question: Identifiable, Equatable {
        var id: String
        var question: String
        var why: String
        var options: [String]
    }
    struct Round: Equatable {
        var understanding: String
        var overlooked: [String]
        var questions: [Question]
    }
    enum Failure: LocalizedError {
        case invalidAnswer
        var errorDescription: String? { "The assistant returned an unusable answer. Try again; your input is kept." }
    }
    static let system = """
    You are a senior QA engineer discussing a new end-to-end scenario with its author BEFORE writing steps.
    Read relevant project documentation and attached materials. Ask 3–5 focused questions about unresolved choices only:
    objective/scope, applications and independent actors, starting state/test data, observable success, important negative cases.
    Do not ask for credentials. Do not repeat settled facts or answered questions. Offer 2–4 useful answer suggestions where appropriate;
    the author can write another answer. Explain why each question matters. Do not decide for the author.
    Identify up to four possibly overlooked cases as suggestions, not established requirements. Use the goal's language.
    Return no questions only if every important choice is settled. Do not execute or create a scenario yet.
    """
    static var schema: [String: Any] {
        ["type": "object", "properties": [
            "understanding": ["type": "string"], "overlooked": ["type": "array", "items": ["type": "string"]],
            "questions": ["type": "array", "items": ["type": "object", "properties": [
                "question": ["type": "string"], "why": ["type": "string"], "options": ["type": "array", "items": ["type": "string"]]
            ]]]
        ]]
    }
    static func prompt(_ request: QAGenerationRequest) -> String {
        "Discuss this proposal without generating steps.\n\n" + QAGeneration.prompt(request).replacingOccurrences(of: "Return the scenario as the structured answer.", with: "Return your understanding, suggested overlooked cases and clarification questions.")
    }
    static func parse(_ value: Any?) throws -> Round {
        guard let object = value as? [String: Any], let text = object["understanding"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let items = object["questions"] as? [[String: Any]], items.count <= 5 else { throw Failure.invalidAnswer }
        let prefix = UUID().uuidString
        var questions: [Question] = []
        for (index, item) in items.enumerated() {
            guard let question = item["question"] as? String, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidAnswer }
            questions.append(Question(id: "\(prefix)-\(index)", question: String(question.prefix(1000)), why: String((item["why"] as? String ?? "").prefix(600)),
                                      options: Array((item["options"] as? [String] ?? []).prefix(4)).map { String($0.prefix(500)) }))
        }
        return Round(understanding: String(text.prefix(1600)), overlooked: Array((object["overlooked"] as? [String] ?? []).prefix(4)).map { String($0.prefix(700)) }, questions: questions)
    }
}

/// The fingerprint ignores UI selection, save dates and the summary itself.
enum QASummary {
    static func source(_ scenario: QAScenario) -> String {
        var value = scenario
        value.summary = nil; value.summarySource = nil; value.selected = []
        value.created = .distantPast; value.updated = .distantPast
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(value)) ?? Data()
        var hash: UInt64 = 14695981039346656037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
    static func current(_ scenario: QAScenario) -> String? {
        guard scenario.summarySource == source(scenario), let summary = scenario.summary, !summary.isEmpty else { return nil }
        return summary
    }
    static let schema: [String: Any] = ["type": "object", "properties": ["summary": ["type": "string"]]]
    static func prompt(_ scenario: QAScenario) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var input = scenario
        input.summary = nil; input.summarySource = nil
        let text = (try? encoder.encode(input)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return """
        Summarize this QA scenario in 2–3 concise sentences, in \(QALanguage.name(of: scenario) ?? "the scenario's language").
        Explain purpose, participants, main flow and important outcome/failure checks. Ground claims in the scenario;
        do not copy the original request, invent coverage or repeat credentials. This appears under the scenario title.
        Scenario JSON:
        \(text)
        """
    }
    static func parse(_ value: Any?) throws -> String {
        guard let object = value as? [String: Any], let raw = object["summary"] as? String else { throw QADiscovery.Failure.invalidAnswer }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1400 else { throw QADiscovery.Failure.invalidAnswer }
        return text
    }
}
