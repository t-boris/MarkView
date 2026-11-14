import Foundation

/// DEC-015: the simulator answers in the application's own transport envelope, and an IPC call names its record in the body.
func envelopeChecks() {
    let ipc = "http://electron.ipc/ppd/invoke/"
    let app = "http://localhost:5173"
    var counter = 0
    func call(_ method: String, _ url: String, body: String? = nil) -> StudioHTTPRequest {
        counter += 1
        return StudioHTTPRequest(method: method, url: URL(string: url)!, headers: [:], body: body, requestId: "envelope-\(counter)")
    }
    func answer(_ outcome: StudioSimOutcome) -> (status: Int, body: StudioJSON?) {
        guard case .respond(let response, _) = outcome else { return (-1, nil) }
        return (response.status, response.body.flatMap { StudioJSON(text: $0) })
    }
    func product(_ id: Int, _ name: String) -> StudioJSON { .object(["id": .number(Double(id)), "name": .string(name)]) }

    var spec = StudioEnvironmentSpec()
    spec.entities = [
        StudioEntity(name: "products", fields: [StudioField(name: "name", type: "string", required: true)]),
        StudioEntity(name: "agentQuestions", idField: "accountId", fields: [StudioField(name: "text", type: "string")]),
    ]
    spec.seed = [
        "products": [product(1, "Atlas"), product(2, "Beacon")],
        "agentQuestions": [.object(["accountId": .string("a1"), "text": .string("Solve the CAPTCHA")]),
                           .object(["accountId": .string("a2"), "text": .string("Confirm the email")])],
    ]
    spec.rules = [
        StudioRule(id: "products-list", method: "POST", path: ipc + "products.list", operation: .list, entity: "products", envelope: "result"),
        StudioRule(id: "products-get", method: "POST", path: ipc + "products.get", operation: .get, entity: "products", idParam: "id"),
        StudioRule(id: "products-create", method: "POST", path: ipc + "products.create", operation: .create, entity: "products"),
        StudioRule(id: "questions-list", method: "POST", path: ipc + "agent.questions", operation: .list, entity: "agentQuestions"),
        StudioRule(id: "agent-answer", method: "POST", path: ipc + "agent.answer", operation: .delete, entity: "agentQuestions", idParam: "accountId"),
        StudioRule(id: "engines", method: "POST", path: ipc + "engines.list", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .array([.string("claude")])]))),
        StudioRule(id: "web-list", method: "GET", path: "/api/items", operation: .list, entity: "products"),
        StudioRule(id: "plain-list", method: "GET", path: "/other/items", operation: .list, entity: "products"),
    ]
    let ipcEnvelope = StudioEnvelope(prefix: ipc, resultKey: "result", successFields: ["ok": .bool(true)],
                                     failure: .object(["ok": .bool(false), "error": .object(["code": .string("E{{status}}"), "message": .string("{{message}}")])]))
    var enveloped = spec
    enveloped.envelopes = [ipcEnvelope,
                           StudioEnvelope(prefix: "/api/", resultKey: "data", successFields: ["success": .bool(true)])]
    func simulator(_ spec: StudioEnvironmentSpec, overrides: [StudioOverride] = []) -> StudioSimulator {
        var scenario = StudioScenario(id: "populated", name: "Populated", kind: .populated)
        scenario.overrides = overrides
        return StudioSimulator(spec: spec, scenario: scenario, appOrigin: app)
    }

    // The case of a real project: a list rule that says `envelope: "result"` answered {result: [...]} without `ok`.
    var plain = simulator(spec)
    let before = answer(plain.handle(call("POST", ipc + "products.list", body: "null")))
    check("DEC-015 without an envelope the list is wrapped only in its own key, with no ok", before.body?["ok"] == nil && before.body?["result"]?.arrayValue?.count == 2)

    var sim = simulator(enveloped)
    let list = answer(sim.handle(call("POST", ipc + "products.list", body: "null")))
    check("DEC-015 a list whose rule already holds it under the result key gains the fields, not a second wrapper",
          list.status == 200 && list.body?["ok"] == .bool(true) && list.body?["result"]?.arrayValue?.count == 2, "\(list)")
    let questions = answer(sim.handle(call("POST", ipc + "agent.questions")))
    check("DEC-015 a list with no key of its own goes under the result key", questions.body?["ok"] == .bool(true) && questions.body?["result"]?.arrayValue?.count == 2, "\(questions)")

    // An IPC call names its record in the body.
    let get = answer(sim.handle(call("POST", ipc + "products.get", body: #"{"id": 2}"#)))
    check("DEC-015 a get names its record in the body", get.body?["ok"] == .bool(true) && get.body?["result"]?["name"] == .string("Beacon"), "\(get)")
    let missing = answer(sim.handle(call("POST", ipc + "products.get", body: #"{"id": 9}"#)))
    check("DEC-015 a failure uses the failure template with the status and the message",
          missing.status == 404 && missing.body?["ok"] == .bool(false) && missing.body?["error"]?["code"] == .string("E404")
            && missing.body?["error"]?["message"]?.stringValue?.contains("was not found") == true, "\(missing)")
    let created = answer(sim.handle(call("POST", ipc + "products.create", body: #"{"name": "Comet"}"#)))
    check("DEC-015 a create is wrapped", created.status == 201 && created.body?["ok"] == .bool(true) && created.body?["result"]?["name"] == .string("Comet"), "\(created)")

    // A write that resolves what another request lists: the answer removes the question and the list shows it.
    let dismissed = answer(sim.handle(call("POST", ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 a delete has no body, so it answers ok with a null result and status 200",
          dismissed.status == 200 && dismissed.body?["ok"] == .bool(true) && dismissed.body?["result"]?.isNull == true, "\(dismissed)")
    let after = answer(sim.handle(call("POST", ipc + "agent.questions")))
    check("DEC-015 the answered question is gone from the list and the other stays",
          after.body?["result"]?.arrayValue?.count == 1 && after.body?["result"]?.arrayValue?.first?["accountId"] == .string("a2"), "\(after)")
    let again = answer(sim.handle(call("POST", ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 answering a question that is gone fails in the application's shape", again.body?["ok"] == .bool(false), "\(again)")

    // What is written as the application sees it stays as it is.
    let engines = answer(sim.handle(call("POST", ipc + "engines.list")))
    check("DEC-015 a fixed answer is never wrapped again", engines.body?["ok"] == .bool(true) && engines.body?["result"] == .array([.string("claude")]), "\(engines)")
    var overridden = simulator(enveloped, overrides: [StudioOverride(ruleId: "products-list", status: 500, body: .object(["boom": .bool(true)]))])
    let boom = answer(overridden.handle(call("POST", ipc + "products.list")))
    check("DEC-015 an override's body is verbatim", boom.status == 500 && boom.body == .object(["boom": .bool(true)]), "\(boom)")
    var emptied = simulator(enveloped, overrides: [StudioOverride(ruleId: "products-list", empty: true)])
    let none = answer(emptied.handle(call("POST", ipc + "products.list")))
    check("DEC-015 an empty list is wrapped too", none.body?["ok"] == .bool(true) && none.body?["result"] == .array([]), "\(none)")

    // Two services, the longest prefix, and a rule no envelope covers.
    let web = answer(sim.handle(call("GET", app + "/api/items")))
    check("DEC-015 another prefix has its own envelope", web.body?["success"] == .bool(true) && web.body?["data"]?.arrayValue?.count == 3, "\(web)")
    let other = answer(sim.handle(call("GET", app + "/other/items")))
    check("DEC-015 a rule outside every prefix answers plain", other.body?.arrayValue?.count == 3, "\(other)")
    var nested = enveloped
    nested.envelopes = (nested.envelopes ?? []) + [StudioEnvelope(prefix: ipc + "agent.", resultKey: "payload")]
    check("DEC-015 the longest matching prefix wins", nested.envelope(forPath: ipc + "agent.answer")?.resultKey == "payload"
          && nested.envelope(forPath: ipc + "products.list")?.resultKey == "result")

    // The path wins over the body, and a rule that names no parameter never reads the body.
    var routed = enveloped
    routed.envelopes = nil
    routed.rules = [StudioRule(id: "rename", method: "PATCH", path: "/api/projects/:id", operation: .update, entity: "products"),
                    StudioRule(id: "loose", method: "POST", path: "/api/loose", operation: .get, entity: "products")]
    var routedSim = simulator(routed)
    let renamed = answer(routedSim.handle(call("PATCH", app + "/api/projects/1", body: #"{"id": 2, "name": "Renamed"}"#)))
    check("DEC-015 a path parameter wins over the same name in the body", renamed.body?["name"] == .string("Renamed"), "\(renamed)")
    let loose = answer(routedSim.handle(call("POST", app + "/api/loose", body: #"{"id": 2}"#)))
    check("DEC-015 a rule with no idParam does not read the body", loose.status == 404, "\(loose)")

    // Files written before the field still open, and a damaged envelope is ignored, not fatal.
    func file(_ edit: (inout [String: Any]) -> Void) -> Data {
        var object = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(StudioEnvironmentSpec()))) as? [String: Any]) ?? [:]
        edit(&object)
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
    let oldFile = file { $0.removeValue(forKey: "envelopes") }
    let decoded = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: oldFile)
    check("DEC-015 an environment without envelopes decodes as not looked at yet", decoded != nil && decoded?.envelopes == nil)
    let round = (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: JSONEncoder().encode(enveloped)))?.envelopes
    check("DEC-015 envelopes survive a round trip", round == enveloped.envelopes)
    let damaged = file { $0["envelopes"] = [["prefix": 5], ["prefix": "/api/", "resultKey": "data"]] }
    let lenient = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: damaged)
    check("DEC-015 a damaged envelope is not usable and the others still read", lenient?.envelopes?.count == 2 && lenient?.envelopes?.first?.isUsable == false
          && lenient?.envelope(forPath: "/api/x")?.resultKey == "data")
    // The assistant's side: the answer is parsed, the validator refuses a template in `envelope`, and an envelope-only answer registers.
    let structured: [String: Any] = [
        "unsupported": false, "reason": "", "assumptions": [],
        "entities": [["name": "agentQuestions", "idField": "accountId", "fields": [["name": "text", "type": "string", "required": false, "enumValues": [], "references": ""]]]],
        "records": [],
        "rules": [["id": "agent-answer", "method": "POST", "path": ipc + "agent.answer", "operation": "delete", "entity": "agentQuestions", "envelope": "",
                   "idParam": "accountId", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]]],
        "envelopes": [["prefix": ipc, "resultKey": "result", "successFields": #"{"ok": true}"#,
                       "failure": #"{"ok": false, "error": {"code": "{{status}}", "message": "{{message}}"}}"#]],
    ]
    let parsed = StudioPrompts.proposal(from: structured)
    check("DEC-015 the assistant's answer carries the envelope and the id parameter",
          parsed?.envelopes?.first?.prefix == ipc && parsed?.envelopes?.first?.resultKey == "result"
            && parsed?.envelopes?.first?.successFields == ["ok": .bool(true)]
            && parsed?.envelopes?.first?.failure?["error"]?["code"] == .string("{{status}}") && parsed?.rules.first?.idParam == "accountId", "\(String(describing: parsed?.envelopes))")
    let properties = StudioPrompts.preparationSchema["properties"] as? [String: Any]
    let ruleProperties = (((properties?["rules"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    check("DEC-015 the schema offers envelopes and idParam", properties?["envelopes"] != nil && ruleProperties["idParam"] != nil)
    check("DEC-015 the prompt says what envelope means and where the transport's wrapper goes",
          StudioPrompts.preparationSystem.contains("`envelopes`") && StudioPrompts.preparationSystem.contains("never a template")
            && StudioPrompts.preparationSystem.contains("`idParam`") && StudioPrompts.preparationSystem.contains("Never answer such a list with a fixed"))

    var registry = simulator(StudioEnvironmentSpec())
    var templated = StudioProposal()
    templated.entities = [StudioEntity(name: "things", fields: [])]
    var listRule = StudioRule(id: "things", method: "POST", path: ipc + "things.list", operation: .list, entity: "things")
    listRule.envelope = #"{"ok":true,"result":{{data}}}"#
    templated.rules = [listRule]
    let refused = registry.register(templated)
    check("DEC-015 a template in `envelope` is refused with the way out", refused.contains { $0.contains("`envelopes`") }, "\(refused)")
    listRule.envelope = "result"
    templated.rules = [listRule]
    check("DEC-015 a plain key is accepted", registry.register(templated).isEmpty)
    var bodyID = StudioProposal()
    bodyID.rules = [StudioRule(id: "thing-get", method: "POST", path: ipc + "things.get", operation: .get, entity: "things", idParam: "thingId"),
                    StudioRule(id: "thing-drop", method: "POST", path: ipc + "things.drop", operation: .delete, entity: "things")]
    let noID = registry.register(bodyID)
    check("DEC-015 a get needs an id in the path or an idParam, and only the one without is refused",
          noID.count == 1 && noID[0].contains("thing-drop"), "\(noID)")
    var onlyEnvelope = StudioProposal()
    onlyEnvelope.envelopes = [ipcEnvelope]
    check("DEC-015 an answer that is only an envelope registers", registry.register(onlyEnvelope).isEmpty && registry.spec.envelopes == [ipcEnvelope])
    var replacement = StudioProposal()
    replacement.envelopes = [StudioEnvelope(prefix: ipc, resultKey: "data"), StudioEnvelope(prefix: "/api/", resultKey: "data")]
    _ = registry.register(replacement)
    check("DEC-015 an envelope with the same prefix is replaced, another added",
          registry.spec.envelopes?.count == 2 && registry.spec.envelope(forPath: ipc + "x")?.resultKey == "data")
    var nothing = StudioProposal()
    nothing.envelopes = []
    var looked = simulator(StudioEnvironmentSpec())
    check("DEC-015 \"none\" is an answer: an empty list is kept, so the review is not repeated",
          looked.register(nothing).isEmpty && looked.spec.envelopes == [])
    var badKey = StudioProposal()
    badKey.envelopes = [StudioEnvelope(prefix: "/api/", resultKey: #"{"a":1}"#)]
    check("DEC-015 a result key that is not a plain name is refused", !looked.register(badKey).isEmpty)

    var empty = StudioEnvironmentSpec()
    empty.envelopes = []
    check("DEC-015 an empty list means none and is kept", (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: JSONEncoder().encode(empty)))?.envelopes == [])
}

/// DEC-015: the one-time review of an environment prepared before envelopes and state-following lists existed.
func reviewChecks() {
    let ipc = "http://electron.ipc/ppd/invoke/"
    func call(_ url: String, body: String? = nil) -> StudioHTTPRequest {
        StudioHTTPRequest(method: "POST", url: URL(string: url)!, headers: [:], body: body, requestId: UUID().uuidString)
    }
    func answer(_ outcome: StudioSimOutcome) -> StudioJSON? {
        guard case .respond(let response, _) = outcome else { return nil }
        return response.body.flatMap { StudioJSON(text: $0) }
    }
    let questions = StudioJSON.array([.object(["accountId": .string("a1"), "text": .string("Solve the CAPTCHA")]),
                                      .object(["accountId": .string("a2"), "text": .string("Confirm the email")])])
    // What a real project had: the pending questions as a fixed answer, the answer as a fixed answer, a list with a template in `envelope`.
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "products", fields: [StudioField(name: "name", type: "string")])]
    spec.seed = ["products": [.object(["id": .number(1), "name": .string("Atlas")])]]
    var templated = StudioRule(id: "products-list", method: "POST", path: ipc + "products.list", operation: .list, entity: "products")
    templated.envelope = #"{"ok":true,"result":{{data}}}"#
    spec.rules = [
        templated,
        StudioRule(id: "agent-questions", method: "POST", path: ipc + "agent.questions", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": questions]))),
        StudioRule(id: "agent-answer", method: "POST", path: ipc + "agent.answer", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .null]))),
        StudioRule(id: "app-info", method: "POST", path: ipc + "app.info", operation: .respond,
                   response: StudioFixedResponse(status: 200, body: .object(["ok": .bool(true), "result": .object(["version": .string("1.0")])]))),
    ]
    spec.channels = [StudioChannel(id: "ipc-events", path: ipc + "onEvent")]
    let simulator = StudioSimulator(spec: spec, scenario: StudioScenario(id: "populated", name: "Populated", kind: .populated), appOrigin: "http://localhost:5173")

    let prompt = StudioReview.prompt(spec: spec, appFolder: "")
    check("DEC-015 the review shows the rules, the start of a fixed body, the entities and the channels",
          prompt.contains("agent-questions") && prompt.contains("[fixed: ") && prompt.contains("Entities: products") && prompt.contains("ipc-events"))
    let required = StudioReview.schema["required"] as? [String] ?? []
    check("DEC-015 the review must answer envelopes, replaces, links and notes, so that nothing to correct is explicit",
          ["envelopes", "replaces", "links", "notes"].allSatisfy(required.contains))
    check("DEC-015 the review prompt carries the preparation rules and its own task",
          StudioReview.system.contains("`envelopes`") && StudioReview.system.contains("`replaces`") && StudioReview.system.contains("`links`"))

    // What a good answer is.
    let structured: [String: Any] = [
        "unsupported": false, "reason": "", "assumptions": [],
        "entities": [["name": "agentQuestions", "idField": "accountId", "fields": [["name": "text", "type": "string", "required": false, "enumValues": [], "references": ""]]]],
        "records": [["entity": "agentQuestions", "json": questions.text]],
        "rules": [["id": "agent-questions-list", "method": "POST", "path": ipc + "agent.questions", "operation": "list", "entity": "agentQuestions", "envelope": "",
                   "idParam": "", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]],
                  ["id": "agent-answer-delete", "method": "POST", "path": ipc + "agent.answer", "operation": "delete", "entity": "agentQuestions", "envelope": "",
                   "idParam": "accountId", "filters": [], "include": [], "responseStatus": 0, "responseBody": "", "evidence": [["kind": "contract", "detail": "api.ts"]]]],
        "envelopes": [["prefix": ipc, "resultKey": "result", "successFields": #"{"ok": true}"#, "failure": ""]],
        "replaces": ["agent-questions", "agent-answer"],
        "links": [["channel": "ipc-events", "entity": "agentQuestions", "message": #"{"type": "changed", "scope": "accounts"}"#],
                  ["channel": "ipc-events", "entity": "agentQuestions", "message": "not json"]],
        "notes": "The questions are state.",
    ]
    guard let outcome = StudioReview.outcome(from: structured) else { check("DEC-015 the review answer is read", false); return }
    check("DEC-015 the review answer is read: rules, envelope, replaced ids, one good link and a note",
          outcome.proposal.rules.count == 2 && outcome.proposal.envelopes?.count == 1 && outcome.replaces == ["agent-questions", "agent-answer"]
            && outcome.links == [StudioReview.Link(channel: "ipc-events", entity: "agentQuestions",
                                                   message: .object(["type": .string("changed"), "scope": .string("accounts")]))]
            && outcome.notes == "The questions are state.")
    var withoutEnvelopes = structured
    withoutEnvelopes.removeValue(forKey: "envelopes")
    check("DEC-015 an answer with no envelopes field means none, never not looked at", StudioReview.outcome(from: withoutEnvelopes)?.proposal.envelopes == [])

    var reviewed = simulator
    let problems = StudioReview.apply(outcome, to: &reviewed)
    check("DEC-015 the review is applied", problems.isEmpty, "\(problems)")
    check("DEC-015 the replaced fixed rules are gone and the new ones stand in their place",
          !reviewed.spec.rules.contains { $0.id == "agent-questions" || $0.id == "agent-answer" }
            && reviewed.spec.rules.contains { $0.id == "agent-questions-list" } && reviewed.spec.rules.contains { $0.id == "app-info" })
    check("DEC-015 a template left in a rule's `envelope` is cleaned", reviewed.spec.rules.first { $0.id == "products-list" }?.envelope == nil)
    check("DEC-015 the environment now knows its envelope", reviewed.spec.envelopes?.first?.resultKey == "result")
    check("DEC-015 the event channel pushes the change when the entity is written",
          reviewed.spec.channels?.first?.links.first?.entity == "agentQuestions" && reviewed.spec.channels?.first?.links.first?.message != nil)

    // What the page sees: the dialog's list shrinks when its button's request is answered.
    var sim = reviewed
    let before = answer(sim.handle(call(ipc + "agent.questions")))
    check("DEC-015 the page lists both questions", before?["ok"] == .bool(true) && before?["result"]?.arrayValue?.count == 2, "\(String(describing: before))")
    let done = answer(sim.handle(call(ipc + "agent.answer", body: #"{"accountId": "a1", "answer": "done"}"#)))
    check("DEC-015 pressing I'm done is answered in the application's shape", done?["ok"] == .bool(true), "\(String(describing: done))")
    let after = answer(sim.handle(call(ipc + "agent.questions")))
    check("DEC-015 the answered question leaves the list", after?["result"]?.arrayValue?.count == 1 && after?["result"]?.arrayValue?.first?["accountId"] == .string("a2"))
    let table = answer(sim.handle(call(ipc + "products.list")))
    check("DEC-015 the list that had a template now answers in the envelope", table?["ok"] == .bool(true) && table?["result"]?.arrayValue?.count == 1, "\(String(describing: table))")
    let info = answer(sim.handle(call(ipc + "app.info")))
    check("DEC-015 a fixed answer that is truly static is untouched", info?["result"]?["version"] == .string("1.0") && info?["ok"] == .bool(true))

    // A refused review changes nothing.
    var broken = outcome
    broken.proposal.rules[0].method = "TRACE"
    var untouched = simulator
    let refused = StudioReview.apply(broken, to: &untouched)
    check("DEC-015 a refused review changes nothing", !refused.isEmpty && untouched.spec == simulator.spec)
    var noEntity = outcome
    noEntity.links = [StudioReview.Link(channel: "ipc-events", entity: "nothing", message: .object([:]))]
    var unlinked = simulator
    check("DEC-015 a link to an undefined entity refuses the review", !StudioReview.apply(noEntity, to: &unlinked).isEmpty && unlinked.spec == simulator.spec)
    var wrongChannel = outcome
    wrongChannel.links = [StudioReview.Link(channel: "no-such", entity: "agentQuestions", message: .object([:]))]
    var onlyChannel = simulator
    check("DEC-015 the application's only raw channel is used when the assistant names another",
          StudioReview.apply(wrongChannel, to: &onlyChannel).isEmpty && onlyChannel.spec.channels?.first?.links.count == 1)
    var two = simulator
    var more = two.spec
    more.channels = (more.channels ?? []) + [StudioChannel(id: "other", path: "/socket")]
    two.replaceSpec(more)
    check("DEC-015 with two raw channels a wrong name is refused", !StudioReview.apply(wrongChannel, to: &two).isEmpty)
    // A scenario naming requests no rule serves: the ones to prepare, once each, none of the served ones.
    let named = [StudioOverride(method: "post", path: ipc + "passport.get", status: 500), StudioOverride(method: "POST", path: ipc + "passport.get", status: 404),
                 StudioOverride(method: "POST", path: ipc + "products.list", empty: true), StudioOverride(ruleId: "app-info", status: 500),
                 StudioOverride(method: "GET", path: "/api/ghost", hang: true), StudioOverride(status: 500)]
    let unserved = StudioContextValidator.unservedRequests(named, spec: spec)
    check("DEC-015 the requests a scenario names without a rule are found once each, served ones and rule ids left out",
          unserved.map { "\($0.method) \($0.path)" } == ["POST " + ipc + "passport.get", "GET /api/ghost"], "\(unserved)")
    // A screen is shown with nothing in front of it.
    let screen = StudioScreen(name: "Products", route: "/#/products", selector: "[data-testid=products]", description: "The list", instructions: "Open it.", source: "src/App.tsx")
    check("DEC-015 the screen request asks for a screen without a blocking dialog in front of it",
          screen.request.contains("not covered by a blocking dialog") && screen.request.contains("unless this screen is that dialog"))
    check("DEC-015 the assistant is told to take a covering dialog away in the scenario",
          StudioPrompts.editSystem.contains("shown with nothing in front of it") && StudioPrompts.editSystem.contains("press the dialog's own button"))
    var empty = StudioReview.Outcome(proposal: StudioProposal(), replaces: [], links: [], notes: "")
    empty.proposal.envelopes = []
    var looked = simulator
    check("DEC-015 nothing to correct is applied and recorded as looked at", StudioReview.apply(empty, to: &looked).isEmpty && looked.spec.envelopes == [])
}
