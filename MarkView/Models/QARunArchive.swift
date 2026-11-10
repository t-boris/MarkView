import Foundation

// End-to-End QA (feature end-to-end-qa, REQ-015): the runs a scenario has made, read back from `.dde/qa/runs/` so that a run can be looked at
// again after the app was restarted, and its findings marked. The run just made is QARunModel; this is every run on this Mac, newest first.

@MainActor
final class QARunArchive: ObservableObject {
    /// The runs of the scenario shown, newest first.
    @Published private(set) var runs: [QARunRecord] = []
    /// The run being looked at; nil shows the scenario.
    @Published private(set) var opened: QARunRecord?
    @Published private(set) var notice: String?

    var root: URL?
    /// Where the bug reports of the findings are; set by the window that owns them.
    var bugFiler: QABugFiler?

    private var loading: Task<Void, Never>?
    private var triageTail: Task<Void, Never>?
    private var scenarioID = ""

    /// Reads the runs of `scenarioID` off the main thread. The run being looked at stays, with whatever the file now holds.
    func reload(scenarioID: String) {
        self.scenarioID = scenarioID
        guard let root else { runs = []; opened = nil; return }
        loading?.cancel()
        loading = Task { [weak self] in
            let all = await Task.detached(priority: .userInitiated) { QAStore.loadRuns(root) }.value
            guard !Task.isCancelled, let self else { return }
            self.runs = all.filter { $0.scenarioID == scenarioID }
            if let open = self.opened { self.opened = self.runs.first { $0.id == open.id } }
        }
    }

    func open(_ id: String) {
        notice = nil
        opened = runs.first { $0.id == id }
    }

    func close() {
        opened = nil
        notice = nil
    }

    /// Marks a finding of the run being looked at; one mark after another, so that none is lost.
    func mark(_ id: String, _ state: QATriageState?, note: String = "") {
        let previous = triageTail
        triageTail = Task { [weak self] in
            await previous?.value
            await self?.applyMark(id, state, note: note)
        }
    }

    private func applyMark(_ id: String, _ state: QATriageState?, note: String) async {
        guard let record = opened, let root, let outcome = await QATriageService.apply(record, root: root, finding: id, state: state, note: note, filer: bugFiler) else { return }
        if let index = runs.firstIndex(where: { $0.id == outcome.record.id }) { runs[index] = outcome.record }
        if opened?.id == outcome.record.id { opened = outcome.record }
        notice = outcome.notice
    }

    // MARK: Files of a run

    /// The recording of a branch of the run, when the file is there: the run writes `branch-<n>.mp4`, n counting the selected branches from 1.
    func video(of branch: String, in record: QARunRecord) -> URL? {
        guard let root, let index = record.selected.firstIndex(of: branch) else { return nil }
        let url = QAStore.runFolder(root, runID: record.id).appendingPathComponent("branch-\(index + 1).mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The picture of a finding's screen, when the file is there.
    func frame(of finding: QAFinding, in record: QARunRecord) -> URL? {
        guard let root, let url = QABugDrafts.frameURL(finding.frame, in: QAStore.runFolder(root, runID: record.id)) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
