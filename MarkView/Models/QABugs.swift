import Foundation

// End-to-End QA (feature end-to-end-qa, DEC-010): the bug reports a run asks for. A failed, blocked or interrupted check gets one bug
// each, whatever the cause; a finding of the step-by-step review gets one only when it is a defect, and a suggestion stays in the run
// report. This file is the pure mapping from a run to the reports (nothing is written here); QABugFiler.swift files them. Foundation
// only; checked on its own by tools/tests/qa-bugs-tests.sh.

/// A picture of the run to copy beside a bug report: a screen a finding is about.
struct QABugPicture: Equatable, Sendable {
    var label: String
    /// The file inside the run's folder.
    var file: URL
}

/// One bug report a run asks for, before it is written. `key` names what it reports (a check of a run, or a finding of a run), so that
/// filing the same candidate again is recognised and creates nothing.
struct QABugCandidate: Equatable, Identifiable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A branch of the run that failed, was blocked or was interrupted.
        case check(branch: String, outcome: QAOutcome)
        /// A finding of the review that is a defect.
        case finding(id: String)
    }

    var key: String
    var origin: Origin
    var runID: String
    var title: String
    /// One of the project's bug severities (`FeatureVocabulary.severities`).
    var severity: String
    /// The Markdown after the front matter. Pictures are not in it: the filer appends them once they are copied.
    var body: String
    var pictures: [QABugPicture]

    var id: String { key }

    /// The outcome of the check; nil for a finding.
    var outcome: QAOutcome? {
        if case .check(_, let outcome) = origin { return outcome }
        return nil
    }

    var branch: String? {
        if case .check(let branch, _) = origin { return branch }
        return nil
    }

    var findingID: String? {
        if case .finding(let id) = origin { return id }
        return nil
    }
}

/// The recording of one branch: where it is (relative to the project) and when it began, in seconds from the start of the run.
struct QABugVideo: Equatable {
    var path: String
    var startsAt: Double = 0
}

enum QABugDrafts {
    /// Title of the bug made for a defect finding (the bug of a check opens with `QAOutcome.bugTitlePrefix`).
    static let defectTitlePrefix = "QA defect"
    /// The pictures one bug carries at most.
    static let maxPictures = 6
    /// The findings one check bug lists at most.
    static let maxListedFindings = 20

    static let highSeverity = "high"
    static let mediumSeverity = "medium"
    static let lowSeverity = "low"

    // MARK: Mapping

    /// The bug reports of a run, in the order they are told: the checks in the order they were selected, then the defect findings in
    /// the order they were noticed. Passed, uncovered and not yet checked branches and suggestions give none. `videos` are the
    /// recordings on this Mac by branch id (`.dde/` is not committed, so the report names the file and does not link it); `runFolder` is
    /// where the findings' frames are.
    static func drafts(run: QARunRecord, scenario: QAScenario, findings: [QAFinding], videos: [String: QABugVideo], runFolder: URL?, now: Date) -> [QABugCandidate] {
        let context = Context(run: run, scenario: scenario, findings: findings, videos: videos, runFolder: runFolder, now: now)
        var candidates: [QABugCandidate] = []
        var seen = Set<String>()
        for branch in run.selected {
            guard let result = run.results.first(where: { $0.branch == branch }), result.verdict.outcome.createsBug,
                  let prefix = result.verdict.outcome.bugTitlePrefix else { continue }
            let candidate = context.check(result, prefix: prefix)
            if seen.insert(candidate.key).inserted { candidates.append(candidate) }
        }
        for finding in findings where finding.isDefect {
            let candidate = context.defect(finding)
            if seen.insert(candidate.key).inserted { candidates.append(candidate) }
        }
        return candidates
    }

    /// The key of the bug of a branch's check in a run. A branch id has only letters, digits, - and _ between its > signs, so the key
    /// of a check cannot equal the key of a finding.
    static func key(run: String, branch: String) -> String { "\(run):\(component(branch))" }

    static func key(run: String, finding: String) -> String { "\(run):finding:\(component(finding))" }

    /// Severity of the bug of a check: a check that did not hold is the product's fault, a blocked or interrupted one is not (yet).
    static func severity(of outcome: QAOutcome) -> String {
        switch outcome {
        case .failed: return highSeverity
        case .blocked: return mediumSeverity
        case .interrupted: return lowSeverity
        case .passed, .uncovered: return mediumSeverity
        }
    }

    /// The picture file of a finding's frame, which is named relative to the run's folder. Nil without a folder or a frame, and for a
    /// frame that is an absolute path or leaves the folder.
    static func frameURL(_ frame: String?, in folder: URL?) -> URL? {
        guard let folder, let frame, !frame.isEmpty, !frame.hasPrefix("/"), !frame.hasPrefix("~"), !frame.contains("\0") else { return nil }
        let parts = frame.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(".."), !parts.contains("") else { return nil }
        let url = folder.appendingPathComponent(frame).standardizedFileURL
        return url.path.hasPrefix(folder.standardizedFileURL.path + "/") ? url : nil
    }

    // MARK: Text

    /// `text` on one line: every run of white space or control characters is one space; cut with an ellipsis at `limit` characters.
    static func line(_ text: String, _ limit: Int) -> String {
        let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.map { blank.contains($0) ? " " : $0 }))
        let joined = flat.split(separator: " ").joined(separator: " ")
        guard joined.count > limit else { return joined }
        return String(joined.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// `line`, cut at a word when there is one near the end.
    static func short(_ text: String, _ limit: Int) -> String {
        let joined = line(text, Int.max)
        guard joined.count > limit else { return joined }
        var head = Substring(joined.prefix(max(limit - 1, 0)))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 { head = head[..<space] }
        return String(head).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;:-–—"))) + "…"
    }

    /// `text` as a code span that its own back ticks cannot end.
    static func code(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        return longest == 0 ? "`\(text)`" : "\(fence) \(text) \(fence)"
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// An id as part of a key: white space and control characters (which a front matter line cannot hold) become underscores.
    private static func component(_ text: String) -> String {
        let blank = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { blank.contains($0) ? "_" : $0 }))
    }

    private static func words(_ reason: QABlockReason) -> String {
        switch reason {
        case .baselineNotEstablished: return "the baseline could not be established"
        case .launchFailed: return "the application could not be launched"
        case .secondInstanceRefused: return "a second instance of the application was refused"
        case .loginFailed: return "a login failed"
        case .permissionMissing: return "a permission is missing"
        case .approvalMissing: return "an approval is missing"
        case .elementNotFound: return "an element was not found"
        case .stepBudgetExhausted: return "the step budget ran out"
        case .other: return "another cause"
        }
    }

    private static func words(_ interruption: QAInterruption) -> String {
        switch interruption {
        case .stoppedByUser: return "stopped by the user"
        case .applicationCrashed: return "the application crashed"
        case .permissionRevoked: return "a permission was revoked"
        case .other: return "another cause"
        }
    }

    private static func verb(_ outcome: QAOutcome) -> String {
        switch outcome {
        case .failed: return "failed"
        case .blocked: return "was blocked"
        case .interrupted: return "was interrupted"
        case .passed: return "passed"
        case .uncovered: return "was not covered"
        }
    }

    private static func kindWord(_ kind: QANodeKind) -> String {
        switch kind {
        case .action: return "Action"
        case .check: return "Check"
        case .alternative: return "Alternative"
        case .failure: return "Failure"
        }
    }

    // MARK: Context

    /// Everything one run's reports are told from.
    private struct Context {
        let run: QARunRecord
        let scenario: QAScenario
        let findings: [QAFinding]
        let videos: [String: QABugVideo]
        let runFolder: URL?
        let now: Date

        // MARK: Checks

        func check(_ result: QACheckResult, prefix: String) -> QABugCandidate {
            let verdict = result.verdict
            let outcome = verdict.outcome
            let branch = QABranch(nodes: result.branch.split(separator: ">").map(String.init))
            let label = branchLabel(branch, id: result.branch)
            let related = findings.filter { finding in finding.node.map { branch.nodes.contains($0) } ?? false }
            let target = targetText()

            let summary = "End-to-End QA run \(code(run.id)) against \(target): the branch \"\(line(label, 120))\" of the scenario "
                + "\"\(line(scenario.title, 120))\" \(verb(outcome))."
            var actual: [String] = []
            let place = verdict.node.map { " at the step \(stepName($0))" } ?? ""
            switch outcome {
            case .failed:
                actual.append("The check did not hold\(place).")
            case .blocked:
                actual.append("The check could not go on\(place)" + (verdict.blockReason.map { " because \(words($0))" } ?? "") + ".")
            case .interrupted:
                actual.append("The check was stopped" + (verdict.interruption.map { " (\(words($0)))" } ?? "") + ".")
            case .passed, .uncovered:
                break
            }
            let reason = line(verdict.reason, 1_500)
            if !reason.isEmpty { actual.append("Reason: \(reason)") }

            var details = [
                "- Scenario: \(line(scenario.title, 120)) (\(code(scenario.id)))",
                "- Branch: \(line(label, 120)) (\(code(result.branch)))",
                "- Outcome: \(outcome.label)",
            ]
            if let reason = verdict.blockReason { details.append("- Block reason: \(words(reason))") }
            if let interruption = verdict.interruption { details.append("- Interruption: \(words(interruption))") }
            if let node = verdict.node { details.append("- Step: \(stepName(node))") }
            let video = videos[result.branch]
            details += runLines(video: video)

            let title = titled(prefix, label, shortReason(verdict))
            let body = document(title: title, [
                ("Summary", summary),
                ("Steps to reproduce", steps(of: branch, marking: verdict.node, as: outcome).joined(separator: "\n")),
                ("Expected", expected(verdict)),
                ("Actual", actual.joined(separator: "\n\n")),
                ("Environment", environment(apps: scenario.apps(in: branch))),
                ("QA run", details.joined(separator: "\n")),
                ("Findings", findingList(related, video: video)),
            ])
            return QABugCandidate(key: QABugDrafts.key(run: run.id, branch: result.branch), origin: .check(branch: result.branch, outcome: outcome),
                                  runID: run.id, title: title, severity: QABugDrafts.severity(of: outcome),
                                  body: body, pictures: pictures(of: related))
        }

        private func titled(_ prefix: String, _ label: String, _ reason: String) -> String {
            "\(prefix): \(short(label, 80)) — \(reason)"
        }

        /// What the title says went wrong: the verdict's reason, else the block reason or the interruption.
        private func shortReason(_ verdict: QACheckVerdict) -> String {
            let reason = short(verdict.reason, 90)
            if !reason.isEmpty { return reason }
            if let block = verdict.blockReason { return words(block) }
            if let interruption = verdict.interruption { return words(interruption) }
            return "no reason recorded"
        }

        private func expected(_ verdict: QACheckVerdict) -> String {
            if verdict.outcome == .failed, let id = verdict.node, let node = scenario.node(id) {
                let text = line(node.detail.isEmpty ? node.title : node.detail, 400)
                return node.kind == .check ? text : "The step \"\(line(node.title, 160))\" works: \(text)"
            }
            return "The check runs through every step of the branch and reaches a verdict."
        }

        // MARK: Findings

        func defect(_ finding: QAFinding) -> QABugCandidate {
            let title = "\(defectTitlePrefix): \(short(finding.title.isEmpty ? finding.kind.rawValue : finding.title, 120))"
            let covering = finding.node.flatMap { node in
                run.selected.map { QABranch(nodes: $0.split(separator: ">").map(String.init)) }.first { $0.nodes.contains(node) }
            }
            var reproduction: [String] = []
            if let covering, let node = finding.node {
                reproduction = steps(of: covering, upTo: node, marking: node, as: nil)
            }
            let apps = finding.app.map { [$0] } ?? covering.map { scenario.apps(in: $0) } ?? []
            var details = [
                "- Scenario: \(line(scenario.title, 120)) (\(code(scenario.id)))",
                "- Kind: \(finding.kind.rawValue)",
                "- Severity: \(finding.severity.rawValue)",
            ]
            if let covering { details.append("- Branch: \(line(branchLabel(covering, id: covering.id), 120)) (\(code(covering.id)))") }
            if let node = finding.node { details.append("- Step: \(stepName(node))") }
            let video = covering.flatMap { videos[$0.id] }
            if let time = videoTime(finding, video) { details.append("- At \(String(format: "%.1f", time)) s of the video") }
            details += runLines(video: video)

            let detail = line(finding.detail, 1_500)
            let body = document(title: title, [
                ("Summary", "End-to-End QA run \(code(run.id)) against \(targetText()) found a defect: \(line(finding.title, 200))."),
                ("Steps to reproduce", reproduction.joined(separator: "\n")),
                ("Actual", detail),
                ("Proposed change", line(finding.proposal, 1_500)),
                ("Environment", environment(apps: apps)),
                ("QA run", details.joined(separator: "\n")),
            ])
            return QABugCandidate(key: QABugDrafts.key(run: run.id, finding: finding.id), origin: .finding(id: finding.id), runID: run.id,
                                  title: title, severity: finding.severity.rawValue, body: body, pictures: pictures(of: [finding]))
        }

        private func findingList(_ list: [QAFinding], video: QABugVideo?) -> String {
            var lines = list.prefix(maxListedFindings).flatMap { findingEntry($0, video: video) }
            if list.count > maxListedFindings { lines.append("- … and \(list.count - maxListedFindings) more in the run report.") }
            return lines.joined(separator: "\n")
        }

        private func findingEntry(_ finding: QAFinding, video: QABugVideo?) -> [String] {
            var head = "- **\(line(finding.title, 160))** — \(finding.kind.rawValue), \(finding.severity.rawValue), \(finding.isDefect ? "reported as a bug" : "suggestion")"
            if let node = finding.node { head += ", step \(stepName(node))" }
            if let app = finding.app { head += ", \(appName(app))" }
            if let time = videoTime(finding, video) { head += ", at \(String(format: "%.1f", time)) s of the video" }
            var lines = [head]
            let detail = line(finding.detail, 600)
            if !detail.isEmpty { lines.append("  - Finding: \(detail)") }
            let proposal = line(finding.proposal, 600)
            if !proposal.isEmpty { lines.append("  - Proposal: \(proposal)") }
            return lines
        }

        /// The frames of the findings, once each, inside the run's folder.
        private func pictures(of list: [QAFinding]) -> [QABugPicture] {
            var pictures: [QABugPicture] = []
            for finding in list {
                guard pictures.count < maxPictures, let file = QABugDrafts.frameURL(finding.frame, in: runFolder),
                      !pictures.contains(where: { $0.file == file }) else { continue }
                pictures.append(QABugPicture(label: line(finding.title.isEmpty ? finding.kind.rawValue : finding.title, 100), file: file))
            }
            return pictures
        }

        // MARK: Shared text

        /// Where the finding is in the recording of its branch: its time from the start of the run, less the time the recording began.
        private func videoTime(_ finding: QAFinding, _ video: QABugVideo?) -> Double? {
            guard let video, !video.path.isEmpty, let time = finding.time else { return nil }
            return max(0, time - video.startsAt)
        }

        private func branchLabel(_ branch: QABranch, id: String) -> String {
            branch.nodes.allSatisfy { scenario.node($0) != nil } ? scenario.label(of: branch) : id
        }

        private func stepName(_ id: String) -> String {
            scenario.node(id).map { "\"\(line($0.title, 100))\" (\(code(id)))" } ?? code(id)
        }

        private func appName(_ id: String) -> String { scenario.app(id).map { line($0.name, 80) } ?? id }

        /// The steps of a branch in order, up to and including `last` when it is given. The step the verdict is about is marked.
        private func steps(of branch: QABranch, upTo last: String? = nil, marking marked: String?, as outcome: QAOutcome?) -> [String] {
            var lines: [String] = []
            for (index, id) in branch.nodes.enumerated() {
                var text = "\(index + 1). " + stepText(id)
                if id == marked { text += " — **\(outcome.map { "\(verb($0)) here" } ?? "the finding is about this step")**" }
                lines.append(text)
                if id == last { break }
            }
            return lines
        }

        private func stepText(_ id: String) -> String {
            guard let node = scenario.node(id) else { return "\(code(id)) (no longer in the scenario)" }
            var text = "\(kindWord(node.kind)): \(line(node.title, 160))"
            let detail = line(node.detail, 300)
            if !detail.isEmpty { text += " — \(detail)" }
            var who: [String] = []
            if let actor = scenario.actorID(of: node) { who.append(scenario.actors.first { $0.id == actor }?.name ?? actor) }
            if scenario.apps.count > 1, let app = scenario.appID(of: node) { who.append(appName(app)) }
            if !who.isEmpty { text += " (\(line(who.joined(separator: ", "), 80)))" }
            return text
        }

        private func targetText() -> String {
            let name = scenario.target(run.targetID)?.name ?? run.targetID
            return "the target \(line(name, 80)) (\(run.targetKind.rawValue))"
        }

        /// The target, and where each application of the branch runs there; an address is shown without credentials, query or fragment.
        private func environment(apps: [String]) -> String {
            var parts = ["MarkView End-to-End QA", targetText()]
            let target = scenario.target(run.targetID)
            for id in apps {
                guard let location = target?.locations[id] else { continue }
                if let url = location.url {
                    parts.append("\(appName(id)) at \(address(url))")
                } else if let application = location.application {
                    parts.append("\(appName(id)) is \(line(application.name, 80)) (\(line(application.bundleIdentifier, 120)))")
                }
            }
            return parts.joined(separator: " · ")
        }

        private func address(_ text: String) -> String {
            guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), parts.host != nil else { return "an address that is not shown" }
            parts.user = nil
            parts.password = nil
            parts.query = nil
            parts.fragment = nil
            return code(line(parts.string ?? "", 200))
        }

        private func runLines(video: QABugVideo?) -> [String] {
            var lines = ["- Run: \(code(run.id)), started \(iso(run.startedAt))" + (run.finishedAt.map { ", finished \(iso($0))" } ?? ", not finished")]
            if let path = video?.path, !path.isEmpty {
                lines.append("- Video (a file on this Mac: `.dde/` is not committed): \(code(path))")
            }
            lines.append("- Reported: \(iso(now))")
            return lines
        }

        private func document(title: String, _ sections: [(String, String)]) -> String {
            "# \(title)\n\n" + sections.filter { !$0.1.isEmpty }.map { "## \($0.0)\n\n\($0.1)" }.joined(separator: "\n\n")
        }

        private func line(_ text: String, _ limit: Int) -> String { QABugDrafts.line(text, limit) }
        private func short(_ text: String, _ limit: Int) -> String { QABugDrafts.short(text, limit) }
        private func code(_ text: String) -> String { QABugDrafts.code(text) }
        private func iso(_ date: Date) -> String { QABugDrafts.iso(date) }
        private func verb(_ outcome: QAOutcome) -> String { QABugDrafts.verb(outcome) }
        private func words(_ reason: QABlockReason) -> String { QABugDrafts.words(reason) }
        private func words(_ interruption: QAInterruption) -> String { QABugDrafts.words(interruption) }
        private func kindWord(_ kind: QANodeKind) -> String { QABugDrafts.kindWord(kind) }
    }
}
