import Foundation

// Checks for MarkView/Models/QAScenario.swift, QARun.swift and QAStore.swift (feature end-to-end-qa), run by tools/tests/qa-tests.sh.
// Fixtures are scenarios and events; nothing touches a file but the store checks in a temp folder.

let now = Date(timeIntervalSince1970: 1_790_000_000)

func shop() -> QAScenario {
    QAScenario(
        id: "checkout", title: "Checkout with a card", goal: "A buyer pays and the seller sees the order", appKind: .web,
        targets: [
            QATarget(id: "local", kind: .local, name: "Local", url: "http://localhost:3000"),
            QATarget(id: "prod", kind: .production, name: "Production", url: "https://shop.example.com"),
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

let main = "n1>n2>n3>n4>n5", slow = "n1>n2>f1>c2", declined = "n1>a1>c1"

// MARK: - Branches

do {
    let scenario = shop()
    check("scenario: the fixture has no problems", scenario.problems().isEmpty)
    let branches = scenario.enumerateBranches()
    check("branches: every line from the start to a last step, in the order the edges are written", branches.branches.map(\.id) == [main, slow, declined])
    check("branches: nothing was cut", !branches.truncated)
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

    var ladder = QAScenario(id: "ladder", title: "Ladder", goal: "g", appKind: .web, actors: [QAActor(id: "a", name: "A")], start: "s", created: now, updated: now)
    ladder.nodes.append(QANode(id: "s", kind: .action, title: "start"))
    var previous = "s"
    for i in 0..<12 {
        for name in ["x\(i)", "y\(i)", "j\(i)"] { ladder.nodes.append(QANode(id: name, kind: .action, title: name)) }
        ladder.edges += [QAEdge(from: previous, to: "x\(i)"), QAEdge(from: previous, to: "y\(i)"), QAEdge(from: "x\(i)", to: "j\(i)"), QAEdge(from: "y\(i)", to: "j\(i)")]
        previous = "j\(i)"
    }
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
    check("problems: an id with the branch separator", !QAScenario.isValidNodeID("a>b") && QAScenario.isValidNodeID("step_1-a"))
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
    check("problems: no target", kinds(changed(shop()) { $0.targets = [] }) == [.noTarget])
    check("problems: a web target needs an http address", kinds(changed(shop()) { $0.targets[0].url = "localhost:3000" }) == [.incompleteTarget] && kinds(changed(shop()) { $0.targets[0].url = nil }) == [.incompleteTarget])
    check("problems: a web target may not be a file address", kinds(changed(shop()) { $0.targets[0].url = "file:///etc/passwd" }) == [.incompleteTarget])
    check("problems: a web target may not use another protocol", kinds(changed(shop()) { $0.targets[0].url = "ftp://shop.example.com" }) == [.incompleteTarget])
    let native = changed(shop()) { $0.appKind = .nativeMacOS; $0.targets = [QATarget(id: "app", kind: .local, name: "Notes", application: QAApplication(bundleIdentifier: "com.example.Notes", name: "Notes"))] }
    check("problems: a native scenario with an installed application has none", native.problems().isEmpty)
    check("problems: a native target needs an application", kinds(changed(native) { $0.targets[0].application = nil }) == [.incompleteTarget])
    check("problems: a native target needs a bundle identifier", kinds(changed(native) { $0.targets[0].application?.bundleIdentifier = "" }) == [.incompleteTarget])

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

    check("store: scenarios are reusable assets under .markview/qa", QAStore.scenariosFolder(root).path.hasSuffix("/.markview/qa/scenarios") && QAStore.policyURL(root).path.hasSuffix("/.markview/qa/policy.json"))
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

finish("QA")
