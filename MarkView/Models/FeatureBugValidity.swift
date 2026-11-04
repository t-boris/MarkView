import Foundation

/// The app's side of the bug validity check (BugValidity): the real git runner, the verification call that reads an export of main
/// instead of the working tree, and the saving of the outcome in the report. The rules and the order of steps are in BugValidity and
/// are checked without the app; this file only connects them to the project, the assistant and the report store.
extension FeatureAssistant {
    /// `git` through the app's runner: both pipes are drained and a stalled process is ended after the timeout.
    static let bugValidityGit: BugValidity.GitRunner = { arguments, directory, timeout in
        let output = await GitHubClient.execute(arguments, in: directory, git: true, timeout: timeout)
        return BugValidity.GitOutput(status: output.status, stdout: output.stdout, stderr: output.stderr)
    }

    /// The step that runs in front of every analysis of the report at `url`.
    func validityGate(for url: URL) -> BugValidity.Gate {
        BugValidity.Gate(verify: { await self.verifyBug(url) }, save: { self.recordValidity($0, in: url) })
    }

    /// Verifies the report against main. Never throws: whatever goes wrong is an inconclusive verdict with its reason, which the
    /// analysis is told. Nil only when the user stopped the verification (then nothing else runs).
    func verifyBug(_ url: URL) async -> BugValidity.Verdict? {
        guard let bug = BugReport.load(url), let text = try? String(contentsOf: url, encoding: .utf8), let root = store.root else {
            return BugValidity.inconclusive("The report could not be read.")
        }
        guard let baseline = await BugValidity.resolveMain(root: root, git: Self.bugValidityGit) else {
            return BugValidity.inconclusive("The project's main branch could not be identified (the project is not a git repository, or it has no main branch), so the report could not be checked against it.")
        }
        let hints = await BugValidity.commitHints(key: bug.key, issues: bug.issueNumbers, baseline: baseline, root: root, git: Self.bugValidityGit)
        guard let export = await BugValidity.exportMain(baseline, root: root, git: Self.bugValidityGit) else {
            return BugValidity.inconclusive("The code of \(baseline.label) could not be exported for reading (it failed, took too long or is too large), so the report could not be checked against it.", baseline: baseline)
        }
        defer { export.remove() }
        let key = "validity:bug:" + bug.key
        let reportPath = store.relativePath(url)
        let prompt = BugValidity.prompt(reportPath: reportPath, report: FrontMatter.split(text).1, baseline: baseline, hints: hints)
        guard let object = await structured(key, prompt: prompt, schema: BugValidity.schema, effort: "medium", readable: export.tree) else {
            if actions[key]?.phase == .stopped { return nil }
            let why = error.map { ": \($0)" } ?? "."
            return BugValidity.inconclusive("The verification did not complete" + why, baseline: baseline)
        }
        return BugValidity.verdict(from: object, baseline: baseline, tree: export.tree, reportPath: reportPath)
    }

    /// Saves the verdict in the report. An already-fixed verdict closes the report; the others only record the latest check (and only
    /// when it says something new). Returns the error text when an already-fixed verdict could not be saved: the closure is then not claimed.
    func recordValidity(_ verdict: BugValidity.Verdict, in url: URL) -> String? {
        let today = FeatureStore.today
        if verdict.outcome != .alreadyFixed {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               BugValidity.isRecorded(verdict, today: today, in: FrontMatter.split(text).1) { return nil }
            // A check that only notes the outcome must never block the analysis; a failed save is not shown for it.
            let saved = store.lastError
            store.updateBug(url) { front, body in BugValidity.record(verdict, today: today, front: &front, body: &body) }
            store.lastError = saved
            return nil
        }
        let previous = store.lastError
        store.lastError = nil
        let written = store.updateBug(url) { front, body in BugValidity.record(verdict, today: today, front: &front, body: &body) }
        if written { store.lastError = previous; return nil }
        let reason = store.lastError ?? "The report could not be saved."
        store.lastError = "The check found this bug already fixed on \(verdict.baseline?.label ?? "main"), but closing the report failed: \(reason) The report stays open."
        return reason
    }
}
