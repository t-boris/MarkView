import Foundation

// Checks for MarkView/Models/QAScenario.swift, QARun.swift and QAStore.swift (feature end-to-end-qa), run by tools/tests/qa-tests.sh.
// Fixtures are scenarios and events; nothing touches a file but the store checks in a temp folder.

let now = Date(timeIntervalSince1970: 1_790_000_000)

func shop() -> QAScenario {
    QAScenario(
        id: "checkout", title: "Checkout with a card", goal: "A buyer pays and the seller sees the order", appKind: .web,
        apps: [QAApp(id: "shop", name: "Shop")],
        targets: [
            QATarget(id: "local", kind: .local, name: "Local", locations: ["shop": QALocation(url: "http://localhost:3000")]),
            QATarget(id: "prod", kind: .production, name: "Production", locations: ["shop": QALocation(url: "https://shop.example.com")]),
        ],
        actors: [
            QAActor(id: "buyer", name: "Buyer", login: QALoginReference(host: "shop.example.com", username: "buyer@example.com")),
            QAActor(id: "seller", name: "Seller", createTestAccount: true),
        ],
        nodes: [
            QANode(id: "n1", kind: .action, title: "Add a product to the cart", detail: "Open the shop and add the first product", actor: "buyer", changesData: .no),
            QANode(id: "n2", kind: .action, title: "Pay with a valid card", detail: "Pay with the test card", actor: "buyer", changesData: .yes),
            QANode(id: "n3", kind: .check, title: "Confirmation is shown", detail: "The order confirmation is shown", actor: "buyer"),
            QANode(id: "n4", kind: .action, title: "Open the order list", detail: "Open the orders page", actor: "seller", changesData: .no),
            QANode(id: "n5", kind: .check, title: "The order is listed", detail: "The new order is in the list", actor: "seller"),
            QANode(id: "a1", kind: .alternative, title: "Card is declined", detail: "The bank declines the card", actor: "buyer", changesData: .yes,
                   condition: QACondition(kind: .data, establish: "Use the decline test card", verify: "The card field holds the decline test card")),
            QANode(id: "c1", kind: .check, title: "Decline message", detail: "A decline message is shown", actor: "buyer"),
            QANode(id: "f1", kind: .failure, title: "Payment is slow", detail: "The payment request takes eight seconds", actor: "buyer",
                   condition: QACondition(kind: .delay, establish: "Delay the payment request by 8 s", verify: "The delayed request was seen",
                                          fault: QAFault(urlPattern: "/api/pay", mode: .delay, milliseconds: 8000))),
            QANode(id: "c2", kind: .check, title: "Waiting indicator", detail: "A waiting indicator is shown", actor: "buyer"),
        ],
        edges: [
            QAEdge(from: "n1", to: "n2"), QAEdge(from: "n2", to: "n3"), QAEdge(from: "n3", to: "n4"), QAEdge(from: "n4", to: "n5"),
            QAEdge(from: "n1", to: "a1", label: "declined"), QAEdge(from: "a1", to: "c1"),
            QAEdge(from: "n2", to: "f1", label: "slow"), QAEdge(from: "f1", to: "c2"),
        ],
        start: "n1", created: now, updated: now)
}

func changed(_ scenario: QAScenario, _ change: (inout QAScenario) -> Void) -> QAScenario {
    var copy = scenario
    change(&copy)
    return copy
}

func kinds(_ scenario: QAScenario) -> Set<QAProblem.Kind> { Set(scenario.problems().map(\.kind)) }

/// Twelve forks that each close again: 37 steps and 4096 lines from the start.
let ladder: QAScenario = {
    var ladder = QAScenario(id: "ladder", title: "Ladder", goal: "g", appKind: .web, apps: [QAApp(id: "app", name: "App")], actors: [QAActor(id: "a", name: "A")], start: "s", created: now, updated: now)
    ladder.nodes.append(QANode(id: "s", kind: .action, title: "start"))
    var previous = "s"
    for i in 0..<12 {
        for name in ["x\(i)", "y\(i)", "j\(i)"] { ladder.nodes.append(QANode(id: name, kind: .action, title: name)) }
        ladder.edges += [QAEdge(from: previous, to: "x\(i)"), QAEdge(from: previous, to: "y\(i)"), QAEdge(from: "x\(i)", to: "j\(i)"), QAEdge(from: "y\(i)", to: "j\(i)")]
        previous = "j\(i)"
    }
    return ladder
}()

let main = "n1>n2>n3>n4>n5", slow = "n1>n2>f1>c2", declined = "n1>a1>c1"

// MARK: - Branches

do {
    let scenario = shop()
    check("scenario: the fixture has no problems", scenario.problems().isEmpty)
    let branches = scenario.enumerateBranches()
    check("branches: every line from the start to a last step, in the order the edges are written", branches.branches.map(\.id) == [main, slow, declined])
    check("branches: nothing was cut", !branches.truncated)
    let titles = Array(scenario.displayLabels(for: branches.branches).values)
    check("branches: display names distinguish choices at each fork", Set(titles).count == titles.count && titles.contains(where: { $0.contains("declined") }) && titles.contains(where: { $0.contains("slow") }))
    let shared = changed(scenario) { s in
        s.nodes += [QANode(id: "shared", kind: .action, title: "Shared")]
        s.edges += [QAEdge(from: "shared", to: "n1", label: "Common setup"), QAEdge(from: "shared", to: "n5", label: "Other")]
        s.start = "shared"
    }
    let paths = shared.enumerateBranches().branches.filter { $0.nodes.contains("n1") }
    let names = shared.displayLabels(for: paths)
    check("branches: shared choices are omitted while distinct choices stay visible", names.count == paths.count && names.values.allSatisfy { !$0.contains("Common setup") } && Set(names.values).count == paths.count)
    let oldPath = QABranch(nodes: ["missing", "step"])
    check("branches: archived paths missing from the current scenario keep their original ID", scenario.displayLabels(for: [oldPath])[oldPath.id] == oldPath.id)

    check("branches: a branch is named by the alternatives and failures it takes",
          scenario.label(of: QABranch(nodes: ["n1", "n2", "f1", "c2"])) == "Payment is slow" && scenario.label(of: QABranch(nodes: ["n1", "a1", "c1"])) == "Card is declined")
    check("branches: the main line has no alternative", scenario.label(of: QABranch(nodes: ["n1", "n2", "n3", "n4", "n5"])) == "Main line")
    check("branches: the conditions along a branch, in order",
          scenario.conditions(of: QABranch(nodes: ["n1", "n2", "f1", "c2"])).map(\.node) == ["f1"] && scenario.conditions(of: QABranch(nodes: ["n1", "n2", "n3", "n4", "n5"])).isEmpty)
    check("branches: the actors of a branch, in order of first appearance",
          scenario.actors(in: QABranch(nodes: ["n1", "n2", "n3", "n4", "n5"])) == ["buyer", "seller"] && scenario.actors(in: QABranch(nodes: ["n1", "a1", "c1"])) == ["buyer"])
    check("condition: a fault in the actor's page changes nothing in the target, any other condition may",
          scenario.node("f1")?.condition?.changesData == QADataChange.no && scenario.node("a1")?.condition?.changesData == QADataChange.unknown)

    let doubled = changed(scenario) { $0.edges.append(QAEdge(from: "n1", to: "n2")) }
    check("branches: a connection written twice makes one branch", doubled.enumerateBranches().branches.map(\.id) == [main, slow, declined])

    let cut = ladder.enumerateBranches(limit: 500)
    check("branches: a scenario with thousands of lines is cut at the limit and says so", cut.branches.count == 500 && cut.truncated)
    check("branches: a limit that is not reached cuts nothing", shop().enumerateBranches(limit: 3).truncated == false && shop().enumerateBranches(limit: 2).truncated)
}

// MARK: - Selection

do {
    let scenario = changed(shop()) { $0.selected = [declined, slow] }
    let picked = scenario.selectedBranches()
    check("selection: the selected branches that exist, in the order selected", picked.found.map(\.id) == [declined, slow] && picked.gone.isEmpty)
    let edited = changed(scenario) { $0.edges.removeAll { $0.from == "a1" } ; $0.nodes.removeAll { $0.id == "c1" } }
    check("selection: a branch an edit removed is reported as gone", edited.selectedBranches().found.map(\.id) == [slow] && edited.selectedBranches().gone == [declined])
    check("selection: ... and the scenario cannot run until it is dealt with", kinds(edited) == [.selectionGone])
    let gone = changed(shop()) { $0.selected = ["n1>zz"] }
    check("selection: a selected branch that does not exist is a problem", kinds(gone) == [.selectionGone])
}

// MARK: - What stops a scenario from running

do {
    check("problems: a duplicate step id", kinds(changed(shop()) { $0.nodes.append($0.nodes[0]) }).contains(.duplicateNode))
    check("problems: an id that is not a plain id", kinds(changed(shop()) { $0.nodes[0].id = "n 1" }).contains(.badID))
    check("problems: an id with the branch separator", !QAScenario.isValidID("a>b") && QAScenario.isValidID("step_1-a"))
    check("problems: no start", kinds(changed(shop()) { $0.start = nil }) == [.missingStart])
    check("problems: a start that is not a step", kinds(changed(shop()) { $0.start = "zz" }).contains(.missingStart))
    check("problems: a connection to an unknown step", kinds(changed(shop()) { $0.edges.append(QAEdge(from: "n5", to: "zz")) }) == [.unknownNode])
    check("problems: a step nothing leads to", kinds(changed(shop()) { $0.nodes.append(QANode(id: "lonely", kind: .action, title: "Lonely", actor: "buyer")) }) == [.unreachableNode])
    check("problems: a step with no title", kinds(changed(shop()) { $0.nodes[0].title = "  " }) == [.emptyTitle])
    check("problems: a check that does not say what must hold", kinds(changed(shop()) { $0.nodes[2].detail = "" }) == [.missingExpectation])
    check("problems: a step of an unknown actor", kinds(changed(shop()) { $0.nodes[0].actor = "ghost" }) == [.unknownActor])
    check("problems: a step with no actor when there are two", kinds(changed(shop()) { $0.nodes[0].actor = nil }) == [.ambiguousActor])
    check("problems: with one actor a step needs no name",
          kinds(changed(shop()) { $0.actors = [QAActor(id: "buyer", name: "Buyer")]; for i in $0.nodes.indices { $0.nodes[i].actor = nil } }).isEmpty)
    check("problems: no actor at all", kinds(changed(shop()) { $0.actors = []; for i in $0.nodes.indices { $0.nodes[i].actor = nil } }) == [.noActor])
    check("problems: two actors with one id", kinds(changed(shop()) { $0.actors.append($0.actors[0]) }).contains(.duplicateActor))
    check("problems: a condition that does not say how to establish it", kinds(changed(shop()) { $0.nodes[5].condition?.establish = "" }) == [.incompleteCondition])
    check("problems: a condition that does not say how to verify it", kinds(changed(shop()) { $0.nodes[5].condition?.verify = " " }) == [.incompleteCondition])
    check("problems: a network condition with no fault", kinds(changed(shop()) { $0.nodes[7].condition?.fault = nil }) == [.incompleteCondition])
    check("problems: a delay with no time", kinds(changed(shop()) { $0.nodes[7].condition?.fault?.milliseconds = 0 }) == [.incompleteCondition])
    check("problems: a status answer needs a real status", kinds(changed(shop()) { $0.nodes[7].condition?.fault = QAFault(urlPattern: "/api", mode: .status, status: 42) }) == [.incompleteCondition])
    check("problems: a network fault rejects an unknown HTTP method", kinds(changed(shop()) { $0.nodes[7].condition?.fault?.method = "SEND" }) == [.incompleteCondition])
    check("problems: a POST-only network fault is valid", kinds(changed(shop()) { $0.nodes[7].condition?.fault?.method = "POST" }).isEmpty)
    check("problems: no target", kinds(changed(shop()) { $0.targets = [] }) == [.noTarget])
    check("problems: a web target needs an http address", kinds(changed(shop()) { $0.targets[0].locations["shop"]?.url = "localhost:3000" }) == [.incompleteTarget] && kinds(changed(shop()) { $0.targets[0].locations["shop"]?.url = nil }) == [.incompleteTarget])
    check("problems: a web target may not be a file address", kinds(changed(shop()) { $0.targets[0].locations["shop"]?.url = "file:///etc/passwd" }) == [.incompleteTarget])
    check("problems: a web target may not use another protocol", kinds(changed(shop()) { $0.targets[0].locations["shop"]?.url = "ftp://shop.example.com" }) == [.incompleteTarget])
    let native = changed(shop()) { $0.appKind = .nativeMacOS; $0.targets = [QATarget(id: "app", kind: .local, name: "Notes", locations: ["shop": QALocation(application: QAApplication(bundleIdentifier: "com.example.Notes", name: "Notes"))])] }
    check("problems: a native scenario with an installed application has none", native.problems().isEmpty)
    check("problems: a native target needs an application", kinds(changed(native) { $0.targets[0].locations["shop"]?.application = nil }) == [.incompleteTarget])
    check("problems: a native target needs a bundle identifier", kinds(changed(native) { $0.targets[0].locations["shop"]?.application?.bundleIdentifier = "" }) == [.incompleteTarget])

    let loop = changed(shop()) { $0.edges.append(QAEdge(from: "n3", to: "n1")) }
    check("problems: a branch that loops back is reported", kinds(loop) == [.cycle])
    check("problems: ... and listing the branches of it still ends", loop.enumerateBranches().branches.map(\.id).contains(main))
    check("problems: the fixture reports each problem once per cause", changed(shop()) { $0.nodes[2].detail = "" }.problems().count == 1)
}

// MARK: - A scenario holds no secret

do {
    let json = String(data: (try? QAStore.encoder.encode(shop())) ?? Data(), encoding: .utf8) ?? ""
    check("scenario file: a login is a host and a user name, never a password", !json.lowercased().contains("password") && json.contains("buyer@example.com"))
    let back = try? QAStore.decoder.decode(QAScenario.self, from: Data(json.utf8))
    check("scenario file: JSON round trip keeps the scenario", back == shop())
    let legacyFault = try? QAStore.decoder.decode(QAFault.self, from: Data(#"{"urlPattern":"/messages","mode":"status","status":503}"#.utf8))
    check("scenario file: old network faults still affect every HTTP method", legacyFault?.method == nil && legacyFault?.status == 503)
    let postOnly = QAFault(urlPattern: "/messages", mode: .status, status: 503, method: "POST")
    let encodedFault = (try? QAStore.encoder.encode(postOnly)) ?? Data()
    check("scenario file: a method-specific fault survives saving and loading", (try? QAStore.decoder.decode(QAFault.self, from: encodedFault)) == postOnly)
}

// MARK: - Outcomes of one check

func machine(_ conditionRequired: Bool, _ events: [QACheckEvent]) -> QACheckMachine {
    var machine = QACheckMachine(conditionRequired: conditionRequired)
    for event in events { machine.apply(event) }
    return machine
}

do {
    let passed = machine(false, [.baselineEstablished, .nodeMet("n1"), .nodeMet("n2"), .allNodesDone])
    check("check: a branch whose steps and checks all held passed", passed.verdict?.outcome == .passed && passed.phase == .finished && passed.nodesMet == ["n1", "n2"])
    check("check: a passed check is completed and makes no bug", passed.verdict?.outcome.isCompleted == true && passed.verdict?.outcome.createsBug == false)

    let failed = machine(false, [.baselineEstablished, .nodeMet("n1"), .checkNotMet("n3", "No confirmation")])
    check("check: a check that did not hold is failed", failed.verdict?.outcome == .failed && failed.verdict?.node == "n3" && failed.verdict?.reason == "No confirmation")
    check("check: a failed check is completed and makes a bug", failed.verdict?.outcome.isCompleted == true && failed.verdict?.outcome.createsBug == true)

    let noBaseline = machine(false, [.baselineFailed(.baselineNotEstablished, "The cart could not be emptied"), .nodeMet("n1"), .allNodesDone])
    check("check: a baseline that cannot be established makes the branch blocked", noBaseline.verdict?.outcome == .blocked && noBaseline.verdict?.blockReason == .baselineNotEstablished)
    check("check: ... it is not reported as completed, whatever follows", noBaseline.verdict?.outcome.isCompleted == false && noBaseline.ignored.count == 2)

    let noLaunch = machine(false, [.baselineFailed(.launchFailed, "The application did not start"), .allNodesDone])
    check("check: a native application that cannot be launched is blocked, not completed",
          noLaunch.verdict?.outcome == .blocked && noLaunch.verdict?.blockReason == .launchFailed && noLaunch.verdict?.outcome.isCompleted == false)

    let stuck = machine(false, [.baselineEstablished, .cannotProceed("n2", .elementNotFound, "No pay button")])
    check("check: a step that cannot be done makes the branch blocked", stuck.verdict?.outcome == .blocked && stuck.verdict?.node == "n2" && stuck.verdict?.blockReason == .elementNotFound)

    let uncovered = machine(true, [.baselineEstablished, .conditionNotAchieved("The delay did not show"), .nodeMet("n1"), .allNodesDone])
    check("check: a condition that was not achieved leaves the branch uncovered", uncovered.verdict?.outcome == .uncovered && uncovered.verdict?.reason == "The delay did not show")
    check("check: ... the branch is not executed and cannot pass afterwards", uncovered.nodesMet.isEmpty && uncovered.ignored.count == 2)
    check("check: an uncovered branch is not completed and makes no bug", uncovered.verdict?.outcome.isCompleted == false && uncovered.verdict?.outcome.createsBug == false)

    let premature = machine(true, [.baselineEstablished, .nodeMet("n1"), .allNodesDone])
    check("check: a branch with a condition cannot run before the condition is verified", premature.verdict == nil && premature.phase == .condition && premature.ignored.count == 2)
    let verified = machine(true, [.baselineEstablished, .conditionVerified, .nodeMet("n1"), .allNodesDone])
    check("check: once the condition is verified the branch runs and can pass", verified.verdict?.outcome == .passed)

    check("check: nothing runs before the baseline", machine(false, [.nodeMet("n1"), .allNodesDone]).verdict == nil)
    check("check: a condition is not verified before the baseline", machine(true, [.conditionVerified, .conditionNotAchieved("x")]).verdict == nil)
    check("check: a branch without a condition goes straight from the baseline to execution", machine(false, [.baselineEstablished]).phase == .execution)

    for phase in [[QACheckEvent](), [.baselineEstablished], [.baselineEstablished, .conditionVerified, .nodeMet("n1")]] {
        let stopped = machine(true, phase + [.interrupted(.stoppedByUser, "Stopped by the person")])
        check("check: a stop is interrupted after \(phase.count) event(s)", stopped.verdict?.outcome == .interrupted && stopped.verdict?.interruption == .stoppedByUser)
    }
    let crash = machine(false, [.baselineEstablished, .interrupted(.applicationCrashed, "The application quit")])
    check("check: an interrupted check is not completed and makes a bug", crash.verdict?.outcome.isCompleted == false && crash.verdict?.outcome.createsBug == true)

    let final = machine(false, [.baselineEstablished, .checkNotMet("n3", "x"), .interrupted(.stoppedByUser, "stop"), .allNodesDone])
    check("check: the first verdict is final", final.verdict?.outcome == .failed && final.ignored.count == 2)
}

do {
    check("outcomes: failed, blocked and interrupted are distinct", Set([QAOutcome.failed, .blocked, .interrupted].map(\.rawValue)).count == 3)
    check("outcomes: bugs for failed, blocked and interrupted only",
          QAOutcome.allCases.filter(\.createsBug) == [.failed, .blocked, .interrupted])
    check("outcomes: each bug title names its outcome",
          QAOutcome.failed.bugTitlePrefix == "QA failed" && QAOutcome.blocked.bugTitlePrefix == "QA blocked" && QAOutcome.interrupted.bugTitlePrefix == "QA interrupted")
    check("outcomes: no title where there is no bug", QAOutcome.passed.bugTitlePrefix == nil && QAOutcome.uncovered.bugTitlePrefix == nil)
    check("outcomes: completed means a verdict about the product", QAOutcome.allCases.filter(\.isCompleted) == [.passed, .failed])
}

// MARK: - A run reports each branch on its own

do {
    func result(_ branch: String, _ outcome: QAOutcome, reason: String = "r") -> QACheckResult {
        QACheckResult(branch: branch, verdict: QACheckVerdict(outcome: outcome, reason: reason), startedAt: now, finishedAt: now)
    }
    var run = QARunRecord(id: "20261109-120000-ab12", scenarioID: "checkout", targetID: "local", targetKind: .local, selected: [main, slow, declined], startedAt: now)
    check("run: every selected branch is listed, none has an outcome yet", run.lines.map(\.branch) == [main, slow, declined] && run.lines.allSatisfy { $0.outcome == nil } && run.pending == 3 && !run.isFinished)
    check("run: a result is stored for its own branch", run.record(result(slow, .failed, reason: "no spinner")))
    check("run: the other branches are not touched", run.lines.map(\.outcome) == [nil, .failed, nil] && run.lines[1].reason == "no spinner")
    check("run: a branch has one result, the first", !run.record(result(slow, .passed)) && run.lines[1].outcome == .failed)
    check("run: a branch that was not selected is refused", !run.record(result("n1>zz", .passed)) && run.results.count == 1)
    run.record(result(main, .passed))
    run.record(result(declined, .uncovered))
    check("run: finished when every selected branch has its result", run.isFinished && run.pending == 0)
    check("run: counts per outcome", run.count(.passed) == 1 && run.count(.failed) == 1 && run.count(.uncovered) == 1 && run.count(.blocked) == 0)
    check("run: the results that become bugs", run.bugResults.map(\.branch) == [slow])
}

// MARK: - Store

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("qa-checks-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    check("store: scenarios are reusable assets under .markview/qa", QAStore.scenariosFolder(root).path.hasSuffix("/.markview/qa/scenarios"))
    check("store: runs are local data under .dde/qa", QAStore.runURL(root, runID: "r1").path.hasSuffix("/.dde/qa/runs/r1/run.json"))
    check("store: an id is a plain file name", QAStore.safeID("Checkout / Card!") == "checkout-card" && QAStore.safeID("../../etc") == "etc" && QAStore.safeID("") == "scenario")
    check("store: an id is not longer than 60 characters", QAStore.safeID(String(repeating: "a", count: 200)).count == 60)
    check("store: a new scenario id is not one in use", QAStore.newScenarioID(title: "Checkout", existing: ["checkout"]) == "checkout-2" && QAStore.newScenarioID(title: "Checkout", existing: ["checkout", "checkout-2"]) == "checkout-3" && QAStore.newScenarioID(title: "Checkout", existing: []) == "checkout")
    let runID = QAStore.newRunID(at: now, suffix: "AB12")
    check("store: a run id carries the time and a suffix", runID.range(of: #"^\d{8}-\d{6}-ab12$"#, options: .regularExpression) != nil)

    let scenario = changed(shop()) { $0.selected = [slow] }
    do {
        try QAStore.saveScenario(scenario, root: root)
        check("store: a scenario is saved under its id", FileManager.default.fileExists(atPath: QAStore.scenariosFolder(root).appendingPathComponent("checkout.json").path))
        let listing = QAStore.loadScenarios(root)
        check("store: a saved scenario with its selection is read back whole", listing.scenarios == [scenario] && listing.unreadable.isEmpty)
    } catch { check("store: scenario saved (\(error))", false) }

    do {
        try QAStore.saveScenario(changed(shop()) { $0.id = "../x" }, root: root)
        check("store: an id that is a path is refused", false)
    } catch { check("store: an id that is a path is refused", (error as? QAStoreError) == .badID("../x")) }

    let folder = QAStore.scenariosFolder(root)
    try? "not json".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
    try? QAStore.save(changed(shop()) { $0.id = "future"; $0.schema = QAScenario.currentSchema + 1 }, to: folder.appendingPathComponent("future.json"))
    try? QAStore.save(changed(shop()) { $0.id = "other" }, to: folder.appendingPathComponent("misnamed.json"))
    let listing = QAStore.loadScenarios(root)
    check("store: only the usable scenario is listed", listing.scenarios.map(\.id) == ["checkout"])
    check("store: a damaged file, a newer one and a misnamed one are each reported", Set(listing.unreadable.map(\.file)) == ["broken.json", "future.json", "misnamed.json"])
    check("store: the reasons are told apart", listing.unreadable.first { $0.file == "future.json" }?.message.contains("newer") == true && listing.unreadable.first { $0.file == "misnamed.json" }?.message.contains("file name") == true)
    check("store: a damaged file is left as it was", (try? String(contentsOf: folder.appendingPathComponent("broken.json"), encoding: .utf8)) == "not json")

    let outside = QAStore.configFolder(root).appendingPathComponent("victim.json")
    try? "keep".write(to: outside, atomically: true, encoding: .utf8)
    QAStore.deleteScenario("../victim", root: root)
    check("store: a path is not a scenario to delete", FileManager.default.fileExists(atPath: outside.path) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("checkout.json").path))
    QAStore.deleteScenario("checkout", root: root)
    check("store: delete removes that scenario only", !FileManager.default.fileExists(atPath: folder.appendingPathComponent("checkout.json").path) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("broken.json").path))

    let first = QARunRecord(id: "20261109-120000-aaaa", scenarioID: "checkout", targetID: "local", targetKind: .local, selected: [main], startedAt: now)
    let second = QARunRecord(id: "20261109-130000-bbbb", scenarioID: "checkout", targetID: "prod", targetKind: .production, selected: [slow], startedAt: now.addingTimeInterval(3600))
    do {
        try QAStore.saveRun(first, root: root)
        try QAStore.saveRun(second, root: root)
        check("store: runs are read back, newest first", QAStore.loadRuns(root).map(\.id) == [second.id, first.id])
        check("store: a run is read by its id", QAStore.loadRun(root, runID: first.id) == first && QAStore.loadRun(root, runID: "../x") == nil)
        let ignore = try? String(contentsOf: QAStore.localFolder(root).appendingPathComponent(".gitignore"), encoding: .utf8)
        check("store: runs are kept out of Git", ignore?.contains("\n*\n") == true)
        try "# mine\n".write(to: QAStore.localFolder(root).appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        QAStore.prepareLocalFolder(root)
        check("store: an edited ignore file is not overwritten", (try? String(contentsOf: QAStore.localFolder(root).appendingPathComponent(".gitignore"), encoding: .utf8)) == "# mine\n")
    } catch { check("store: runs saved (\(error))", false) }
}

// MARK: - Generation: what the AI wrote

func answer(nodes: [[String: Any]]? = nil, edges: [[String: Any]]? = nil, actors: [[String: Any]]? = nil, title: String = "Pay an order") -> [String: Any] {
    func node(_ id: String, _ kind: String, _ title: String, detail: String = "", actor: String = "buyer", changes: String = "no", condition: [String: Any] = [:]) -> [String: Any] {
        var item: [String: Any] = ["id": id, "kind": kind, "title": title, "detail": detail, "actor": actor, "changesData": changes, "conditionKind": "",
                                   "conditionEstablish": "", "conditionVerify": "", "faultUrlPattern": "", "faultMode": "", "faultStatus": 0, "faultMilliseconds": 0]
        for (key, value) in condition { item[key] = value }
        return item
    }
    return [
        "title": title, "start": "n1",
        "actors": actors ?? [["id": "buyer", "name": "Buyer", "createTestAccount": false], ["id": "seller", "name": "Seller", "createTestAccount": true]],
        "nodes": nodes ?? [
            node("n1", "action", "Pay", detail: "Pay the order", changes: "yes"),
            node("n2", "check", "Paid", detail: "The order shows as paid"),
            node("f1", "failure", "Slow payment", detail: "Payment is slow", condition: ["conditionKind": "delay", "conditionEstablish": "Delay /api/pay", "conditionVerify": "The delayed request was seen",
                                                                                   "faultUrlPattern": "/api/pay", "faultMode": "delay", "faultMilliseconds": 5000]),
            node("c1", "check", "Waiting shown", detail: "A waiting indicator is shown"),
        ],
        "edges": edges ?? [["from": "n1", "to": "n2", "label": ""], ["from": "n1", "to": "f1", "label": "slow"], ["from": "f1", "to": "c1", "label": ""]],
    ]
}

do {
    let request = QAGenerationRequest(goal: "A buyer pays an order", appKind: .web,
                                      targets: [QATarget(id: "local", kind: .local, name: "Local", locations: ["app": QALocation(url: "http://localhost:8765")])], now: now)
    let result = QAGeneration.parse(answer(), request: request)
    check("generation: a well-formed answer is a clean scenario", result.isClean && result.scenario.problems().isEmpty)
    check("generation: the title, steps, connections and actors are read",
          result.scenario.title == "Pay an order" && result.scenario.nodes.map(\.id) == ["n1", "n2", "f1", "c1"] && result.scenario.edges.count == 3 && result.scenario.actors.map(\.id) == ["buyer", "seller"])
    check("generation: the goal and the targets are the person's, not the AI's", result.scenario.goal == "A buyer pays an order" && result.scenario.targets == request.targets)
    check("generation: an empty label is no label, a label is kept", result.scenario.edges[0].label == nil && result.scenario.edges[1].label == "slow")
    check("generation: an empty actor means no actor and a data change is read", result.scenario.node("n1")?.changesData == QADataChange.yes && result.scenario.node("n1")?.actor == "buyer")
    check("generation: a network condition is read with its fault",
          result.scenario.node("f1")?.condition == QACondition(kind: .delay, establish: "Delay /api/pay", verify: "The delayed request was seen", fault: QAFault(urlPattern: "/api/pay", mode: .delay, status: nil, milliseconds: 5000)))
    check("generation: no condition kind means no condition", result.scenario.node("n1")?.condition == nil)
    var methodAnswer = answer()
    var methodNodes = methodAnswer["nodes"] as! [[String: Any]]
    methodNodes[2]["faultMethod"] = "post"
    methodAnswer["nodes"] = methodNodes
    check("generation: a fault method is normalized and kept", QAGeneration.parse(methodAnswer, request: request).scenario.node("f1")?.condition?.fault?.method == "POST")
    check("generation: the scenario id comes from the title and is not one in use", result.scenario.id == "pay-an-order")
    check("generation: ... or is made unique", QAGeneration.parse(answer(), request: QAGenerationRequest(goal: "g", appKind: .web, existingIDs: ["pay-an-order"], now: now)).scenario.id == "pay-an-order-2")
    check("generation: a missing target is not the AI's to fix", QAGeneration.parse(answer(), request: QAGenerationRequest(goal: "g", appKind: .web, now: now)).isClean)

    let strange = QAGeneration.parse(answer(nodes: [["id": "n1", "kind": "teleport", "title": "x", "detail": "", "actor": "", "changesData": "no", "conditionKind": "", "conditionEstablish": "", "conditionVerify": "", "faultUrlPattern": "", "faultMode": "", "faultStatus": 0, "faultMilliseconds": 0]], edges: []), request: request)
    check("generation: a step of an unknown kind is reported and left out", strange.parseProblems.contains { $0.contains("teleport") } && strange.scenario.nodes.isEmpty)
    check("generation: ... and the scenario without it cannot run", !strange.isClean && strange.problems.contains { $0.kind == .missingStart })

    var badData = answer()
    var nodes = badData["nodes"] as! [[String: Any]]
    nodes[0]["changesData"] = "maybe"
    nodes[2]["faultMode"] = "explode"
    nodes[3]["conditionKind"] = "weather"
    badData["nodes"] = nodes
    let bad = QAGeneration.parse(badData, request: request)
    check("generation: a data change, a fault mode and a condition kind that are not known are each reported",
          bad.parseProblems.count == 3 && bad.parseProblems.contains { $0.contains("changesData") } && bad.parseProblems.contains { $0.contains("faultMode") } && bad.parseProblems.contains { $0.contains("weather") })

    check("generation: an answer that is not an object is reported", QAGeneration.parse("nonsense", request: request).parseProblems == ["The answer is not a scenario object.", "The scenario has no title."])
    check("generation: nothing at all is reported too", !QAGeneration.parse(nil, request: request).isClean)
    check("generation: a missing title falls back to the goal", QAGeneration.parse(answer(title: ""), request: request).scenario.title == "A buyer pays an order" && !QAGeneration.parse(answer(title: ""), request: request).isClean)
    check("generation: an actor id that is not plain is reported", QAGeneration.parse(answer(actors: [["id": "the buyer", "name": "B", "createTestAccount": false]]), request: request).parseProblems.contains { $0.contains("the buyer") })

    let duplicated = QAGeneration.parse(answer(edges: [["from": "n1", "to": "zz", "label": ""]]), request: request)
    check("generation: what makes the scenario unrunnable is listed with the reason", duplicated.problems.contains { $0.kind == .unknownNode } && duplicated.messages.contains { $0.contains("zz") })

    var many = (0..<(QAGeneration.maxNodes + 1)).map { i -> [String: Any] in
        ["id": "s\(i)", "kind": "action", "title": "t", "detail": "", "actor": "buyer", "changesData": "no", "conditionKind": "", "conditionEstablish": "", "conditionVerify": "",
         "faultUrlPattern": "", "faultMode": "", "faultStatus": 0, "faultMilliseconds": 0]
    }
    let big = QAGeneration.parse(answer(nodes: many, edges: []), request: request)
    check("generation: more steps than allowed are cut and reported", big.scenario.nodes.count == QAGeneration.maxNodes && big.parseProblems.contains { $0.contains("at most") })
    many.removeAll()

    let retry = QAGeneration.retryPrompt(base: "BASE", previous: "{\"title\":\"x\"}", result: duplicated)
    check("generation: a second try carries the request, the earlier answer and each problem", retry.hasPrefix("BASE") && retry.contains("{\"title\":\"x\"}") && retry.contains("- ") && retry.contains("zz"))
    check("generation: the prompt carries the goal and the targets", QAGeneration.prompt(request).contains("A buyer pays an order") && QAGeneration.prompt(request).contains("http://localhost:8765"))
    check("generation: the prompt names the users the person gave",
          QAGeneration.prompt(QAGenerationRequest(goal: "g", appKind: .web, actorNames: ["buyer", "seller"], now: now)).contains("buyer, seller"))
    check("generation: a web prompt allows network faults, a native one does not",
          QAGeneration.systemPrompt(.web).contains("networkFault") && !QAGeneration.systemPrompt(.nativeMacOS).contains("networkFault") && QAGeneration.systemPrompt(.nativeMacOS).contains("native macOS"))

    let schema = QAGeneration.schema
    let props = schema["properties"] as? [String: Any] ?? [:]
    let nodeProps = ((props["nodes"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    check("generation: the schema is valid JSON with its parts", JSONSerialization.isValidJSONObject(schema) && Set(props.keys) == ["title", "summary", "baselineEstablish", "baselineVerify", "baselineManual", "actors", "start", "nodes", "edges"])
    check("generation: the schema offers the node kinds the model knows", ((nodeProps["kind"] as? [String: Any])?["enum"] as? [String]) == QANodeKind.allCases.map(\.rawValue))
    check("generation: ... and the condition kinds, or none", ((nodeProps["conditionKind"] as? [String: Any])?["enum"] as? [String]) == [""] + QAConditionKind.allCases.map(\.rawValue))
    check("generation: the schema has a property for each field the reader uses", Set(nodeProps.keys).isSuperset(of: ["id", "kind", "title", "detail", "actor", "changesData", "conditionKind", "conditionEstablish", "conditionVerify", "faultUrlPattern", "faultMode", "faultStatus", "faultMilliseconds"]))
}

// MARK: - Editing a scenario

do {
    let t1 = now.addingTimeInterval(60), t2 = now.addingTimeInterval(120)
    var scenario = shop()
    check("edit: a new step gets the next free id of its kind", scenario.freshNodeID(prefix: "n") == "n6" && scenario.freshNodeID(prefix: "a") == "a2" && scenario.freshNodeID(prefix: "x") == "x1")
    let added = scenario.addNode(.action, title: "Log out", after: "n5", at: t1)
    check("edit: a step is added after a step and connected from it", added == "n6" && scenario.edges.last == QAEdge(from: "n5", to: "n6") && scenario.node("n6")?.title == "Log out")
    check("edit: ... it belongs to the actor of the step before it", scenario.node("n6")?.actor == "seller")
    check("edit: ... and the change is stamped", scenario.updated == t1 && scenario.problems().isEmpty)
    check("edit: a step added after a step with lines out of it is a fork", changed(shop()) { $0.addNode(.alternative, title: "Empty cart", after: "n1", label: "empty") }.enumerateBranches().branches.count == 4)
    check("edit: an unknown parent adds nothing", changed(shop()) { _ = $0.addNode(.action, title: "x", after: "zz") } == shop())
    check("edit: a step with no parent is refused in a scenario that has steps", changed(shop()) { _ = $0.addNode(.action, title: "x", after: nil) } == shop())
    var empty = QAScenario(id: "e", title: "E", goal: "g", appKind: .web, actors: [QAActor(id: "a", name: "A")], created: now, updated: now)
    let first = empty.addNode(.action, title: "Open", after: nil)
    check("edit: the first step of an empty scenario is its start, for the only actor", first == "n1" && empty.start == "n1" && empty.node("n1")?.actor == "a")

    var inserted = changed(shop()) { $0.selected = [main, declined] }
    let middle = inserted.insertNode(.check, title: "Cart shows one item", between: "n1", and: "n2", at: t2)
    check("edit: a step is put on a connection", middle == "c3" && inserted.edges.contains(QAEdge(from: "n1", to: "c3")) && inserted.edges.contains(QAEdge(from: "c3", to: "n2")) && !inserted.edges.contains(QAEdge(from: "n1", to: "n2")))
    check("edit: ... the selected branches over that connection run over the new step", inserted.selected == ["n1>c3>n2>n3>n4>n5", declined] && inserted.selectedBranches().gone.isEmpty)
    check("edit: ... the branches are still three, and the new check waits for its expectation", inserted.enumerateBranches().branches.count == 3 && kinds(inserted) == [.missingExpectation])
    check("edit: a connection that is not there takes no step", changed(shop()) { _ = $0.insertNode(.check, title: "x", between: "n1", and: "n5") } == shop())

    var removed = changed(shop()) { $0.selected = [main] }
    removed.removeNode("n3", reconnect: true, at: t1)
    check("edit: taking a step out of a line joins the steps around it", removed.edges.contains(QAEdge(from: "n2", to: "n4")) && removed.node("n3") == nil && removed.problems().isEmpty)
    check("edit: ... and the selected branch stays selected without it", removed.selected == ["n1>n2>n4>n5"] && removed.selectedBranches().gone.isEmpty)
    var cut = changed(shop()) { $0.selected = [main] }
    cut.removeNode("n3", reconnect: false)
    check("edit: without joining, the steps after it are left unreachable", kinds(cut).contains(.unreachableNode) && cut.selected.isEmpty)
    var noStart = shop()
    noStart.removeNode("n1", reconnect: false)
    check("edit: removing the start moves it to the next step", noStart.start == "n2")
    var gone = changed(shop()) { $0.selected = [declined] }
    gone.removeNode("a1", reconnect: false)
    check("edit: removing the step of a selected branch drops that branch from the selection", gone.selected.isEmpty && !gone.problems().contains { $0.kind == .selectionGone })
    check("edit: a step that is not there changes nothing", changed(shop()) { $0.removeNode("zz", reconnect: true) } == shop())

    var renamed = shop()
    renamed.update(node: "n1", at: t2) { $0.title = "Add two products"; $0.changesData = .yes }
    check("edit: a step is changed and the change is stamped", renamed.node("n1")?.title == "Add two products" && renamed.node("n1")?.changesData == QADataChange.yes && renamed.updated == t2)

    var joined = shop()
    check("connect: two steps are joined", joined.connect("c2", "n3", label: "recovers") && joined.edges.last == QAEdge(from: "c2", to: "n3", label: "recovers"))
    check("connect: ... two lines meeting make more branches, not a loop", joined.problems().isEmpty && joined.enumerateBranches().branches.count == 3)
    check("connect: not twice", !joined.connect("c2", "n3"))
    func connects(_ from: String, _ to: String) -> Bool { var copy = shop(); return copy.connect(from, to) }
    check("connect: not a step to itself", !connects("n1", "n1"))
    check("connect: not an unknown step", !connects("n1", "zz") && !connects("zz", "n1"))
    var looped = shop()
    check("connect: not a connection that leads a line back to itself", !looped.connect("n5", "n1") && looped == shop())

    var cutLine = changed(shop()) { $0.selected = [slow, main] }
    cutLine.disconnect("f1", "c2", at: t1)
    check("connect: a connection is removed and the branches that ran over it leave the selection", !cutLine.edges.contains(QAEdge(from: "f1", to: "c2")) && cutLine.selected == [main] && cutLine.updated == t1)
    check("connect: removing a connection that is not there changes nothing", changed(shop()) { $0.disconnect("n1", "n5") } == shop())
    var labelled = shop()
    labelled.setLabel("  pays  ", from: "n1", to: "n2")
    check("connect: a label is trimmed", labelled.edges.first { $0.from == "n1" && $0.to == "n2" }?.label == "pays")
    labelled.setLabel("  ", from: "n1", to: "n2")
    check("connect: an empty label is no label", labelled.edges.first { $0.from == "n1" && $0.to == "n2" }?.label == nil)

    var chosen = shop()
    chosen.setSelected(slow, true, at: t1)
    chosen.setSelected(slow, true)
    chosen.setSelected("n1>zz", true)
    check("select: an existing branch is chosen once, one that does not exist is not", chosen.selected == [slow] && chosen.updated == t1)
    chosen.setSelected(slow, false)
    check("select: a branch is dropped", chosen.selected.isEmpty)
    chosen.selectAllBranches()
    check("select: all branches", chosen.selected == [main, slow, declined])
    chosen.clearSelection()
    check("select: none", chosen.selected.isEmpty)
    var repeated = changed(shop()) { $0.selected = [slow, slow, "n1>zz", main] }
    repeated.pruneSelection()
    check("select: pruning keeps the order and drops repeats and branches that are gone", repeated.selected == [slow, main])
}

// MARK: - Where the steps are drawn

do {
    let layout = QAGraphLayout.make(shop())
    func column(_ id: String) -> Int? { layout.node(id)?.column }
    func row(_ id: String) -> Int? { layout.node(id)?.row }
    check("layout: each step is in the column of the longest line to it", ["n1", "n2", "n3", "n4", "n5"].map(column) == [0, 1, 2, 3, 4] && column("a1") == 1 && column("c1") == 2 && column("f1") == 2 && column("c2") == 3)
    check("layout: the main line is the top row", ["n1", "n2", "n3", "n4", "n5"].allSatisfy { row($0) == 0 })
    check("layout: a fork continues on a row of its own", row("f1") == 1 && row("c2") == 1 && row("a1") == 2 && row("c1") == 2)
    let frames = layout.nodes.map(\.frame)
    check("layout: no two steps overlap", frames.indices.allSatisfy { i in frames.indices.allSatisfy { j in i == j || !frames[i].intersects(frames[j]) } })
    check("layout: every step is inside the drawing", frames.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0) })
    check("layout: every connection is drawn once", layout.edges.count == 8 && Set(layout.edges.map(\.id)).count == 8)
    check("layout: a connection leaves the right side of a step and enters the left side of the next",
          layout.edges.allSatisfy { edge in
              guard let from = layout.node(edge.from), let to = layout.node(edge.to) else { return false }
              return edge.curve.first == CGPoint(x: from.frame.maxX, y: from.frame.midY) && edge.curve.last == CGPoint(x: to.frame.minX, y: to.frame.midY)
          })
    check("layout: a click finds the step under it", layout.node(at: CGPoint(x: layout.node("n2")!.frame.midX, y: layout.node("n2")!.frame.midY))?.id == "n2" && layout.node(at: .zero) == nil)
    let wire = layout.edges.first { $0.id == "n1>a1" }!
    check("layout: a click finds the connection near it", layout.edge(near: wire.labelPoint)?.id == "n1>a1" && layout.edge(near: CGPoint(x: -500, y: -500)) == nil)
    check("layout: it is the same every time", QAGraphLayout.make(shop()).nodes == layout.nodes && QAGraphLayout.make(shop()).edges == layout.edges)

    let withLoose = QAGraphLayout.make(changed(shop()) { $0.nodes.append(QANode(id: "lonely", kind: .action, title: "Lonely", actor: "buyer")) })
    let reachedBottom = withLoose.nodes.filter { !$0.loose }.map(\.frame.maxY).max() ?? 0
    check("layout: a step nothing leads to is kept below the graph", withLoose.node("lonely")?.loose == true && (withLoose.node("lonely")?.frame.minY ?? 0) > reachedBottom && withLoose.nodes.count == 10)

    let loop = QAGraphLayout.make(changed(shop()) { $0.edges.append(QAEdge(from: "n3", to: "n1")) })
    check("layout: a loop does not stop the layout and its step is still placed", loop.nodes.count == 9 && column("n3") == 2 && loop.edges.count == 9)
    let back = loop.edges.first { $0.id == "n3>n1" }!
    check("layout: a connection back is drawn under the steps, from the bottom of one to the bottom of the other",
          back.curve.first?.y == loop.node("n3")!.frame.maxY && back.curve.last?.y == loop.node("n1")!.frame.maxY)

    let joined = QAGraphLayout.make(changed(shop()) { $0.connect("c2", "n4") })
    check("layout: a step reached by two lines is in the column of the longer one", joined.node("n4")?.column == 4 && joined.node("n5")?.column == 5)

    let ladderLayout = QAGraphLayout.make(ladder)
    let ladderFrames = ladderLayout.nodes.map(\.frame)
    check("layout: a scenario of dozens of steps is laid out without overlaps", ladderLayout.nodes.count == 37 && ladderFrames.indices.allSatisfy { i in ladderFrames.indices.allSatisfy { j in i == j || !ladderFrames[i].intersects(ladderFrames[j]) } })
    let none = QAGraphLayout.make(QAScenario(id: "e", title: "E", goal: "g", appKind: .web, created: now, updated: now))
    check("layout: an empty scenario has nothing to draw", none.nodes.isEmpty && none.edges.isEmpty && none.size.width > 0)
}

// MARK: - Several applications and players (DEC-018, DEC-019)

/// Three web applications and five players: a shop for customers, a back office for staff and a partner portal.
func platform() -> QAScenario {
    var scenario = shop()
    scenario.id = "platform"
    scenario.apps = [
        QAApp(id: "shop", name: "Shop", profile: .userFacing),
        QAApp(id: "backoffice", name: "Back office", profile: .administration),
        QAApp(id: "partner", name: "Partner portal", profile: .custom, requirements: "Partners see only their own orders."),
    ]
    scenario.actors = [
        QAActor(id: "buyer", name: "Buyer", app: "shop"),
        QAActor(id: "seller", name: "Seller", app: "backoffice"),
        QAActor(id: "admin", name: "Admin", app: "backoffice"),
        QAActor(id: "courier", name: "Courier", app: "partner"),
        QAActor(id: "support", name: "Support", app: "backoffice"),
    ]
    scenario.targets = [QATarget(id: "local", kind: .local, name: "Local", locations: [
        "shop": QALocation(url: "http://localhost:3000"), "backoffice": QALocation(url: "http://localhost:3001"), "partner": QALocation(url: "http://localhost:3002"),
    ])]
    scenario.nodes[4].app = "shop"   // n5: the seller checks the order in the shop, not in their own application
    return scenario
}

do {
    let scenario = platform()
    check("apps: three applications and five players make a scenario with no problems", scenario.problems().isEmpty && scenario.apps.count == 3 && scenario.actors.count == 5)
    check("apps: a step happens in its actor's application", scenario.appID(of: scenario.node("n1")!) == "shop" && scenario.appID(of: scenario.node("n4")!) == "backoffice")
    check("apps: a step may name another application than its actor's", scenario.appID(of: scenario.node("n5")!) == "shop")
    check("apps: the applications of a branch, in order of first appearance", scenario.apps(in: QABranch(nodes: ["n1", "n2", "n3", "n4", "n5"])) == ["shop", "backoffice"] && scenario.apps(in: QABranch(nodes: ["n1", "a1", "c1"])) == ["shop"])
    check("apps: with one application no step needs to name it", shop().nodes.allSatisfy { shop().appID(of: $0) == "shop" })
    check("apps: a step added after a seller's step is the seller's, in the seller's application",
          { var copy = scenario; let id = copy.addNode(.action, title: "Ship", after: "n4")!; return copy.appID(of: copy.node(id)!) == "backoffice" }())
    check("apps: the round trip keeps them", (try? QAStore.decoder.decode(QAScenario.self, from: QAStore.encoder.encode(scenario))) == scenario)

    check("apps: a player who does not say which application they use is a problem when there are several", kinds(changed(scenario) { $0.actors[0].app = nil }) == [.ambiguousApp])
    check("apps: ... named once, for the player, not for each step", changed(scenario) { $0.actors[0].app = nil }.problems().count == 1)
    check("apps: ... but not for a player with no step of their own", kinds(changed(scenario) { $0.actors[0].app = nil; $0.nodes.removeAll { $0.actor == "buyer" }; $0.edges = []; $0.start = "n4" }).contains(.ambiguousApp) == false)
    check("apps: a player of an unknown application", kinds(changed(scenario) { $0.actors[1].app = "ghost" }) == [.unknownApp])
    check("apps: a step in an unknown application", kinds(changed(scenario) { $0.nodes[4].app = "ghost" }) == [.unknownApp])
    check("apps: two applications with one id", kinds(changed(scenario) { $0.apps.append($0.apps[0]) }) == [.duplicateApp])
    check("apps: an application id that is not plain", kinds(changed(scenario) { $0.apps[2].id = "partner portal"; $0.actors[3].app = "partner portal"; $0.targets[0].locations["partner portal"] = $0.targets[0].locations["partner"] }) == [.badID])
    check("apps: no application at all", kinds(changed(shop()) { $0.apps = [] }).contains(.noApp))
    check("apps: an environment that does not say where an application runs", kinds(changed(scenario) { $0.targets[0].locations["partner"] = nil }) == [.incompleteTarget])
    check("apps: ... and which application it is", changed(scenario) { $0.targets[0].locations["partner"] = nil }.problems().first?.message.contains("Partner portal") == true)
    check("apps: an address of the wrong kind in one of them", kinds(changed(scenario) { $0.targets[0].locations["backoffice"]?.url = "ftp://admin.example.com" }) == [.incompleteTarget])
    check("apps: a place for an application that is not listed is ignored", changed(scenario) { $0.targets[0].locations["old"] = QALocation(url: "http://old") }.problems().isEmpty)
    let nativeSet = changed(scenario) {
        $0.appKind = .nativeMacOS
        $0.targets = [QATarget(id: "mac", kind: .local, name: "Mac", locations: ["shop": QALocation(application: QAApplication(bundleIdentifier: "com.example.Shop", name: "Shop")),
                                                                              "backoffice": QALocation(application: QAApplication(bundleIdentifier: "com.example.Admin", name: "Admin")),
                                                                              "partner": QALocation(application: QAApplication(bundleIdentifier: "com.example.Partner", name: "Partner"))])]
    }
    check("apps: native applications are located by installed application, one per application", nativeSet.problems().isEmpty && kinds(changed(nativeSet) { $0.targets[0].locations["partner"]?.application = nil }) == [.incompleteTarget])

    check("profiles: a user-facing application is reviewed for looks, readiness and attention",
          QAReviewProfile.userFacing.presetRequirements.contains("Attractive") && QAReviewProfile.userFacing.presetRequirements.contains("Production-ready") && QAReviewProfile.userFacing.presetRequirements.contains("Holds attention"))
    check("profiles: an administration application is reviewed for speed, economy and automation",
          QAReviewProfile.administration.presetRequirements.contains("Fast") && QAReviewProfile.administration.presetRequirements.contains("Optimal") && QAReviewProfile.administration.presetRequirements.contains("Ready for automation"))
    check("profiles: the presets differ and a custom application starts empty", QAReviewProfile.userFacing.presetRequirements != QAReviewProfile.administration.presetRequirements && QAReviewProfile.custom.presetRequirements.isEmpty)
    check("profiles: an application with no text of its own is reviewed against its profile", scenario.app("shop")?.effectiveRequirements == QAReviewProfile.userFacing.presetRequirements && scenario.app("backoffice")?.effectiveRequirements == QAReviewProfile.administration.presetRequirements)
    check("profiles: the person's text replaces the preset", scenario.app("partner")?.effectiveRequirements == "Partners see only their own orders." && QAApp(id: "x", name: "X", profile: .administration, requirements: "  Mine  ").effectiveRequirements == "Mine")
    check("profiles: speed is measured and automation readiness collected for an administration application only",
          QAReviewProfile.allCases.filter(\.measuresSpeed) == [.administration] && QAReviewProfile.allCases.filter(\.assessesAutomation) == [.administration])
}

// MARK: - Several applications in generation

do {
    let apps = platform().apps
    let request = QAGenerationRequest(goal: "An order travels from the shop to the partner", appKind: .web, apps: apps, targets: platform().targets, now: now)
    let prompt = QAGeneration.prompt(request)
    check("generation: the prompt lists each application with what it is judged as", prompt.contains("shop: Shop [user-facing]") && prompt.contains("backoffice: Back office [administration]") && prompt.contains("partner: Partner portal [custom]"))
    check("generation: ... and where each runs in each environment", prompt.contains("shop at http://localhost:3000; backoffice at http://localhost:3001; partner at http://localhost:3002"))
    check("generation: the system prompt tells the AI to bind players to applications", QAGeneration.systemPrompt(.web).contains("`app`"))

    func node(_ id: String, _ kind: String, _ actor: String, app: String = "", detail: String = "d") -> [String: Any] {
        ["id": id, "kind": kind, "title": id, "detail": detail, "actor": actor, "app": app, "changesData": "no", "conditionKind": "", "conditionEstablish": "", "conditionVerify": "",
         "faultUrlPattern": "", "faultMode": "", "faultStatus": 0, "faultMilliseconds": 0]
    }
    func multi(actors: [[String: Any]]? = nil, nodes: [[String: Any]]? = nil) -> [String: Any] {
        ["title": "Order travels", "start": "n1",
         "actors": actors ?? [["id": "buyer", "name": "Buyer", "app": "shop", "createTestAccount": false], ["id": "seller", "name": "Seller", "app": "backoffice", "createTestAccount": false],
                              ["id": "courier", "name": "Courier", "app": "partner", "createTestAccount": false]],
         "nodes": nodes ?? [node("n1", "action", "buyer"), node("n2", "action", "seller"), node("n3", "check", "courier"), node("n4", "check", "seller", app: "shop")],
         "edges": [["from": "n1", "to": "n2", "label": ""], ["from": "n2", "to": "n3", "label": ""], ["from": "n3", "to": "n4", "label": ""]]]
    }
    let result = QAGeneration.parse(multi(), request: request)
    check("generation: players and steps keep the applications the AI gave them", result.isClean && result.scenario.actors.map(\.app) == ["shop", "backoffice", "partner"] && result.scenario.node("n4")?.app == "shop")
    check("generation: the applications are the person's, not the AI's", result.scenario.apps == apps)
    check("generation: with none named there is one application", QAGeneration.parse(multi(), request: QAGenerationRequest(goal: "g", appKind: .web, now: now)).scenario.apps == [QAApp(id: "app", name: "Application")])
    let wrong = QAGeneration.parse(multi(actors: [["id": "buyer", "name": "Buyer", "app": "kiosk", "createTestAccount": false]], nodes: [node("n1", "action", "buyer")]), request: request)
    check("generation: an application the AI invented is a problem to give back", wrong.problems.contains { $0.kind == .unknownApp } && wrong.messages.contains { $0.contains("kiosk") })
    let silent = QAGeneration.parse(multi(actors: [["id": "buyer", "name": "Buyer", "app": "", "createTestAccount": false]], nodes: [node("n1", "action", "buyer")]), request: request)
    check("generation: a player with no application among several is a problem to give back", silent.problems.contains { $0.kind == .ambiguousApp })
    let schemaProps = QAGeneration.schema["properties"] as? [String: Any] ?? [:]
    let actorProps = ((schemaProps["actors"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    let nodeProps = ((schemaProps["nodes"] as? [String: Any])?["items"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    check("generation: the schema has an application for a player and for a step", actorProps["app"] != nil && nodeProps["app"] != nil)
    let eleven = (0..<(QAGeneration.maxActors + 1)).map { ["id": "p\($0)", "name": "P", "app": "shop", "createTestAccount": false] as [String: Any] }
    check("generation: more players than allowed are cut and reported", QAGeneration.parse(multi(actors: eleven, nodes: [node("n1", "action", "p0")]), request: request).parseProblems.contains { $0.contains("at most") })
}

// MARK: - The baseline in generation

do {
    let request = QAGenerationRequest(goal: "g", appKind: .web, apps: [QAApp(id: "app", name: "App")], now: now)
    var withBaseline = answer(title: "T")
    withBaseline["baselineEstablish"] = "POST /api/reset"
    withBaseline["baselineVerify"] = "GET /api/requests is empty"
    let parsed = QAGeneration.parse(withBaseline, request: request)
    check("generation: the baseline the AI wrote is kept", parsed.scenario.baseline == QACondition(kind: .state, establish: "POST /api/reset", verify: "GET /api/requests is empty"))
    check("generation: no baseline when it wrote none", QAGeneration.parse(answer(title: "T"), request: request).scenario.baseline == nil)
    var half = answer(title: "T")
    half["baselineEstablish"] = "POST /api/reset"
    check("generation: a baseline with no way to verify it is a problem to give back", QAGeneration.parse(half, request: request).problems.contains { $0.kind == .incompleteCondition && $0.subject == "baseline" })
    check("generation: the AI is told about the baseline", QAGeneration.systemPrompt(.web).contains("baselineEstablish"))
    var manualAnswer = answer(title: "T"); manualAnswer["baselineEstablish"] = "Restore the snapshot"; manualAnswer["baselineManual"] = true
    let manualParsed = QAGeneration.parse(manualAnswer, request: request)
    check("manual: the generator may say a baseline is the person's own, and then needs no way to verify it", manualParsed.scenario.baseline?.manual == true && manualParsed.problems.allSatisfy { $0.kind != .incompleteCondition })
    check("manual: and the generator is told what the pages can and cannot do", QAGeneration.systemPrompt(.web).contains("cannot restore a snapshot") && QAGeneration.systemPrompt(.web).contains("createTestAccount true starts with no account"))
}

// MARK: - The layout never lets steps overlap, whatever the graph

do {
    var seed: UInt64 = 20_261_109
    func next(_ bound: Int) -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int((seed >> 33) % UInt64(bound)) }
    var failuresFound = 0, graphs = 0
    for _ in 0..<400 {
        let count = 6 + next(25)
        var scenario = QAScenario(id: "r", title: "R", goal: "g", appKind: .web, apps: [QAApp(id: "app", name: "App")], actors: [QAActor(id: "a", name: "A")], start: "s0", created: now, updated: now)
        scenario.nodes = (0..<count).map { QANode(id: "s\($0)", kind: .action, title: "s\($0)") }
        for i in 1..<count {
            scenario.edges.append(QAEdge(from: "s\(next(i))", to: "s\(i)"))
            if next(3) == 0 { scenario.edges.append(QAEdge(from: "s\(next(i))", to: "s\(i)")) }
            if next(4) == 0 && i + 1 < count { scenario.edges.append(QAEdge(from: "s\(i)", to: "s\(i + 1 + next(count - i - 1))")) }
            if next(12) == 0 { scenario.edges.append(QAEdge(from: "s\(i)", to: "s\(next(i))")) }   // now and then a loop back
        }
        let layout = QAGraphLayout.make(scenario)
        let frames = layout.nodes.map(\.frame)
        let overlap = frames.indices.contains { i in frames.indices.contains { j in i != j && frames[i].intersects(frames[j]) } }
        if overlap || layout.nodes.count != count { failuresFound += 1 }
        graphs += 1
    }
    check("layout: 400 random graphs with merges, long jumps and loops are laid out whole and without overlaps", failuresFound == 0 && graphs == 400)
}

// MARK: - The tries to get a scenario right (QAGenerator)

func runAsync<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error> = .failure(CancellationError())
    Task { do { outcome = .success(try await body()) } catch { outcome = .failure(error) }; done.signal() }
    done.wait()
    return outcome
}

func answerNode(_ id: String, _ kind: String, _ actor: String) -> [String: Any] {
    ["id": id, "kind": kind, "title": id, "detail": "d", "actor": actor, "app": "", "changesData": "no", "conditionKind": "", "conditionEstablish": "", "conditionVerify": "",
     "faultUrlPattern": "", "faultMode": "", "faultStatus": 0, "faultMilliseconds": 0]
}

/// An answer the assistant could give; `actor` is the one the steps use, so a wrong one makes the scenario unsound.
func answer(title: String, actor: String = "a") -> [String: Any] {
    ["title": title, "start": "n1", "actors": [["id": "a", "name": "A", "app": "", "createTestAccount": false]],
     "nodes": [answerNode("n1", "action", actor), answerNode("n2", "check", actor)], "edges": [["from": "n1", "to": "n2", "label": ""]]]
}

final class FakeAssistant {
    var prompts: [String] = []
    var answers: [(structured: Any?, costUSD: Double?)]
    init(_ answers: [(structured: Any?, costUSD: Double?)]) { self.answers = answers }
    func complete(_ prompt: String) async throws -> QAGenerator.Answer {
        prompts.append(prompt)
        let next = answers.isEmpty ? (structured: nil as Any?, costUSD: nil as Double?) : answers.removeFirst()
        return QAGenerator.Answer(structured: next.structured, costUSD: next.costUSD)
    }
}

do {
    let request = QAGenerationRequest(goal: "g", appKind: .web, apps: [QAApp(id: "app", name: "App")], now: now)
    func run(_ assistant: FakeAssistant, attempts: Int = 3, seen: ((Int) -> Void)? = nil) -> Result<QAGenerator.Outcome, Error> {
        runAsync { try await QAGenerator.generate(request, maxAttempts: attempts, onAttempt: seen, complete: assistant.complete) }
    }

    let good = FakeAssistant([(answer(title: "First"), 0.1)])
    let first = try? run(good).get()
    check("generator: a whole answer is taken at the first try", first?.attempts == 1 && first?.remaining.isEmpty == true && good.prompts.count == 1 && first?.scenario.title == "First")
    check("generator: the first prompt is the one made for the request", good.prompts.first == QAGeneration.prompt(request))

    let fixed = FakeAssistant([(answer(title: "Bad", actor: "ghost"), 0.1), (answer(title: "Good"), 0.2)])
    var seen: [Int] = []
    let second = try? run(fixed, seen: { seen.append($0) }).get()
    check("generator: an unsound answer is asked for again", second?.attempts == 2 && second?.scenario.title == "Good" && second?.remaining.isEmpty == true && seen == [1, 2])
    check("generator: the retry carries the problems and the earlier answer", fixed.prompts.count == 2 && fixed.prompts[1].contains("ghost") && fixed.prompts[1].contains("\"title\":\"Bad\"") && fixed.prompts[1].hasPrefix(QAGeneration.prompt(request)))
    check("generator: what the tries cost is added up", abs((second?.costUSD ?? 0) - 0.3) < 0.000_001)

    let never = FakeAssistant([(answer(title: "One", actor: "ghost"), nil), (answer(title: "Two", actor: "ghost"), nil), (answer(title: "Three", actor: "ghost"), nil), (answer(title: "Four"), nil)])
    let gaveUp = try? run(never).get()
    check("generator: after the last try the last scenario comes back with what is wrong", gaveUp?.attempts == 3 && never.prompts.count == 3 && gaveUp?.scenario.title == "Three" && gaveUp?.remaining.isEmpty == false)
    check("generator: no cost is reported when the assistant reports none", gaveUp?.costUSD == nil)

    let silent = FakeAssistant([(nil, nil), (answer(title: "Later"), nil)])
    let afterSilence = try? run(silent).get()
    check("generator: an answer with nothing in it is asked for again", afterSilence?.attempts == 2 && afterSilence?.scenario.title == "Later")

    let once = FakeAssistant([(answer(title: "Bad", actor: "ghost"), nil), (answer(title: "Good"), nil)])
    let single = try? run(once, attempts: 1).get()
    check("generator: one try is one call", single?.attempts == 1 && once.prompts.count == 1 && single?.remaining.isEmpty == false)
    let none = FakeAssistant([(answer(title: "Good"), nil)])
    check("generator: no tries at all still asks once", (try? run(none, attempts: 0).get())?.attempts == 1 && none.prompts.count == 1)

    struct Broken: Error {}
    let failing = runAsync { try await QAGenerator.generate(request, complete: { _ in throw Broken() }) }
    check("generator: an error of the assistant is passed on", { if case .failure(let error) = failing { return error is Broken } else { return false } }())

    let stopped = runAsync { () async throws -> QAGenerator.Outcome in
        let task = Task { () async throws -> QAGenerator.Outcome in
            while !Task.isCancelled { await Task.yield() }   // runs only once it was stopped, so the stop reaches the loop itself
            return try await QAGenerator.generate(request, complete: { _ in QAGenerator.Answer(structured: answer(title: "Never"), costUSD: nil) })
        }
        task.cancel()
        return try await task.value
    }
    check("generator: a stopped generation does not ask again", { if case .failure(let error) = stopped { return error is CancellationError } else { return false } }())
}

// MARK: - The plan of a run and its gate (QAPlanner, QAGate)

do {
    let buyer = QALoginReference(host: "shop.example.com", username: "buyer@example.com")
    let localBuyer = QALoginReference(host: "localhost", username: "buyer")
    var all = shop()
    all.selectAllBranches()
    let main = "n1>n2>n3>n4>n5", slow = "n1>n2>f1>c2", declined = "n1>a1>c1"
    var localAll = changed(all) { $0.actors[0].login = localBuyer }

    func plan(_ scenario: QAScenario, _ target: String? = "local", saved: Set<QALoginReference> = [buyer, localBuyer]) -> QAExecutionPlan {
        QAPlanner.make(scenario, targetID: target, savedLogins: saved)
    }
    func ids(_ steps: [QAPreparationStep]) -> Set<String> { Set(steps.map(\.id)) }
    func problems(_ plan: QAExecutionPlan) -> Set<QAPlanProblem.Kind> { Set(plan.problems.map(\.kind)) }

    // The plan
    let local = plan(localAll)
    check("plan: three branches against a local environment can be approved", local.canBeApproved && local.problems.filter(\.blocks).isEmpty && Set(local.branches.map(\.id)) == [main, slow, declined])
    check("plan: the players the branches use sign in or get a test account", ids(local.preparation).isSuperset(of: ["login:buyer", "account:seller"]))
    check("plan: each condition is a step of its branch; a network fault is brought about by the run itself",
          ids(local.preparation).isSuperset(of: ["condition:\(slow):f1", "condition:\(declined):a1"]) &&
          local.preparation.first { $0.id == "condition:\(slow):f1" }?.automated == true && local.preparation.first { $0.id == "condition:\(declined):a1" }?.automated == false)
    check("plan: a delay does not change data, a data condition may", local.preparation.first { $0.id == "condition:\(slow):f1" }?.changesData == .no && local.preparation.first { $0.id == "condition:\(declined):a1" }?.changesData == .unknown)
    check("plan: a created account changes data, a sign-in does not", local.preparation.first { $0.id == "account:seller" }?.changesData == .yes && local.preparation.first { $0.id == "login:buyer" }?.changesData == .no)
    check("plan: nothing needs a yes of its own outside production", local.confirmations.isEmpty && !local.isProduction)
    var declinedOnly = localAll
    declinedOnly.clearSelection(); declinedOnly.setSelected(declined, true)
    check("plan: only the players of the chosen branches are prepared", !ids(plan(declinedOnly).preparation).contains("account:seller") && ids(plan(declinedOnly).preparation).contains("login:buyer"))

    // Production
    let production = plan(all, "prod")
    check("plan: production is approvable once its logins match", production.isProduction && production.canBeApproved)
    check("plan: on production every action that may change data needs a yes, a check never does, a read-only action neither",
          Set(production.confirmations.map(\.id)) == ["account:seller", "condition:\(declined):a1", "node:n2", "node:a1", "node:f1"])
    check("plan: a confirmation says why", production.confirmations.allSatisfy { !$0.reason.isEmpty && !$0.title.isEmpty })
    check("plan: a baseline reset on production needs a yes for each branch", Set(plan(changed(all) { $0.baseline = QACondition(kind: .state, establish: "Reset", verify: "Empty") }, "prod").confirmations.map(\.id)).isSuperset(of: ["baseline:\(main)", "baseline:\(slow)", "baseline:\(declined)"]))

    // What blocks and what only warns
    check("plan: no environment chosen", problems(plan(localAll, nil)).contains(.noTarget) && !plan(localAll, nil).canBeApproved)
    check("plan: an environment that is not in the scenario", problems(plan(localAll, "ghost")).contains(.unknownTarget) && !plan(localAll, "ghost").canBeApproved)
    check("plan: a scenario without environments", problems(plan(changed(localAll) { $0.targets = [] })).contains(.noTarget))
    check("plan: no branch chosen", problems(plan(changed(localAll) { $0.clearSelection() })).contains(.noBranch) && !plan(changed(localAll) { $0.clearSelection() }).canBeApproved)
    check("plan: a saved login is required", problems(plan(localAll, saved: [])).contains(.loginNotSaved) && !plan(localAll, saved: []).canBeApproved)
    check("plan: a login of another host is refused", problems(plan(all)).contains(.loginHostMismatch) && !plan(all).canBeApproved)
    check("plan: the host is compared as the browser's passwords do", !problems(plan(changed(all) { $0.actors[0].login = QALoginReference(host: "WWW.Shop.Example.com", username: "buyer@example.com") }, "prod", saved: [QALoginReference(host: "WWW.Shop.Example.com", username: "buyer@example.com")])).contains(.loginHostMismatch))
    let anonymous = plan(changed(localAll) { $0.actors[1].createTestAccount = false })
    check("plan: a player without access only warns", problems(anonymous).contains(.actorWithoutAccess) && anonymous.canBeApproved && anonymous.problems.first { $0.kind == .actorWithoutAccess }?.blocks == false)
    check("plan: an unfinished environment that was not chosen does not block", changed(localAll) { $0.targets[1].locations["shop"]?.url = "nonsense" }.problems().contains { $0.kind == .incompleteTarget } && plan(changed(localAll) { $0.targets[1].locations["shop"]?.url = "nonsense" }).canBeApproved)
    check("plan: the chosen one does block", problems(plan(changed(localAll) { $0.targets[0].locations["shop"]?.url = "nonsense" })).contains(.targetIncomplete) && !plan(changed(localAll) { $0.targets[0].locations["shop"]?.url = "nonsense" }).canBeApproved)
    check("plan: an unsound scenario blocks", problems(plan(changed(localAll) { $0.edges.removeAll { $0.to == "n5" } })).contains(.scenarioUnsound) && !plan(changed(localAll) { $0.edges.removeAll { $0.to == "n5" } }).canBeApproved)
    check("plan: checks that change data with no baseline only warn, and only when there are several", problems(local).contains(.noBaseline) && local.canBeApproved && !problems(plan(declinedOnly)).contains(.noBaseline))
    let withBaseline = plan(changed(localAll) { $0.baseline = QACondition(kind: .state, establish: "Reset the demo data", verify: "No requests") })
    check("plan: a baseline is a step of each branch and ends the warning", !problems(withBaseline).contains(.noBaseline) && ids(withBaseline.preparation).isSuperset(of: ["baseline:\(main)", "baseline:\(slow)", "baseline:\(declined)"]))
    check("plan: an unfinished baseline is a problem of the scenario", changed(localAll) { $0.baseline = QACondition(kind: .state, establish: "", verify: "x") }.problems().contains { $0.kind == .incompleteCondition && $0.subject == "baseline" })
    check("plan: a baseline is kept in the file", (try? QAStore.decoder.decode(QAScenario.self, from: QAStore.encoder.encode(changed(localAll) { $0.baseline = QACondition(kind: .state, establish: "a", verify: "b") })))?.baseline?.establish == "a")

    // The fingerprint
    let base = local.fingerprint
    func fp(_ change: (inout QAScenario) -> Void, _ target: String? = "local") -> String { plan(changed(localAll, change), target).fingerprint }
    check("fingerprint: the same plan has the same one", plan(localAll).fingerprint == base && base.count == 64)
    check("fingerprint: a step's text decides what the run does", fp { $0.nodes[0].detail = "Open the other shop" } != base)
    check("fingerprint: whether a step changes data", fp { $0.nodes[0].changesData = .yes } != base)
    check("fingerprint: a new step", fp { _ = $0.addNode(.action, title: "More", after: "n5") } != base)
    check("fingerprint: a connection", fp { $0.disconnect("n1", "a1") } != base)
    check("fingerprint: who signs in", fp { $0.actors[0].login?.username = "other" } != base)
    check("fingerprint: the chosen branches", fp { $0.setSelected(slow, false) } != base)
    check("fingerprint: where the chosen environment is", fp { $0.targets[0].locations["shop"]?.url = "http://localhost:3999" } != base)
    check("fingerprint: the baseline", fp { $0.baseline = QACondition(kind: .state, establish: "Reset", verify: "Empty") } != base)
    check("fingerprint: the condition of a branch", fp { $0.nodes[7].condition?.fault?.milliseconds = 9000 } != base)
    check("fingerprint: a title is only a label", fp { $0.nodes[0].title = "Another title" } == base)
    check("fingerprint: so are the goal, the name of a player and the review text", fp { $0.goal = "Something else"; $0.title = "Else"; $0.actors[0].name = "Someone"; $0.apps[0].requirements = "New text" } == base)
    check("fingerprint: another environment does not count", fp { $0.targets[1].locations["shop"]?.url = "https://other.example.com" } == base)
    check("fingerprint: nor does the date", fp { $0.updated = now.addingTimeInterval(9999) } == base)
    check("fingerprint: nor the order the branches were chosen in", plan(changed(localAll) { $0.selected = Array($0.selected.reversed()) }).fingerprint == base)
    check("fingerprint: another environment is another plan", plan(localAll, "prod").fingerprint != base)

    // The gate
    var gate = QAGate(plan: local)
    check("gate: nothing is allowed before the approval", gate.state == .needsApproval && !gate.canPrepare && gate.decision(for: "login:buyer") == .refused("The plan is not approved."))
    var unsound = QAGate(plan: plan(localAll, nil))
    check("gate: a plan with blocking problems cannot be approved", !unsound.approve(acknowledgedProduction: true) && unsound.state == .needsApproval && !unsound.canPrepare)
    check("gate: approval opens preparation and records when", gate.approve(acknowledgedProduction: false, at: now) && gate.canPrepare && gate.approvedAt == now && gate.approvedFingerprint == base)
    check("gate: outside production everything is then allowed", gate.decision(for: "login:buyer") == .allowed && gate.decision(for: "node:n2") == .allowed && gate.decision(for: "account:seller") == .allowed)

    var prod = QAGate(plan: production)
    check("gate: a production plan is not approved without the person acknowledging it", !prod.approve(acknowledgedProduction: false) && prod.state == .needsApproval && prod.approve(acknowledgedProduction: true) && prod.canPrepare)
    if case .needsConfirmation(let first) = prod.decision(for: "node:n2") { check("gate: an action that changes data waits for a yes", first.id == "node:n2") } else { check("gate: an action that changes data waits for a yes", false) }
    check("gate: a read-only action and a check do not", prod.decision(for: "node:n1") == .allowed && prod.decision(for: "node:n3") == .allowed)
    prod.confirm("node:n2")
    check("gate: a yes is for that one thing", prod.decision(for: "node:n2") == .allowed && { if case .needsConfirmation = prod.decision(for: "node:a1") { return true } else { return false } }())
    prod.confirm("node:bogus")
    check("gate: a yes to something that is not asked is ignored", !prod.confirmed.contains("node:bogus"))
    prod.confirmAllRemaining()
    check("gate: one answer to the whole list", production.confirmations.allSatisfy { prod.decision(for: $0.id) == .allowed })

    // A change after the approval
    var edited = QAGate(plan: production)
    edited.approve(acknowledgedProduction: true); edited.confirm("node:n2")
    edited.update(plan: plan(changed(all) { $0.nodes[1].detail = "Pay with the real card" }, "prod"))
    check("gate: a plan that changed has to be approved again, and the earlier yes is forgotten", edited.state == .needsApproval && !edited.canPrepare && edited.confirmed.isEmpty && edited.approvedAt == nil && edited.decision(for: "node:n2") == .refused("The plan is not approved."))
    var relabelled = QAGate(plan: production)
    relabelled.approve(acknowledgedProduction: true); relabelled.confirm("node:n2")
    relabelled.update(plan: plan(changed(all) { $0.nodes[1].title = "Pay by card" }, "prod"))
    check("gate: a new title is not a new plan", relabelled.canPrepare && relabelled.confirmed == ["node:n2"] && relabelled.plan.confirmations.first { $0.id == "node:n2" }?.title == "Pay by card")
    edited.update(plan: production)
    check("gate: the old plan back does not bring the old approval back", edited.state == .needsApproval)

    // Stop
    var stopped = QAGate(plan: local)
    stopped.approve(acknowledgedProduction: false)
    stopped.stop()
    check("gate: a stopped run allows nothing", stopped.isStopped && !stopped.canPrepare && stopped.decision(for: "login:buyer") == .refused("The run was stopped."))
    check("gate: and cannot be approved or revived", !stopped.approve(acknowledgedProduction: true) && { stopped.update(plan: plan(localAll)); stopped.confirmAllRemaining(); return stopped.isStopped }())
    var stoppedProduction = QAGate(plan: production)
    stoppedProduction.approve(acknowledgedProduction: true)
    stoppedProduction.stop()
    stoppedProduction.confirm("node:n2")
    stoppedProduction.confirmAllRemaining()
    check("gate: a stopped run takes no yes either", stoppedProduction.confirmed.isEmpty && stoppedProduction.decision(for: "node:n2") == .refused("The run was stopped."))
}

// MARK: - What the assistant is asked and what it answers (QAStepPrompt, QAScreen)

do {
    func answer(_ move: String, narration: String = "n", reason: String = "", block: String = "", action: [String: Any]? = nil) -> [String: Any] {
        ["move": move, "narration": narration, "action": action ?? ["kind": "none"], "reason": reason, "blockReason": block]
    }
    func parsed(_ value: Any?, http: Bool = false, kind: QAAppKind = .web) -> QADecision? { try? QAStepPrompt.parse(value, kind: kind, allowsHTTP: http) }
    func fails(_ value: Any?, http: Bool = false, kind: QAAppKind = .web) -> QAStepPrompt.ParseError? {
        do { _ = try QAStepPrompt.parse(value, kind: kind, allowsHTTP: http); return nil } catch { return error as? QAStepPrompt.ParseError }
    }

    check("step answer: an action is read with its narration", parsed(answer("act", narration: "Clicking Pay to send the order", action: ["kind": "click", "ref": "e12"]))
          == QADecision(move: .act(QAAction(kind: .click, ref: "e12")), narration: "Clicking Pay to send the order"))
    check("step answer: a reference written [e12] is e12", parsed(answer("act", action: ["kind": "click", "ref": "[e12]"]))?.move == .act(QAAction(kind: .click, ref: "e12")))
    check("step answer: fill keeps the text as written, spaces included", parsed(answer("act", action: ["kind": "fill", "ref": "e2", "text": " 42 "]))?.move == .act(QAAction(kind: .fill, ref: "e2", text: " 42 ")))
    check("step answer: done", parsed(answer("done", narration: "The order is shown"))?.move == .done)
    check("step answer: not met carries what was seen", parsed(answer("notMet", reason: "No confirmation"))?.move == .notMet("No confirmation"))
    check("step answer: not met with no reason says the narration", parsed(answer("notMet", narration: "Nothing shown"))?.move == .notMet("Nothing shown"))
    check("step answer: blocked carries its reason", parsed(answer("blocked", reason: "Refused", block: "loginFailed"))?.move == .blocked(.loginFailed, "Refused"))
    check("step answer: an unknown block reason is other", parsed(answer("blocked", reason: "x", block: "mystery"))?.move == .blocked(.other, "x"))
    check("step answer: the assistant cannot claim the baseline was not established", parsed(answer("blocked", reason: "x", block: "baselineNotEstablished"))?.move == .blocked(.other, "x"))
    check("step answer: narration is cut to 300 characters", (parsed(answer("done", narration: String(repeating: "x", count: 900)))?.narration.count ?? 0) == 300)
    check("step answer: a click needs an element", fails(answer("act", action: ["kind": "click", "ref": ""])) == .missingRef(.click))
    check("step answer: so does a fill", fails(answer("act", action: ["kind": "fill", "ref": "", "text": "x"])) == .missingRef(.fill))
    check("step answer: a choice needs the option", fails(answer("act", action: ["kind": "select", "ref": "e1", "text": ""])) == .missingText(.select))
    check("step answer: opening a page needs an address", fails(answer("act", action: ["kind": "navigate"])) == .missingURL(.navigate))
    check("step answer: a key needs its name", fails(answer("act", action: ["kind": "key"])) == .missingText(.key))
    check("step answer: an action that is none is no action", fails(answer("act", action: ["kind": "none"])) == .missingAction)
    check("step answer: an act with no action is refused", fails(["move": "act", "narration": "n"]) == .missingAction)
    check("step answer: a step may not send requests of its own", fails(answer("act", action: ["kind": "http", "url": "/api/reset"]), http: false) == .notAllowed(.http))
    check("step answer: preparation may, and a request defaults to GET", parsed(answer("act", action: ["kind": "http", "url": "/api/reset"]), http: true)?.move == .act(QAAction(kind: .http, url: "/api/reset", method: "GET")))
    check("step answer: a method is upper-cased", parsed(answer("act", action: ["kind": "http", "url": "/x", "method": "post"]), http: true)?.move == .act(QAAction(kind: .http, url: "/x", method: "POST")))
    check("step answer: a wait is capped at 30 seconds", parsed(answer("act", action: ["kind": "wait", "amount": 900_000]))?.move == .act(QAAction(kind: .wait, amount: 30_000)))
    check("step answer: an unknown move", fails(answer("dance")) == .unknownMove("dance"))
    check("step answer: not an object", fails("done") == .notAnObject && fails(nil) == .notAnObject)

    let schema = QAStepPrompt.schema
    let properties = schema["properties"] as? [String: Any] ?? [:]
    check("step answer: the schema is valid JSON with the five parts", JSONSerialization.isValidJSONObject(schema) && Set(properties.keys) == ["move", "narration", "action", "reason", "blockReason"])
    check("step answer: every kind of action is offered", {
        let kinds = (((properties["action"] as? [String: Any])?["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String] ?? []
        return Set(kinds) == Set(["none"] + QAActionKind.allCases.map(\.rawValue))
    }())

    // The prompt
    let task = QAStepTask(id: "n2", kind: .act, title: "Pay with a valid card", detail: "Use the test card", actorName: "Buyer", appName: "Shop")
    let page = QAObservation(address: "http://localhost:3000/cart", title: "Cart", snapshot: "[e1] button \"Pay\"\nTotal 12")
    let history = (1...9).map { QAHistoryItem(narration: "n", action: "click [e\($0)]", result: "ok \($0)") }
    let text = QAStepPrompt.prompt(kind: .web, task: task, goal: "A buyer pays", history: history, observation: page)
    check("step prompt: the goal, the application, the player, the step and its details", ["A buyer pays", "Shop", "Buyer", "Pay with a valid card", "Use the test card"].allSatisfy(text.contains))
    check("step prompt: the page", text.contains("http://localhost:3000/cart") && text.contains("Title: Cart") && text.contains("[e1] button \"Pay\""))
    check("step prompt: the last six actions only, with what came of them", text.contains("click [e9] → ok 9") && text.contains("click [e4] → ok 4") && !text.contains("click [e3] → ok 3"))
    let baselineHistory = [QAHistoryItem(narration: "Baseline has two events: /events/old-a and /events/old-b", action: "click [e1]", result: "ok")]
        + (1...9).map { QAHistoryItem(narration: "Navigation \($0)", action: "click [e\($0 + 1)]", result: "ok") }
    let remembered = QAStepPrompt.prompt(kind: .web, task: task, goal: "g", history: baselineHistory, observation: page)
    check("step prompt: recorded baseline survives more than six navigation actions", remembered.contains("Baseline has two events: /events/old-a and /events/old-b"))
    let hugeEvidence = "initial baseline" + String(repeating: "x", count: 30000) + "latest event ID"
    let bounded = QAStepPrompt.boundedEvidence(hugeEvidence)
    check("step prompt: long evidence keeps initial and latest facts and declares omitted material", bounded.hasPrefix("initial baseline") && bounded.hasSuffix("latest event ID") && bounded.contains("evidence omitted") && bounded.count < 12100)
    check("step prompt: the assistant is not told it has a budget of actions", !text.contains("left for this step") && !QAStepPrompt.systemPrompt(.web).contains("actions left"))
    check("step prompt: no history, no history heading", !QAStepPrompt.prompt(kind: .web, task: task, goal: "g", history: [], observation: page).contains("What you did so far"))
    check("step prompt: a check is told to change nothing", QAStepPrompt.prompt(kind: .web, task: QAStepTask(id: "n3", kind: .verify, title: "t", detail: "", actorName: "B", appName: "S"), goal: "g", history: [], observation: page).contains("do not change anything"))
    check("step prompt: requests are allowed only for preparation", text.contains("may not use http") && QAStepPrompt.prompt(kind: .web, task: QAStepTask(id: "s", kind: .act, title: "t", detail: "", actorName: "B", appName: "S", allowsHTTP: true), goal: "g", history: [], observation: page).contains("you may use http"))
    let long = QAObservation(address: "a", title: "t", snapshot: String(repeating: "x", count: 20_000))
    let cut = QAStepPrompt.prompt(kind: .web, task: task, goal: "g", history: [], observation: long)
    check("step prompt: a long page is cut and says so", cut.count < 9000 && cut.contains("the page continues"))
    check("step prompt: the system prompt keeps passwords away from the assistant", QAStepPrompt.systemPrompt(.web).contains("{{password}}") && QAStepPrompt.systemPrompt(.web).contains("Never type, guess or write a real password"))

    // A native application
    let window = QAObservation(address: "app://com.example.shop/Cart", title: "Cart", snapshot: "[e1] button \"Pay\"\nTotal 12")
    let nativeText = QAStepPrompt.prompt(kind: .nativeMacOS, task: task, goal: "A buyer pays", history: [], observation: window)
    check("native step prompt: the window, not a page, and no address", nativeText.contains("Window now:") && nativeText.contains("Title: Cart") && !nativeText.contains("Address:") && !nativeText.contains("app://"))
    check("step prompt: no language named, no language line", !text.contains("Narration language"))
    let named = QAStepPrompt.prompt(kind: .web, task: task, goal: "g", history: [], observation: page, language: "Russian")
    check("step prompt: a named language is asked for outright", named.contains("Narration language: Russian, the language of this scenario. Write the narration in it, whatever language the application is in."))
    check("native step prompt: a named language is asked for too", QAStepPrompt.prompt(kind: .nativeMacOS, task: task, goal: "g", history: [], observation: window, language: "English").contains("Narration language: English"))
    check("language: an English scenario is English", QALanguage.name(ofText: "Sign in to the demo app. A tester signs in to the demo application and chooses a role. Look at the sign-in window.") == "English")
    check("language: a Russian scenario is Russian", QALanguage.name(ofText: "Войти в демонстрационное приложение. Тестировщик входит в приложение и выбирает роль. Посмотреть на окно входа.") == "Russian")
    check("language: a Spanish scenario is Spanish", QALanguage.name(ofText: "Iniciar sesión en la aplicación de demostración. El probador inicia sesión y elige un rol.") == "Spanish")
    check("language: nothing to go by names nothing", QALanguage.name(ofText: "") == nil && QALanguage.name(ofText: "  \n ") == nil)
    var spanishIds = shop()
    spanishIds.id = "es-12"
    check("language: the scenario's own texts decide, not its id", QALanguage.name(of: spanishIds) == "English")
    check("native step prompt: a long window is cut and says so", QAStepPrompt.prompt(kind: .nativeMacOS, task: task, goal: "g", history: [], observation: long).contains("the window continues"))
    check("native step prompt: its own system prompt names the application and the shortcuts", QAStepPrompt.systemPrompt(.nativeMacOS).contains("native macOS application") && QAStepPrompt.systemPrompt(.nativeMacOS).contains("cmd+n"))
    check("native step prompt: it offers no browser actions", !QAStepPrompt.systemPrompt(.nativeMacOS).contains("navigate") && !QAStepPrompt.systemPrompt(.nativeMacOS).contains("http"))
    check("native step prompt: it keeps passwords away from the assistant", QAStepPrompt.systemPrompt(.nativeMacOS).contains("{{password}}") && QAStepPrompt.systemPrompt(.nativeMacOS).contains("Never type, guess or write a real password"))
    check("native step answer: opening an address is refused", fails(answer("act", action: ["kind": "navigate", "url": "http://x"]), kind: .nativeMacOS) == .notAllowed(.navigate))
    check("native step answer: so is a request, even in preparation", fails(answer("act", action: ["kind": "http", "url": "/x"]), http: true, kind: .nativeMacOS) == .notAllowed(.http))
    check("native step answer: a click, a fill and a shortcut are read as on the web", parsed(answer("act", action: ["kind": "key", "text": "cmd+n"]), kind: .nativeMacOS)?.move == .act(QAAction(kind: .key, text: "cmd+n")))

    check("native step answer: scoped read and whole-window reset are accepted", parsed(answer("act", action: ["kind": "inspect", "ref": "e7", "amount": 24]), kind: .nativeMacOS)?.move == .act(QAAction(kind: .inspect, ref: "e7", amount: 24))
          && parsed(answer("act", action: ["kind": "inspect"]), kind: .nativeMacOS)?.move == .act(QAAction(kind: .inspect)))
    check("native step answer: inspection is not offered to a web actor", fails(answer("act", action: ["kind": "inspect", "ref": "e7"]), kind: .web) == .notAllowed(.inspect))

    // Where a player finds its application
    let both = QALocation(url: "http://localhost:3000", application: QAApplication(bundleIdentifier: "com.example.shop", name: "Shop"))
    check("location: a web scenario opens the address, a native one the bundle identifier", both.address(for: .web) == "http://localhost:3000" && both.address(for: .nativeMacOS) == "com.example.shop")
    check("location: nothing chosen for the kind is no address", QALocation(url: "http://x").address(for: .nativeMacOS) == nil && QALocation(application: QAApplication(bundleIdentifier: "a.b", name: "A")).address(for: .web) == nil)

    // What a step costs
    var effort = QAEffort()
    for (kind, expected) in [(QAActionKind.click, "clicks"), (.fill, "fills"), (.select, "fills"), (.scroll, "scrolls"), (.navigate, "loads"), (.key, "keys")] {
        var one = QAEffort()
        QAAction(kind: kind).addEffort(to: &one)
        let counted = [one.clicks, one.fills, one.scrolls, one.loads, one.keys].reduce(0, +)
        check("effort: \(kind.rawValue) is one \(expected)", counted == 1 && one.interactions == 1 && { switch expected { case "clicks": return one.clicks == 1; case "fills": return one.fills == 1; case "scrolls": return one.scrolls == 1; case "loads": return one.loads == 1; default: return one.keys == 1 } }())
        QAAction(kind: kind).addEffort(to: &effort)
    }
    QAAction(kind: .wait).addEffort(to: &effort)
    QAAction(kind: .http).addEffort(to: &effort)
    check("effort: waiting and the runner's own requests cost a person nothing", effort.interactions == 6 && effort.clicks == 1 && effort.fills == 2)
    check("effort: efforts add up", (QAEffort(clicks: 1, fills: 2, scrolls: 3, loads: 4, keys: 5, screens: 6, milliseconds: 7) + QAEffort(clicks: 10, milliseconds: 100))
          == QAEffort(clicks: 11, fills: 2, scrolls: 3, loads: 4, keys: 5, screens: 6, milliseconds: 107))

    // Which screen is this
    let a = QAScreen.signature(address: "http://x/orders?page=2#top", snapshot: "[e1] button \"Open 3\"\nOrders 12")
    check("screen: the same screen has the same signature whatever the numbers, the references and the query", a == QAScreen.signature(address: "http://x/orders?page=9", snapshot: "[e7] button \"Open 8\"\nOrders 40"))
    check("screen: another address is another screen", a != QAScreen.signature(address: "http://x/cart", snapshot: "[e1] button \"Open 3\"\nOrders 12"))
    check("screen: other content is another screen", a != QAScreen.signature(address: "http://x/orders", snapshot: "[e1] button \"Open 3\"\nOrders 12\nA new row"))
}

// MARK: - A player's sign-in (QACredentials)

do {
    let both = QACredentials(username: "alice", password: "alice-test-pass")
    check("credentials: both placeholders are filled, wherever and as often as they stand", both.fill("{{username}}/{{password}} then {{username}} again") == "alice/alice-test-pass then alice again")
    check("credentials: text with no placeholder is left alone", both.fill("Pay 12 EUR") == "Pay 12 EUR")
    check("credentials: a placeholder of another name is left as written", both.fill("{{token}}") == "{{token}}")
    check("credentials: without a password its placeholder stays, so nothing is made up", QACredentials(username: "alice", password: nil).fill("{{username}} {{password}}") == "alice {{password}}")
    check("credentials: without a user name likewise", QACredentials(username: nil, password: "secret1").fill("{{username}} {{password}}") == "{{username}} secret1")
    check("credentials: a password in the page's answer is scrubbed everywhere", both.scrub("typed alice-test-pass, echo alice-test-pass") == "typed \(QACredentials.mask), echo \(QACredentials.mask)")
    check("credentials: the user name is not a secret", both.scrub("alice signed in") == "alice signed in")
    check("credentials: a password shorter than three characters is not scrubbed (it would blot out words)", QACredentials(username: nil, password: "ab").scrub("about a table") == "about a table")
    check("credentials: three characters are scrubbed", QACredentials(username: nil, password: "abc").scrub("xabcx") == "x\(QACredentials.mask)x")
    check("credentials: no password, nothing to scrub", QACredentials(username: "a", password: nil).scrub("text") == "text" && QACredentials(username: nil, password: "").scrub("text") == "text")
    check("credentials: a placeholder this player has no value for is reported, so it is never typed as it stands", QACredentials(username: "alice", password: nil).unfilled("{{username}} {{password}}") == ["{{password}}"] && QACredentials(username: nil, password: nil).unfilled("{{username}} {{password}}") == ["{{username}}", "{{password}}"])
    check("credentials: nothing is unfilled when the player has both, or the text has no placeholder", both.unfilled("{{username}} {{password}}").isEmpty && QACredentials(username: nil, password: nil).unfilled("plain").isEmpty)
    check("credentials: what was filled in never survives scrubbing", !both.scrub(both.fill("{{password}}")).contains("alice-test-pass"))
}

// MARK: - A run (QARunner), with a browser and an assistant made up for the check

enum RunTestError: Error, LocalizedError {
    case refused
    var errorDescription: String? { "refused" }
}

final class FakeDriver: QAActorDriver {
    let request: QADriverRequest
    var opened: [String] = []
    var performed: [QAAction] = []
    var failing: Set<String> = []
    var armed: [QAFault] = []
    var hits = 0
    var closed = false
    var evidence: QAPageEvidence?
    var measured = 0
    var viewportOnly = false
    var scrollLimit: Int?
    private var changes = 0
    init(_ request: QADriverRequest) { self.request = request }
    func open(_ address: String) async throws { opened.append(address) }
    func observe() async throws -> QAObservation {
        QAObservation(address: request.address + "/page", title: "Page", snapshot: "view " + String(repeating: "x", count: viewportOnly ? 1 : changes + 1) + "\n[e1] button \"Go\"", positionSignature: viewportOnly ? String(changes) : "")
    }
    func perform(_ action: QAAction) async throws -> String {
        if failing.contains(action.summary) { throw RunTestError.refused }
        performed.append(action)
        if action.kind != .http && action.kind != .wait { changes = min(changes + 1, scrollLimit ?? Int.max) }
        return "ok"
    }
    func screenshot() async -> Data? { Data([1, 2, 3]) }
    func arm(_ fault: QAFault) async throws { armed.append(fault) }
    func faultHits() async -> Int { hits }
    func measure() async -> QAPageEvidence? { measured += 1; return evidence }
    func close() async { closed = true }
}

final class FakeFactory: QADriverFactory {
    var drivers: [FakeDriver] = []
    var failFor: Set<String> = []
    var failing: Set<String> = []
    var hits = 0
    var evidence: QAPageEvidence?
    var viewportOnly = false
    var scrollLimit: Int?
    func makeDriver(_ request: QADriverRequest) async throws -> QAActorDriver {
        if failFor.contains(request.actor?.id ?? "setup") { throw RunTestError.refused }
        let driver = FakeDriver(request)
        driver.viewportOnly = viewportOnly
        driver.scrollLimit = scrollLimit
        driver.failing = failing
        driver.evidence = evidence
        driver.hits = hits
        drivers.append(driver)
        return driver
    }
    func driver(_ actor: String?) -> FakeDriver? { drivers.first { $0.request.actor?.id == actor } }
}

final class ScriptedAssistant: QAAssistant {
    var script: [String: [[String: Any]]]
    var prompts: [String] = []
    var systems: [String] = []
    var failure: Error?
    var cancelOnCall: Int?
    var respond: ((String) -> [String: Any]?)?
    private var calls = 0
    init(_ script: [String: [[String: Any]]] = [:]) { self.script = script }
    func decide(system: String, prompt: String, schema: [String: Any]) async throws -> Any? {
        calls += 1
        prompts.append(prompt)
        systems.append(system)
        if let failure { throw failure }
        if calls == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        if let response = respond?(prompt) { return response }
        for title in script.keys where prompt.contains("): \(title)\n") {
            if var queue = script[title], !queue.isEmpty { let next = queue.removeFirst(); script[title] = queue; return next }
        }
        return ["move": "done", "narration": "Done.", "action": ["kind": "none"], "reason": "", "blockReason": ""] as [String: Any]
    }
    func asked(_ title: String) -> Bool { prompts.contains { $0.contains("): \(title)\n") } }
}

final class Recorder: QARunObserver {
    var events: [QARunEvent] = []
    var onEvent: ((QARunEvent) -> Void)?
    func handle(_ event: QARunEvent) { events.append(event); onEvent?(event) }
    var narrations: [QATimelineEntry] { events.compactMap { if case .narration(let entry) = $0 { return entry } else { return nil } } }
    var shown: [QAScreenEvent] { events.compactMap { if case .screen(let screen) = $0 { return screen } else { return nil } } }
    var screens: [(isNew: Bool, png: Data?)] { shown.map { ($0.isNew, $0.png) } }
}

func move(_ kind: String, _ ref: String = "e1", text: String = "", url: String = "", method: String = "", _ narration: String = "Doing it") -> [String: Any] {
    ["move": "act", "narration": narration, "action": ["kind": kind, "ref": ref, "text": text, "url": url, "method": method, "direction": "", "amount": 0], "reason": "", "blockReason": ""]
}
func finished(_ narration: String = "Done.") -> [String: Any] { ["move": "done", "narration": narration, "action": ["kind": "none"], "reason": "", "blockReason": ""] }
func notMet(_ reason: String) -> [String: Any] { ["move": "notMet", "narration": "Looking", "action": ["kind": "none"], "reason": reason, "blockReason": ""] }
func stuck(_ reason: String, _ block: String) -> [String: Any] { ["move": "blocked", "narration": "Stuck", "action": ["kind": "none"], "reason": reason, "blockReason": block] }

do {
    let mainLine = "n1>n2>n3>n4>n5", slow = "n1>n2>f1>c2", declined = "n1>a1>c1"
    let localBuyer = QALoginReference(host: "localhost", username: "buyer")
    let local = changed(shop()) { $0.actors[0].login = localBuyer }

    struct Setup {
        var record: QARunRecord
        var factory: FakeFactory
        var assistant: ScriptedAssistant
        var recorder: Recorder
        var asked: [String]
        var gate: QAGate
        var result: QACheckResult? { record.results.first }
    }

    func run(scenario: QAScenario = local, target: String = "local", branches: [String] = [mainLine], script: [String: [[String: Any]]] = [:],
             saved: Set<QALoginReference> = [localBuyer], approve: Bool = true, confirm: Bool = true, config: QARunner.Config = QARunner.Config(),
             control: QARunControl = QARunControl(), sessions: QARunSessions = QARunSessions(),
             observe: ((QARunEvent) -> Void)? = nil,
             prepare: (FakeFactory, ScriptedAssistant) -> Void = { _, _ in }) -> Setup {
        var scenario = scenario
        scenario.clearSelection()
        for branch in branches { scenario.setSelected(branch, true) }
        let plan = QAPlanner.make(scenario, targetID: target, savedLogins: saved)
        var gate = QAGate(plan: plan)
        if approve { gate.approve(acknowledgedProduction: true) }
        let factory = FakeFactory(), assistant = ScriptedAssistant(script), recorder = Recorder()
        prepare(factory, assistant)
        recorder.onEvent = observe
        var asked: [String] = []
        var tick = 0.0
        let runner = QARunner(scenario: scenario, plan: plan, gate: gate, factory: factory, assistant: assistant, runID: "r1",
                              confirm: { confirmation in asked.append(confirmation.id); return confirm }, observer: recorder,
                              now: { tick += 1; return now.addingTimeInterval(tick) }, config: config, control: control, sessions: sessions)
        let record = (try? runAsync { await runner.run() }.get()) ?? QARunRecord(id: "lost", scenarioID: "", targetID: "", targetKind: .local, selected: [], startedAt: now)
        return Setup(record: record, factory: factory, assistant: assistant, recorder: recorder, asked: asked, gate: runner.gate)
    }

    // A run that passes
    let okScript: [String: [[String: Any]]] = [
        "Add a product to the cart": [move("click", "e1"), finished("The product is in the cart")],
        "Pay with a valid card": [move("fill", "e2", text: "4242"), move("click", "e3"), finished()],
        "Open the order list": [move("navigate", url: "/orders"), finished()],
    ]
    let ok = run(script: okScript)
    let passed = ok.result
    check("run: a branch whose steps all hold passes", passed?.verdict.outcome == .passed && ok.record.isFinished && ok.record.results.count == 1)
    check("run: the scenario's language is named in every step prompt", !ok.assistant.prompts.isEmpty && ok.assistant.prompts.allSatisfy { $0.contains("Narration language: English") })
    check("run: every step was met, in order", passed?.nodesMet == ["n1", "n2", "n3", "n4", "n5"])
    check("run: what the person would have done is counted: two clicks, one field, one page load", passed?.effort.clicks == 2 && passed?.effort.fills == 1 && passed?.effort.loads == 1 && passed?.effort.keys == 0 && passed?.effort.scrolls == 0)
    check("run: each step has its own count", passed?.steps.map(\.node) == ["n1", "n2", "n3", "n4", "n5"] && passed?.steps[0].effort.clicks == 1 && passed?.steps[1].effort.fills == 1 && passed?.steps[1].effort.clicks == 1 && passed?.steps[2].effort.interactions == 0)
    check("run: the branch's count is the sum of its steps", passed.map { result in result.steps.reduce(QAEffort()) { $0 + $1.effort }.interactions == result.effort.interactions && result.steps.reduce(0) { $0 + $1.effort.milliseconds } == result.effort.milliseconds } == true)
    check("run: time is measured from the clock", (passed?.steps.allSatisfy { $0.effort.milliseconds > 0 && $0.effort.milliseconds % 1000 == 0 }) == true)
    check("run: the screens a step reached are counted", (passed?.effort.screens ?? 0) >= 3)
    check("run: the actor's driver got the actor's saved login, the other none", ok.factory.driver("buyer")?.request.login == localBuyer && ok.factory.driver("seller")?.request.login == nil)
    check("run: each player has a session of its own, opened at the environment's address", ok.factory.drivers.count == 2 && ok.factory.drivers.allSatisfy { $0.opened == ["http://localhost:3000"] })
    check("run: the sessions are closed when the branch ends", ok.factory.drivers.allSatisfy(\.closed))
    check("run: actions reach the right session", ok.factory.driver("buyer")?.performed.map(\.kind) == [.click, .fill, .click] && ok.factory.driver("seller")?.performed.map(\.kind) == [.navigate])
    check("run: the buyer signs in and the seller gets an account before the steps", ok.assistant.prompts.first?.contains("Sign in as Buyer") == true && ok.assistant.prompts.contains { $0.contains("Create a new test account for Seller") })
    check("run: a check is told to change nothing, an action is not", ok.assistant.prompts.first { $0.contains("): Confirmation is shown\n") }?.contains("a check: do not change anything") == true && ok.assistant.prompts.first { $0.contains("): Pay with a valid card\n") }?.contains("an action") == true)
    check("run: the sign-in is told to use placeholders, never real values", ok.assistant.prompts.first?.contains("{{username}} and {{password}}") == true)

    let rememberedRun = run(script: [
        "Add a product to the cart": [move("click", "e1", "Baseline: /events/old-a and /events/old-b")]
            + (1...8).map { _ in move("click", "e1", "Continue browsing") }
            + [finished("New event /events/new-c; marker QA-PACKAGE-123")],
    ])
    let sellerPrompt = rememberedRun.assistant.prompts.first { $0.contains("Step (an action): Open the order list\n") } ?? ""
    check("run: another player receives the baseline and new event from the customer's completed step", sellerPrompt.contains("/events/old-a") && sellerPrompt.contains("/events/old-b") && sellerPrompt.contains("/events/new-c") && sellerPrompt.contains("QA-PACKAGE-123"))
    check("run: a later check receives evidence across step and player changes", rememberedRun.assistant.prompts.first { $0.contains("Step (a check: do not change anything): The order is listed\n") }?.contains("QA-PACKAGE-123") == true)
    check("run: account preparation is not retained as shared scenario evidence", !(rememberedRun.assistant.prompts.first { $0.contains("Step (an action): Add a product to the cart\n") } ?? "").contains("Completed steps in this branch"))

    // Preparation and the first common step must see the selected branch's data, before any steps finish.
    let mapped = changed(local) { scenario in
        scenario.nodes[0].detail = "Data map: main order ORDER-MAIN; declined order ORDER-DECLINED. Use the order for the selected branch."
        scenario.nodes[2].condition = QACondition(kind: .data, establish: "Prepare ORDER-MAIN", verify: "ORDER-MAIN ready")
        scenario.nodes[5].condition = QACondition(kind: .data, establish: "Prepare ORDER-DECLINED", verify: "ORDER-DECLINED ready")
    }
    let mappedRun = run(scenario: mapped, branches: [mainLine, declined], script: [
        "Bring about the condition": [move("click", "e1"), finished(), move("click", "e1"), finished()]
    ], prepare: { _, assistant in
        assistant.respond = { prompt in
            guard prompt.contains("Step (an action): Add a product to the cart\n") else { return nil }
            if prompt.contains("What you did so far in this step:") { return finished() }
            return move("fill", "e1", text: prompt.contains("Active branch ID: \(declined)") ? "ORDER-DECLINED" : "ORDER-MAIN")
        }
    })
    let prepPrompts = mappedRun.assistant.prompts.filter { $0.contains("Step (an action): Bring about the condition\n") }
    let firstPrompts = mappedRun.assistant.prompts.filter { $0.contains("Step (an action): Add a product to the cart\n") }
    check("run: preparation sees branch ID, path, initial data map and its condition before the first step", prepPrompts.contains { $0.contains("Active branch ID: \(declined)") && $0.contains("ORDER-DECLINED") && $0.contains("Data map:") && !$0.contains("Prepare ORDER-MAIN") })
    check("run: both first shared steps see their own branch and data map", firstPrompts.count == 4 && firstPrompts.contains { $0.contains("Active branch ID: \(mainLine)") && $0.contains("Prepare ORDER-MAIN") && !$0.contains("Prepare ORDER-DECLINED") } && firstPrompts.contains { $0.contains("Active branch ID: \(declined)") && $0.contains("Prepare ORDER-DECLINED") && !$0.contains("Prepare ORDER-MAIN") })
    let buyerDrivers = mappedRun.factory.drivers.filter { $0.request.actor?.id == "buyer" }
    check("run: each branch acts on its own order from the first common step", buyerDrivers.count == 2 && buyerDrivers[0].performed.contains { $0.text == "ORDER-MAIN" } && buyerDrivers[1].performed.contains { $0.text == "ORDER-DECLINED" })
    check("run: branch path is reference and future steps must not be executed", firstPrompts.allSatisfy { $0.contains("Execute ONLY the current task") && $0.contains("Do not execute future steps") && $0.contains("Ordered branch path (reference only)") })
    let declineDriver = mappedRun.factory.drivers.filter { $0.request.actor?.id == "buyer" }.last
    check("run: condition uses the signed-in player's existing driver and saved login", declineDriver?.request.login == localBuyer && declineDriver?.performed.contains(where: { $0.kind == .click }) == true && mappedRun.factory.drivers.filter { $0.request.actor?.id == "buyer" }.count == 2 && mappedRun.factory.driver(nil) == nil)
    let unassigned = changed(mapped) { $0.nodes[5].actor = nil }
    let unassignedRun = run(scenario: unassigned, branches: [declined], script: ["Bring about the condition": [move("click", "e1"), finished()]])
    check("run: a condition without an assigned player still uses the setup session", unassignedRun.factory.driver(nil)?.performed.contains(where: { $0.kind == .click }) == true)

    // A native macOS scenario runs through the same loop, with the application's own words
    let nativeShop = changed(local) { scenario in
        scenario.appKind = .nativeMacOS
        scenario.targets = [QATarget(id: "local", kind: .local, name: "Local",
                                     locations: ["shop": QALocation(application: QAApplication(bundleIdentifier: "com.example.shop", name: "Shop"))])]
        scenario.actors[0].login = nil
    }
    let native = run(scenario: nativeShop, script: okScript.merging(["Open the order list": [move("key", text: "cmd+o"), finished()]]) { _, new in new }, saved: [])
    check("native run: a branch whose steps all hold passes", native.result?.verdict.outcome == .passed && native.result?.nodesMet == ["n1", "n2", "n3", "n4", "n5"])
    check("native run: each player's application is opened by its bundle identifier", native.factory.drivers.count == 2 && native.factory.drivers.allSatisfy { $0.opened == ["com.example.shop"] && $0.request.address == "com.example.shop" })
    check("native run: the assistant is told it drives a native application and sees a window, not a page", native.assistant.systems.allSatisfy { $0.contains("native macOS application") } && native.assistant.prompts.allSatisfy { $0.contains("Window now:") && !$0.contains("Page now:") })
    check("native run: a browser action is not accepted, the turn is asked again", {
        let asked = run(scenario: nativeShop, script: ["Add a product to the cart": [move("navigate", url: "http://x"), move("click", "e1"), finished()]], saved: [])
        return asked.factory.driver("buyer")?.performed.map(\.kind) == [.click] && asked.result?.verdict.outcome == .passed
    }())
    check("native run: an environment with no application for it says where the problem is", {
        let missing = changed(nativeShop) { $0.targets[0].locations["shop"] = QALocation(url: "http://localhost:3000") }
        return !missing.problems().isEmpty
    }())
    check("web run: still opens the web address and tells the assistant about a browser", ok.assistant.systems.allSatisfy { $0.contains("web application") } && ok.assistant.prompts.allSatisfy { $0.contains("Page now:") })

    let nativeAttached = changed(nativeShop) { scenario in
        scenario.actors = [scenario.actors[0]]
        for i in scenario.nodes.indices where scenario.nodes[i].actor != nil { scenario.nodes[i].actor = scenario.actors[0].id }
        scenario.targets[0].locations["shop"]?.application?.startupPolicy = .attach
    }
    let attachedData = try? QAStore.encoder.encode(nativeAttached)
    let attachedBack = attachedData.flatMap { try? QAStore.decoder.decode(QAScenario.self, from: $0) }
    check("native policy: old scenarios launch and explicit attachment round-trips", nativeShop.targets[0].locations["shop"]?.application?.effectiveStartupPolicy == .launch && attachedBack == nativeAttached)
    check("scenario conflict: unchanged file may be saved", !QAStore.scenarioChangedOnDisk(expected: nativeAttached, data: attachedData, exists: true))
    var fractional = nativeAttached; fractional.updated = Date(timeIntervalSince1970: 1_790_000_000.75)
    check("scenario conflict: the encoder's date precision does not cause a false conflict", !QAStore.scenarioChangedOnDisk(expected: fractional, data: try? QAStore.encoder.encode(fractional), exists: true))
    check("scenario conflict: external edits, unreadable data and deletion are preserved", QAStore.scenarioChangedOnDisk(expected: nativeShop, data: attachedData, exists: true) && QAStore.scenarioChangedOnDisk(expected: nativeShop, data: Data("bad".utf8), exists: true) && QAStore.scenarioChangedOnDisk(expected: nativeShop, data: nil, exists: false))
    check("scenario conflict: an already existing file is never treated as new", QAStore.scenarioChangedOnDisk(expected: nil, data: attachedData, exists: true))
    check("native policy: policy changes the approved plan fingerprint", QAPlanner.fingerprint(nativeShop, target: nativeShop.targets[0], branches: []) != QAPlanner.fingerprint(nativeAttached, target: nativeAttached.targets[0], branches: []))
    var nativeKeep = QARunner.Config(); nativeKeep.keepSessions = true
    let attachedSessions = QARunSessions()
    let attached = run(scenario: nativeAttached, branches: [mainLine, declined], config: nativeKeep, sessions: attachedSessions)
    check("native policy: sequential branches reuse one attached player", attached.factory.drivers.count == 1 && attached.factory.drivers.first?.request.startupPolicy == .attach)
    _ = runAsync { await attachedSessions.close() }

    // What is told
    let lines = ok.record.timeline
    check("run: the timeline is the story: preparation, actions, what was seen, the result", lines.first?.kind == .preparation && lines.contains { $0.kind == .action && $0.text.contains("Buyer: Doing it") } && lines.last?.kind == .result && lines.last?.text == "Passed: Every step and check held.")
    check("run: every line has its place in time, in order", lines.map(\.id) == Array(1...lines.count) && zip(lines, lines.dropFirst()).allSatisfy { $0.time <= $1.time } && (lines.last?.time ?? 0) > (lines.first?.time ?? 0) && lines.allSatisfy { $0.branch == mainLine })
    check("run: with two players a line says whose turn it is", lines.contains { $0.text.hasPrefix("Buyer: ") } && lines.contains { $0.text.hasPrefix("Seller: ") })
    check("run: the run record carries the timeline", ok.record.timeline == ok.recorder.narrations)
    check("run: a step with no narration is told in the action's own words", run(script: ["Add a product to the cart": [move("click", "e5", "")]]).record.timeline.contains { $0.text.contains("click [e5]") })
    check("run: with one player no name is put in front", run(scenario: changed(local) { $0.actors = [$0.actors[0]]; $0.nodes[3].actor = "buyer"; $0.nodes[4].actor = "buyer" }, script: ["Add a product to the cart": [move("click", "e5", "Opening")]]).record.timeline.contains { $0.text == "Opening" })

    let events = ok.recorder.events
    check("run: the observer hears the run start, then the branch, then the steps, then the end", {
        guard case .runStarted(let id, let branches)? = events.first, id == "r1", branches == [mainLine] else { return false }
        guard case .runFinished(let record)? = events.last, record == ok.record else { return false }
        let names = events.map { event -> String in switch event { case .branchStarted: return "branch"; case .nodeStarted: return "start"; case .nodeFinished: return "end"; case .branchFinished: return "done"; default: return "" } }.filter { !$0.isEmpty }
        return names.first == "branch" && names.last == "done" && names.filter { $0 == "start" }.count == 5 && names.filter { $0 == "end" }.count == 5
    }())
    check("run: every turn shows the observer the page and a picture; the first look at a screen is new", ok.recorder.screens.count >= 8 && ok.recorder.screens.allSatisfy { $0.png == Data([1, 2, 3]) } && ok.recorder.screens.first?.isNew == true)
    check("run: pictures can be left out", run(config: { var c = QARunner.Config(); c.captureFrames = false; return c }()).recorder.screens.allSatisfy { $0.png == nil })

    let inputEvents = ok.recorder.events.compactMap { event -> (String?, QAInputMark, Data?)? in
        if case .input(let actor, let mark, let png) = event { return (actor, mark, png) }; return nil
    }
    check("input: every executed action has a pre-input picture and the correct player", !inputEvents.isEmpty && inputEvents.allSatisfy { $0.2 == Data([1,2,3]) && $0.0 != nil })
    check("input: markers carry semantics without typed values", inputEvents.contains { $0.1.kind == .fill && $0.1.label == "Type text" })
    var noInputs = QARunner.Config(); noInputs.captureInputs = false
    check("input: video annotations can be disabled", !run(script: okScript, config: noInputs).recorder.events.contains { if case .input = $0 { return true }; return false })

    var tailConfig = QARunner.Config(); tailConfig.startPoint = QAStartPoint(branch: mainLine, node: "n3")
    let tail = run(config: tailConfig)
    check("restart: only the chosen tail runs and no preparation repeats", tail.result?.nodesMet == ["n3", "n4", "n5"] && !tail.assistant.asked("Restore the baseline") && !tail.assistant.asked("Sign in as Buyer"))
    check("restart: skipped steps never become a full pass", tail.result?.verdict.outcome == .uncovered && tail.result?.skippedNodes == ["n1", "n2"] && tail.record.startPoint == tailConfig.startPoint)
    var invalidStart = tailConfig; invalidStart.startPoint = QAStartPoint(branch: mainLine, node: "missing")
    check("restart: an invalid start opens no application", run(config: invalidStart).factory.drivers.isEmpty)
    check("restart: starting mid-scenario still requires approval", run(approve: false, config: tailConfig).factory.drivers.isEmpty)
    let retained = QARunSessions()
    var keep = QARunner.Config(); keep.keepSessions = true
    let beforeRetry = run(config: keep, sessions: retained)
    check("restart: sessions remain live for an explicit continuation", !beforeRetry.factory.drivers.isEmpty && beforeRetry.factory.drivers.allSatisfy { !$0.closed })
    let afterRetry = run(config: tailConfig, sessions: retained)
    check("restart: continuation reuses existing players without reopening", afterRetry.factory.drivers.isEmpty && afterRetry.result?.nodesMet == ["n3", "n4", "n5"])
    _ = runAsync { await retained.close() }
    check("restart: releasing retained sessions closes every player", beforeRetry.factory.drivers.allSatisfy(\.closed))
    let pauseControl = QARunControl()
    var sawPause = false
    let resumed = run(control: pauseControl, observe: { event in
        if case .nodeStarted(_, "n1", _, _) = event { pauseControl.pause() }
        if case .paused(true) = event { sawPause = true; DispatchQueue.global().async { pauseControl.resume() } }
    })
    check("pause: execution acknowledges pause and resumes all steps", sawPause && resumed.result?.verdict.outcome == .passed && resumed.recorder.events.contains { if case .paused(false) = $0 { return true }; return false })
    let jumpControl = QARunControl()
    let jumped = run(control: jumpControl, observe: { event in
        if case .nodeStarted(_, "n1", _, _) = event { jumpControl.pause() }
        if case .paused(true) = event { DispatchQueue.global().async { jumpControl.resume(at: "n4") } }
    })
    check("pause: continuing at another step uses the same run and marks omissions", jumped.result?.nodesMet == ["n4", "n5"] && jumped.result?.verdict.outcome == .uncovered && !jumped.assistant.asked("Add a product to the cart"))
    let stopControl = QARunControl()
    let stoppedPaused = run(control: stopControl, observe: { event in
        if case .nodeStarted(_, "n1", _, _) = event { stopControl.pause() }
        if case .paused(true) = event { DispatchQueue.global().async { stopControl.stop() } }
    })
    check("pause: Stop wakes a paused runner without executing input", stoppedPaused.result?.verdict.outcome == .interrupted && stoppedPaused.factory.drivers.allSatisfy { $0.performed.isEmpty && $0.closed })

    // What the review is given with each new screen
    var dirty = QAPageEvidence()
    dirty.smallText = QAPageEvidence.Tally(count: 2, samples: ["p 9px"])
    let measured = run(script: okScript, prepare: { factory, _ in factory.evidence = dirty })
    let shownScreens = measured.recorder.shown
    check("run: a new screen of a step comes with what was measured in the page", shownScreens.contains { $0.isNew && $0.node != nil && $0.evidence == dirty })
    check("run: a screen that is not new is not measured again", shownScreens.filter { !$0.isNew }.allSatisfy { $0.evidence == nil })
    check("run: preparation screens are not measured", shownScreens.filter { $0.node == nil }.allSatisfy { $0.evidence == nil })
    check("run: each screen is told what its step has cost so far and what the branch has", shownScreens.contains { $0.node == "n2" && $0.stepEffort.clicks == 1 } && shownScreens.contains { $0.node == "n2" && $0.branchEffort.clicks > $0.stepEffort.clicks || $0.node == "n2" && $0.branchEffort.clicks == 1 })
    check("run: the effort of the branch only grows", zip(shownScreens.filter { $0.node != nil }, shownScreens.filter { $0.node != nil }.dropFirst()).allSatisfy { $0.branchEffort.interactions <= $1.branchEffort.interactions })
    var noMeasuring = QARunner.Config(); noMeasuring.measureScreens = false
    check("run: measuring can be switched off", run(script: okScript, config: noMeasuring, prepare: { factory, _ in factory.evidence = dirty }).factory.drivers.allSatisfy { $0.measured == 0 })
    check("run: and when on, every driver is asked", measured.factory.drivers.contains { $0.measured > 0 })
    check("run: a driver that cannot measure gives no evidence", ok.recorder.shown.allSatisfy { $0.evidence == nil })

    // A check that does not hold, a step that cannot be done
    let failed = run(script: ["Confirmation is shown": [notMet("No confirmation, an error page is shown")]])
    check("run: an expectation that does not hold fails the branch at that step", failed.result?.verdict.outcome == .failed && failed.result?.verdict.node == "n3" && failed.result?.verdict.reason == "No confirmation, an error page is shown")
    check("run: the steps before it were met and the steps after it never ran", failed.result?.nodesMet == ["n1", "n2"] && !failed.assistant.asked("Open the order list") && !failed.assistant.asked("The order is listed"))
    check("run: even a failed check shows its count", failed.result?.steps.map(\.node) == ["n1", "n2", "n3"])
    let blocked = run(script: ["Pay with a valid card": [stuck("There is no pay button", "elementNotFound")]])
    check("run: a step that cannot be done blocks the branch with the assistant's reason", blocked.result?.verdict.outcome == .blocked && blocked.result?.verdict.blockReason == .elementNotFound && blocked.result?.verdict.node == "n2" && blocked.result?.verdict.reason == "There is no pay button")
    // A step has no cap on its actions: only going in circles ends it
    let endless = run(script: ["Add a product to the cart": Array(repeating: move("wait"), count: 10)])
    check("run: a step that does the same thing on a page that does not change is given up as going in circles", endless.result?.verdict.blockReason == .stepStuck && endless.result?.verdict.outcome == .blocked
          && endless.factory.driver("buyer")?.performed.count == 3 && endless.result?.verdict.reason.contains("going in circles") == true)
    let longForm = run(script: ["Add a product to the cart": (1...30).map { move("fill", "e\($0)", text: "value \($0)") } + [finished("The long form is filled")]])
    check("run: a long step is not cut: thirty different actions that move the page on, then it is done", longForm.result?.verdict.outcome == .passed && longForm.factory.driver("buyer")?.performed.count == 30 && longForm.result?.steps.first?.effort.fills == 30)
    let sameClick = run(script: ["Add a product to the cart": Array(repeating: move("click", "e1"), count: 10) + [finished()]])
    check("run: the same click on a page that changes each time is progress, not a loop", sameClick.result?.verdict.outcome == .passed && sameClick.factory.driver("buyer")?.performed.count == 10)
    let scrolling = run(script: ["Add a product to the cart": Array(repeating: move("scroll"), count: 10) + [finished()]], prepare: { factory, _ in factory.viewportOnly = true })
    check("run: scrolling through unchanged DOM text remains progress", scrolling.result?.verdict.outcome == .passed && scrolling.factory.driver("buyer")?.performed.count == 10)
    let bottom = run(script: ["Add a product to the cart": Array(repeating: move("scroll"), count: 10)], prepare: { factory, _ in factory.viewportOnly = true; factory.scrollLimit = 2 })
    check("run: repeated scrolling at the bottom still blocks", bottom.result?.verdict.blockReason == .stepStuck && bottom.factory.driver("buyer")?.performed.count == 5)
    var patient = QARunner.Config(); patient.maxRepeats = 2
    check("run: how many repeats are allowed is a setting", run(script: ["Add a product to the cart": Array(repeating: move("wait"), count: 10)], config: patient).factory.driver("buyer")?.performed.count == 1)

    // Actions that fail, answers that cannot be used
    let giveUp = run(script: ["Add a product to the cart": Array(repeating: move("click", "e9"), count: 6)], prepare: { factory, _ in factory.failing = ["click [e9]"] })
    check("run: an action that keeps failing blocks the step as an element that is not there", giveUp.result?.verdict.blockReason == .elementNotFound && giveUp.result?.verdict.node == "n1" && giveUp.result?.steps.first?.effort.clicks == 0 && giveUp.result?.verdict.reason.contains("failed 3 times") == true)
    let failedInputs = giveUp.recorder.events.compactMap { event -> QAInputMark? in if case .input(_, let mark, _) = event { return mark }; return nil }
    check("input: failed attempts have explicit failure annotations", failedInputs.filter(\.failed).count == 3 && failedInputs.filter { !$0.failed }.count == 3)
    check("run: a screen that did not change is not new the second time", giveUp.recorder.screens.contains { !$0.isNew } && giveUp.recorder.screens.first?.isNew == true)
    check("run: and the assistant was told each time it failed", giveUp.assistant.prompts.contains { $0.contains("click [e9] → failed: refused") })
    let retried = run(script: ["Add a product to the cart": [move("click", "e9"), move("click", "e1"), finished()]], prepare: { factory, _ in factory.failing = ["click [e9]"] })
    check("run: an action that failed once is not the end, and only the one that worked is counted", retried.result?.verdict.outcome == .passed && retried.result?.steps.first?.effort.clicks == 1)
    let confused = run(script: ["Add a product to the cart": [["move": "dance"], ["move": "act", "narration": "x", "action": ["kind": "click", "ref": ""]], ["move": "dance"], finished()]])
    check("run: answers that cannot be used are asked for again, a few times", confused.result?.verdict.blockReason == .other && confused.result?.verdict.reason == "The assistant's answers could not be used." && confused.result?.verdict.node == "n1")
    let twice = run(script: ["Add a product to the cart": [["move": "dance"], ["move": "dance"], finished()]])
    check("run: two such answers in a row are still forgiven", twice.result?.verdict.outcome == .passed)
    let spread = run(script: ["Add a product to the cart": [["move": "dance"], move("click"), ["move": "dance"], move("click"), ["move": "dance"], finished()]])
    check("run: a usable answer clears the count of unusable ones", spread.result?.verdict.outcome == .passed)
    let slip = run(script: ["Add a product to the cart": [["move": "dance"], finished()]])
    check("run: one such answer does not matter, and the assistant is told to answer again", slip.result?.verdict.outcome == .passed && slip.assistant.prompts.contains { $0.contains("(unusable answer)") })
    let down = run(prepare: { _, assistant in assistant.failure = RunTestError.refused })
    check("run: an assistant that does not answer blocks the check with why", down.result?.verdict.outcome == .blocked && down.result?.verdict.reason.contains("did not answer") == true)
    let sneaky = run(script: ["Add a product to the cart": [move("http", url: "/api/reset", method: "POST"), move("http", url: "/api/reset", method: "POST"), move("http", url: "/api/reset", method: "POST")]])
    check("run: a step of the scenario cannot send requests of its own", sneaky.result?.verdict.outcome == .blocked && sneaky.factory.drivers.allSatisfy { $0.performed.allSatisfy { $0.kind != .http } })

    // Baseline, sign-in, launch
    let withBaseline = changed(local) { $0.baseline = QACondition(kind: .state, establish: "POST /api/reset", verify: "GET /api/orders is empty") }
    let reset = run(scenario: withBaseline, script: ["Restore the baseline": [move("http", url: "/api/reset", method: "POST"), finished()], "Confirm: restore the baseline": [finished()]])
    check("run: the baseline is restored by a session of nobody's, with the person's words, before anything else", reset.factory.drivers.first?.request.actor == nil && reset.factory.drivers.first?.performed.map(\.kind) == [.http]
          && reset.assistant.prompts.first?.contains("POST /api/reset") == true && reset.result?.verdict.outcome == .passed)
    check("run: the baseline is confirmed with the person's other words", reset.assistant.prompts.contains { $0.contains("GET /api/orders is empty") })
    check("run: preparation is not counted as the person's effort", reset.result?.effort.interactions == 0)
    let unreset = run(scenario: withBaseline, script: ["Confirm: restore the baseline": [notMet("The list still has orders")]])
    check("run: a baseline that is not confirmed blocks the check before any step", unreset.result?.verdict.outcome == .blocked && unreset.result?.verdict.blockReason == .baselineNotEstablished && !unreset.assistant.asked("Add a product to the cart") && unreset.result?.nodesMet.isEmpty == true)
    let unopened = run(scenario: withBaseline, prepare: { factory, _ in factory.failFor = ["setup"] })
    check("run: a baseline that cannot even open the application is a launch failure, not an unestablished baseline",
          unopened.result?.verdict.outcome == .blocked && unopened.result?.verdict.blockReason == .launchFailed && !unopened.assistant.asked("Add a product to the cart"))
    let lost = run(scenario: withBaseline, script: ["Restore the baseline": [stuck("The server is down", "other")]])
    check("run: a baseline that cannot be restored blocks the check", lost.result?.verdict.blockReason == .baselineNotEstablished && lost.result?.verdict.reason.hasPrefix("The server is down") == true && lost.result?.verdict.reason.contains("I restore it myself") == true)
    // A baseline only a person can bring about (a snapshot restore): the run asks them and does not hand it to the page assistant.
    let manualBaseline = changed(local) { $0.baseline = QACondition(kind: .state, establish: "Restore the approved snapshot of the test environment", verify: "", manual: true) }
    let manualPlan = QAPlanner.make({ var s = manualBaseline; s.clearSelection(); s.setSelected(mainLine, true); return s }(), targetID: "local", savedLogins: [localBuyer])
    check("manual: the plan lists the baseline as the person's own step and asks for their word on every target, local too",
          manualPlan.preparation.first { $0.id == "baseline:\(mainLine)" }?.manual == true && manualPlan.confirmations.first { $0.id == "baseline:\(mainLine)" }?.manual == true && manualPlan.target?.kind == .local)
    check("manual: a baseline the pages can restore needs no word on a local environment", QAPlanner.make({ var s = withBaseline; s.clearSelection(); s.setSelected(mainLine, true); return s }(), targetID: "local", savedLogins: [localBuyer]).confirmations.isEmpty)
    check("manual: a manual baseline needs no way to verify it, a page baseline still does", manualBaseline.problems().allSatisfy { $0.kind != .incompleteCondition } && !changed(manualBaseline) { $0.baseline?.manual = nil }.problems().filter { $0.kind == .incompleteCondition }.isEmpty)
    check("manual: the flag is part of what an approval covers", QAPlanner.fingerprint(manualBaseline, target: nil, branches: []) != QAPlanner.fingerprint(changed(manualBaseline) { $0.baseline?.manual = nil }, target: nil, branches: []))
    check("manual: a file written before the flag existed still loads", (try? QAStore.decoder.decode(QAScenario.self, from: QAStore.encoder.encode(withBaseline)))?.baseline?.manual == nil
          && (try? JSONDecoder().decode(QACondition.self, from: Data(#"{"kind":"state","establish":"a","verify":"b"}"#.utf8)))?.isManual == false)
    let manualRun = run(scenario: manualBaseline, script: okScript)
    check("manual: the person is asked first and the run goes on when they say it is done", manualRun.asked == ["baseline:\(mainLine)"] && manualRun.result?.verdict.outcome == .passed)
    check("manual: the page assistant is never asked to restore it", !manualRun.assistant.asked("Restore the baseline") && !manualRun.assistant.asked("Confirm: restore the baseline") && !manualRun.assistant.prompts.contains { $0.contains("Restore the approved snapshot") })
    check("manual: the timeline says the person did it", manualRun.record.timeline.contains { $0.kind == .preparation && $0.text.hasPrefix("Baseline restored by the person") })
    let manualDeclined = run(scenario: manualBaseline, script: okScript, confirm: false)
    check("manual: when they say no, the check is blocked before any step", manualDeclined.result?.verdict.outcome == .blocked && manualDeclined.result?.nodesMet.isEmpty == true && !manualDeclined.assistant.asked("Add a product to the cart"))
    let manualCondition = changed(local) { s in
        s.nodes[s.nodes.firstIndex { $0.id == "f1" }!].condition = QACondition(kind: .state, establish: "Switch the payment gateway to its failing mode", verify: "", manual: true)
    }
    let manualConditionRun = run(scenario: manualCondition, branches: [slow], script: [:])
    check("manual: a condition only a person can set is asked, not tried by the page assistant", manualConditionRun.asked.contains("condition:\(slow):f1") && !manualConditionRun.assistant.asked("Bring about the condition") && manualConditionRun.assistant.prompts.contains { $0.contains("person handles this condition") })
    let refusedLogin = run(script: ["Sign in as Buyer": [stuck("The password was refused", "loginFailed")]])
    check("run: a refused sign-in blocks the check before any step", refusedLogin.result?.verdict.blockReason == .loginFailed && refusedLogin.result?.verdict.outcome == .blocked && !refusedLogin.assistant.asked("Add a product to the cart"))
    let noAccount = run(script: ["Create a new test account for Seller and sign in": [stuck("Sign-up is closed", "other")]])
    check("run: an account that cannot be created blocks the check", noAccount.result?.verdict.outcome == .blocked && noAccount.result?.verdict.reason == "Sign-up is closed")
    let noLaunch = run(prepare: { factory, _ in factory.failFor = ["buyer"] })
    check("run: an application that cannot be opened blocks the check as a launch failure, never as a pass", noLaunch.result?.verdict.blockReason == .launchFailed && noLaunch.result?.verdict.outcome == .blocked && noLaunch.result?.nodesMet.isEmpty == true)
    let noAddress = run(scenario: changed(local) { $0.targets[0].locations = [:] })
    check("run: an environment with no address for the application blocks the check", noAddress.result?.verdict.outcome == .blocked)

    // Conditions
    let condition = run(branches: [declined], script: ["Bring about the condition": [move("http", url: "/api/decline-card", method: "POST"), finished()], "Confirm: bring about the condition": [finished()]])
    check("run: a data condition is brought about by the person's words and then confirmed, before the steps", condition.result?.verdict.outcome == .passed
          && condition.assistant.prompts.contains { $0.contains("Use the decline test card") } && condition.assistant.prompts.contains { $0.contains("The card field holds the decline test card") })
    let unmet = run(branches: [declined], script: ["Confirm: bring about the condition": [notMet("The card field is empty")]])
    check("run: a condition that is not achieved leaves the branch uncovered, and no step ran", unmet.result?.verdict.outcome == .uncovered && unmet.result?.verdict.reason == "The card field is empty" && unmet.result?.nodesMet.isEmpty == true && !unmet.assistant.asked("Decline message"))
    let delayed = run(branches: [slow], prepare: { factory, _ in factory.hits = 1 })
    check("run: a network fault is armed in the player's own session before the steps", delayed.factory.driver("buyer")?.armed == [QAFault(urlPattern: "/api/pay", mode: .delay, milliseconds: 8000)] && delayed.result?.verdict.outcome == .passed)
    let unhit = run(branches: [slow], prepare: { factory, _ in factory.hits = 0 })
    check("run: a fault that was never met leaves the branch uncovered, even though every step held", unhit.result?.verdict.outcome == .uncovered && unhit.result?.verdict.reason.contains("never met") == true && unhit.result?.nodesMet.count == 4)
    let unhitAndFailed = run(branches: [slow], script: ["Waiting indicator": [notMet("No indicator")]], prepare: { factory, _ in factory.hits = 0 })
    check("run: a step that fails is a failure, whether or not the fault was met", unhitAndFailed.result?.verdict.outcome == .failed)
    check("run: a branch with no fault arms nothing", ok.factory.drivers.allSatisfy { $0.armed.isEmpty })

    // Several branches, and a stop
    let several = run(branches: [mainLine, declined, slow], script: ["Confirmation is shown": [notMet("No confirmation")]], prepare: { factory, _ in factory.hits = 1 })
    check("run: each branch is a check of its own, with its own outcome", several.record.results.map(\.verdict.outcome) == [.failed, .passed, .passed] && several.record.isFinished && several.record.selected == [mainLine, declined, slow])
    check("run: each branch starts from fresh sessions", several.factory.drivers.count == 4 && several.factory.drivers.allSatisfy(\.closed) && several.factory.drivers.allSatisfy { $0.opened.count == 1 })
    let isolatedContext = run(branches: [mainLine, declined], script: ["Add a product to the cart": [finished("Only the first branch: QA-PACKAGE-first")]])
    let newBranchPrompt = isolatedContext.assistant.prompts.last { $0.contains("Step (an action): Add a product to the cart\n") } ?? ""
    check("run: a new branch never inherits a previous branch's event or marker", !newBranchPrompt.isEmpty && !newBranchPrompt.contains("QA-PACKAGE-first") && !newBranchPrompt.contains("Completed steps in this branch"))
    check("run: the branches' counts are separate", several.record.results[0].steps.count == 3 && several.record.results[1].steps.count == 3)
    let stopped = run(branches: [mainLine, declined, slow], prepare: { _, assistant in assistant.cancelOnCall = 4 })
    check("run: stopping interrupts the branch in progress", stopped.record.results.first?.verdict.outcome == .interrupted && stopped.record.results.first?.verdict.interruption == .stoppedByUser)
    check("run: and leaves the ones not started uncovered, never failed", stopped.record.results.dropFirst().allSatisfy { $0.verdict.outcome == .uncovered && $0.verdict.reason.contains("stopped") } && stopped.record.isFinished)
    check("run: a stopped run still closes its sessions", stopped.factory.drivers.allSatisfy(\.closed))
    check("run: interrupted checks make bugs, uncovered ones do not", stopped.record.bugResults.count == 1)

    let abandoned = run(branches: [mainLine, declined], prepare: { _, assistant in assistant.failure = CancellationError() })
    check("run: a stop that reaches the assistant while the run's own task lives on still leaves the later branches uncovered",
          abandoned.record.results.first?.verdict.interruption == .stoppedByUser && abandoned.record.results.dropFirst().allSatisfy { $0.verdict.outcome == .uncovered })

    // The gate
    let prodScenario = shop()
    let prodBuyer = QALoginReference(host: "shop.example.com", username: "buyer@example.com")
    let unapproved = run(scenario: prodScenario, target: "prod", saved: [prodBuyer], approve: false)
    check("run: nothing is touched before the plan is approved", unapproved.result?.verdict.blockReason == .approvalMissing && unapproved.result?.verdict.outcome == .blocked && unapproved.factory.drivers.isEmpty && unapproved.assistant.prompts.isEmpty)
    check("run: and the person is told it was the missing approval", unapproved.result?.verdict.reason == "The plan was not approved.")
    let production = run(scenario: prodScenario, target: "prod", saved: [prodBuyer])
    check("run: on production each action that may change data waits for a yes, in order, and once", production.asked == ["account:seller", "node:n2"] && production.result?.verdict.outcome == .passed)
    check("run: a yes is remembered by the gate", production.gate.confirmed == ["account:seller", "node:n2"])
    let declinedYes = run(scenario: prodScenario, target: "prod", saved: [prodBuyer], confirm: false)
    check("run: without the yes the check is blocked as unapproved, and the account was never created", declinedYes.result?.verdict.blockReason == .approvalMissing && declinedYes.factory.drivers.allSatisfy { $0.request.actor?.id != "seller" } && !declinedYes.assistant.prompts.contains { $0.contains("Create a new test account") })
    check("run: a gate that was stopped refuses everything", { () -> Bool in
        let plan = QAPlanner.make(changed(local) { $0.clearSelection(); $0.setSelected(mainLine, true) }, targetID: "local", savedLogins: [localBuyer])
        var gate = QAGate(plan: plan)
        gate.approve(acknowledgedProduction: true)
        gate.stop()
        let factory = FakeFactory()
        let runner = QARunner(scenario: changed(local) { $0.clearSelection(); $0.setSelected(mainLine, true) }, plan: plan, gate: gate, factory: factory, assistant: ScriptedAssistant(), runID: "r2", confirm: { _ in true })
        let record = try? runAsync { await runner.run() }.get()
        return record?.results.first?.verdict.blockReason == .approvalMissing && factory.drivers.isEmpty
    }())

    // The record
    let stored = try? QAStore.decoder.decode(QARunRecord.self, from: QAStore.encoder.encode(ok.record))
    check("run: the record, its counts and its timeline survive being saved", stored == ok.record && stored?.results.first?.effort.clicks == 2 && stored?.timeline.isEmpty == false)

    // The machine's late verdict
    var machine = QACheckMachine(conditionRequired: false)
    machine.apply(.baselineEstablished)
    machine.apply(.nodeMet("n1"))
    machine.apply(.conditionNotAchieved("The fault was never met"))
    check("machine: a condition that cannot be confirmed before the steps may be found unmet after them", machine.verdict?.outcome == .uncovered && machine.nodesMet == ["n1"])
    machine.apply(.nodeMet("n2"))
    check("machine: and then nothing more is taken", machine.nodesMet == ["n1"] && machine.ignored.count == 1)
}

// Copying a scenario, starting one from another, and the material attached to a new one
do {
    let original = shop()
    let at = Date(timeIntervalSince1970: 2_000_000_000)
    let copy = original.duplicated(existingIDs: [original.id], at: at)
    check("copy: a new id, a title that says it is a copy, fresh dates", copy.id != original.id && copy.title == original.title + " (copy)" && copy.created == at && copy.updated == at)
    check("copy: the same steps, connections, players, applications and chosen branches", copy.nodes == original.nodes && copy.edges == original.edges && copy.actors == original.actors && copy.apps == original.apps && copy.selected == original.selected && copy.start == original.start)
    check("copy: it is a valid scenario of its own", copy.problems().isEmpty)
    let second = original.duplicated(existingIDs: [original.id, copy.id])
    check("copy: copying twice never reuses an id", second.id != copy.id && second.id != original.id)
    var untitled = original
    untitled.title = ""
    check("copy: a scenario without a title is named after its id", untitled.duplicated(existingIDs: []).title == untitled.id + " (copy)")

    let plain = QAGenerationRequest(goal: "Buy a ticket", appKind: .web)
    check("prompt: without a base or files it is the goal as before", !QAGeneration.prompt(plain).contains("Base scenario") && !QAGeneration.prompt(plain).contains("Material the person attached") && QAGeneration.prompt(plain).hasPrefix("Goal of the test:\nBuy a ticket"))
    var based = plain
    based.base = original
    let basedPrompt = QAGeneration.prompt(based)
    check("prompt: a base scenario is given whole, and the goal is what changes", basedPrompt.contains("Base scenario") && basedPrompt.contains(original.nodes[0].id) && basedPrompt.contains("what changes compared with the base scenario") && !basedPrompt.hasPrefix("Goal of the test:"))
    var withFiles = plain
    withFiles.attachmentPaths = ["docs/screens/cart.png", ".dde/qa/inputs/x/1-spec.pdf"]
    let filesPrompt = QAGeneration.prompt(withFiles)
    check("prompt: attached files are listed by path for the assistant to read", filesPrompt.contains("- docs/screens/cart.png") && filesPrompt.contains("- .dde/qa/inputs/x/1-spec.pdf"))

    let fm = FileManager.default
    let sandbox = fm.temporaryDirectory.appendingPathComponent("qa-attach-" + UUID().uuidString, isDirectory: true)
    let project = sandbox.appendingPathComponent("project", isDirectory: true)
    let elsewhere = sandbox.appendingPathComponent("elsewhere", isDirectory: true)
    try? fm.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: sandbox) }
    let inside = project.appendingPathComponent("docs/spec.md")
    let insideImage = project.appendingPathComponent("docs/cart.png")
    let outsideImage = elsewhere.appendingPathComponent("pasted:image.PNG")
    let outsideNote = elsewhere.appendingPathComponent(".notes.txt")
    for file in [inside, insideImage, outsideImage, outsideNote] { try? Data("x".utf8).write(to: file) }

    let staged = try? QAAttachments.stage([inside, insideImage, outsideImage, outsideNote, inside], root: project, id: "run 1")
    check("files: a file of the project is named by its path and is not copied, a repeated one counts once", staged?.paths.prefix(2) == ["docs/spec.md", "docs/cart.png"] && staged?.paths.count == 4)
    check("files: a file from outside is copied under .dde/qa/inputs and named relative to the project", staged?.paths[2].hasPrefix(".dde/qa/inputs/run-1/3-") == true && staged?.paths[3].hasPrefix(".dde/qa/inputs/run-1/4-") == true && staged?.copies != nil)
    check("files: the copy has a plain name (no colon, no leading dot) and its content", staged?.paths[2].hasSuffix("pasted-image.PNG") == true && staged?.paths[3].hasSuffix("4-notes.txt") == true && staged.flatMap { try? String(contentsOf: project.appendingPathComponent($0.paths[2])) } == "x")
    check("files: images are told apart by extension, in any case, and are absolute under the project", staged?.images.count == 2 && staged?.images.allSatisfy { $0.path.hasPrefix(project.standardizedFileURL.resolvingSymlinksInPath().path + "/") } == true)
    check("files: the local QA folder ignores the copies in Git", fm.fileExists(atPath: project.appendingPathComponent(".dde/qa/.gitignore").path))
    if let staged { QAAttachments.discard(staged) }
    check("files: after the run the copies are gone and the project's own files stay", !fm.fileExists(atPath: project.appendingPathComponent(".dde/qa/inputs/run-1").path) && fm.fileExists(atPath: inside.path))

    let many = (0...QAAttachments.maxFiles).map { elsewhere.appendingPathComponent("f\($0).txt") }
    many.forEach { try? Data("x".utf8).write(to: $0) }
    var refusal: QAAttachments.Failure?
    do { _ = try QAAttachments.stage(many, root: project, id: "many") } catch { refusal = error as? QAAttachments.Failure }
    check("files: more than the limit is refused", refusal == .tooMany(QAAttachments.maxFiles))

    let big = elsewhere.appendingPathComponent("big.bin")
    fm.createFile(atPath: big.path, contents: nil)
    if let handle = try? FileHandle(forWritingTo: big) { try? handle.truncate(atOffset: UInt64(QAAttachments.maxBytes + 1)); try? handle.close() }
    refusal = nil
    do { _ = try QAAttachments.stage([outsideNote, big], root: project, id: "big") } catch { refusal = error as? QAAttachments.Failure }
    check("files: a file from outside that is too large is refused, and the copies made before it are removed", refusal == .tooLarge("big.bin") && !fm.fileExists(atPath: project.appendingPathComponent(".dde/qa/inputs/big").path))

    refusal = nil
    do { _ = try QAAttachments.stage([elsewhere], root: project, id: "dir") } catch { refusal = error as? QAAttachments.Failure }
    check("files: a folder from outside is refused", refusal == .notAFile("elsewhere"))
    check("files: a folder of the project is named by its path", (try? QAAttachments.stage([project.appendingPathComponent("docs")], root: project, id: "docs"))?.paths == ["docs"])
    refusal = nil
    do { _ = try QAAttachments.stage([elsewhere.appendingPathComponent("missing.png")], root: project, id: "missing") } catch { refusal = error as? QAAttachments.Failure }
    check("files: a file that is not there is refused with its name", refusal == .unreadable("missing.png"))
    check("files: the refusals say what is wrong in words", QAAttachments.Failure.tooLarge("big.bin").errorDescription?.contains("big.bin") == true)
}

// MARK: - What the person decides about a finding (REQ-015)

do {
    let defect = QAFinding(id: "f1", node: "n2", app: "shop", kind: .defect, severity: .high, title: "Pay does nothing", detail: "d", proposal: "p", isDefect: true)
    let note = QAFinding(id: "f2", node: "n2", app: "shop", kind: .wording, severity: .low, title: "Say Pay now", detail: "d", proposal: "p", isDefect: false)
    let when = Date(timeIntervalSince1970: 1_800_000_000)
    check("triage: a defect offers confirm, not a bug and workaround; anything else offers seen and dismiss", QATriage.states(for: defect) == [.confirmed, .notABug, .workaround] && QATriage.states(for: note) == [.seen, .dismissed])
    var marked = defect
    check("triage: a defect is confirmed, and the mark says when", QATriage.mark(&marked, .confirmed, note: "", now: when) && marked.triage == .confirmed && marked.triagedAt == when && marked.triageNote == nil)
    check("triage: a workaround needs its words", !QATriage.mark(&marked, .workaround, note: "   ", now: when) && marked.triage == .confirmed)
    check("triage: the workaround keeps its words on one line", QATriage.mark(&marked, .workaround, note: "Use the\n  keyboard\tshortcut", now: when) && marked.triage == .workaround && marked.triageNote == "Use the keyboard shortcut")
    check("triage: not a bug is one click and keeps no words", QATriage.mark(&marked, .notABug, note: "ignored", now: when) && marked.triage == .notABug && marked.triageNote == nil)
    check("triage: a note is not given a bug's mark, a defect not a note's", { var n = note; var d = defect; return !QATriage.mark(&n, .confirmed, note: "", now: when) && n.triage == nil && !QATriage.mark(&d, .seen, note: "", now: when) && d.triage == nil }())
    check("triage: the mark is taken back with nil, words and time with it", QATriage.mark(&marked, nil, note: "", now: when) && marked.triage == nil && marked.triageNote == nil && marked.triagedAt == nil)
    check("triage: only the words of a mark that asks for them are kept", { var n = note; QATriage.mark(&n, .seen, note: "ignored", now: when); return n.triageNote == nil }())
    check("triage: a note of any length is cut", QATriage.clean(String(repeating: "word ", count: 200)).count == 400)
    var record = QARunRecord(id: "r", scenarioID: "s", targetID: "t", targetKind: .local, selected: [], startedAt: when)
    record.findings = [defect, note]
    check("triage: a finding of a run is marked by its id, a missing one is refused", QATriage.mark(&record, finding: "f2", .dismissed, note: "", now: when) && record.findings[1].triage == .dismissed && record.findings[0].triage == nil && !QATriage.mark(&record, finding: "nope", .seen, note: "", now: when))
    check("triage: what is still unmarked is counted and told", QATriage.unmarked(record.findings) == 1 && QATriage.summary(record.findings) == "2 findings, 1 not marked" && QATriage.summary([]) == nil
          && QATriage.summary([marked]) == "1 finding, 1 not marked")
    var done = defect; QATriage.mark(&done, .confirmed, note: "", now: when)
    check("triage: all marked is told too", QATriage.summary([done]) == "1 finding, all marked")
    let saved = (try? QAStore.encoder.encode(record)).flatMap { try? QAStore.decoder.decode(QARunRecord.self, from: $0) }
    check("triage: the mark survives the run file", saved?.findings[1].triage == .dismissed && saved?.findings[1].triagedAt == when)
    let oldFile = #"{"id":"f1","kind":"defect","severity":"high","title":"t","detail":"d","proposal":"p","isDefect":true,"frame":"frames/1.png","time":3.5}"#
    let old = try? JSONDecoder().decode(QAFinding.self, from: Data(oldFile.utf8))
    check("triage: a finding written before the marks existed loads without one", old?.triage == nil && old?.frame == "frames/1.png")
    check("triage: a mark of a bug names what it does to the report", QABugTriageChange.make(.confirmed, note: "").readyToFix && QABugTriageChange.make(.workaround, note: "Use X").workaround == "Use X"
          && QABugTriageChange.make(.notABug, note: "").cancelReason == "Marked not a bug after a QA run." && QABugTriageChange.make(.notABug, note: "ignored").cancelReason == "Marked not a bug after a QA run.")
    check("triage: a note's mark or no mark leaves the report alone", QABugTriageChange.make(.seen, note: "") == QABugTriageChange.make(nil, note: "") && !QABugTriageChange.make(nil, note: "").readyToFix)
    let body = "## Summary\n\nIt breaks.\n\n## Expected\n\nIt works.\n"
    let with = QABugTriage.settingWorkaround("Use the menu", in: body)
    check("triage: a workaround is a section at the end of the report", with == body + "\n## Workaround\n\nUse the menu\n")
    check("triage: a second workaround replaces the first, not adds a copy", QABugTriage.settingWorkaround("Press Enter", in: with).components(separatedBy: "## Workaround").count == 2 && QABugTriage.settingWorkaround("Press Enter", in: with).contains("Press Enter") && !QABugTriage.settingWorkaround("Press Enter", in: with).contains("Use the menu"))
    check("triage: taking the workaround back leaves the report as it was", QABugTriage.settingWorkaround(nil, in: with) == body)
    check("triage: a workaround in the middle of a report leaves the sections after it", { let mid = "## Summary\n\nA\n\n## Workaround\n\nOld\n\n## Expected\n\nB\n"; let out = QABugTriage.settingWorkaround(nil, in: mid); return out.contains("## Expected") && !out.contains("Workaround") }())
}

do {
    let clarification = QAClarification(question: "Which user?", answer: "An existing administrator")
    var request = QAGenerationRequest(goal: "Buy a ticket", appKind: .web)
    request.clarifications = [clarification]
    check("discovery: answers reach generation without rewriting the original goal", QAGeneration.prompt(request).contains(clarification.answer) && request.goal == "Buy a ticket")
    check("discovery: the question prompt does not instruct scenario generation", !QADiscovery.prompt(request).contains("Return the scenario as the structured answer."))
    let round = try? QADiscovery.parse(["understanding":"Check an administrator purchase", "overlooked":["Duplicate submission"], "questions":[["question":"Which environment?", "why":"Avoid real data", "options":["Local", "Development"]]]])
    check("discovery: questions, options and suggested omissions parse", round?.questions.count == 1 && round?.questions[0].options == ["Local","Development"] && round?.overlooked == ["Duplicate submission"])
    let again = try? QADiscovery.parse(["understanding":"Ready", "questions":[["question":"Which environment?"]]])
    check("discovery: question identities are unique across rounds", round?.questions[0].id != again?.questions[0].id)
    check("discovery: a settled discussion can have no questions", (try? QADiscovery.parse(["understanding":"Ready", "questions":[] as [[String:Any]]]))?.questions.isEmpty == true)
    check("discovery: malformed answers are refused", (try? QADiscovery.parse(["questions":[]])) == nil)
    var scenario = shop()
    scenario.summary = "A buyer pays an order and an administrator verifies its confirmation."
    scenario.summarySource = QASummary.source(scenario)
    check("summary: generated text has a valid source fingerprint", QASummary.current(scenario) == scenario.summary)
    let originalSource = scenario.summarySource
    scenario.updated = Date(); scenario.selected = []
    check("summary: saving or selecting branches does not invalidate it", QASummary.current(scenario) != nil && QASummary.source(scenario) == originalSource)
    scenario.nodes[0].detail += " New requirement"
    check("summary: changing coverage invalidates the old text", QASummary.current(scenario) == nil)
    check("summary: blank or excessively long text is refused", (try? QASummary.parse(["summary":" "])) == nil && (try? QASummary.parse(["summary":String(repeating:"x",count:1401)])) == nil)
    check("summary: prompt asks for purpose and verified coverage", QASummary.prompt(scenario).contains("purpose, participants") && QASummary.prompt(scenario).contains("do not copy the original request"))
}

finish("QA")
