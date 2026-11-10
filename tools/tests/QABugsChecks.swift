import Foundation

// Checks for MarkView/Models/QABugs.swift and QABugFiler.swift (feature end-to-end-qa, DEC-010), run by tools/tests/qa-bugs-tests.sh.
// The mapping is checked on plain values; the filer on a fake sink; one check files into a real folder through BugReportWriter and
// reads it back with QABugIndex, as the project's bug folder is. Temp folders only.

setvbuf(stdout, nil, _IOLBF, 0)

let now = Date(timeIntervalSince1970: 1_790_000_000)
let started = Date(timeIntervalSince1970: 1_789_999_000)

let mainBranch = "n1>n2>n3>n4>n5"
let declinedBranch = "n1>a1>c1"
let slowBranch = "n1>n2>f1>c2"

func shop() -> QAScenario {
    QAScenario(
        id: "checkout", title: "Checkout with a card", goal: "A buyer pays and the seller sees the order", appKind: .web,
        apps: [QAApp(id: "shop", name: "Shop"), QAApp(id: "admin", name: "Admin")],
        targets: [
            QATarget(id: "local", kind: .local, name: "Local", locations: [
                "shop": QALocation(url: "http://localhost:3000/?token=SECRET#frag"),
                "admin": QALocation(url: "https://user:pw@admin.example.com/panel"),
            ]),
            QATarget(id: "prod", kind: .production, name: "Production", locations: ["shop": QALocation(url: "https://shop.example.com")]),
        ],
        actors: [QAActor(id: "buyer", name: "Buyer", app: "shop"), QAActor(id: "seller", name: "Seller", app: "admin")],
        nodes: [
            QANode(id: "n1", kind: .action, title: "Add a product to the cart", detail: "Open the shop and add the first product", actor: "buyer"),
            QANode(id: "n2", kind: .action, title: "Pay with a valid card", detail: "Pay with the test card", actor: "buyer"),
            QANode(id: "n3", kind: .check, title: "Confirmation is shown", detail: "The order confirmation is shown", actor: "buyer"),
            QANode(id: "n4", kind: .action, title: "Open the order list", detail: "Open the orders page", actor: "seller"),
            QANode(id: "n5", kind: .check, title: "The order is listed", detail: "The new order is in the list", actor: "seller"),
            QANode(id: "a1", kind: .alternative, title: "Card is declined", detail: "The bank declines the card", actor: "buyer"),
            QANode(id: "c1", kind: .check, title: "Decline message", detail: "A decline message is shown", actor: "buyer"),
            QANode(id: "f1", kind: .failure, title: "Payment is slow", detail: "The payment request takes eight seconds", actor: "buyer"),
            QANode(id: "c2", kind: .check, title: "Waiting indicator", detail: "A waiting indicator is shown", actor: "buyer"),
        ],
        edges: [
            QAEdge(from: "n1", to: "n2"), QAEdge(from: "n2", to: "n3"), QAEdge(from: "n3", to: "n4"), QAEdge(from: "n4", to: "n5"),
            QAEdge(from: "n1", to: "a1"), QAEdge(from: "a1", to: "c1"), QAEdge(from: "n2", to: "f1"), QAEdge(from: "f1", to: "c2"),
        ],
        start: "n1", created: now, updated: now)
}

func result(_ branch: String, _ verdict: QACheckVerdict) -> QACheckResult {
    QACheckResult(branch: branch, verdict: verdict, nodesMet: [], startedAt: started, finishedAt: now)
}

func run(id: String = "20261109-101500-ab12", selected: [String] = [mainBranch, declinedBranch, slowBranch], _ results: [QACheckResult]) -> QARunRecord {
    var record = QARunRecord(id: id, scenarioID: "checkout", targetID: "local", targetKind: .local, selected: selected, startedAt: started, finishedAt: now)
    for item in results { record.record(item) }
    return record
}

let failedMain = result(mainBranch, QACheckVerdict(outcome: .failed, reason: "The confirmation is not shown after payment", node: "n3"))
let blockedDeclined = result(declinedBranch, QACheckVerdict(outcome: .blocked, reason: "The application did not start in 30 s", node: "a1", blockReason: .launchFailed))
let interruptedSlow = result(slowBranch, QACheckVerdict(outcome: .interrupted, reason: "Stopped from the run window", interruption: .stoppedByUser))

let mixed = run([failedMain, blockedDeclined, interruptedSlow])

func finding(_ id: String, node: String?, app: String? = nil, kind: QAFindingKind, _ severity: QAFindingSeverity, _ title: String, defect: Bool,
             frame: String? = nil, time: Double? = nil) -> QAFinding {
    QAFinding(id: id, node: node, app: app, kind: kind, severity: severity, title: title, detail: "Detail of \(title)", proposal: "Proposal for \(title)",
              isDefect: defect, frame: frame, time: time)
}

let confirmDefect = finding("f1", node: "n3", kind: .defect, .high, "Confirm button does nothing", defect: true, frame: "frames/0003.png", time: 12.5)
let cardSuggestion = finding("f2", node: "n2", kind: .layout, .medium, "Card field is cramped", defect: false, frame: "frames/0002.png")
let wordingSuggestion = finding("f3", node: "c1", kind: .wording, .low, "Decline wording is vague", defect: false)
let ordersDefect = finding("f4", node: nil, app: "admin", kind: .defect, .low, "Orders list shows stale counts", defect: true, frame: "../outside.png")
let allFindings = [confirmDefect, cardSuggestion, wordingSuggestion, ordersDefect]

let runFolder = URL(fileURLWithPath: "/tmp/qa-runs/20261109-101500-ab12", isDirectory: true)
let videoPath = ".dde/qa/runs/20261109-101500-ab12/run.mp4"

func drafts(_ record: QARunRecord = mixed, findings: [QAFinding] = allFindings, video: String? = videoPath, folder: URL? = runFolder) -> [QABugCandidate] {
    let videos = video.map { path in Dictionary(record.selected.map { ($0, QABugVideo(path: path)) }, uniquingKeysWith: { first, _ in first }) } ?? [:]
    return QABugDrafts.drafts(run: record, scenario: shop(), findings: findings, videos: videos, runFolder: folder, now: now)
}

func candidate(_ list: [QABugCandidate], branch: String) -> QABugCandidate? { list.first { $0.branch == branch } }
func candidate(_ list: [QABugCandidate], finding id: String) -> QABugCandidate? { list.first { $0.findingID == id } }

/// True when every part appears in the text, each after the one before.
func inOrder(_ text: String, _ parts: [String]) -> Bool {
    var from = text.startIndex
    for part in parts {
        guard let range = text.range(of: part, range: from..<text.endIndex) else { return false }
        from = range.upperBound
    }
    return true
}

func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }

// MARK: Sinks

struct SinkFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

actor FakeSink: QABugSink {
    private var folder: URL?
    private var failKeys: Set<String> = []
    private var failLookup = false
    private var delay: UInt64 = 0
    private var lookupDelay: UInt64 = 0
    private(set) var preexisting: [String: String] = [:]
    private(set) var created: [QABugReport] = []
    private var ids: [String: String] = [:]

    init(folder: URL? = nil) { self.folder = folder }

    func setFailing(_ keys: Set<String>) { failKeys = keys }
    func setLookupFails(_ value: Bool) { failLookup = value }
    func setDelay(create: UInt64 = 0, lookup: UInt64 = 0) { delay = create; lookupDelay = lookup }
    func setPreexisting(_ value: [String: String]) { preexisting = value }

    func bugFolder() async -> URL? { folder }

    func filedBugs(forKeys keys: [String]) async throws -> [String: String] {
        if lookupDelay > 0 { try? await Task.sleep(nanoseconds: lookupDelay) }
        if failLookup { throw SinkFailure(message: "the folder is locked") }
        var found: [String: String] = [:]
        for key in keys { if let id = preexisting[key] ?? ids[key] { found[key] = id } }
        return found
    }

    func allFiledKeys() async throws -> [String] {
        if failLookup { throw SinkFailure(message: "the folder is locked") }
        return (Array(preexisting.keys) + Array(ids.keys)).sorted()
    }

    private(set) var triaged: [(key: String, change: QABugTriageChange)] = []

    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome {
        triaged.append((key, change))
        guard let id = preexisting[key] ?? ids[key] else { return .noReport }
        return .updated(id: id)
    }

    func createBug(_ report: QABugReport) async throws -> String {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failKeys.contains(report.key) { throw SinkFailure(message: "disk full") }
        let id = String(format: "BUG-%03d", created.count + preexisting.count + 1)
        created.append(report)
        ids[report.key] = id
        return id
    }
}

/// Files into a real folder the way FeatureStore.createBug does: BugReportWriter writes a numbered file.
actor DiskSink: QABugSink {
    let folder: URL
    init(folder: URL) { self.folder = folder }

    func bugFolder() async -> URL? { folder }

    func filedBugs(forKeys keys: [String]) async throws -> [String: String] { try QABugIndex.filedBugs(in: folder, keys: Set(keys)) }

    func allFiledKeys() async throws -> [String] { try QABugIndex.allKeys(in: folder) }

    func applyTriage(key: String, _ change: QABugTriageChange) async throws -> QABugTriageOutcome {
        guard let file = try QABugIndex.file(forKey: key, in: folder) else { return .noReport }
        var (front, body) = FrontMatter.split(try String(contentsOf: file, encoding: .utf8))
        QABugTriage.apply(change, front: &front, body: &body)
        try front.join(body: body).write(to: file, atomically: true, encoding: .utf8)
        return .updated(id: front.string("id"))
    }

    func createBug(_ report: QABugReport) async throws -> String {
        let count = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("BUG-") }.count
        let id = String(format: "BUG-%03d", count + 1)
        var draft = BugReportDraft(title: report.title, body: report.body, status: "open", severity: report.severity, reporter: "Tester", provenance: report.provenance)
        draft.fields = report.fields.map { (key: $0.key, value: $0.value) }
        let slug = String(report.title.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }).split(separator: "-").prefix(8).joined(separator: "-")
        try BugReportWriter.write(draft, id: id, slug: slug, created: "2026-11-09", in: folder)
        return id
    }
}

func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qa-bugs-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func isCreated(_ result: QAFilingResult) -> Bool { if case .created = result.status { return true } else { return false } }
func isAlreadyFiled(_ result: QAFilingResult) -> Bool { if case .alreadyFiled = result.status { return true } else { return false } }
func isFailed(_ result: QAFilingResult) -> Bool { if case .failed = result.status { return true } else { return false } }

// MARK: Mapping

func mappingChecks() {
    let list = drafts()
    check("one bug for each failed, blocked and interrupted check and each defect finding", list.count == 5)
    check("the checks come first in the order they were selected, then the defects",
          list.map(\.branch) == [mainBranch, declinedBranch, slowBranch, nil, nil] && list.map(\.findingID) == [nil, nil, nil, "f1", "f4"])
    check("a passed check has no bug", drafts(run([result(mainBranch, QACheckVerdict(outcome: .passed, reason: "ok"))]), findings: []).isEmpty)
    check("an uncovered check has no bug", drafts(run([result(mainBranch, QACheckVerdict(outcome: .uncovered, reason: "no fault seen"))]), findings: []).isEmpty)
    check("a branch with no result yet has no bug", drafts(run([]), findings: []).isEmpty)
    check("passed and uncovered next to a failure give only the failure",
          drafts(run([failedMain, result(declinedBranch, QACheckVerdict(outcome: .passed, reason: "ok")),
                      result(slowBranch, QACheckVerdict(outcome: .uncovered, reason: "x"))]), findings: []).map(\.branch) == [mainBranch])
    check("suggestions do not become bugs", candidate(list, finding: "f2") == nil && candidate(list, finding: "f3") == nil)
    check("every outcome that creates a bug has a title prefix and every candidate's outcome creates one",
          QAOutcome.allCases.allSatisfy { $0.createsBug == ($0.bugTitlePrefix != nil) } && list.compactMap(\.outcome).allSatisfy(\.createsBug))

    guard let main = candidate(list, branch: mainBranch), let declined = candidate(list, branch: declinedBranch),
          let slow = candidate(list, branch: slowBranch), let defect = candidate(list, finding: "f1"), let stale = candidate(list, finding: "f4") else {
        check("the bugs of the three checks and of the two defects exist", false)
        return
    }

    // Titles
    check("the title of a failed check carries the outcome, the branch and the reason",
          main.title == "QA failed: Main line — The confirmation is not shown after payment")
    check("the title of a blocked check carries the outcome and the branch", declined.title.hasPrefix("QA blocked: Card is declined — The application did not start"))
    check("the title of an interrupted check carries the outcome and the branch", slow.title.hasPrefix("QA interrupted: Payment is slow — Stopped from the run window"))
    check("the titles use QAOutcome.bugTitlePrefix",
          main.title.hasPrefix(QAOutcome.failed.bugTitlePrefix! + ": ") && declined.title.hasPrefix(QAOutcome.blocked.bugTitlePrefix! + ": ")
              && slow.title.hasPrefix(QAOutcome.interrupted.bugTitlePrefix! + ": "))
    check("a defect finding's title starts with QA defect and has the finding's title",
          candidate(list, finding: "f1")?.title == "QA defect: Confirm button does nothing")

    // Severities
    check("a failed check is high, a blocked one medium, an interrupted one low", main.severity == "high" && declined.severity == "medium" && slow.severity == "low")
    check("a defect finding keeps its own severity", defect.severity == "high" && stale.severity == "low")
    check("every severity is one of the project's bug severities", list.allSatisfy { FeatureVocabulary.severities.contains($0.severity) })
    let medium = drafts(findings: [finding("m", node: "n2", kind: .defect, .medium, "Medium defect", defect: true)])
    check("a medium defect finding is medium", candidate(medium, finding: "m")?.severity == "medium")

    // Body of the failed check
    let body = main.body
    check("the body starts with the title as a heading", body.hasPrefix("# \(main.title)\n\n"))
    check("the body names the scenario", body.contains("Checkout with a card") && body.contains("`checkout`"))
    check("the body names the target and its kind", body.contains("the target Local (local)"))
    check("the body gives the addresses of the applications the branch uses, without credentials, query or fragment",
          body.contains("`http://localhost:3000/`") && body.contains("`https://admin.example.com/panel`")
              && !body.contains("SECRET") && !body.contains("user:pw") && !body.contains("#frag"))
    check("the steps are listed in the order of the branch",
          inOrder(body, ["1. Action: Add a product to the cart", "2. Action: Pay with a valid card", "3. Check: Confirmation is shown",
                         "4. Action: Open the order list", "5. Check: The order is listed"]))
    check("a step names its actor and, with several applications, its application", body.contains("Open the orders page (Seller, Admin)"))
    let stepLines = lines(body)
    check("the step the verdict is about is marked and no other",
          stepLines.first { $0.contains("Confirmation is shown") && $0.hasPrefix("3.") }?.contains("failed here") == true
              && stepLines.filter { $0.contains("failed here") }.count == 1)
    check("the body says what was expected at the failing check", body.contains("## Expected\n\nThe order confirmation is shown"))
    check("the body gives the verdict's reason and the step it concerns",
          body.contains("The check did not hold at the step \"Confirmation is shown\" (`n3`).") && body.contains("Reason: The confirmation is not shown after payment"))
    check("the body names the run and its times", body.contains("`20261109-101500-ab12`") && body.contains(QABugDrafts.iso(started)))
    check("the body names the video as a local file", body.contains("`.dde/qa/runs/20261109-101500-ab12/run.mp4`") && body.contains("not committed"))
    check("the body says when it was reported", body.contains("Reported: \(QABugDrafts.iso(now))"))
    check("the body lists the findings of the branch with their proposals",
          body.contains("**Confirm button does nothing** — defect, high, reported as a bug, step \"Confirmation is shown\"")
              && body.contains("Proposal: Proposal for Confirm button does nothing") && body.contains("**Card field is cramped** — layout, medium, suggestion")
              && body.contains("Proposal: Proposal for Card field is cramped") && body.contains("at 12.5 s of the video"))
    check("a finding of another branch is not listed", !body.contains("Decline wording is vague") && !body.contains("Orders list shows stale counts"))
    check("the picture sections are left to the filer", !body.contains("## Pictures") && !body.contains("!["))
    check("the pictures are the frames of the branch's findings, inside the run folder",
          main.pictures.map(\.file.path) == ["/tmp/qa-runs/20261109-101500-ab12/frames/0003.png", "/tmp/qa-runs/20261109-101500-ab12/frames/0002.png"])
    check("the picture label is the finding's title", main.pictures.first?.label == "Confirm button does nothing")

    // Body of the blocked and interrupted checks
    check("a blocked check says why it could not go on", declined.body.contains("The check could not go on at the step \"Card is declined\" (`a1`) because the application could not be launched."))
    check("a blocked check lists only its own steps in order",
          inOrder(declined.body, ["1. Action: Add a product", "2. Alternative: Card is declined", "3. Check: Decline message"]) && !declined.body.contains("Pay with a valid card"))
    check("a blocked check lists the findings of its branch", declined.body.contains("Decline wording is vague") && declined.body.contains("Proposal: Proposal for Decline wording is vague"))
    check("a blocked check has the block reason in its list", declined.body.contains("- Block reason: the application could not be launched"))
    check("an interrupted check says how it was stopped", slow.body.contains("The check was stopped (stopped by the user).") && slow.body.contains("- Interruption: stopped by the user"))
    check("the expectation of a blocked or interrupted check is that it reaches a verdict", slow.body.contains("reaches a verdict"))
    check("each outcome says so in its summary",
          main.body.contains("\" of the scenario \"Checkout with a card\" failed.") && declined.body.contains("was blocked.") && slow.body.contains("was interrupted."))

    // Body of the defect findings
    check("a defect's steps stop at its step", inOrder(defect.body, ["1. Action", "2. Action", "3. Check: Confirmation is shown"]) && !defect.body.contains("Open the order list"))
    check("a defect's step is marked", defect.body.contains("the finding is about this step"))
    check("a defect has what is wrong and the proposed change", defect.body.contains("## Actual\n\nDetail of Confirm button does nothing")
          && defect.body.contains("## Proposed change\n\nProposal for Confirm button does nothing"))
    check("a defect names its step, kind, run and video time",
          defect.body.contains("- Step: \"Confirmation is shown\" (`n3`)") && defect.body.contains("- Kind: defect") && defect.body.contains("`20261109-101500-ab12`")
              && defect.body.contains("- At 12.5 s of the video"))
    check("a defect has the frame of its screen", defect.pictures.map(\.file.lastPathComponent) == ["0003.png"])
    check("a defect without a step has no steps and no picture outside the run folder", !stale.body.contains("Steps to reproduce") && stale.pictures.isEmpty)
    check("a defect names the application its screen belongs to", stale.body.contains("Admin at `https://admin.example.com/panel`"))

    // Keys
    check("the key of a check is the run and the branch", main.key == "20261109-101500-ab12:\(mainBranch)" && declined.key == "20261109-101500-ab12:\(declinedBranch)")
    check("the key of a finding is the run, finding and its id", defect.key == "20261109-101500-ab12:finding:f1")
    check("the keys are unique", Set(list.map(\.key)).count == list.count)
    check("the keys are the same when the candidates are made again", drafts().map(\.key) == list.map(\.key))
    check("the keys differ between runs", Set(drafts(run(id: "other", [failedMain, blockedDeclined, interruptedSlow])).map(\.key)).isDisjoint(with: Set(list.map(\.key))))
    check("the key does not depend on the findings or the video", drafts(findings: [], video: nil, folder: nil).prefix(3).map(\.key) == list.prefix(3).map(\.key))
    check("the key of a check cannot equal the key of a finding",
          QABugDrafts.key(run: "r", branch: "finding") != QABugDrafts.key(run: "r", finding: "x") && !QAScenario.isValidID("finding:x"))
    check("white space in a finding's id does not reach the key", QABugDrafts.key(run: "r", finding: "a b\tc") == "r:finding:a_b_c")
    check("a finding listed twice is one bug", drafts(findings: [confirmDefect, confirmDefect]).filter { $0.findingID == "f1" }.count == 1)
    check("a branch selected twice is one bug", drafts(run(selected: [mainBranch, mainBranch], [failedMain]), findings: []).count == 1)

    // Titles and text of odd results
    let messy = result(mainBranch, QACheckVerdict(outcome: .failed, reason: "Line one\nline two\t" + String(repeating: "word ", count: 80) + "\n## Fake heading\n- bullet", node: "n3"))
    let messyBug = drafts(run([messy]), findings: [])[0]
    check("a title is one line and not long", !messyBug.title.contains("\n") && messyBug.title.count <= 200 && messyBug.title.hasSuffix("…"))
    check("a title is cut between words", !messyBug.title.dropLast().hasSuffix("wor"))
    check("a reason cannot start a heading or a list in the body", !lines(messyBug.body).contains { $0.hasPrefix("## Fake") || $0.hasPrefix("- bullet") })
    let silent = drafts(run([result(mainBranch, QACheckVerdict(outcome: .blocked, reason: "", blockReason: .loginFailed))]), findings: [])[0]
    check("a title without a reason says the block reason", silent.title == "QA blocked: Main line — a login failed")
    let gone = drafts(run(selected: ["zz>yy"], [result("zz>yy", QACheckVerdict(outcome: .failed, reason: "x", node: "yy"))]), findings: [])[0]
    check("a branch the scenario no longer has is reported by its id", gone.title.hasPrefix("QA failed: zz>yy —") && gone.body.contains("no longer in the scenario"))
    check("a body without a video does not mention one", drafts(video: nil).first?.body.contains("Video") == false)
    check("no run folder means no pictures", drafts(folder: nil).allSatisfy { $0.pictures.isEmpty })
    let crowded = (1...10).map { finding("c\($0)", node: "n3", kind: .layout, .low, "Crowded \($0)", defect: false, frame: "frames/\($0).png") }
    let crowdedBug = drafts(run([failedMain]), findings: crowded)[0]
    check("a bug carries at most \(QABugDrafts.maxPictures) pictures", crowdedBug.pictures.count == QABugDrafts.maxPictures)
    let many = (1...30).map { finding("m\($0)", node: "n3", kind: .layout, .low, "Many \($0)", defect: false) }
    let manyBody = drafts(run([failedMain]), findings: many).first?.body ?? ""
    check("a check bug lists at most \(QABugDrafts.maxListedFindings) findings and counts the rest",
          manyBody.contains("**Many 20**") && !manyBody.contains("**Many 21**") && manyBody.contains("and 10 more"))

    // Frames
    let folder = URL(fileURLWithPath: "/tmp/run", isDirectory: true)
    check("a frame inside the run folder resolves", QABugDrafts.frameURL("frames/a.png", in: folder)?.path == "/tmp/run/frames/a.png")
    check("a frame that leaves the run folder is refused", QABugDrafts.frameURL("../x.png", in: folder) == nil && QABugDrafts.frameURL("a/../../x.png", in: folder) == nil)
    check("an absolute frame is refused", QABugDrafts.frameURL("/etc/passwd", in: folder) == nil && QABugDrafts.frameURL("~/x.png", in: folder) == nil)
    check("an empty frame or none is refused", QABugDrafts.frameURL("", in: folder) == nil && QABugDrafts.frameURL(nil, in: folder) == nil && QABugDrafts.frameURL("a.png", in: nil) == nil)
    check("a frame that is the folder itself or has an empty part is refused", QABugDrafts.frameURL(".", in: folder) == nil && QABugDrafts.frameURL("a//b.png", in: folder) == nil)

    // Text helpers
    check("line puts text on one line", QABugDrafts.line(" a \n b\t\tc ", 50) == "a b c")
    check("line cuts with an ellipsis", QABugDrafts.line("abcdefghij", 5) == "abcd…")
    check("code uses a fence its own back ticks cannot end", QABugDrafts.code("a`b") == "`` a`b ``" && QABugDrafts.code("ab") == "`ab`")
}

// MARK: Filer

func filerChecks() async {
    let list = drafts()
    let keys = list.map(\.key)

    // Filing creates each candidate once
    let sink = FakeSink()
    let filer = QABugFiler(sink: sink)
    let first = await filer.file(list)
    check("every candidate is created, in order", first.count == 5 && first.allSatisfy(isCreated) && first.map(\.key) == keys)
    let createdKeys = await sink.created.map(\.key)
    check("the sink got the candidates in order with the ids it made", createdKeys == keys && first.first?.status == .created(id: "BUG-001"))
    let second = await filer.file(list)
    let createdAfterSecond = await sink.created.count
    check("filing the same candidates again creates nothing", second.allSatisfy(isAlreadyFiled) && createdAfterSecond == 5)
    check("filing again reports the ids the first time made", second.map(\.status) == first.map(\.status).map { status -> QAFilingStatus in
        if case .created(let id) = status { return .alreadyFiled(id: id) }
        return status
    })
    let other = QABugFiler(sink: sink)
    let third = await other.file(list)
    let createdAfterThird = await sink.created.count
    check("a new filer on the same sink also creates nothing", third.allSatisfy(isAlreadyFiled) && createdAfterThird == 5)
    let nothing = await filer.file([])
    check("filing nothing files nothing", nothing.isEmpty)

    // What the sink is given
    let allCreated = await sink.created
    guard allCreated.count == 5 else {
        check("the sink was given five reports to look at", false)
        return
    }
    let report = allCreated[0]
    check("the report has the candidate's title, severity and the key as a field",
          report.title == list[0].title && report.severity == list[0].severity && report.fields.contains(QABugField(key: "qa_key", value: list[0].key)))
    check("the report has the run and the outcome as fields",
          report.fields.contains(QABugField(key: "qa_run", value: "20261109-101500-ab12")) && report.fields.contains(QABugField(key: "qa_outcome", value: "failed")))
    check("a finding's report has the outcome defect", allCreated.last?.fields.contains(QABugField(key: "qa_outcome", value: "defect")) == true)
    check("the report says where it came from", report.provenance == "Created by End-to-End QA from run 20261109-101500-ab12")
    check("a report without pictures has the candidate's body as it is", list[1].pictures.isEmpty && allCreated[1].body == list[1].body)

    // A bug that exists already
    let known = FakeSink()
    await known.setPreexisting([keys[1]: "BUG-042"])
    let partly = await QABugFiler(sink: known).file(list)
    let knownCreated = await known.created.count
    check("a key a report names already is not created again, whatever its status",
          partly[1].status == .alreadyFiled(id: "BUG-042") && partly.filter(isCreated).count == 4 && knownCreated == 4)

    // One failure does not stop the others
    let flaky = FakeSink()
    await flaky.setFailing([keys[1]])
    let flakyFiler = QABugFiler(sink: flaky)
    let attempt = await flakyFiler.file(list)
    check("a candidate that cannot be written is reported as failed and the others are created",
          attempt.map(isCreated) == [true, false, true, true, true] && attempt[1].status == .failed("disk full"))
    await flaky.setFailing([])
    let retry = await flakyFiler.file(list)
    let flakyCreated = await flaky.created.count
    check("filing again creates only what failed", retry.map(isCreated) == [false, true, false, false, false] && retry.filter(isAlreadyFiled).count == 4 && flakyCreated == 5)

    // The look-up fails
    let blind = FakeSink()
    await blind.setLookupFails(true)
    let blindResults = await QABugFiler(sink: blind).file(list)
    let blindCreated = await blind.created.count
    check("when the existing reports cannot be read nothing is filed", blindResults.allSatisfy(isFailed) && blindCreated == 0)
    check("the failure says why", blindResults.first.map { if case .failed(let message) = $0.status { return message.contains("the folder is locked") && message.contains("nothing was filed") } else { return false } } == true)

    // The same candidate twice in one call
    let doubled = FakeSink()
    let twice = await QABugFiler(sink: doubled).file([list[0], list[0]])
    let doubledCreated = await doubled.created.count
    check("a candidate given twice in one call is created once", twice.map(isCreated) == [true, false] && isAlreadyFiled(twice[1]) && doubledCreated == 1)
    let doubledFailing = FakeSink()
    await doubledFailing.setFailing([list[0].key])
    let twiceFailing = await QABugFiler(sink: doubledFailing).file([list[0], list[0]])
    check("a failed candidate given twice is reported failed twice and tried once", twiceFailing.count == 2 && twiceFailing.allSatisfy(isFailed) && twiceFailing[0].status == twiceFailing[1].status)

    // Two calls at the same time
    let slowSink = FakeSink()
    await slowSink.setDelay(create: 60_000_000)
    let slowFiler = QABugFiler(sink: slowSink)
    async let one = slowFiler.file(list)
    async let two = slowFiler.file(list)
    let both = await [one, two]
    let slowCreated = await slowSink.created.count
    check("two calls at the same time create each report once", slowCreated == 5)
    check("one of two simultaneous calls creates and the other finds", both.map { $0.filter(isCreated).count }.sorted() == [0, 5] && both.map { $0.filter(isAlreadyFiled).count }.sorted() == [0, 5])

    // Cancelled
    let waiting = FakeSink()
    await waiting.setDelay(lookup: 300_000_000)
    let cancelFiler = QABugFiler(sink: waiting)
    let task = Task { await cancelFiler.file(list) }
    try? await Task.sleep(nanoseconds: 30_000_000)
    task.cancel()
    let cancelled = await task.value
    let waitingCreated = await waiting.created.count
    check("a cancelled call creates nothing and says so", cancelled.allSatisfy(isFailed) && cancelled.first?.status == .failed("Filing was cancelled.") && waitingCreated == 0)
}

// MARK: Pictures

func pictureChecks() async {
    let work = tempFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    let runDir = work.appendingPathComponent("run", isDirectory: true)
    let bugs = work.appendingPathComponent("bugs", isDirectory: true)
    let frames = runDir.appendingPathComponent("frames", isDirectory: true)
    try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    try? png.write(to: frames.appendingPathComponent("0003.png"))
    try? png.write(to: frames.appendingPathComponent("0002.png"))
    try? Data("not a picture".utf8).write(to: frames.appendingPathComponent("notes.txt"))
    try? Data(count: QABugFiler.maxPictureBytes + 1).write(to: frames.appendingPathComponent("huge.png"))
    try? FileManager.default.createSymbolicLink(at: frames.appendingPathComponent("link.png"), withDestinationURL: frames.appendingPathComponent("0003.png"))

    func pictured(_ names: [String], key: String = "r:main") -> QABugCandidate {
        QABugCandidate(key: key, origin: .check(branch: "main", outcome: .failed), runID: "r", title: "QA failed: Main line — x", severity: "high", body: "# T\n\n## Summary\n\nText",
                       pictures: names.map { QABugPicture(label: "Screen \($0) [1]", file: frames.appendingPathComponent($0)) })
    }

    let sink = FakeSink(folder: bugs)
    let filer = QABugFiler(sink: sink)
    let candidate = pictured(["0003.png", "0002.png"])
    let outcome = await filer.file([candidate])
    let assets = bugs.appendingPathComponent("assets", isDirectory: true)
    let copied = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).sorted()
    let hash = QABugFiler.stableHash(candidate.key)
    check("the pictures are copied into the assets folder beside the reports under names made from the key",
          copied == ["qa-\(hash)-1-0003.png", "qa-\(hash)-2-0002.png"])
    check("a copy has the content of the picture", (try? Data(contentsOf: assets.appendingPathComponent(copied[0]))) == png)
    let body = await sink.created.first?.body ?? ""
    check("the body links the copies relative to the bug folder", body.contains("![Screen 0003.png (1)](assets/qa-\(hash)-1-0003.png)") && body.contains("## Pictures"))
    check("the body is the candidate's body then the pictures", body.hasPrefix(candidate.body + "\n\n## Pictures\n\n"))
    check("the report is filed without notes", isCreated(outcome[0]) && outcome[0].notes.isEmpty)

    // Left out, with a note, and the bug is still filed
    let odd = pictured(["gone.png", "notes.txt", "huge.png", "link.png", "0002.png"], key: "r:odd")
    let oddSink = FakeSink(folder: bugs)
    let oddResult = await QABugFiler(sink: oddSink).file([odd])
    check("the bug is filed when its pictures cannot be copied", isCreated(oddResult[0]))
    check("each picture that cannot be copied is named with its reason",
          oddResult[0].notes.count == 4 && oddResult[0].notes[0].contains("does not exist") && oddResult[0].notes[1].contains("not a PNG")
              && oddResult[0].notes[2].contains("larger than") && oddResult[0].notes[3].contains("not an ordinary file"))
    let oddBody = await oddSink.created.first?.body ?? ""
    check("the notes are in the body and the good picture is linked", oddBody.contains("- Picture \"Screen gone.png (1)\" was not copied") && oddBody.contains("(assets/qa-\(QABugFiler.stableHash("r:odd"))-5-0002.png)"))

    // A failed write takes the copies away
    let failing = FakeSink(folder: bugs)
    await failing.setFailing(["r:fails"])
    let failed = await QABugFiler(sink: failing).file([pictured(["0003.png"], key: "r:fails")])
    let failedName = "qa-\(QABugFiler.stableHash("r:fails"))-1-0003.png"
    check("when the report cannot be written its copied pictures are removed",
          isFailed(failed[0]) && !FileManager.default.fileExists(atPath: assets.appendingPathComponent(failedName).path))

    // Already filed: nothing is copied
    let before = ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).count
    _ = await filer.file([candidate])
    check("a candidate that is filed already copies nothing", ((try? FileManager.default.contentsOfDirectory(atPath: assets.path)) ?? []).count == before)

    // No project folder
    let none = FakeSink(folder: nil)
    let noFolder = await QABugFiler(sink: none).file([pictured(["0003.png"], key: "r:nofolder")])
    check("without a bug folder the report is still filed and the pictures are named as not copied",
          isCreated(noFolder[0]) && noFolder[0].notes.first?.contains("no project folder") == true)

    // Names
    check("the hash of a key is stable and 16 digits", QABugFiler.stableHash("a") == QABugFiler.stableHash("a") && QABugFiler.stableHash("a").count == 16
          && QABugFiler.stableHash("a") != QABugFiler.stableHash("b"))
    check("no pictures and no notes make no section", QABugFiler.picturesSection(links: [], notes: []).isEmpty)

    // Same pictures from a real run folder through the mapping
    let mapped = QABugDrafts.drafts(run: mixed, scenario: shop(), findings: allFindings, videos: [:], runFolder: runDir, now: now)
    let mappedSink = FakeSink(folder: bugs)
    let mappedResult = await QABugFiler(sink: mappedSink).file(mapped)
    check("the frames of a run are copied beside the bugs that name them", mappedResult.allSatisfy(isCreated) && mappedResult.allSatisfy { $0.notes.isEmpty })
    let mappedFirst = await mappedSink.created.first?.body ?? ""
    check("the check bug links both frames of its findings", mappedFirst.components(separatedBy: "![").count == 3)
}

// MARK: Real files

func diskChecks() async {
    let work = tempFolder()
    defer { try? FileManager.default.removeItem(at: work) }
    let bugs = work.appendingPathComponent("docs/bugs", isDirectory: true)
    let tricky = finding("F 1 #x", node: "n3", kind: .defect, .high, "Save: \"Done\" [x] # broken", defect: true)
    let list = drafts(findings: allFindings + [tricky])

    // Before the folder exists
    check("a bug folder that does not exist has no reports", (try? QABugIndex.filedBugs(in: bugs, keys: ["a"])) == [:])

    let filer = QABugFiler(sink: DiskSink(folder: bugs))
    let first = await filer.file(list)
    check("candidates are written as numbered bug files", first.allSatisfy(isCreated) && first.first?.status == .created(id: "BUG-001") && first.last?.status == .created(id: "BUG-006"))
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: bugs.path)) ?? []).sorted()
    check("six files exist", names.count == 6 && names.allSatisfy { $0.hasPrefix("BUG-") && $0.hasSuffix(".md") })

    let text = (try? String(contentsOf: bugs.appendingPathComponent(names[0]), encoding: .utf8)) ?? ""
    let (front, body) = FrontMatter.split(text)
    check("the file has the standard front matter and the QA fields",
          front.string("type") == "bug" && front.string("id") == "BUG-001" && front.string("status") == "open" && front.string("severity") == "high"
              && front.string("qa_key") == list[0].key && front.string("qa_run") == "20261109-101500-ab12" && front.string("qa_outcome") == "failed"
              && front.string("provenance").hasPrefix("Created by End-to-End QA"))
    check("the file keeps the title and the body", front.string("title") == list[0].title && body.contains("## Steps to reproduce") && body.hasPrefix("# \(list[0].title)"))
    let trickyFront = FrontMatter.split((try? String(contentsOf: bugs.appendingPathComponent(names[5]), encoding: .utf8)) ?? "").0
    check("a title with a colon, quotes, brackets and a hash survives the front matter", trickyFront.string("title") == "QA defect: Save: \"Done\" [x] # broken")
    check("a key from an id with white space and a hash survives the front matter", trickyFront.string("qa_key") == "20261109-101500-ab12:finding:F_1_#x")

    // Found again from the files
    let index = (try? QABugIndex.filedBugs(in: bugs, keys: Set(list.map(\.key)))) ?? [:]
    check("every key is found in the files, with the report's id", index.count == 6 && index[list[0].key] == "BUG-001" && index[list[5].key] == "BUG-006")
    check("a key no file names is not found", (try? QABugIndex.filedBugs(in: bugs, keys: ["nope"])) == [:])

    // A new filer over the same folder, as after a restart
    let again = await QABugFiler(sink: DiskSink(folder: bugs)).file(list)
    check("after a restart the same candidates create nothing", again.allSatisfy(isAlreadyFiled) && ((try? FileManager.default.contentsOfDirectory(atPath: bugs.path)) ?? []).count == 6)

    // Only what is not in a file yet is created
    let next = drafts(run(id: "20261110-090000-cd34", [failedMain]), findings: [])
    let mixedAgain = await QABugFiler(sink: DiskSink(folder: bugs)).file(list + next)
    check("a later run's bug is created next to the earlier ones", mixedAgain.map(isCreated) == [false, false, false, false, false, false, true] && mixedAgain.last?.status == .created(id: "BUG-007"))

    // Files that are not QA bugs
    try? "# Notes without front matter\n".write(to: bugs.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try? "---\ntype: bug\nid: BUG-050\ntitle: Hand written\n---\n\nbody\n".write(to: bugs.appendingPathComponent("BUG-050-hand-written.md"), atomically: true, encoding: .utf8)
    try? Data([0xFF, 0xFE, 0x00]).write(to: bugs.appendingPathComponent("BUG-051-broken.md"))
    check("other files in the folder do not disturb the look-up", ((try? QABugIndex.filedBugs(in: bugs, keys: Set(list.map(\.key)))) ?? [:]).count == 6)
    let deletedKey = list[2].key
    try? FileManager.default.removeItem(at: bugs.appendingPathComponent(names[2]))
    let afterDelete = await QABugFiler(sink: DiskSink(folder: bugs)).file(list)
    check("a report that was deleted is filed again", afterDelete.filter(isCreated).count == 1 && afterDelete[2].key == deletedKey && isCreated(afterDelete[2]))
}

func triageChecks() async {
    let bugs = tempFolder().appendingPathComponent("bugs", isDirectory: true)
    let list = drafts()
    let filer = QABugFiler(sink: DiskSink(folder: bugs))
    _ = await filer.file(list)
    guard let defect = list.first(where: { if case .finding = $0.origin { return true } else { return false } }) else { check("triage: a defect was filed", false); return }
    func read(_ key: String) -> (front: FrontMatter, body: String) {
        guard let file = try? QABugIndex.file(forKey: key, in: bugs), let text = try? String(contentsOf: file, encoding: .utf8) else { return (FrontMatter.split("").0, "") }
        return FrontMatter.split(text)
    }
    let before = read(defect.key)
    check("triage: the file of a report is found by its key", ((try? QABugIndex.file(forKey: defect.key, in: bugs)) ?? nil) != nil && ((try? QABugIndex.file(forKey: "nope", in: bugs)) ?? nil) == nil && ((try? QABugIndex.file(forKey: "", in: bugs)) ?? nil) == nil)
    check("triage: a report no one marked has no mark", before.front.string("qa_triage").isEmpty && before.front.string("ready_to_fix").isEmpty && !before.body.contains("## Workaround"))

    let confirmed = try? await filer.applyTriage(key: defect.key, QABugTriageChange.make(.confirmed, note: ""))
    var now = read(defect.key)
    check("triage: a confirmed bug is ready to fix and carries its mark", { if case .updated? = confirmed { return true } else { return false } }() && now.front.string("ready_to_fix") == "true" && now.front.string("qa_triage") == "confirmed")
    check("triage: the title, the key and the body of the report are untouched", now.front.string("title") == before.front.string("title") && now.front.string("qa_key") == defect.key && now.body == before.body)

    _ = try? await filer.applyTriage(key: defect.key, QABugTriageChange.make(.workaround, note: "Use the keyboard shortcut"))
    now = read(defect.key)
    check("triage: a workaround is written into the report and the ready flag this app set is taken back", now.front.string("qa_triage") == "workaround" && now.front.string("ready_to_fix").isEmpty && now.body.contains("## Workaround\n\nUse the keyboard shortcut"))

    _ = try? await filer.applyTriage(key: defect.key, QABugTriageChange.make(.notABug, note: ""))
    now = read(defect.key)
    check("triage: not a bug leaves the workaround out and says so in the mark", now.front.string("qa_triage") == "notABug" && !now.body.contains("## Workaround"))

    _ = try? await filer.applyTriage(key: defect.key, QABugTriageChange.make(nil, note: ""))
    now = read(defect.key)
    check("triage: taking the mark back leaves the report as it was filed", now.front.string("qa_triage").isEmpty && now.front.string("ready_to_fix").isEmpty && now.body == before.body)

    // A flag set by someone else is not this app's to take away
    if let file = try? QABugIndex.file(forKey: defect.key, in: bugs) {
        var (front, body) = FrontMatter.split((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        front.set("ready_to_fix", "true")
        try? front.join(body: body).write(to: file, atomically: true, encoding: .utf8)
        _ = body
    }
    _ = try? await filer.applyTriage(key: defect.key, QABugTriageChange.make(.workaround, note: "Wait a minute"))
    check("triage: a ready flag someone else set stays when a workaround is marked", read(defect.key).front.string("ready_to_fix") == "true")

    let none = try? await filer.applyTriage(key: "no-such-key", QABugTriageChange.make(.confirmed, note: ""))
    check("triage: a finding with no report only carries the mark itself", none == .noReport)

    let fake = FakeSink()
    let fakeFiler = QABugFiler(sink: fake)
    _ = try? await fakeFiler.applyTriage(key: "k", QABugTriageChange.make(.confirmed, note: ""))
    let passed = await fake.triaged
    check("triage: the filer passes the change to the sink as it is", passed.map(\.key) == ["k"] && passed.first?.change.readyToFix == true)
}

mappingChecks()
await filerChecks()
await pictureChecks()
await diskChecks()
await triageChecks()
// MARK: - A video per branch (the run records one file for every branch)

do {
    let videos = [mainBranch: QABugVideo(path: ".dde/qa/runs/r/branch-1.mp4", startsAt: 0),
                  declinedBranch: QABugVideo(path: ".dde/qa/runs/r/branch-2.mp4", startsAt: 40)]
    let late = finding("f9", node: "c1", kind: .defect, .medium, "Decline message is cut off", defect: true, time: 52.5)
    let list = QABugDrafts.drafts(run: mixed, scenario: shop(), findings: [confirmDefect, late], videos: videos, runFolder: nil, now: now)
    let main = list.first { $0.title.contains("Add a product") || $0.origin == .check(branch: mainBranch, outcome: .failed) }
    let declined = list.first { $0.origin == .check(branch: declinedBranch, outcome: .blocked) }
    let slow = list.first { $0.origin == .check(branch: slowBranch, outcome: .interrupted) }
    let first = list.first { $0.origin == .finding(id: "f1") }
    let second = list.first { $0.origin == .finding(id: "f9") }
    check("videos: a failed check names the recording of its own branch", main?.body.contains("branch-1.mp4") == true && main?.body.contains("branch-2.mp4") == false)
    check("videos: a blocked check names the recording of its own branch", declined?.body.contains("branch-2.mp4") == true && declined?.body.contains("branch-1.mp4") == false)
    check("videos: a branch with no recording names none", slow?.body.contains("mp4") == false && slow?.body.contains("Video") == false)
    check("videos: a defect names the recording of the branch that covers its step, at the time in that recording",
          first?.body.contains("branch-1.mp4") == true && first?.body.contains("- At 12.5 s of the video") == true)
    check("videos: a time after the recording began is counted from its start (52.5 s into the run, 40 s in: 12.5 s)",
          second?.body.contains("branch-2.mp4") == true && second?.body.contains("- At 12.5 s of the video") == true)
    let early = finding("f8", node: "c1", kind: .defect, .low, "Early", defect: true, time: 10)
    check("videos: a time before the recording began is not negative",
          QABugDrafts.drafts(run: mixed, scenario: shop(), findings: [early], videos: videos, runFolder: nil, now: now).first { $0.origin == .finding(id: "f8") }?.body.contains("- At 0.0 s of the video") == true)
}

finish("QA bug")
