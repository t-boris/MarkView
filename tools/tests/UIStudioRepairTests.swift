import Foundation

// Checks of UIStudioRepair.swift (REQ-019, REQ-020, DEC-013): a load that does not start a new page, the classification of
// problem rows, the order and the limits of repairs, the page errors of earlier pages, Undo, and that a reload's leftovers are not
// problems. Compiled into tools/tests/ui-studio-tests.sh; `check` comes from UIStudioTests.swift.

@MainActor
func repairChecks() {
    func url(_ text: String) -> URL { URL(string: text)! }

    // A hash-routed application: the address differs only by its fragment, so WebKit would keep the old page and its old generation.
    check("REQ-020 /#/attention → /#/accounts is a navigation inside the page",
          StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/attention"), to: url("http://localhost:5173/#/accounts")))
    check("REQ-020 the same address with the same fragment is too",
          StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/accounts"), to: url("http://localhost:5173/#/accounts")))
    check("REQ-020 another path is a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/a#/x"), to: url("http://localhost:5173/b#/x")))
    check("REQ-020 another query is a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/?a=1#/x"), to: url("http://localhost:5173/#/x")))
    check("REQ-020 a target without a fragment is always a new page",
          !StudioPageLoad.isFragmentNavigation(from: url("http://localhost:5173/#/x"), to: url("http://localhost:5173/")))
    check("REQ-020 with no page yet it is a new page", !StudioPageLoad.isFragmentNavigation(from: nil, to: url("http://localhost:5173/#/x")))

    // The classification of a row of the Log.
    let stale = "Rejected: a message of an earlier generation (20)."
    let errorText = "runtimeError: Unhandled rejection: Error: Cannot read properties of undefined (reading 'label')"
    let key = StudioDataFix.key(of: "Unhandled rejection: Error: Cannot read properties of undefined (reading 'label')")
    func kind(_ kind: StudioLogEntry.Kind, _ problem: Bool, _ text: String, key: String? = nil, notData: Set<String> = []) -> StudioProblem.Kind {
        StudioProblem.classify(kind: kind, problem: problem, text: text, errorKey: key, notData: notData)
    }
    check("REQ-019 a message of an earlier generation is noise, even as a problem",
          kind(.server, true, "[console.warn] MarkView UI Studio: http://electron.ipc/ppd/onEvent: " + stale) == .noise
            && kind(.page, true, "runtimeError: TypeError: Failed to fetch (MarkView UI Studio: " + stale + ")", key: "x") == .noise)
    check("REQ-019 a page error that data may have caused is a data error", kind(.page, true, errorText, key: key) == .dataError)
    check("REQ-019 the same error judged not data is not offered again", kind(.page, true, errorText, key: key, notData: [key]) == .notData)
    check("REQ-019 a redirect to a sign-in page is a sign-in problem",
          kind(.navigation, true, "Server redirect http://localhost:3101/ → http://localhost:3101/login (a sign-in page)") == .signInRedirect)
    check("REQ-019 a blocked third-party script and a Stripe.js failure are reported, not repaired",
          kind(.page, true, "blocked: script https://js.stripe.com/v3") == .blockedService
            && kind(.page, true, "runtimeError: Unhandled rejection: Error: Failed to load Stripe.js", key: "Error: Failed to load Stripe.js") == .blockedService)
    check("REQ-019 a failed or timed-out preparation, and requests without a rule, are missing rules",
          kind(.preparation, true, "GET http://electron.ipc/ppd/invoke/channels.list: timedOut after 90.0 s") == .missingRule
            && kind(.notice, true, "Degraded: 1 request without a simulation rule") == .missingRule)
    check("REQ-019 an error that says its rule is still being prepared is a missing rule, not a data error",
          kind(.page, true, "runtimeError: Error invoking remote method 'automation.get': MarkView UI Studio is still preparing the simulation rule for GET x",
               key: "k") == .missingRule)
    check("REQ-019 any other problem row has no action, and a row that is no problem is not classified as one",
          kind(.server, true, "ERROR in ./src/x.tsx") == .other && kind(.request, false, "GET http://x/ · simulated 200") == .other)
    check("REQ-019 every repairable kind has its action, the others none",
          StudioProblem.action(for: .dataError) == .fix && StudioProblem.action(for: .missingRule) == .prepare
            && StudioProblem.action(for: .signInRedirect) == .signIn
            && [StudioProblem.Kind.blockedService, .notData, .noise, .other].allSatisfy { StudioProblem.action(for: $0) == nil })

    // The order that helps: sign-in, rules, then data; items of one kind keep their order; what cannot be repaired is dropped.
    let items = [StudioProblem.Item(kind: .dataError, key: "a", text: "a"), StudioProblem.Item(kind: .blockedService, key: "s", text: "s"),
                 StudioProblem.Item(kind: .missingRule, key: "r", text: "r"), StudioProblem.Item(kind: .dataError, key: "b", text: "b"),
                 StudioProblem.Item(kind: .signInRedirect, key: "/login", text: "l")]
    check("REQ-020 sign-in first, then rules, then data in order; a blocked service is dropped",
          StudioProblem.ordered(items).map(\.key) == ["/login", "r", "a", "b"])

    // The limits: nothing loops.
    var ledger = StudioRepairLedger()
    let one = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e1")
    let two = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e2")
    let three = StudioRepairLedger.identity(kind: .dataError, scenario: "s1", key: "e3")
    check("REQ-020 a first automatic repair is allowed", ledger.mayRun(one, automatic: true))
    ledger.record(one, outcome: .fixed, automatic: true)
    check("REQ-020 an error that came back after a fix is tried once more", ledger.mayRun(one, automatic: true))
    ledger.record(one, outcome: .fixed, automatic: true)
    check("REQ-020 and not a third time", !ledger.mayRun(one, automatic: true))
    check("REQ-020 the person's own click always may", ledger.mayRun(one, automatic: false))
    ledger.record(two, outcome: .notData, automatic: true)
    check("REQ-020 an error the assistant judged not data is never repaired again by itself", !ledger.mayRun(two, automatic: true))
    check("REQ-020 and is listed as not data for its scenario only",
          ledger.notDataKeys(scenario: "s1") == ["e2"] && ledger.notDataKeys(scenario: "s2").isEmpty)
    check("REQ-020 three automatic repairs are the most of one open", ledger.automaticRuns == 3 && !ledger.mayRun(three, automatic: true))
    ledger.reset()
    check("REQ-020 a new open remembers nothing", ledger.mayRun(one, automatic: true) && ledger.mayRun(three, automatic: true) && ledger.automaticRuns == 0)
    var refused = StudioRepairLedger()
    refused.record(three, outcome: .refused, automatic: true)
    check("REQ-020 refused corrections are not repeated by itself", !refused.mayRun(three, automatic: true))
    var failed = StudioRepairLedger()
    failed.record(three, outcome: .failed, automatic: true)
    check("REQ-020 a run that failed gets one more try", failed.mayRun(three, automatic: true))
    check("REQ-020 a repair of another scenario is another repair",
          failed.mayRun(StudioRepairLedger.identity(kind: .dataError, scenario: "s2", key: "e3"), automatic: true))

    // Page errors of earlier pages of the same scenario keep their action, and Undo writes the old values back.
    let now = Date()
    let seen = [StudioDataFix.Seen(kind: .runtimeError, detail: "Unhandled rejection: Error: boom\n    at a (b.js:1:1)", generation: 3, date: now),
                StudioDataFix.Seen(kind: .route, detail: "/x", generation: 4, date: now)]
    check("REQ-019 the latest event of an error is found whatever its page generation",
          StudioDataFix.latest(seen, key: "Error: boom")?.key == "Error: boom" && StudioDataFix.latest(seen, key: "Error: other") == nil)

    func js(_ text: String) -> StudioJSON { StudioJSON(text: text)! }
    var spec = StudioEnvironmentSpec()
    spec.entities = [StudioEntity(name: "bundles", fields: [StudioField(name: "name", type: "string"), StudioField(name: "status", type: "string")])]
    spec.seed = ["bundles": (1...3).map { js(#"{"id":\#($0),"name":"B\#($0)","status":"draft"}"#) }]
    let scenarioData = ["bundles": [js(#"{"id":1,"name":"B1","status":"draft"}"#)]]
    let fix = StudioDataFix.apply([StudioDataFix.Change(entity: "bundles", id: "1", field: "status", value: js(#""editable""#), reason: "the code expects editable"),
                                   StudioDataFix.Change(entity: "bundles", id: "2", field: "status", value: js(#""editable""#), reason: "the code expects editable")],
                                  spec: spec, scenarioData: scenarioData, redactor: StudioRedactor())
    check("REQ-020 the fixture fix applies", fix.ok && fix.applied.count == 2, fix.problems.joined(separator: "; "))
    check("REQ-020 the fix changed the seed and the scenario's own record",
          fix.seed["bundles"]?[0]["status"] == js(#""editable""#) && fix.scenarioData?["bundles"]?[0]["status"] == js(#""editable""#))
    let back = StudioDataFix.revert(fix.applied, spec: spec, seed: fix.seed, scenarioData: fix.scenarioData)
    check("REQ-020 Undo writes the old values back in the seed and in the scenario",
          back.seed == spec.seed && back.scenarioData == scenarioData)
    let withoutRecord = StudioDataFix.revert(fix.applied, spec: spec, seed: ["bundles": []], scenarioData: nil)
    check("REQ-020 Undo leaves alone what is no longer there", withoutRecord.seed == ["bundles": []] && withoutRecord.scenarioData == nil)

    // What a reload leaves behind is in the Log, but is not counted as a problem.
    let log = StudioLog(root: nil, redactor: StudioRedactor(), queue: DispatchQueue(label: "repair-checks"))
    log.add(.server, problem: true, "[console.warn] MarkView UI Studio: http://electron.ipc/ppd/onEvent: " + stale)
    log.add(.page, problem: true, "runtimeError: boom")
    check("REQ-019 a message of an earlier generation is kept but not counted", log.entries.count == 2 && log.problems == 1)

    // The environment file: older files have no switch and repair by themselves; the switch survives a round trip.
    var environment = StudioEnvironmentSpec()
    let plain = (try? JSONEncoder().encode(environment)) ?? Data()
    check("REQ-020 an environment without the switch has no field and repairs automatically",
          !String(decoding: plain, as: UTF8.self).contains("autoRepair") && environment.repairsAutomatically
            && ((try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: plain))?.repairsAutomatically ?? false))
    environment.autoRepair = false
    let off = (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: (try? JSONEncoder().encode(environment)) ?? Data()))
    check("REQ-020 the switch off survives a round trip", off?.autoRepair == false && off?.repairsAutomatically == false)
}
