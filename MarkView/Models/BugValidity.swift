import Foundation

/// The validity check that runs before every analysis of an existing bug report (feature "Bug Validity Check Before Analysis",
/// REQ-001 … REQ-005, DEC-001 … DEC-004).
///
/// Before the assistant investigates a report, one read-only verification decides whether the reported problem still exists on the
/// project's main branch:
/// - the baseline is one identifiable commit of main (`origin/main`, else `origin/master`, the remote's default branch, a local `main`
///   or `master`); nothing uncommitted and nothing from other branches is ever shown to the verification, which reads a `git archive`
///   export of that commit, never the working tree (DEC-002). Without a repository or a main commit the outcome is inconclusive;
/// - the outcome is still-present, already-fixed or inconclusive. A bug is closed only on affirmative evidence that the reported scenario
///   is handled on main: not reproducing or not finding the problem proves nothing (DEC-001). The assistant's answer is checked in code
///   before it is believed (`verdict(from:)`): evidence has to name files that exist in the export, and "could not reproduce" is not a basis;
/// - an already-fixed outcome closes the local report only (DEC-003), saves the baseline, the evidence and the reason in the report's
///   "Validity check" section, and stops the investigation, but only once the report has been saved (DEC-004);
/// - still-present and inconclusive outcomes continue the investigation, which is told the outcome and, when inconclusive, why.
///
/// Everything here is pure or takes its process runner as a parameter, so the rules are checked without the app
/// (`tools/tests/bug-validity-tests.sh`). `FeatureAssistant` (Models/FeatureBugValidity.swift) supplies the real git runner, the assistant
/// call and the report store.
enum BugValidity {
    // MARK: - Model

    enum Outcome: String, CaseIterable, Sendable {
        case stillPresent = "still-present"
        case alreadyFixed = "already-fixed"
        case inconclusive

        var title: String {
            switch self {
            case .stillPresent: return "Still present"
            case .alreadyFixed: return "Already fixed"
            case .inconclusive: return "Inconclusive"
            }
        }
    }

    /// What a fix claim rests on. The first three are evidence; `couldNotReproduce` and `none` are not (DEC-001).
    enum Basis: String, CaseIterable, Sendable {
        case fixInCode = "fix-in-code"
        case coveredByTest = "covered-by-test"
        case scenarioRemoved = "scenario-removed"
        case couldNotReproduce = "could-not-reproduce"
        case none

        var isEvidence: Bool { self == .fixInCode || self == .coveredByTest || self == .scenarioRemoved }

        var title: String {
            switch self {
            case .fixInCode: return "the code on main handles the reported scenario"
            case .coveredByTest: return "a test on main covers the reported scenario"
            case .scenarioRemoved: return "the reported scenario can no longer occur on main"
            case .couldNotReproduce: return "the problem could not be reproduced"
            case .none: return "no basis given"
            }
        }
    }

    /// The commit of main the verification reads.
    struct Baseline: Equatable, Sendable {
        var ref: String
        var commit: String
        /// Commit date (yyyy-mm-dd) and subject, for the reader of the report.
        var date = ""
        var subject = ""
        /// The project folder's path inside the repository ("" when it is the repository root), so paths stay project-relative.
        var prefix = ""

        var short: String { String(commit.prefix(10)) }
        var label: String { "`\(ref)` @ `\(short)`" + (date.isEmpty ? "" : " (\(date))") }
    }

    struct Evidence: Equatable, Sendable {
        var path: String
        var finding: String
    }

    struct Verdict: Equatable, Sendable {
        var outcome: Outcome
        /// Why: the finding for still-present, what could not be settled for inconclusive, the summary of the fix for already-fixed.
        var reason: String
        var basis: Basis = .none
        var evidence: [Evidence] = []
        /// Why no further correction is needed (already-fixed only).
        var explanation = ""
        var baseline: Baseline?
    }

    static func inconclusive(_ reason: String, baseline: Baseline? = nil) -> Verdict {
        Verdict(outcome: .inconclusive, reason: reason, baseline: baseline)
    }

    // MARK: - Git

    struct GitOutput: Sendable {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs `git` with the arguments in the directory; never throws. The app's runner drains both pipes and ends a stalled process.
    typealias GitRunner = @Sendable (_ arguments: [String], _ directory: URL, _ timeout: TimeInterval) async -> GitOutput

    private static func isCommitID(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy { $0.isHexDigit }
    }

    /// The identifiable revision of main for the project at `root`, or nil when there is no repository or no main branch to read.
    static func resolveMain(root: URL, git: GitRunner) async -> Baseline? {
        let prefix = await git(["rev-parse", "--show-prefix"], root, 20)
        guard prefix.status == 0 else { return nil }
        let inside = prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = ["origin/main", "origin/master"]
        let head = await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], root, 20)
        let remoteDefault = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.status == 0, !remoteDefault.isEmpty { candidates.append(remoteDefault) }
        candidates += ["main", "master"]
        var seen = Set<String>()
        for ref in candidates where seen.insert(ref).inserted {
            let found = await git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], root, 20)
            let commit = found.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard found.status == 0, isCommitID(commit) else { continue }
            let info = await git(["log", "-1", "--format=%cs%n%s", commit], root, 20)
            let lines = info.stdout.components(separatedBy: "\n")
            return Baseline(ref: ref, commit: commit, date: info.status == 0 ? (lines.first ?? "") : "",
                            subject: info.status == 0 && lines.count > 1 ? lines[1] : "", prefix: inside)
        }
        return nil
    }

    /// Subjects of recent commits on main that mention the report (its id or a linked issue): leads for the verification, never evidence.
    static func commitHints(key: String, issues: [Int], baseline: Baseline, root: URL, git: GitRunner) async -> [String] {
        var arguments = ["log", baseline.commit, "-n", "8", "--format=%h %s", "--regexp-ignore-case", "--fixed-strings"]
        let terms = ([key] + issues.map { "#\($0)" }).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !terms.isEmpty else { return [] }
        for term in terms { arguments.append("--grep=\(term)") }
        let output = await git(arguments, root, 30)
        guard output.status == 0 else { return [] }
        return output.stdout.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A read-only copy of the baseline commit on disk, which the verification reads in place of the working tree.
    struct Export {
        let tree: URL
        private let container: URL
        init(tree: URL, container: URL) { self.tree = tree; self.container = container }
        func remove() { try? FileManager.default.removeItem(at: container) }
    }

    static let maxExportBytes: Int64 = 1_500_000_000

    /// Exports the committed files of `baseline` (`git archive`, so uncommitted changes and other branches cannot appear in it).
    /// Nil when the export fails, is too large, or takes too long; the outcome is then inconclusive.
    static func exportMain(_ baseline: Baseline, root: URL, git: GitRunner) async -> Export? {
        let fm = FileManager.default
        let container = fm.temporaryDirectory.appendingPathComponent("markview-validity-" + UUID().uuidString, isDirectory: true)
        let tree = container.appendingPathComponent("main", isDirectory: true)
        let tar = container.appendingPathComponent("main.tar")
        do { try fm.createDirectory(at: tree, withIntermediateDirectories: true) } catch { return nil }
        func fail() -> Export? { try? fm.removeItem(at: container); return nil }
        // Run in the project folder: `git archive <commit>` exports that folder's subtree with project-relative paths.
        let archived = await git(["archive", "--format=tar", "--output=" + tar.path, baseline.commit], root, 240)
        guard archived.status == 0 else { return fail() }
        let size = ((try? fm.attributesOfItem(atPath: tar.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= maxExportBytes else { return fail() }
        guard await extract(tar: tar, into: tree) else { return fail() }
        try? fm.removeItem(at: tar)
        return Export(tree: tree, container: container)
    }

    /// `tar -x` on a background queue (never the main thread); its output goes nowhere, so no pipe can fill up.
    private static func extract(tar: URL, into folder: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xf", tar.path, "-C", folder.path]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: false); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 240, execute: timer)
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }

    // MARK: - The verification request

    static let schema: [String: Any] = ["type": "object", "properties": [
        "outcome": ["type": "string", "enum": Outcome.allCases.map(\.rawValue)],
        "reason": ["type": "string"],
        "basis": ["type": "string", "enum": Basis.allCases.map(\.rawValue)],
        "evidence": ["type": "array", "items": ["type": "object",
            "properties": ["path": ["type": "string"], "finding": ["type": "string"]], "required": ["path", "finding"]]],
        "explanation": ["type": "string"],
    ], "required": ["outcome", "reason", "basis", "evidence", "explanation"]]

    /// The prompt of the verification. The assistant reads only the export of `baseline` (its working folder), and `report` is the report text.
    static func prompt(reportPath: String, report: String, baseline: Baseline, hints: [String]) -> String {
        """
        ## Bug report `\(reportPath)`

        \(report.prefix(40_000))

        ## What you can read

        A snapshot of the project's main branch: \(baseline.label)\(baseline.subject.isEmpty ? "" : " — \"\(baseline.subject)\""). It holds committed \
        files only: nothing uncommitted and nothing from any other branch. The report was written against another state of the \
        project, so paths in it may have moved or changed. Read-only; change nothing.
        \(hints.isEmpty ? "" : "\nCommits on main that mention this report (leads only, never evidence by themselves):\n" + hints.map { "- " + $0 }.joined(separator: "\n") + "\n")
        Task: decide whether the problem this report describes still exists on that snapshot. Read the code that implements each \
        reported step and each difference between the expected and the actual behaviour; find the files the report names or the code it points to.
        - `already-fixed`: only with concrete evidence that the reported scenario is now handled, and that no further correction is \
        needed. Give `basis`: `fix-in-code` (the code now does what the report expected), `covered-by-test` (a test on the snapshot \
        covers the scenario and the code it tests does it) or `scenario-removed` (the code path of the scenario no longer exists). \
        Give `evidence`: for each piece, the path of a file in the snapshot and what it shows about THIS scenario. In `explanation` \
        say why nothing more needs to be corrected. Paths must exist in the snapshot.
        - Not finding the problem, not being able to reproduce it, or a fix the report only claims without code that shows it is NOT \
        evidence: that is `inconclusive` (basis `could-not-reproduce` or `none`), with the reason.
        - `still-present`: the snapshot still contains the behaviour the report describes; give the finding in `reason`.
        - `inconclusive`: the code does not settle it (it needs running the app, data or an environment, or the code could not be \
        located); say in `reason` what is missing.
        Write every field in English. For `still-present` and `inconclusive`, `basis` is `none`, `evidence` is `[]` and `explanation` is empty.
        """
    }

    // MARK: - The answer, checked

    private static func clean(_ text: Any?, limit: Int) -> String {
        let value = flatten((text as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        return value.count > limit ? String(value.prefix(limit)) + "…" : value
    }

    /// A project-relative path that stays inside `tree` and exists there; nil otherwise.
    static func existingPath(_ path: String, in tree: URL, excluding report: String) -> String? {
        var value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("./") { value.removeFirst(2) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), !parts.contains(".."), !parts.contains(where: { $0.isEmpty }) else { return nil }
        guard value != report else { return nil }
        guard FileManager.default.fileExists(atPath: tree.appendingPathComponent(value).path) else { return nil }
        return value
    }

    /// The assistant's answer as a verdict. An already-fixed claim stands only when it meets the evidence rule: a basis that is
    /// evidence, at least one piece of evidence naming an existing file of the snapshot (not the report itself) with a finding,
    /// and an explanation. Anything less becomes inconclusive, so a wrong or careless answer can never close a report (REQ-004).
    static func verdict(from object: [String: Any]?, baseline: Baseline, tree: URL?, reportPath: String = "") -> Verdict {
        guard let object else { return inconclusive("The verification returned no answer.", baseline: baseline) }
        guard let outcome = (object["outcome"] as? String).flatMap(Outcome.init(rawValue:)) else {
            return inconclusive("The verification returned an answer that could not be read.", baseline: baseline)
        }
        let reason = clean(object["reason"], limit: 1_500)
        switch outcome {
        case .stillPresent:
            return Verdict(outcome: .stillPresent, reason: reason.isEmpty ? "The code on main still has the reported behaviour." : reason, baseline: baseline)
        case .inconclusive:
            return inconclusive(reason.isEmpty ? "The code on main does not settle whether the bug still exists." : reason, baseline: baseline)
        case .alreadyFixed:
            let basis = (object["basis"] as? String).flatMap(Basis.init(rawValue:)) ?? .none
            let explanation = clean(object["explanation"], limit: 1_500)
            var evidence: [Evidence] = []
            var rejected = 0
            for item in (object["evidence"] as? [[String: Any]] ?? []).prefix(8) {
                let finding = clean(item["finding"], limit: 600)
                if let tree, !finding.isEmpty, let path = existingPath(item["path"] as? String ?? "", in: tree, excluding: reportPath) {
                    evidence.append(Evidence(path: path, finding: finding))
                } else {
                    rejected += 1
                }
            }
            var gaps: [String] = []
            if !basis.isEvidence { gaps.append("its basis is \"\(basis.title)\", which is not evidence that the problem was fixed") }
            if evidence.isEmpty { gaps.append(rejected > 0 ? "none of the evidence it named is a file of main with a finding" : "it named no evidence") }
            if explanation.isEmpty { gaps.append("it did not explain why no further correction is needed") }
            guard gaps.isEmpty else {
                let claim = reason.isEmpty ? "" : " Its finding: \(reason)"
                return inconclusive("The check reported the bug as already fixed, but " + gaps.joined(separator: " and ")
                                    + ". The report stays as it is." + claim, baseline: baseline)
            }
            return Verdict(outcome: .alreadyFixed, reason: reason, basis: basis, evidence: evidence, explanation: explanation, baseline: baseline)
        }
    }

    // MARK: - The report

    static let sectionName = "Validity check"

    /// The text of the report's "Validity check" section: the latest check, so a reader of the report sees the baseline,
    /// the evidence and the reason without opening anything else (REQ-005).
    static func sectionText(_ verdict: Verdict, today: String) -> String {
        var parts: [String] = []
        switch verdict.outcome {
        case .alreadyFixed: parts.append("**Outcome:** Already fixed — closed automatically on \(today).")
        case .stillPresent: parts.append("**Outcome:** Still present on main (checked \(today)).")
        case .inconclusive: parts.append("**Outcome:** Inconclusive (checked \(today)). The status was not changed.")
        }
        if let baseline = verdict.baseline {
            parts.append("**Verified against:** \(baseline.label)" + (baseline.subject.isEmpty ? "" : " — \(baseline.subject)"))
        } else {
            parts.append("**Verified against:** no revision of main could be identified.")
        }
        if verdict.outcome == .alreadyFixed {
            parts.append("**Basis:** \(verdict.basis.title).")
            parts.append("**Evidence:**\n" + verdict.evidence.map { "- `\($0.path)` — \($0.finding)" }.joined(separator: "\n"))
            if !verdict.reason.isEmpty { parts.append("**Finding:** \(verdict.reason)") }
            parts.append("**Why no further correction is needed:** \(verdict.explanation)")
        } else {
            parts.append("**Reason:** \(verdict.reason)")
        }
        return flatten(parts.joined(separator: "\n\n"))
    }

    /// A line that starts a level-2 heading would split the report's sections: drop its marker.
    static func flatten(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.hasPrefix("## ") ? String($0.dropFirst(3)) : $0 }.joined(separator: "\n")
    }

    /// True when saving `verdict` would not change the report: a check that found nothing new is not written again.
    static func isRecorded(_ verdict: Verdict, today: String, in body: String) -> Bool {
        guard verdict.outcome != .alreadyFixed else { return false }
        let existing = BugReportLayout.sections(body).first { $0.heading == sectionName }?.text ?? ""
        let new = sectionText(verdict, today: today)
        func undated(_ text: String) -> String {
            text.replacingOccurrences(of: #"\(checked \d{4}-\d{2}-\d{2}\)"#, with: "(checked)", options: .regularExpression)
        }
        return undated(existing) == undated(new)
    }

    /// Saves the verdict in the report: the "Validity check" section is replaced by this check's record, and an already-fixed verdict
    /// closes the report (status `closed`) and adds the reason to the discussion, where the reader of the conversation sees it.
    static func record(_ verdict: Verdict, today: String, front: inout FrontMatter, body: inout String) {
        var sections = BugReportLayout.sections(body)
        let text = sectionText(verdict, today: today)
        if let index = sections.firstIndex(where: { $0.heading == sectionName }) {
            sections[index].text = text
        } else {
            let at = sections.firstIndex { BugReportLayout.kept.contains($0.heading) } ?? sections.count
            sections.insert((sectionName, text), at: at)
        }
        if verdict.outcome == .alreadyFixed {
            front.set("status", "closed")
            front.set("ready_to_fix", nil)
            let evidence = verdict.evidence.map { "`\($0.path)`" }.joined(separator: ", ")
            BugReportLayout.appendDiscussion(&sections, speaker: "Validity check", date: today, message: flatten(
                "Closed automatically: the problem is already fixed on \(verdict.baseline?.label ?? "main"). \(verdict.explanation) Evidence: \(evidence). See the Validity check section."))
        }
        body = BugReportLayout.join(sections)
    }

    // MARK: - What the analysis is told

    /// The part of the analysis prompt that carries the outcome. Uncertainty is stated, never presented as confirmed validity (REQ-004).
    static func note(for verdict: Verdict, closeError: String? = nil) -> String {
        let basis = verdict.baseline?.label ?? "main (no revision could be identified)"
        if let closeError {
            return "Validity check against \(basis): the problem looks already fixed, but the report could not be closed (\(closeError)), so the finding is not recorded. The report stays open. State this in the report and treat the finding as unconfirmed: \(verdict.reason)"
        }
        switch verdict.outcome {
        case .stillPresent:
            return "Validity check against \(basis): the problem is still present on main. \(verdict.reason)"
        case .inconclusive:
            return "Validity check against \(basis): INCONCLUSIVE. It is not established whether this bug still exists. Reason: \(verdict.reason) Say so in the Summary and list in Missing information what would settle it; do not present the bug as confirmed, and do not present it as fixed."
        case .alreadyFixed:
            return "Validity check against \(basis): the problem is already fixed on main. \(verdict.reason)"
        }
    }

    // MARK: - The gate

    /// What the analysis receives when the check lets it continue.
    struct Passed {
        var verdict: Verdict
        /// Set when the check found the problem fixed but the report could not be closed: the analysis goes on, no closure is claimed.
        var closeError: String?
        var note: String { BugValidity.note(for: verdict, closeError: closeError) }
    }

    /// The check as a step in front of an analysis. `verify` runs the verification (nil when the user stopped it); `save` records the
    /// verdict in the report and returns the error text when that failed.
    struct Gate {
        var verify: () async -> Verdict?
        var save: (Verdict) -> String?

        enum Result {
            /// The analysis goes on.
            case proceed(Passed)
            /// Already fixed and the report is closed: the investigation of this problem ends.
            case closed(Verdict)
            /// The user stopped the check: nothing else runs.
            case stopped
        }

        func run() async -> Result {
            guard let verdict = await verify() else { return .stopped }
            let failure = save(verdict)
            guard verdict.outcome == .alreadyFixed else { return .proceed(Passed(verdict: verdict, closeError: nil)) }
            // The investigation stops only after the closure is saved (DEC-004); a failed save is reported and not claimed as success.
            if let failure { return .proceed(Passed(verdict: verdict, closeError: failure)) }
            return .closed(verdict)
        }
    }

    /// The three ways into an analysis of an existing report. Each passes through the gate before any analytical assistant call, and the
    /// user's own input is saved first (REQ-001).
    enum Entry {
        /// The Investigate action.
        static func investigate(gate: Gate, analyze: (Passed) async -> Void) async {
            guard case .proceed(let passed) = await gate.run() else { return }
            await analyze(passed)
        }

        /// An answer to a question: saved, checked, then the analysis.
        static func answer(record: () -> Bool, gate: Gate, analyze: (Passed) async -> Void) async {
            guard record() else { return }
            await investigate(gate: gate, analyze: analyze)
        }

        /// A discussion message: saved, checked, then the reply to it, then the analysis (which does not check again).
        static func discuss(record: () async -> Bool, gate: Gate, reply: (Passed) async -> Bool, analyze: (Passed) async -> Void) async {
            guard await record() else { return }
            guard case .proceed(let passed) = await gate.run() else { return }
            guard await reply(passed) else { return }
            await analyze(passed)
        }
    }
}

/// The layout of a bug report's body: "## " sections in order, and the ones a rewrite by the analysis keeps.
enum BugReportLayout {
    /// What the analysis does not write and therefore keeps when it rewrites the report.
    static let kept = [BugValidity.sectionName, "Attachments", "Clarifications", "Discussion", "Original description"]

    /// A report's "## " sections in order; the text before the first one has the heading "".
    /// "Original description" runs to the end: the user's own text may contain headings.
    static func sections(_ body: String) -> [(heading: String, text: String)] {
        var sections: [(heading: String, text: String)] = [("", "")]
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## "), sections.last?.heading != "Original description" {
                sections.append((line.dropFirst(3).trimmingCharacters(in: .whitespaces), ""))
            } else {
                sections[sections.count - 1].text += line + "\n"
            }
        }
        return sections.map { ($0.heading, $0.text.trimmingCharacters(in: .newlines)) }
            .filter { !$0.heading.isEmpty || !$0.text.isEmpty }
    }

    static func join(_ sections: [(heading: String, text: String)]) -> String {
        sections.map { $0.heading.isEmpty ? $0.text : "## \($0.heading)\n\n\($0.text)" }.joined(separator: "\n\n")
    }

    /// Adds an entry to the "Discussion" section, creating it before "Original description" when there is none.
    static func appendDiscussion(_ sections: inout [(heading: String, text: String)], speaker: String, date: String, message: String) {
        let entry = "### \(speaker) · \(date)\n\n\(message)"
        if let index = sections.firstIndex(where: { $0.heading == "Discussion" }) {
            sections[index].text += "\n\n" + entry
        } else {
            let at = sections.firstIndex { $0.heading == "Original description" } ?? sections.count
            sections.insert(("Discussion", entry), at: at)
        }
    }

    /// The report after the analysis rewrote its own sections: `generated` first, then every kept section as it was. A hand-written
    /// report keeps its text as the original description. `fallbackTitle` heads a report that has no heading of its own.
    static func rewritten(_ body: String, generated: [(heading: String, text: String)], fallbackTitle: String) -> String {
        var existing = sections(body)
        let heading = existing.first { $0.heading.isEmpty }?.text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
        if !existing.contains(where: { $0.heading == "Original description" }) {
            let own = existing.filter { !kept.contains($0.heading) }
                .map { section -> (heading: String, text: String) in
                    section.heading.isEmpty
                        ? ("", section.text.components(separatedBy: "\n").filter { !$0.hasPrefix("# ") }.joined(separator: "\n"))
                        : section
                }
            existing.removeAll { !kept.contains($0.heading) }
            existing.append(("Original description", join(own)))
        }
        var rebuilt = generated
        for name in kept {
            if let section = existing.first(where: { $0.heading == name }) { rebuilt.append(section) }
        }
        return (heading ?? "# \(fallbackTitle)") + "\n\n" + join(rebuilt)
    }
}
