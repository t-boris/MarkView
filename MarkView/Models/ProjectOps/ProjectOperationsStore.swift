import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import UserNotifications
import MarkViewCore

@MainActor
final class ProjectOperationRun: ObservableObject, Identifiable {
    let id: String
    let snapshot: ProjectOperation
    let session: TerminalSession
    let started = Date()
    @Published var state = "running"
    @Published var exitCode: Int32?
    @Published var ended: Date?
    @Published var definitionNotice: String?
    @Published var graceSeconds: Int?
    @Published var forced = false
    private(set) var cancelRequested = false
    private var escalation: Task<Void, Never>?

    init(snapshot: ProjectOperation, directory: URL) {
        id = snapshot.id
        self.snapshot = snapshot
        session = TerminalSession(directory: directory, title: snapshot.label, operationCommand: snapshot.command)
    }

    var isActive: Bool { state == "running" || state == "cancelling" }

    func cancel() {
        guard state == "running", session.isRunning else { return }
        cancelRequested = true
        state = "cancelling"
        graceSeconds = 30
        session.signalProcessGroup(SIGINT)
        escalation = Task { [weak self] in
            for remaining in (1...30).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.state == "cancelling", !Task.isCancelled else { return }
                self.graceSeconds = remaining - 1
            }
            guard let self, self.state == "cancelling" else { return }
            self.session.signalProcessGroup(SIGTERM)
            for remaining in (1...5).reversed() {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.state == "cancelling", !Task.isCancelled else { return }
                self.graceSeconds = remaining - 1
            }
            self.forceStop()
        }
    }

    func forceStop() {
        guard isActive else { return }
        cancelRequested = true
        state = "cancelling"
        forced = true
        graceSeconds = nil
        session.signalProcessGroup(SIGKILL)
    }

    func finish(exitCode: Int32) {
        escalation?.cancel()
        escalation = nil
        graceSeconds = nil
        self.exitCode = exitCode
        ended = Date()
        state = cancelRequested ? "cancelled" : exitCode == 0 ? (snapshot.remoteTrigger ? "dispatched" : "succeeded") : "failed"
    }
}

/// The window that shows what the person starts in a project's operations: the console of a run and the editor of a definition.
/// The store is one per project folder, so the windows that show the same folder share the operations and their runs, but each
/// window owns what it has open (BUG-120 and the window-state audit): the store asks the window that started the action.
@MainActor
protocol ProjectOperationsPresenter: AnyObject {
    func showOperationConsole(selecting id: String)
    func showOperationEditor(_ request: ProjectOperationEditRequest)
    /// The window to bring forward when a notification of a finished run is clicked.
    var operationsHostWindow: NSWindow? { get }
}

@MainActor
final class ProjectOperationsStore: ObservableObject {
    private static var stores: [String: ProjectOperationsStore] = [:]
    /// The store of a project folder; the first window that asks makes it, and its questions go through that window's `prompts`.
    static func forRoot(_ root: URL, prompts: any UserPrompts) -> ProjectOperationsStore {
        let canonical = ProjectOperationDiscovery.canonical(root)
        if let existing = stores[canonical.path] { return existing }
        let store = ProjectOperationsStore(root: canonical, prompts: prompts)
        stores[canonical.path] = store
        return store
    }

    static func existing(rootPath: String) -> ProjectOperationsStore? {
        stores[ProjectOperationDiscovery.canonical(URL(fileURLWithPath: rootPath)).path]
    }

    static func stopAllBeforeQuit(prompts: any UserPrompts) async -> Bool {
        let active = stores.values.flatMap { $0.runs.values }.filter(\.isActive)
        guard !active.isEmpty else { await finishWritesBeforeQuit(); return true }
        let stop = UserPrompt(
            title: "Stop running project operations before quitting?",
            detail: active.map { $0.snapshot.label + ($0.snapshot.environment.map { " (\($0))" } ?? "") }.joined(separator: "\n"),
            buttons: ["Keep working", "Stop operations and quit"])
        guard prompts.confirm(stop, proceedingWith: 1) else { return false }
        for store in stores.values { store.cancelForClose() }
        while stores.values.contains(where: { $0.runs.values.contains(where: \.isActive) }) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await finishWritesBeforeQuit()
        return true
    }

    /// The edits and run records the person's last actions started are on disk before the application ends, and the reads and the
    /// discovery that were running stop.
    private static func finishWritesBeforeQuit() async {
        for store in stores.values {
            store.discoveryTask?.cancel()
            store.tasks.cancelAll()
            await store.writes.drain()
        }
    }

    let root: URL
    /// How the store asks the person before it runs, adopts, accepts, rejects or cancels something (`AR-22`).
    private let prompts: any UserPrompts
    /// The window that last started something here; `WorkspaceManager.operations()` sets it.
    weak var presenter: (any ProjectOperationsPresenter)?
    @Published private(set) var document = ProjectOperationsDocument()
    @Published private(set) var fileError: String?
    @Published private(set) var hasFile = false
    @Published private(set) var lastRuns: [String: ProjectOperationLastRun] = [:]
    @Published private(set) var runs: [String: ProjectOperationRun] = [:]
    @Published private(set) var revision = 0
    @Published var message: String? { didSet { revision += 1 } }
    @Published private(set) var discoveryPhase: String?
    @Published private(set) var discoveryReport: ProjectOperationDiscoveryReport?
    @Published private(set) var sourcesChanged = false
    private var discoveryTask: Task<Void, Never>?
    /// The reads this store starts (the history, the operations file, the sources' signature) and the start of a run: they end with the
    /// store, which is one per project folder for as long as the application runs, and a second start of one kind replaces the first.
    private let tasks = TaskBag()
    /// The edits and the run records, written in the order they were asked for (see `ProjectOperationWrites`).
    private let writes: ProjectOperationWrites
    /// The poll that reads the definition file again, a job of the app's scheduler (`AR-19`): paused while the app is in the background.
    private var pollKey: String { "project-operations-" + root.path }
    private var lastFileData: Data?
    private var refreshInFlight = false
    private var stalenessTick = 0
    private var stalenessInFlight = false
    private var suppressNotifications = false

    private init(root: URL, prompts: any UserPrompts) {
        self.root = root
        self.prompts = prompts
        writes = ProjectOperationWrites(root: root)
        if UNUserNotificationCenter.current().delegate == nil {
            UNUserNotificationCenter.current().delegate = ProjectOperationNotificationRouter.shared
        }
        refresh()
        tasks.store(Task {
            let previous = (try? await Task.detached { try ProjectOperationHistory.load(root: root) }.value) ?? [:]
            for (id, var record) in previous where record.state == "running" || record.state == "cancelling" {
                record.state = "interrupted"
                record.ended = Date()
                writes.record(record)
                lastRuns[id] = record
            }
            for (id, record) in previous where lastRuns[id] == nil { lastRuns[id] = record }
            revision += 1
        }, for: "history")
        let key = pollKey
        PollingScheduler.app.every(1.5, key: key) { [weak self] in
            guard let self else { PollingScheduler.app.stop(key: key); return }
            self.refresh()
            self.stalenessTick += 1
            if self.stalenessTick >= 10 {
                self.stalenessTick = 0
                self.checkSourceSignature()
            }
        }
        if Settings.standard.contains(fingerprintsKey) { checkSourceSignature() }
    }

    var operations: [ProjectOperation] { fileError == nil ? document.operations.filter { !$0.deleted } : [] }
    var deployOperations: [ProjectOperation] { operations.filter { $0.kind == "deploy" } }
    /// The operations shown up front (`ProjectOperation.primary`); the rest are found by search.
    var primaryOperations: [ProjectOperation] {
        let running = Set(runs.filter { $0.value.isActive }.keys)
        return ProjectOperation.primary(operations, running: running, lastStarted: lastRuns.mapValues(\.started))
    }
    var readOnly: Bool { document.version > 1 }

    func state(id: String) -> String? { runs[id]?.state ?? lastRuns[id]?.state }

    func unavailability(for operation: ProjectOperation) -> String? {
        if readOnly { return "Operations file version \(document.version) requires a newer MarkView." }
        let path = Self.resolve(operation.cwd, root: root)
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &directory) && directory.boolValue
            ? nil : "Working directory unavailable: " + path.path
    }

    func payloadJSON() -> String {
        struct State: Encodable {
            var state: String
            var exitCode: Int32?
            var ended: Date?
            var definitionNotice: String?
        }
        struct Payload: Encodable {
            var operations: [ProjectOperation]
            var primary: [String]
            var states: [String: State]
            var unavailable: [String: String]
            var error: String?
            var hasFile: Bool
            var discoveryPhase: String?
            var discoveryReport: ProjectOperationDiscoveryReport?
            var sourcesChanged: Bool
            var message: String?
            var readOnly: Bool
        }
        var states: [String: State] = [:]
        for (id, record) in lastRuns {
            states[id] = State(state: record.state, exitCode: record.exitCode, ended: record.ended, definitionNotice: nil)
        }
        for (id, run) in runs {
            states[id] = State(state: run.state, exitCode: run.exitCode, ended: run.ended,
                               definitionNotice: run.definitionNotice)
        }
        var unavailable: [String: String] = [:]
        for operation in operations {
            unavailable[operation.id] = unavailability(for: operation)
        }
        let payload = Payload(operations: operations, primary: primaryOperations.map(\.id),
                              states: states, unavailable: unavailable,
                              error: fileError, hasFile: hasFile, discoveryPhase: discoveryPhase,
                              discoveryReport: discoveryReport, sourcesChanged: sourcesChanged, message: message,
                              readOnly: readOnly)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let root = self.root
        tasks.store(Task {
            let result = await Task.detached { () -> (ProjectOperationsDocument?, Data?, Bool, String?) in
                let file = ProjectOperationsFile.url(root: root)
                let exists = FileManager.default.fileExists(atPath: file.path)
                do {
                    let data = exists ? try Data(contentsOf: file) : nil
                    let document = try ProjectOperationsFile.read(root: root)
                    return (document, data, exists, nil)
                } catch { return (nil, nil, exists, error.localizedDescription) }
            }.value
            refreshInFlight = false
            if let error = result.3 {
                if fileError != error { fileError = error; revision += 1 }
                return
            }
            guard let next = result.0 else { return }
            if lastFileData != result.1 || fileError != nil {
                document = next
                lastFileData = result.1
                hasFile = result.2
                fileError = nil
                for (id, run) in runs {
                    if let current = next.operations.first(where: { $0.id == id && !$0.deleted }) {
                        run.definitionNotice = current.command != run.snapshot.command || current.cwd != run.snapshot.cwd
                            ? "Definition changed since this run started" : nil
                    } else {
                        run.definitionNotice = "Operation removed since this run started"
                    }
                }
                revision += 1
            }
        }, for: "refresh")
    }

    /// Applies one UI action to the operations file. The edits are written one at a time in the order they were asked for, each on
    /// top of the file as the one before it left it (`ProjectOperationWrites`), so none is dropped by another; it reloads first, so a
    /// hand edit or git update is not lost either.
    func change(_ edit: @escaping (inout ProjectOperationsDocument) throws -> Void) {
        writes.edit(edit) { [self] result in
            switch result {
            case .success(let next):
                document = next
                fileError = nil
                refresh()
            case .failure(let error):
                fileError = error.localizedDescription
                revision += 1
            }
        }
    }

    func save(_ operation: ProjectOperation) {
        change { document in
            try operation.validate()
            if let index = document.operations.firstIndex(where: { $0.id == operation.id }) {
                document.operations[index] = operation
            } else {
                document.operations.append(operation)
            }
        }
    }

    func edit(id: String?) {
        guard !readOnly else { return }
        if let id, let operation = operations.first(where: { $0.id == id }) {
            presenter?.showOperationEditor(ProjectOperationEditRequest(operation: operation))
        } else if id == nil {
            presenter?.showOperationEditor(ProjectOperationEditRequest(operation: nil))
        }
    }

    func addUnknown(index: Int) {
        guard let report = discoveryReport, report.notDetermined.indices.contains(index) else { return }
        let item = report.notDetermined[index]
        presenter?.showOperationEditor(ProjectOperationEditRequest(operation: nil, kind: item.kind,
                                                                  environment: item.environment, label: item.label))
    }

    private var fingerprintsKey: SettingsKey<[String: Any]> { Setting.operationFingerprints(project: String(ContentHash.of(root.path).prefix(24))) }
    private var rejectedKey: SettingsKey<[String]> { Setting.operationsRejected(project: String(ContentHash.of(root.path).prefix(24))) }

    func checkSourceSignature() {
        guard !stalenessInFlight,
              let saved = Settings.standard.stored(fingerprintsKey) as? [String: String] else { return }
        stalenessInFlight = true
        let root = self.root
        let paths = Set(operations.filter { $0.origin == "discovered" }.flatMap { operation in
            operation.provenance.filter { $0.kind == "project" || $0.kind == "external" }.map(\.location)
        }).intersection(saved.keys)
        tasks.store(Task {
            let changed = await Task.detached { () -> Bool in
                for path in paths {
                    let url = ProjectOperationsStore.resolve(path, root: root)
                    guard let data = try? Data(contentsOf: url), data.count <= 128_000 else { return true }
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    if digest != saved[path] { return true }
                }
                return false
            }.value
            stalenessInFlight = false
            if sourcesChanged != changed { sourcesChanged = changed; revision += 1 }
        }, for: "staleness")
    }

    func discover(nodes: [ProjectOperation.Node]) {
        guard discoveryTask == nil, fileError == nil, !readOnly else { return }
        let root = self.root
        let existing = document.operations
        discoveryReport = nil
        discoveryPhase = "project files"
        revision += 1
        discoveryTask = Task { [self] in
            defer { discoveryTask = nil; discoveryPhase = nil; revision += 1 }
            do {
                let result = try await ProjectOperationDiscoveryService.discover(
                    root: root, existing: existing, deploymentNodes: nodes) { [weak self] phase in
                        Task { @MainActor in self?.discoveryPhase = phase; self?.revision += 1 }
                    }
                try Task.checkCancellation()
                let rejected = Set(Settings.standard.value(rejectedKey))
                var report = result.report
                report.proposals.removeAll { rejected.contains(String(ContentHash.of($0.command))) }
                // One atomic shared-file write, only after both AI phases and validation succeed.
                let discovered = result.operations
                let latest = try await Task.detached { () -> ProjectOperationsDocument in
                    try ProjectOperationsFile.mutate(root: root) { document in
                        for proposal in discovered {
                            if let index = document.operations.firstIndex(where: { $0.id == proposal.id }) {
                                document.operations[index] = ProjectOperation.merged(
                                    stored: document.operations[index], proposal: proposal)
                            } else {
                                document.operations.append(proposal)
                            }
                        }
                    }
                }.value
                document = latest
                hasFile = true
                fileError = nil
                discoveryReport = report
                Settings.standard.set(result.sourceFingerprints as [String: Any], for: fingerprintsKey)
                sourcesChanged = false
                refresh()
            } catch is CancellationError {
                message = "Operation discovery was cancelled. The operations file was not changed."
            } catch {
                message = "Operation discovery failed: \(error.localizedDescription) The operations file was not changed."
            }
        }
    }

    func cancelDiscovery() { discoveryTask?.cancel() }

    func dismissDiscoveryReport() { discoveryReport = nil; revision += 1 }

    func acceptProposal(index: Int) {
        guard var report = discoveryReport, report.proposals.indices.contains(index) else { return }
        let operation = report.proposals[index]
        let accept = UserPrompt(
            title: "Add externally sourced operation?",
            detail: operation.label + "\n\n" + operation.command + "\n\nSource: " + operation.provenance.map(\.location).joined(separator: ", "),
            buttons: ["Keep as proposal", "Accept operation"])
        guard prompts.confirm(accept, proceedingWith: 1) else { return }
        change { document in
            if let index = document.operations.firstIndex(where: { $0.id == operation.id }) {
                document.operations[index] = ProjectOperation.merged(
                    stored: document.operations[index], proposal: operation)
            } else {
                document.operations.append(operation)
            }
        }
        report.proposals.remove(at: index)
        discoveryReport = report
        revision += 1
    }

    func rejectProposal(index: Int) {
        guard var report = discoveryReport, report.proposals.indices.contains(index) else { return }
        let reject = UserPrompt(
            title: "Reject this proposed command?",
            detail: report.proposals[index].command + "\n\nThe same command will not be proposed again on this machine.",
            buttons: ["Keep proposal", "Reject"])
        guard prompts.confirm(reject, proceedingWith: 1) else { return }
        let operation = report.proposals.remove(at: index)
        var rejected = Set(Settings.standard.value(rejectedKey))
        rejected.insert(String(ContentHash.of(operation.command)))
        Settings.standard.set(Array(rejected).sorted(), for: rejectedKey)
        discoveryReport = report
        revision += 1
    }

    func newID(kind: String, environment: String, target: String, label: String) -> String {
        let base = [kind, environment, target].filter { !$0.isEmpty }.joined(separator: "-")
        let source = base.isEmpty ? label : base
        let slug = source.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = slug.isEmpty ? "operation" : slug
        var candidate = stem
        var number = 2
        let ids = Set(document.operations.map(\.id))
        while ids.contains(candidate) { candidate = "\(stem)-\(number)"; number += 1 }
        return candidate
    }

    func delete(id: String) {
        change { document in
            guard let index = document.operations.firstIndex(where: { $0.id == id }) else { return }
            if document.operations[index].origin == "discovered" { document.operations[index].deleted = true }
            else { document.operations.remove(at: index) }
        }
    }

    func adoptDiscovered(id: String) {
        guard let operation = operations.first(where: { $0.id == id }), let discovered = operation.discovered else { return }
        let adopt = UserPrompt(
            title: "Adopt the discovered command?",
            detail: "Command:\n\(discovered.command)\n\nWorking directory:\n\(discovered.cwd)",
            buttons: ["Keep current", "Adopt discovered"])
        guard prompts.confirm(adopt, proceedingWith: 1) else { return }
        change { document in
            guard let index = document.operations.firstIndex(where: { $0.id == id }),
                  let discovered = document.operations[index].discovered else { return }
            document.operations[index].command = discovered.command
            document.operations[index].cwd = discovered.cwd
        }
    }

    func run(id: String) {
        guard !readOnly else { return }
        guard !id.isEmpty, id.count <= 100, id.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { return }
        guard runs[id]?.isActive != true else { openPanel(id: id); return }
        let root = self.root
        // One start per operation at a time: the confirmation of the first is on the screen until it is answered.
        let key = "run-" + id
        guard !tasks.contains(key: key) else { return }
        tasks.store(Task { await confirmAndRun(id: id, root: root) }, for: key)
    }

    /// Reads the operation fresh from disk, asks for confirmation and starts it. A method of its own
    /// (not a `Task` closure) keeps type-checking cheap for older compilers (Xcode 16 in CI).
    private func confirmAndRun(id: String, root: URL) async {
        let snapshot: ProjectOperation
        do {
            let latest = try await Task.detached { try ProjectOperationsFile.read(root: root) }.value
            guard let found = latest.operations.first(where: { $0.id == id && !$0.deleted }) else {
                message = "Operation \(id) is no longer in the operations file."
                return
            }
            snapshot = found
        } catch { fileError = error.localizedDescription; return }
        let cwd = Self.resolve(snapshot.cwd, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            message = "Working directory is unavailable: \(cwd.path)"
            return
        }
        guard runs[id]?.isActive != true else { openPanel(id: id); return }
        let previous = lastRuns[id]
        let start = UserPrompt(
            title: "Run \(snapshot.label)?",
            detail: Self.confirmationDetails(snapshot: snapshot, cwd: cwd, previous: previous),
            buttons: ["Cancel", "Run"])
        guard prompts.confirm(start, proceedingWith: 1) else { return }
        guard runs[id]?.isActive != true else { openPanel(id: id); return }
        let run = ProjectOperationRun(snapshot: snapshot, directory: cwd)
        suppressNotifications = false
        runs[id] = run
        presenter?.showOperationConsole(selecting: id)
        revision += 1
        let history = ProjectOperationLastRun(id: id, label: snapshot.label, environment: snapshot.environment,
            command: snapshot.command, cwd: snapshot.cwd, started: run.started, ended: nil, state: "running", exitCode: nil)
        lastRuns[id] = history
        writes.record(history)
        // task: asks the system once for notification permission; it holds nothing of its own and ends with the answer
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        run.session.onExit = { [weak self, weak run] code in
            guard let self, let run else { return }
            run.finish(exitCode: code)
            self.recordCompletion(run)
        }
        run.session.onLaunchFailure = { [weak self, weak run] reason in
            guard let self, let run else { return }
            run.state = "failed"
            run.ended = Date()
            self.message = "Could not start \(run.snapshot.label): \(reason)"
            self.recordCompletion(run)
        }
        _ = run.session.webView
        run.session.start()
    }

    /// The confirmation text: command, directory, changes since the last run, provenance.
    private static func confirmationDetails(snapshot: ProjectOperation, cwd: URL,
                                            previous: ProjectOperationLastRun?) -> String {
        let changed: Bool = previous?.command != snapshot.command || previous?.cwd != snapshot.cwd
        var details: String = "Command:\n\(snapshot.command)\n\nWorking directory:\n\(cwd.path)"
        if let env = snapshot.environment { details = "Environment: \(env)\n\n" + details }
        if changed {
            details += "\n\nNew or changed since your last run on this machine."
            if let previous { details += "\nPrevious command: \(previous.command)\nPrevious directory: \(previous.cwd)" }
        }
        let locations: String = snapshot.provenance.map(\.location).joined(separator: ", ")
        if snapshot.origin == "user" {
            details += "\n\nUser-added operation."
        } else if snapshot.isEdited {
            details += "\n\nUser-edited operation. Discovery confidence does not apply to this command."
            if !snapshot.provenance.isEmpty { details += "\nOriginally discovered from: " + locations }
        } else {
            details += "\n\nDiscovery confidence: " + (snapshot.confidence ?? "unknown")
            if !snapshot.provenance.isEmpty {
                let sources: [String] = snapshot.provenance.map { source in
                    let line: String = source.line.map { ":\($0)" } ?? ""
                    return "\(source.location)\(line) (\(source.kind))"
                }
                details += "\nSource: " + sources.joined(separator: ", ")
            }
        }
        let commandChanged: Bool = previous == nil || previous?.command != snapshot.command
        if snapshot.hasExternalOrigin && commandChanged && !snapshot.isEdited {
            details += "\n\nExternal source: " + locations
        }
        if snapshot.remoteTrigger { details += "\n\nThis only starts a remote run; MarkView does not track its result." }
        if !snapshot.prerequisites.isEmpty { details += "\n\nPrerequisites: " + snapshot.prerequisites.joined(separator: "; ") }
        return details
    }

    private func recordCompletion(_ run: ProjectOperationRun) {
        let summary = ProjectOperationLastRun(id: run.id, label: run.snapshot.label,
            environment: run.snapshot.environment, command: run.snapshot.command,
            cwd: run.snapshot.cwd, started: run.started, ended: run.ended,
            state: run.state, exitCode: run.exitCode)
        lastRuns[run.id] = summary
        writes.record(summary)
        revision += 1
        guard !suppressNotifications, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = root.lastPathComponent + " · " + run.snapshot.label
        let environment = run.snapshot.environment.map { " (\($0))" } ?? ""
        let code = run.state == "failed" ? " (exit \(run.exitCode ?? -1))" : ""
        let untracked: String = run.state == "dispatched" ? " · Remote run is not tracked" : ""
        content.body = "\(run.snapshot.label)\(environment): \(run.state)\(code)\(untracked)"
        content.userInfo = ["projectOperationRoot": root.path, "projectOperationID": run.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "project-operation-\(UUID().uuidString)", content: content, trigger: nil))
    }

    func openPanel(id: String) {
        guard runs[id] != nil || lastRuns[id] != nil else { return }
        presenter?.showOperationConsole(selecting: id)
    }

    func dismiss(id: String) {
        guard runs[id]?.isActive != true else { return }
        runs[id] = nil
        revision += 1
    }

    func cancel(id: String, confirm: Bool = true) {
        guard let run = runs[id], run.state == "running" else { return }
        if confirm {
            let stopRun = UserPrompt(
                title: "Cancel \(run.snapshot.label)?",
                detail: "The target environment may be left partially changed.",
                buttons: ["Keep running", "Cancel operation"])
            guard prompts.confirm(stopRun, proceedingWith: 1) else { return }
        }
        run.cancel()
        revision += 1
    }

    func forceStop(id: String) {
        runs[id]?.forceStop()
        revision += 1
    }

    func cancelForClose() {
        suppressNotifications = true
        for run in runs.values where run.isActive { cancel(id: run.id, confirm: false) }
    }

    nonisolated static func resolve(_ path: String, root: URL) -> URL {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return root.appendingPathComponent(path).standardizedFileURL
    }

    nonisolated static func storedPath(_ url: URL, root: URL) -> String {
        let target = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if target == base { return "." }
        if target.hasPrefix(base + "/") { return String(target.dropFirst(base.count + 1)) }
        let parent = root.deletingLastPathComponent().standardizedFileURL.path
        if target.hasPrefix(parent + "/") { return "../" + String(target.dropFirst(parent.count + 1)) }
        let grandparent = root.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        if target.hasPrefix(grandparent + "/") { return "../../" + String(target.dropFirst(grandparent.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if target == home { return "~" }
        if target.hasPrefix(home + "/") { return "~/" + String(target.dropFirst(home.count + 1)) }
        if target.hasPrefix("/Users/") {
            let components = target.split(separator: "/")
            if components.count >= 2 {
                return "/Users/<user>/" + components.dropFirst(2).joined(separator: "/")
            }
        }
        return target
    }
}

private final class ProjectOperationNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ProjectOperationNotificationRouter()

    /// A Cockpit notice is sent when the person is not looking at the run, which can include another window of this app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.userInfo["cockpitRoot"] != nil ? [.banner, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if info["cockpitRoot"] != nil {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .cockpitNoticeOpened, object: nil, userInfo: info)
                completionHandler()
            }
            return
        }
        guard let root = info["projectOperationRoot"] as? String,
              let id = info["projectOperationID"] as? String else {
            completionHandler(); return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let store = ProjectOperationsStore.existing(rootPath: root) {
                store.presenter?.operationsHostWindow?.makeKeyAndOrderFront(nil)
                if store.runs[id] != nil { store.openPanel(id: id) }
            }
            completionHandler()
        }
    }
}
