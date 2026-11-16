import AppKit
import Combine
import Foundation
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

@MainActor
protocol StudioWindowServices: AnyObject, Sendable {
    func studioEditorBuffers(root: URL) -> [String: String]
    func studioRecordUsage(_ input: Int, _ output: Int, _ cost: Double)
    func studioOpenFile(_ url: URL)
    func studioFeatureStore() -> FeatureStore?
    func studioDidExportFeature(_ slug: String)
}

extension StudioWindowServices {
    func studioEditorBuffers(root: URL) -> [String: String] { [:] }
    func studioRecordUsage(_ input: Int, _ output: Int, _ cost: Double) {}
    func studioOpenFile(_ url: URL) {}
    func studioFeatureStore() -> FeatureStore? { nil }
    func studioDidExportFeature(_ slug: String) {}
}

/// One UI Studio session (feature "MarkView UI Studio"): the project's real web interface running from its development
/// server in a managed browser, its requests answered by the simulated environment, with element selection, questions and
/// source changes by the project assistant, reproducible scenarios and revision-linked captures.
@MainActor
final class StudioSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    enum Mode: String { case interact, select, record }

    struct EventRecord: Identifiable, Hashable {
        let id = UUID()
        var kind: StudioBridge.Event.Kind
        var detail: String
        var generation: Int
        var date = Date()
        /// The scenario the page showed when the event arrived: a row of an earlier page keeps its Fix while the scenario is the same.
        var scenarioID = ""
    }

    struct RequestRecord: Identifiable, Hashable {
        let id = UUID()
        var method: String
        var url: String
        var contract: String
        /// simulated, allowed, preparing, unresolved, unsupported
        var outcome: String
        var status: Int?
        /// "page", or "server" for a request the development server made through a simulated connection (REQ-007).
        var transport = "page"
        var date = Date()
    }

    /// A question or change request the assistant is working on: shown at the end of the conversation from the moment
    /// it is sent until its turn is in the history, or the work fails or is cancelled.
    struct PendingTurn: Equatable {
        var kind: StudioOperation.Kind
        var request: String
        /// The selected element as the turn will record it (tag and source file).
        var element: String
        /// The images sent with the request, as project-relative paths; filled once they are saved.
        var attachments: [String] = []
        var started = Date()
    }

    struct Comparison: Identifiable {
        let id = UUID()
        var before: StudioCapture
        var after: StudioCapture
        var diffFile: URL?
        var changedRatio: Double?
        var changedBounds: CGRect?
        /// Why the two captures are not comparable; empty when they are.
        var reasons: [String]
    }

    let id = UUID()
    let token = UUID().uuidString
    let root: URL
    let webView: WKWebView
    let preparation = StudioPreparationQueue(limits: StudioSession.preparationLimits)
    /// The application's map (REQ-014): its API surface, prepared in the background once per application.
    private(set) lazy var mapping = StudioEnvironmentMapper(routeScanner: { [weak self] in
        await self?.requestPath.routeHandlers() ?? []
    })
    /// What the session did and saw, redacted (REQ-011): the log drawer and `.dde/studio/session.log`.
    let sessionLog: StudioLog

    /// The bounds of rule preparation for new sessions (overridable for tests outside the app).
    static var preparationLimits = StudioPreparationLimits()
    /// Bound the wait for a requested screen while its simulated dependencies are being prepared.
    static var expectedStateTimeout: TimeInterval = 45

    @Published var targets: [WebAppTarget] = []
    @Published private(set) var target: WebAppTarget?
    @Published private(set) var state: StudioSessionState = .analyzing
    @Published private(set) var stateDetail = ""
    @Published private(set) var appURL: URL?
    @Published private(set) var ownsServer = false
    @Published private(set) var serverLog = ""
    @Published private(set) var removedEnvironment: [String] = []
    @Published private(set) var disclosures: [String] = []
    @Published private(set) var limitations: [String] = []
    @Published private(set) var spec: StudioEnvironmentSpec
    @Published var savedScenarios: [StudioScenario] = []
    /// The application's screens and what is prepared for each (REQ-021).
    @Published var screenBook = StudioScreenBook()
    /// The screens being prepared ahead by the assistant, and the sources' current hashes (staleness).
    @Published var preparingScreens: Set<String> = []
    @Published var screenWork: ScreenWork?
    @Published var screenHashes: [String: String] = [:]
    var screenTask: Task<Void, Never>?
    /// The one-time review of the environment (DEC-015): the task waiting to run it, and whether this open already tried.
    var reviewTask: Task<Void, Never>?
    var environmentReviewTried = false
    var screens: [StudioScreen] { screenBook.entries.map(\.screen) }

    /// What the background screen work is doing now, for its banner.
    struct ScreenWork: Equatable {
        var text: String
        var done = 0
        var total = 0
    }
    @Published private(set) var scenario: StudioScenario {
        didSet {
            if !changeFlow.tryingScenario { rememberActiveScenario() }
            if let undo = repair.repairUndo, undo.scenarioID != scenario.id { repair.repairUndo = nil }
        }
    }
    /// The scenario id last written to the project's session data (BUG-087).
    private var rememberedScenarioID: String?

    private func rememberActiveScenario() {
        guard scenario.id != rememberedScenarioID else { return }
        rememberedScenarioID = scenario.id
        let root = root, id = scenario.id
        io.async { StudioStore.saveActiveScenarioID(id, root: root) }
    }
    /// Service addresses of the development server (REQ-007): simulated through the gateway, or real.
    @Published private(set) var serverConnections: [StudioServerConnection] = []
    /// Secret variables the server reads; each gets a test value unless kept real.
    @Published private(set) var serverSecrets: [String] = []
    /// What is not simulated on the server side, and why.
    @Published private(set) var serverNotes: [String] = []
    @Published var zoom: Double? = nil
    @Published var notice: String? {
        didSet { if let notice, notice != oldValue { sessionLog.add(.notice, problem: StudioLogFormat.looksLikeError(notice), notice) } }
    }
    /// The images in the request box, waiting to be sent with the next request (REQ-005); the box edits them through a binding.
    @Published var attachments = ImageAttachmentList()

    @Published private(set) var events: [EventRecord] = []
    @Published private(set) var dependencies: [StudioDependency] = []
    @Published var buildError: String?
    /// The last capture of working code, shown as stale while a change does not build (EDIT-08, AC-15).
    @Published var stalePreview: StudioCapture?
    @Published var recordedSteps: [StudioStep] = []
    @Published private(set) var route = "/"
    @Published private(set) var rejectedMessages = 0
    weak var windowServices: (any StudioWindowServices)?
    /// Unsaved editor buffers of files in the project (path relative to the root → text).
    func editorBuffers() -> [String: String] { windowServices?.studioEditorBuffers(root: root) ?? [:] }
    /// Counts an assistant run in the workspace's usage.
    func recordUsage(_ input: Int, _ output: Int, _ cost: Double) { windowServices?.studioRecordUsage(input, output, cost) }
    func openFile(_ url: URL) { windowServices?.studioOpenFile(url) }
    func featureStore() -> FeatureStore? { windowServices?.studioFeatureStore() }

    var simulator: StudioSimulator
    var server: StudioDevServer?
    private var failedInstallFolder: URL?
    private var ruleListID: String?
    /// Whether the connection policy is in force: without it nothing is blocked and no SDK needs a stand-in.
    private var policyInstalled = false
    var appOrigin: StudioBridge.Origin?
    /// Main-frame page loads committed so far: tells a replay step that loaded another page from one that failed.
    private var pageCommits = 0
    /// The real time at which the scenario's test clock shows its test time: set by every restore, shared by the page and the
    /// development server, so the clock runs on across page loads (DEC-006).
    private var clockAnchor = Date()
    /// The listeners the simulated connections point at, by variable (REQ-007).
    private var gateway: StudioGateway?
    var gatewayPorts: [String: UInt16] = [:]
    /// The gateway's WebSocket and event-stream events, read in order.
    private var gatewayStreams: Task<Void, Never>?
    /// Hashes of the project's secret values (from its env files), to redact them from requests; never the values.
    var secretHashes: [String: String] = [:] {
        didSet { sessionLog.secretHashes = secretHashes }
    }
    /// The clock file the server's Node processes follow (DEC-006), in a folder of this session.
    private var clockFile: URL?
    /// Whether the server MarkView started was given the clock file (not a webpack server).
    private var serverFollowsClock = false
    /// Preparations ahead of a page by route (BUG-074): started while the server starts, awaited before the page loads.
    private var aheadTasks: [String: Task<Void, Never>] = [:]
    /// Routes prepared ahead in this session, whatever came of it, so a failure is not asked again on every Reset.
    private var aheadTried: Set<String> = []
    /// The server was just started and has not compiled a page yet, so the next load may take minutes (BUG-076).
    private var firstLoadAfterStart = false
    /// A restore is preparing, loading or replaying the page: its own end decides the state (BUG-076).
    private(set) var restoringPage = false
    /// The development server's output as whole lines for the log.
    private var serverLines = StudioLogLines()
    /// The address of the main frame's provisional navigation, for the "from" of a server redirect.
    private var navigationURL: URL?
    /// Navigations that leave the application and are answered by the session (REQ-010).
    private var simulatedNavigation = StudioSimulatedNavigation()

    /// The Node preload that gives the server the scenario's clock, time zone and locale (DEC-006).
    static var nodePreloadURL = Bundle.main.url(forResource: "markview-ui-studio-node", withExtension: "cjs", subdirectory: "Editor/js")
    /// The globals an Electron renderer's preload exposes, simulated as the preload bridge (REQ-016).
    private(set) var electronGlobals: [String] = []
    private var startTask: Task<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private let handler = StudioMessageHandler()
    let redactor: StudioRedactor
    let io = DispatchQueue(label: "markview.ui-studio.io")
    private(set) var closed = false
    /// The folder with the page runtime's parts (`StudioRuntime.parts`), from the editor bundle (overridable for tests outside the app).
    static var runtimeFolder = Bundle.main.url(forResource: StudioRuntime.parts[0], withExtension: nil, subdirectory: "Editor/js")?.deletingLastPathComponent()
    private static var runtimeSource: String? { runtimeFolder.flatMap(StudioRuntime.source(in:)) }

    init(root: URL) {
        self.root = root.standardizedFileURL
        let loaded = StudioStore.loadEnvironment(root) ?? StudioEnvironmentSpec()
        spec = loaded
        redactor = StudioRedactor(fields: loaded.confidentialFields)
        sessionLog = StudioLog(root: self.root, redactor: redactor, queue: io)
        var base = StudioScenario(id: "builtin-populated", name: "Populated", kind: .populated)
        base.role = .tester(role: loaded.testUserRole)
        let builtin = StudioScenarioCompatibility.presets(spec: loaded, base: base)
        var first = builtin[0]
        // Open on the scenario the last session ended on, so the data the person asked for is still there (BUG-087). One that was
        // deleted, or whose contracts changed since (it needs an update), is not opened silently: the built-in one is, with a notice.
        var needsUpdate: String?
        if let id = StudioStore.loadActiveScenarioID(self.root), id != first.id,
           let remembered = (builtin + StudioStore.loadScenarios(self.root)).first(where: { $0.id == id }) {
            if remembered.id.hasPrefix("builtin-") || StudioScenarioCompatibility.problems(remembered, spec: loaded).isEmpty {
                first = remembered
            } else {
                needsUpdate = remembered.name
            }
        }
        rememberedScenarioID = first.id
        scenario = first
        simulator = StudioSimulator(spec: loaded, scenario: first)

        let configuration = WebHost.makeConfiguration(
            dataStore: .nonPersistent,
            handlers: [.reply(StudioBridge.handlerName, handler)],
            allowsPopups: true,
            applicationName: "Version/17.0 Safari/605.1.15 MarkViewUIStudio")
        webView = WebHost.makeWebView(frame: CGRect(x: 0, y: 0, width: first.viewport.width, height: first.viewport.height),
                                      configuration: configuration)
        super.init()
        preparation.recordEvents.sink { [weak self] record in self?.logPreparation(record) }.store(in: &partChanges)
        wireMapping()
        handler.session = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        applyTheme()

        savedScenarios = StudioStore.loadScenarios(root)
        rebuildDependencies()
        Self.registerTermination()
        if let needsUpdate { notice = "The scenario \(needsUpdate) needs an update, so UI Studio opened on Populated. Update it in the Scenario menu." }
    }

    // MARK: - Parts that own their state (AR-16)

    // The session is the one object the views observe; each part below owns the state of one responsibility and is created when it is first
    // used. What the views, the tests and the other parts read from the session is forwarded here.

    private var partChanges: Set<AnyCancellable> = []

    /// A part's changes are the session's changes: the views observe the session only.
    private func adopt<Part: ObservableObject>(_ part: Part) -> Part where Part.ObjectWillChangePublisher == ObservableObjectPublisher {
        part.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &partChanges)
        return part
    }

    /// The work in progress: the busy banner, and the turn the assistant is answering.
    private(set) lazy var workStore = adopt(StudioWork(session: self))
    var busy: String? { workStore.busy }
    var busyDetail: String {
        get { workStore.busyDetail }
        set { workStore.busyDetail = newValue }
    }
    var pendingTurn: PendingTurn? {
        get { workStore.pendingTurn }
        set { workStore.pendingTurn = newValue }
    }
    func runWork(_ title: String, pending: PendingTurn? = nil, _ work: @escaping @MainActor (StudioSession) async -> Void) {
        workStore.runWork(title, pending: pending, work)
    }
    func awaitWork() async { await workStore.awaitWork() }
    func showBusyDetail(_ text: String) { workStore.showBusyDetail(text) }
    func cancelWork() { workStore.cancelWork() }
    /// The one way a part starts a task that goes on after its call: the task holds this session until it ends (see `StudioWork.startPartTask`).
    @discardableResult
    func startPartTask(_ body: @escaping @MainActor (StudioSession) async -> Void) -> Task<Void, Never> { workStore.startPartTask(body) }
    func progress(_ activity: CLICompletion.Activity) { workStore.progress(activity) }

    /// The operations of the session and the conversation the assistant remembers.
    private(set) lazy var historyStore = adopt(StudioHistory(session: self))
    var history: [StudioOperation] { historyStore.history }
    var conversation: [StudioOperation] { historyStore.conversation }
    func clearConversation() { historyStore.clearConversation() }
    func keep(_ id: String) { historyStore.keep(id) }
    func replace(_ operation: StudioOperation) { historyStore.replace(operation) }

    /// The request box: a request answered, checked and recorded, and the undo of what it did.
    private(set) lazy var changeFlow = adopt(StudioChangeFlow(session: self))
    var undoConflicts: [String: [(path: String, merged: String)]] { changeFlow.undoConflicts }
    func change(_ text: String, attachments: [ImageAttachment] = [], clarification: String? = nil,
                replacing pending: StudioOperation? = nil, destination: StudioScreen? = nil) {
        changeFlow.change(text, attachments: attachments, clarification: clarification, replacing: pending, destination: destination)
    }
    func answerClarification(_ operation: StudioOperation, choice: String, attachments: [ImageAttachment] = []) {
        changeFlow.answerClarification(operation, choice: choice, attachments: attachments)
    }
    func undo(_ id: String) { changeFlow.undo(id) }
    func resolveUndoConflictInEditor(_ id: String) { changeFlow.resolveUndoConflictInEditor(id) }

    /// The pictures of the preview and the comparison of two of them.
    private(set) lazy var captureStore = adopt(StudioCaptures(session: self))
    var captures: [StudioCapture] { captureStore.captures }
    var comparison: Comparison? {
        get { captureStore.comparison }
        set { captureStore.comparison = newValue }
    }
    var comparisonEnlarged: Bool {
        get { captureStore.comparisonEnlarged }
        set { captureStore.comparisonEnlarged = newValue }
    }
    func captureNow() { captureStore.captureNow() }
    func compare(_ beforeID: String, _ afterID: String, enlarge: Bool = false) { captureStore.compare(beforeID, afterID, enlarge: enlarge) }
    func url(of capture: StudioCapture) -> URL { captureStore.url(of: capture) }

    /// The feature packages exported from the session.
    private(set) lazy var packageStore = adopt(StudioPackages(session: self))
    var packages: [StudioPackage] { packageStore.packages }
    var exportableOperations: [StudioOperation] { packageStore.exportableOperations }
    func exportFeature(title: String, summary: String, operations ids: [String]) {
        packageStore.exportFeature(title: title, summary: summary, operations: ids)
    }
    func revalidatePackages() async { await packageStore.revalidatePackages() }

    /// The requests of the page and of the server, the simulated connections, and the rules that arrive late.
    private(set) lazy var requestPath = adopt(StudioRequestPath(session: self))
    var requests: [RequestRecord] { requestPath.requests }
    var rulesArrivedLate: Bool {
        get { requestPath.rulesArrivedLate }
        set { requestPath.rulesArrivedLate = newValue }
    }
    var servedAnswers: [StudioDataFix.Served] { requestPath.servedAnswers }
    var servedRules: [String] { requestPath.servedRules }

    /// Problems and repair: what came of this open's repairs, the last fix for Undo, and the sign-in page the application sent the page to.
    private(set) lazy var repair = adopt(StudioRepair(session: self))

    /// The mode, and the element picked in the page.
    private(set) lazy var elementPicker = adopt(StudioElementPicker(session: self))
    var mode: Mode {
        get { elementPicker.mode }
        set { elementPicker.mode = newValue }
    }
    var selection: StudioSelectionContext? { elementPicker.selection }
    func setMode(_ next: Mode) { elementPicker.setMode(next) }
    func selectParent() { elementPicker.selectParent() }
    func selectChild() { elementPicker.selectChild() }
    func clearSelection() { elementPicker.clearSelection() }

    /// The page's cookies and storage kept for later restores.
    private(set) lazy var keptData = adopt(StudioKeptData(session: self))

    var title: String { "UI Studio" + (target.map { " — \($0.label)" } ?? "") }
    var viewport: StudioViewport { scenario.viewport }
    var presets: [StudioScenario] { StudioScenarioCompatibility.presets(spec: spec, base: scenarioBase) }
    var appFolder: URL { target?.folder ?? root }
    var isPreparing: Bool { preparation.records.values.contains { $0.status == .preparing || $0.status == .waiting } }

    private var scenarioBase: StudioScenario {
        var base = scenario
        base.data = nil
        base.overrides = []
        base.steps = []
        base.expectedPath = nil
        base.expectedSelector = nil
        return base
    }

    // MARK: - Lifecycle

    /// Finds the project's web apps and starts the only one (or the one chosen).
    func start(_ chosen: WebAppTarget? = nil) {
        guard !closed else { return }
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            self.set(.analyzing, "Looking for the project's web application")
            let root = self.root
            let found = await Task.detached { WebAppPreview.targets(root: root) }.value
            self.targets = found
            guard let target = chosen ?? (found.count == 1 ? found[0] : nil) else {
                if found.isEmpty {
                    self.set(.failed, "No web application with a development server was found. Add .markview/preview.json with its command and port, then try again.")
                } else {
                    self.set(.analyzing, "Choose the application to open.")
                }
                return
            }
            await self.launch(target)
        }
    }

    private func launch(_ target: WebAppTarget) async {
        // A server this session started for another target never outlives the switch.
        await stopOwnedServer()
        self.target = target
        repair.repairLedger.reset()
        environmentReviewTried = false
        reviewTask?.cancel()
        reviewTask = nil
        screenTask?.cancel()
        screenTask = nil
        screenWork = nil
        preparingScreens = []
        screenBook = StudioStore.loadScreenBook(root, appFolder: relativeAppFolder) ?? StudioScreenBook(appFolder: relativeAppFolder)
        sessionLog.add(.notice, "Opening \(target.label): `\(target.command)`")
        disclosures = StudioTargetLimits.disclosures(for: target)
        if target.isElectron {
            let folder = target.folder
            electronGlobals = await Task.detached { StudioTargetLimits.electronGlobals(in: folder) }.value
        }
        set(.starting, "Looking for a running development server")
        // Listening is enough: a GET of a server-rendered page waits for its data calls (BUG-076).
        var url = target.reuseRunningServer ? await WebAppPreview.firstListening(target.ports) : nil
        if url == nil {
            set(.starting, "Starting `\(target.command)` in \(target.label)")
            url = await startServer(target)
        } else {
            ownsServer = false
        }
        guard !closed else { return }
        guard let url, let origin = StudioBridge.Origin(url: url) else {
            if state != .failed { set(.failed, "The development server did not answer.") }
            return
        }
        appURL = url
        appOrigin = origin
        simulator.appOrigin = origin.text
        await configureAuthMock(target)
        await installConnectionPolicy()
        beginMapping()
        set(.starting, "Loading the application")
        await restore()
        scheduleEnvironmentReview()
        scheduleScreenWork()
    }

    private func startServer(_ target: WebAppTarget) async -> URL? {
        let occupied = target.reuseRunningServer ? nil : await WebAppPreview.firstListening(target.ports)
        guard !closed, !Task.isCancelled else { return nil }
        if let occupied {
            set(.failed, "The configured port \(occupied.port ?? 0) is already in use. Stop that server or choose a free port.")
            return nil
        }
        let root = self.root, retry = failedInstallFolder == target.folder
        let install = await Task.detached { WebAppPreview.missingDependencies(for: target, root: root, retry: retry) }.value
        guard !closed, !Task.isCancelled else { return nil }
        if let install {
            failedInstallFolder = target.folder
            set(.starting, "Installing the application's dependencies (`\(install.command)`)")
            let environment = await StudioLaunchEnvironment.make()
            guard !closed, !Task.isCancelled else { return nil }
            let installer = StudioDevServer(command: install.command, folder: install.folder, onOutput: { [weak self] text in
                Task { @MainActor in self?.refreshServerLog(); self?.logServerOutput(text) }
            })
            do { try installer.start(environment: environment.environment) }
            catch { set(.failed, "Could not install dependencies: \(error.localizedDescription)"); return nil }
            server = installer
            ownsServer = true
            StudioDevServer.track(installer)
            let finished = await installer.waitForExit(timeout: 600)
            guard !closed, !Task.isCancelled, server === installer else { return nil }
            let output = await Task.detached { [redactor] in redactor.redact(text: String(installer.output.suffix(12_000))) }.value
            guard !closed, !Task.isCancelled, server === installer else { return nil }
            serverLog = output
            if !finished {
                await stopOwnedServer()
                set(.failed, "Installing dependencies timed out. See the output below, then try again.")
                return nil
            }
            let code = installer.exitStatus ?? -1
            StudioDevServer.untrack(installer)
            server = nil
            guard code == 0 else {
                set(.failed, "Could not install the application's dependencies (exit \(code)). See the output below, then try again.")
                return nil
            }
            failedInstallFolder = nil
            set(.starting, "Starting `\(target.command)` in \(target.label)")
        }
        let overrides = await prepareServerConnections(target)
        let launch = await StudioLaunchEnvironment.make(overrides: overrides, nodePreload: Self.nodePreloadURL?.path)
        removedEnvironment = launch.removed
        serverLines = StudioLogLines()
        let server = StudioDevServer(command: target.command, folder: target.folder, onOutput: { [weak self] text in
            Task { @MainActor in
                self?.refreshServerLog()
                self?.logServerOutput(text)
            }
        }, onExit: { [weak self] server, code in
            // Only the session's current server reports its end: one it stopped or replaced on purpose does not.
            Task { @MainActor [weak self, weak server] in
                guard let self, let server, self.server === server else { return }
                self.serverEnded(code)
            }
        })
        do {
            try server.start(environment: launch.environment)
        } catch {
            set(.failed, error.localizedDescription)
            return nil
        }
        self.server = server
        ownsServer = true
        StudioDevServer.track(server)
        // The agent reads the project while the server starts; the page waits for it before it loads (BUG-074).
        beginAhead(scenario.route)
        let deadline = Date().addingTimeInterval(180)
        var round = 0
        while Date() < deadline, !closed {
            if let code = server.exitStatus {
                set(.failed, "The development server stopped (exit \(code)). See its output below.")
                return nil
            }
            // The server is up once it listens (BUG-076). Rendering the page to find out would make its data calls before
            // their rules are prepared, again on every probe; the first load waits for the first compile instead.
            if let printed = WebAppPreview.firstLocalURL(in: server.output), await WebAppPreview.isListening(printed.port ?? 80) {
                firstLoadAfterStart = true
                return URL(string: "\(printed.scheme ?? "http")://\(printed.host ?? "localhost"):\(printed.port ?? 80)/")
            }
            if round % 4 == 3, let listening = await WebAppPreview.firstListening(target.ports) {
                firstLoadAfterStart = true
                return listening
            }
            round += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !closed { set(.failed, "The development server did not print an address within 3 minutes.") }
        return nil
    }

    /// Finds the server's service addresses and secrets, opens the gateway for the simulated ones and returns the variables
    /// to start the server with (REQ-007), with the scenario's clock, time zone and language (DEC-006).
    private func prepareServerConnections(_ target: WebAppTarget) async -> [String: String] {
        let root = root, folder = target.folder, saved = spec.serverConnections ?? []
        let expectedOrigin = target.ports.first.map { "http://localhost:\($0)" }
        let found = await Task.detached {
            StudioConnections.discover(root: root, appFolder: folder, appOrigin: expectedOrigin, saved: saved)
        }.value
        serverConnections = found.connections
        serverSecrets = found.secrets
        serverNotes = found.notRedirected.map { "\($0.variable): \($0.reason)" } + found.disclosures
        secretHashes = found.secretHashes
        gateway?.close()
        gateway = nil
        gatewayPorts = [:]
        gatewayStreams?.cancel()
        requestPath.channels.closeAll(source: "server")
        let simulated = found.connections.filter { $0.mode == .simulated }.map(\.variable)
        if !simulated.isEmpty {
            let gateway = StudioGateway { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else {
                        return reply(StudioGatewayResponse(status: 503, headers: [:], body: nil))
                    }
                    self.requestPath.handleServerRequest(request, reply: reply)
                }
            }
            var continuation: AsyncStream<StudioGatewayStreamEvent>.Continuation?
            let events = AsyncStream<StudioGatewayStreamEvent> { continuation = $0 }
            if let continuation { gateway.setStreamHandler { event in continuation.yield(event) } }
            gatewayStreams = Task { [weak self] in
                for await event in events { self?.requestPath.handleServerStream(event, on: gateway) }
            }
            do {
                gatewayPorts = try await gateway.open(simulated)
                self.gateway = gateway
            } catch {
                gateway.close()
                serverNotes.insert("The server's connections could not be simulated: \(error.localizedDescription) They stay real.", at: 0)
            }
        }
        var overrides = StudioConnections.launchOverrides(found, ports: gatewayPorts, keptReal: Set(spec.keptSecrets ?? []))
        if let zone = scenario.timeZone, zone.range(of: #"^[A-Za-z0-9_+\-/]+$"#, options: .regularExpression) != nil { overrides["TZ"] = zone }
        if scenario.locale.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
            overrides["LANG"] = scenario.locale.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
        }
        let folderURL = target.folder, command = target.command
        serverFollowsClock = false
        if let reason = await Task.detached(operation: { StudioServerClock.realClockReason(command: command, folder: folderURL) }).value {
            serverNotes.append(reason)
        } else if let file = await writeClockFile() {
            overrides["MARKVIEW_STUDIO_CLOCK"] = file.path
            serverFollowsClock = true
        }
        return overrides
    }

    /// The scenario's clock for the server's Node processes (DEC-006): the test time at the session's anchor, the time zone
    /// and the locale. The preload rereads it when it changes, so every restore moves the server's clock with the page's.
    @discardableResult
    private func writeClockFile() async -> URL? {
        if clockFile == nil {
            clockFile = FileManager.default.temporaryDirectory.appendingPathComponent("markview-studio-\(token)", isDirectory: true)
                .appendingPathComponent("clock.json")
        }
        guard let file = clockFile else { return nil }
        let clock: [String: Any] = ["testTime": scenario.testTime.timeIntervalSince1970 * 1000, "anchor": clockAnchor.timeIntervalSince1970 * 1000,
                                    "timeZone": scenario.timeZone ?? NSNull(), "locale": scenario.locale]
        guard let data = try? JSONSerialization.data(withJSONObject: clock) else { return nil }
        let written = await Task.detached { () -> Bool in
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            return (try? AtomicFile.write(data, to: file)) != nil
        }.value
        return written ? file : nil
    }

    /// Stops the server this session started, without reporting it as a failure.
    private func stopOwnedServer() async {
        guard ownsServer, let server else { return }
        self.server = nil
        await server.stop()
        StudioDevServer.untrack(server)
    }

    /// Starts the development server again with the current connections (REQ-007), after a connection was switched between
    /// simulated and real or a secret was kept real. Only a server MarkView started can be restarted.
    func restartServer() {
        guard let target else { return }
        guard ownsServer else {
            notice = "This development server was started outside MarkView, so it keeps its own environment and clock. Stop it, then "
                + "open UI Studio again: MarkView starts the server itself, with simulated connections and the scenario's clock."
            return
        }
        runWork("Restarting the development server") { session in
            await session.stopOwnedServer()
            session.set(.starting, "Starting `\(target.command)` in \(target.label)")
            guard let url = await session.startServer(target), let origin = StudioBridge.Origin(url: url) else {
                if session.state != .failed { session.set(.failed, "The development server did not answer.") }
                return
            }
            session.appURL = url
            session.appOrigin = origin
            session.simulator.appOrigin = origin.text
            await session.configureAuthMock(target)
            await session.installConnectionPolicy()
            _ = await session.restore()
        }
    }

    /// Switches one of the server's service addresses between the simulation and the real service (REQ-007).
    func setConnectionMode(_ variable: String, _ mode: StudioServerConnection.Mode) {
        guard let index = serverConnections.firstIndex(where: { $0.variable == variable }), serverConnections[index].mode != mode else { return }
        serverConnections[index].mode = mode
        var next = simulator.spec
        var saved = next.serverConnections ?? []
        saved.removeAll { $0.variable == variable }
        saved.append(serverConnections[index])
        next.serverConnections = saved.sorted { $0.variable < $1.variable }
        replaceEnvironment(next)
        restartServer()
    }

    /// Turns the automatic repair of page errors on or off for the project (REQ-020).
    func setAutoRepair(_ on: Bool) {
        guard on != spec.repairsAutomatically else { return }
        var next = simulator.spec
        next.autoRepair = on ? nil : false
        replaceEnvironment(next)
        if on { repair.scheduleAutoRepair() } else { repair.autoRepairTask?.cancel() }
    }

    /// Turns the preparation of the main screens ahead on or off for the project (REQ-021).
    func setPrepareScreens(_ on: Bool) {
        guard on != spec.preparesScreens else { return }
        var next = simulator.spec
        next.prepareScreens = on ? nil : false
        replaceEnvironment(next)
        if on { scheduleScreenWork() } else { cancelScreenWork() }
    }

    /// Keeps a secret's real value for the server instead of its test value, or gives it the test value again (REQ-007).
    func setSecretKeptReal(_ name: String, _ kept: Bool) {
        var next = simulator.spec
        var names = Set(next.keptSecrets ?? [])
        guard kept != names.contains(name) else { return }
        if kept { names.insert(name) } else { names.remove(name) }
        next.keptSecrets = names.isEmpty ? nil : names.sorted()
        replaceEnvironment(next)
        restartServer()
    }

    private var serverLogRefreshPending = false

    /// The visible tail of the server's output (BUG-082). Redacting it runs every credential pattern over 12,000
    /// characters, so it is done at most once per `serverLogInterval`, however fast the server prints, and off the main
    /// actor; output that arrives meanwhile is picked up by that refresh.
    private func refreshServerLog() {
        guard !serverLogRefreshPending else { return }
        serverLogRefreshPending = true
        startPartTask { session in
            try? await Task.sleep(nanoseconds: Self.serverLogInterval)
            session.serverLogRefreshPending = false
            guard let server = session.server else { return }
            let tail = String(server.output.suffix(12_000)), redactor = session.redactor
            let text = await Task.detached(priority: .utility) { redactor.redact(text: tail) }.value
            // A server stopped or replaced meanwhile keeps its log out of the current one.
            guard !session.closed, session.server === server else { return }
            session.serverLog = text
        }
    }

    static let serverLogInterval: UInt64 = 250_000_000

    private func serverEnded(_ code: Int32) {
        refreshServerLog()
        serverLines.flush().forEach { sessionLog.add(.server, problem: StudioLogFormat.looksLikeError($0), $0) }
        guard !closed, ownsServer else { return }
        set(.failed, "The development server stopped (exit \(code)).")
    }

    /// Closes the session (REQ-006, AC-18): cancels the work in progress, removes the page, its handlers and storage, and
    /// stops the development server only when the session started it.
    func close() async {
        guard !closed else { return }
        closed = true
        workStore.cancelPartTasks()
        startTask?.cancel()
        screenTask?.cancel()
        reviewTask?.cancel()
        preparation.cancelEverything()
        mapping.close()
        resumeLoadWaiters(false)
        webView.stopLoading()
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
        controller.removeAllContentRuleLists()
        if let ruleListID { StudioConnectionPolicy.remove(identifier: ruleListID) }
        webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await stopOwnedServer()
        server = nil
        gateway?.close()
        gateway = nil
        gatewayStreams?.cancel()
        requestPath.channels.closeAll()
        if let folder = clockFile?.deletingLastPathComponent() {
            await Task.detached { try? FileManager.default.removeItem(at: folder) }.value
        }
        set(.stopped, ownsServer ? "The development server MarkView started was stopped." : "Closed. The development server was already running and was left running.")
        sessionLog.seal()
    }

    private static var terminationObserver: NSObjectProtocol?

    /// Development servers a session started do not outlive MarkView.
    private static func registerTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                     queue: nil) { _ in StudioDevServer.stopAllNow() }
    }

    private func set(_ state: StudioSessionState, _ detail: String) {
        // The log gets a failure each time it is different, a degradation when it begins, and the way back to ready.
        if (state == .failed && (self.state != .failed || detail != stateDetail)) || (state == .degraded && self.state != .degraded) {
            sessionLog.add(.notice, problem: true, "\(state.title): \(detail)")
        } else if state == .ready, [.failed, .degraded].contains(self.state) {
            sessionLog.add(.notice, "\(state.title): \(detail)")
        }
        self.state = state
        stateDetail = detail
    }

    // MARK: - Page

    private func installConnectionPolicy() async {
        guard let appOrigin else { return }
        let json = StudioConnectionPolicy.ruleListJSON(appOrigin: appOrigin, allowed: spec.allowedRequests)
        let identifier = "markview-ui-studio-" + StudioHash.sha256(json).prefix(16)
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        // The page reloads under the new policy and reports the SDKs it still needs a stand-in for; one the person has just
        // allowed loads for real and must not stay listed as simulated.
        if observed.keys.contains(where: { $0.hasPrefix("sdk:") }) {
            observed = observed.filter { !$0.key.hasPrefix("sdk:") }
            rebuildDependencies()
        }
        if let list = await StudioConnectionPolicy.compile(identifier: identifier, json: json) {
            controller.add(list)
            if let old = ruleListID, old != identifier { StudioConnectionPolicy.remove(identifier: old) }
            ruleListID = identifier
            policyInstalled = true
        } else {
            policyInstalled = false
            notice = "The connection policy could not be installed; requests are still answered only by the simulation."
        }
    }

    private func runtimeScript() -> WKUserScript? {
        guard let source = Self.runtimeSource else { return nil }
        let config: [String: Any] = [
            "session": token, "generation": simulator.generation, "seed": Int(scenario.seed),
            "testTime": scenario.testTime.timeIntervalSince1970 * 1000, "locale": scenario.locale,
            "timeZone": scenario.timeZone ?? NSNull(), "electron": target?.isElectron ?? false, "electronGlobals": electronGlobals,
            "recording": mode == .record, "browser": scenario.browserProfile.runtimeConfig,
            // What a simulated payment does (BUG-103): an error scenario declines the card, every other one succeeds.
            "standIns": ["payment": scenario.kind == .error ? "decline" : "succeed", "enabled": policyInstalled],
            // The addresses the policy lets through, as the regular expressions its rules use: a script the person allowed is never
            // replaced by a stand-in.
            "allowedFilters": spec.allowedRequests.compactMap(StudioConnectionPolicy.filter(forAllowed:)),
            "keptStorage": spec.keptBrowserData?.runtimeStorage ?? [], "clockAnchor": clockAnchor.timeIntervalSince1970 * 1000,
            // The arguments of a preload bridge call are redacted in the page before they cross the bridge (REQ-016).
            "redaction": ["fields": spec.confidentialFields, "patterns": StudioRedactor.secretPatterns],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return WKUserScript(source: source.replacingOccurrences(of: "__MARKVIEW_STUDIO_CONFIG__", with: json),
                            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    /// The page runtime with the current configuration, for every page loaded from now on.
    func installRuntime() -> Bool {
        guard let script = runtimeScript() else { return false }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(script)
        return true
    }

    /// Loads the scenario's route in a fresh page of the current generation and waits for it to load.
    private func loadPage() async -> Bool {
        guard let appURL, installRuntime() else {
            if Self.runtimeSource == nil { set(.failed, "The UI Studio page runtime is missing from the app bundle.") }
            return false
        }
        applyTheme()
        resizeWebView()
        buildError = nil
        let target = URL(string: scenario.route, relativeTo: appURL)?.absoluteURL ?? appURL
        route = scenario.route
        sessionLog.add(.navigation, "Loading \(target.absoluteString) (scenario \(scenario.name), generation \(simulator.generation))")
        var page = URLRequest(url: target)
        // A fresh server render: Next.js serves cached server fetches in development unless the request says no-cache.
        StudioConnectionPolicy.frameworkRequestHeaders.forEach { page.setValue($0.value, forHTTPHeaderField: $0.key) }
        await loadDocument(page)
        // The first load after MarkView started the server includes the framework's first compile (BUG-076).
        let timeout: TimeInterval = firstLoadAfterStart ? 180 : 45
        firstLoadAfterStart = false
        return await waitForLoad(timeout: timeout)
    }

    /// Starts loading `page` as a new document. A hash-routed application (`/#/attention` → `/#/accounts`) is the catch: an address that
    /// differs only by its fragment is a navigation inside the same document. WebKit keeps the old page, which keeps the old generation,
    /// so every request it makes is rejected as stale ("Failed to fetch … a message of an earlier generation") and the load never
    /// finishes. An empty page first makes the next load a new page.
    private func loadDocument(_ page: URLRequest) async {
        if let target = page.url, StudioPageLoad.isFragmentNavigation(from: webView.url, to: target) {
            sessionLog.add(.navigation, "The address differs from the page's only by its fragment: an empty page is loaded first so that the page starts again")
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            _ = await waitForLoad(timeout: 10)
            }
        webView.load(page)
    }

    private func waitForLoad(timeout: TimeInterval) async -> Bool {
        let timer = Task { [weak self] in
            // A timer cancelled because the load ended must not wake the next wait: that one has its own timer.
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
            self?.resumeLoadWaiters(false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { loadWaiters.append($0) }
    }

    private func resumeLoadWaiters(_ loaded: Bool) {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume(returning: loaded) }
    }

    func applyTheme() {
        webView.appearance = NSAppearance(named: scenario.theme == .dark ? .darkAqua : .aqua)
    }

    private func resizeWebView() {
        let size = CGSize(width: scenario.viewport.width, height: scenario.viewport.height)
        if webView.frame.size != size { webView.setFrameSize(size) }
    }

    /// Calls a script in the page. A cancelled task stops waiting for the page's answer at once (`StudioPageCall`), so that a call whose
    /// Promise never settles, as the picker's `pick()` while the person has not clicked, cannot keep the task and the session it holds alive.
    @discardableResult
    func call(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        let pending = StudioPageCall()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StudioPageValue, Error>) in
                guard pending.begin(continuation) else { return }
                webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { pending.finish($0) }
            }
        } onCancel: { pending.cancel() }
        return result.value
    }

    /// Back to the scenario's baseline (SIM-04, AC-04): a new generation (late answers of the old one are dropped), empty
    /// browser storage with only the kept cookies set again (REQ-008; the runtime writes the kept localStorage), a fresh
    /// page and the scenario's restoration steps. Returns why the restore is incomplete, if it is.
    @discardableResult
    func restore(keepingSignIn: Bool = false) async -> String? {
        guard !closed, appURL != nil else { return "The application is not running." }
        mode = mode == .record ? .interact : mode
        elementPicker.pickTask?.cancel()
        simulator.reset()
        repair.signInWall = nil
        requestPath.forgetServedAnswers()
        // A preparation in flight is not cancelled: its rules belong to the environment, not to the scenario, and the minute the
        // assistant has spent on them is not thrown away by switching scenarios (BUG-089).
        elementPicker.selection = nil
        clockAnchor = Date()
        gateway?.releaseHeld()
        // The page's connections end with its page; the server's are closed so that they connect again to the baseline.
        requestPath.channels.closeAll(source: "page")
        requestPath.channels.closeAll(source: "server", code: 1012, reason: "The simulated service was reset.")
        if ownsServer, serverFollowsClock {
            await writeClockFile()
            // The preload rereads the clock file within 250 ms; the page's first server render must see the new clock.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let signedIn = keepingSignIn ? await keptData.signInCookiesToCarry() : []
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await keptData.restoreKeptCookies()
        for cookie in signedIn { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        keptData.restoredUser = scenario.role.user
        rulesArrivedLate = false
        // Until the page is loaded and restored, a preparation that ends must not report the session ready (BUG-076).
        restoringPage = true
        defer { restoringPage = false }
        if let ahead = beginAhead(scenario.route) {
            set(.preparing, "Preparing the services the page at \(scenario.route) calls from the server")
            await ahead.value
            guard !closed else { return "The session is closed." }
        }
        guard await loadPage() else {
            if state != .failed { set(.degraded, "The page did not finish loading.") }
            return "The page did not finish loading."
        }
        _ = try? await call("return await window.__markviewStudio.whenIdle(40000, 400);")
        var problem = await replay(scenario.steps)
        if problem == nil { problem = await expectedStateProblem() }
        if let problem { notice = problem }
        await refreshPageState()
        // The load may have been sent to the sign-in page before the scenario's own steps signed the user in: once the page is
        // somewhere else, there is no sign-in wall to repair.
        if repair.signInWall != nil, let path = webView.url?.path, !StudioLogFormat.isSignInPath(path) { repair.signInWall = nil }
        restoringPage = false
        updateReadiness()
        if mode == .select { elementPicker.startPicking() }
        // The page has settled: look at what it reported (the check waits until nothing else is working on the session).
        repair.scheduleAutoRepair()
        return problem
    }

    /// Wait for both the destination and its visible content: an address alone can still be a loading or error screen.
    private func expectedStateProblem() async -> String? {
        guard scenario.expectedPath != nil || scenario.expectedSelector != nil else { return nil }
        let deadline = Date().addingTimeInterval(Self.expectedStateTimeout)
        var pathOK = false, elementOK = scenario.expectedSelector == nil
        var stableSince: Date?
        repeat {
            let appPage = webView.url.flatMap(StudioBridge.Origin.init(url:)).flatMap { origin in
                appURL.flatMap(StudioBridge.Origin.init(url:)).map { origin.sameServer($0) }
            } ?? false
            pathOK = appPage && (scenario.expectedPath.map { Self.reached(expectedPath: $0, url: webView.url, appURL: appURL) } ?? true)
            if pathOK, let selector = scenario.expectedSelector {
                let result = try? await call("""
                    try { const e = document.querySelector(selector); if (!e) return false;
                          const s = getComputedStyle(e); return e.getClientRects().length > 0 && s.visibility !== 'hidden' && s.display !== 'none'; }
                    catch (_) { return false; }
                    """, ["selector": selector]) as? Bool
                elementOK = result == true
            }
            let pageState = try? await call("return window.__markviewStudio.state();") as? [String: Any]
            let settled = pageState?["loaded"] as? Bool == true
                && (pageState?["pending"] as? NSNumber)?.intValue == 0
                && (pageState?["buildError"] as? String)?.isEmpty == true
            if pathOK && elementOK && settled {
                if stableSince == nil { stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) >= min(1, Self.expectedStateTimeout / 2) { return nil }
            } else {
                stableSince = nil
            }
            guard !Task.isCancelled, !closed else { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        } while Date() < deadline
        if !pathOK, let expected = scenario.expectedPath {
            let actual = webView.url.map { $0.path + ($0.query.map { "?" + $0 } ?? "") } ?? "no page"
            return redactor.redact(text: "Expected page \(expected), but the application is at \(actual).")
        }
        return redactor.redact(text: "The requested screen did not settle with its expected element \(scenario.expectedSelector ?? "") visible on the page.")
    }

    /// Compare the observed page, including a requested query or fragment, without allowing another origin.
    static func reached(expectedPath: String, url: URL?, appURL: URL?) -> Bool {
        guard StudioContextValidator.isPath(expectedPath), let expected = URLComponents(string: expectedPath), let url, let appURL,
              let origin = StudioBridge.Origin(url: url), let appOrigin = StudioBridge.Origin(url: appURL), origin.sameServer(appOrigin),
              let actual = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return actual.percentEncodedPath == expected.percentEncodedPath
            && (expected.percentEncodedQuery == nil || actual.percentEncodedQuery == expected.percentEncodedQuery)
            && (expected.percentEncodedFragment == nil || actual.percentEncodedFragment == expected.percentEncodedFragment)
    }

    /// Replays restoration steps one at a time, so that a step which loads another page (a link, a form) is followed by the
    /// rest of the steps in that page (BUG-071). Returns why the replay stopped, if it did.
    private func replay(_ steps: [StudioStep]) async -> String? {
        for (index, step) in steps.enumerated() {
            var object: [String: Any] = ["action": step.action.rawValue]
            if let selector = step.selector { object["selector"] = selector }
            if let text = step.text { object["text"] = text }
            if let ms = step.ms { object["ms"] = ms }
            let commits = pageCommits
            do {
                let result = try await call("return await window.__markviewStudio.replay([step]);", ["step": object]) as? [String: Any]
                if result?["ok"] as? Bool != true, !webView.isLoading, pageCommits == commits {
                    return "Restoration step \(index + 1) failed: " + (result?["reason"] as? String ?? "the page did not answer.")
                }
            } catch {
                // The page the step loaded replaced the one that ran it; anything else is a failure.
                guard webView.isLoading || pageCommits != commits else {
                    return "Restoration step \(index + 1) failed: the page did not answer."
                }
            }
            guard await settleAfterStep() else { return "Restoration step \(index + 1) loaded a page that did not finish loading." }
        }
        return nil
    }

    /// Waits for a page load a step started, if any, and for the page to settle.
    private func settleAfterStep() async -> Bool {
        // A click on a link starts the load just after the click.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let deadline = Date().addingTimeInterval(45)
        while webView.isLoading {
            guard Date() < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try? await call("return window.__markviewStudio ? await window.__markviewStudio.whenIdle(4000, 200) : null;")
        return true
    }

    /// Reset (the toolbar): the scenario's baseline data and UI state again.
    func reset() {
        runWork("Resetting the scenario") { session in _ = await session.restore() }
    }

    func reload() {
        runWork("Reloading") { session in
            guard await session.loadPage() else { return }
            _ = try? await session.call("return await window.__markviewStudio.whenIdle(20000, 300);")
            await session.refreshPageState()
            session.updateReadiness()
        }
    }

    private func refreshPageState() async {
        guard let state = try? await call("return window.__markviewStudio ? window.__markviewStudio.state() : null;") as? [String: Any] else { return }
        if let route = state["route"] as? String { self.route = route }
        let overlay = (state["buildError"] as? String) ?? ""
        buildError = overlay.isEmpty ? nil : redactor.redact(text: overlay)
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let appOrigin else { return decisionHandler(.allow) }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { return decisionHandler(.allow) }
        if navigationAction.targetFrame?.isMainFrame != false {
            if allowsSimulatedPage(url) { return decisionHandler(.allow) }
            guard let origin = StudioBridge.Origin(url: url), origin.sameServer(appOrigin) else {
                if simulateNavigation(navigationAction) { return decisionHandler(.cancel) }
                note(.blocked, "Navigation to \(url.absoluteString) was blocked: it leaves the application.")
                sessionLog.add(.navigation, problem: true, "Blocked navigation to \(url.absoluteString): it leaves the application")
                return decisionHandler(.cancel)
            }
            // The page's own navigations; MarkView's loads are logged where they start, redirects when they arrive.
            let made: String?
            switch navigationAction.navigationType {
            case .linkActivated: made = "Link"
            case .formSubmitted, .formResubmitted: made = "Form \(navigationAction.request.httpMethod ?? "GET")"
            case .backForward: made = "Back or forward"
            case .reload: made = "Reload"
            default: made = nil
            }
            if let made { sessionLog.add(.navigation, "\(made) to \(url.absoluteString)") }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationURL = webView.url
    }

    /// A server redirect of the main frame (REQ-011), such as an application sending every page to its sign-in page:
    /// `webView.url` is the new address.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        let from = navigationURL, to = webView.url
        navigationURL = to
        let signIn = to.map { StudioLogFormat.isSignInPath($0.path) } ?? false
        if signIn, let to { repair.noteSignInWall(to.path) }
        sessionLog.add(.navigation, problem: signIn, "Server redirect \(from?.absoluteString ?? "?") → \(to?.absoluteString ?? "?")"
                       + (signIn ? " (a sign-in page)" : ""))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageCommits += 1
        requestPath.channels.closeAll(source: "page")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoadWaiters(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoadWaiters(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        if tookOverNavigation(failure) { return }
        if failure.code != NSURLErrorCancelled {
            let address = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? navigationURL
            sessionLog.add(.navigation, problem: true, "The page at \(address?.absoluteString ?? "?") did not load: "
                           + "\(failure.localizedDescription) (\(failure.domain) \(failure.code))")
            notice = "The page did not load: \(error.localizedDescription)"
        }
        resumeLoadWaiters(false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        set(.degraded, "The page's web content process ended. Reset to load it again.")
        resumeLoadWaiters(false)
    }

    /// Pop-ups stay in the session's page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, let appOrigin, StudioBridge.Origin(url: url)?.sameServer(appOrigin) == true {
            webView.load(navigationAction.request)
        }
        return nil
    }

    /// The Mac's camera and microphone are never opened (REQ-008): the page runtime answers getUserMedia from the scenario,
    /// and a request that reaches WebKit anyway is denied.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// The Mac's location is never given to the page (REQ-008); the runtime answers navigator.geolocation from the scenario.
    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // MARK: - Bridge

    func receive(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard !closed, let appOrigin else { return reply(nil, "The session is not ready.") }
        let security = message.frameInfo.securityOrigin
        let port = security.port != 0 ? security.port : (security.protocol == "https" ? 443 : 80)
        let origin = StudioBridge.Origin(scheme: security.protocol, host: security.host, port: port)
        let expected = StudioBridge.Expectation(session: token, generation: simulator.generation, origin: appOrigin)
        switch StudioBridge.validate(message.body, isMainFrame: message.frameInfo.isMainFrame, origin: origin, expecting: expected) {
        case .failure(let rejection):
            rejectedMessages += 1
            reply(nil, "Rejected: \(rejection.description).")
        case .success(.event(let event)):
            handle(event)
            reply(true, nil)
        case .success(.request(let request)):
            requestPath.handle(request, reply: reply)
        case .success(.channel(let message)):
            requestPath.handleChannel(message, reply: reply)
        }
    }

    // MARK: - Fix data (REQ-017)

    /// Whether an automatic repair may start now (REQ-020): the page has settled and nothing else is working on the session. Never
    /// inside a restore, a trial of a scenario, the map or a preparation (they own the data and the page for that time).
    var isSettled: Bool {
        !closed && !restoringPage && !changeFlow.tryingScenario && busy == nil && appURL != nil && !mapping.isRunning && !isPreparing
            && [.ready, .degraded].contains(state)
    }

    /// The generation of the page the simulator serves now.
    var pageGeneration: Int { simulator.generation }

    /// Forgets the requests nothing could answer, so that the next request prepares them again; their contracts. Like the Retry of the
    /// environment panel, without the Reset that follows it (the repair loads the page itself).
    func forgetUnresolvedDependencies() -> [String] {
        let contracts = dependencies.filter { $0.mode == .unresolved }.map(\.id)
        for contract in contracts {
            preparation.retry(contract)
            observed[contract] = nil
        }
        rebuildDependencies()
        return contracts
    }

    // MARK: - Channels (REQ-015)

    /// Starts preparing the requests the page at `route` makes through the server's simulated connections (BUG-074), unless
    /// the route was prepared before (saved in the environment) or tried in this session. Returns the preparation to wait
    /// for before the page loads; nil when there is nothing to prepare.
    @discardableResult
    private func beginAhead(_ route: String) -> Task<Void, Never>? {
        if let task = aheadTasks[route] { return task }
        let simulated = serverConnections.filter { $0.mode == .simulated && gatewayPorts[$0.variable] != nil }
        guard !closed, !simulated.isEmpty, !(spec.preparedRoutes ?? []).contains(route), !aheadTried.contains(route),
              !(spec.map?.coversEveryGroup ?? false) else { return nil }
        aheadTried.insert(route)
        let lines = simulated.map { connection in
            "\(connection.variable) → \(connection.origin)\(connection.basePath)" + (connection.foundIn.isEmpty ? "" : " (read at \(connection.foundIn))")
        }
        let context = StudioPreparationContext(contract: "Page \(route): server requests", method: "GET", url: route, headers: [:], body: nil,
                                               attempt: 1, problems: [], ahead: StudioRouteAhead(route: route, connections: lines))
        let services = Set(simulated.map(\.origin))
        let preparer = requestPath.makePreparer()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.preparation.prepareAhead(context, services: services, preparer: preparer,
                                                              commit: { [weak self] proposal in self?.commit(proposal) ?? ["The session is closed."] })
            self.aheadTasks[route] = nil
            switch outcome {
            case .registered: self.markPrepared(route)
            case .cancelled: self.aheadTried.remove(route)
            default: break
            }
            self.updateReadiness()
        }
        aheadTasks[route] = task
        return task
    }

    /// Remembers that the page at `route` is prepared, so later sessions do not ask the agent again.
    private func markPrepared(_ route: String) {
        var next = simulator.spec
        var routes = next.preparedRoutes ?? []
        guard !routes.contains(route) else { return }
        routes.append(route)
        next.preparedRoutes = routes
        replaceEnvironment(next)
    }

    /// Loads the current address again, as a fresh server render, keeping the scenario's state (the banner's Reload).
    func reloadPage() {
        rulesArrivedLate = false
        guard let url = webView.url ?? appURL else { return }
        sessionLog.add(.navigation, "Loading \(url.absoluteString) again")
        var page = URLRequest(url: url)
        StudioConnectionPolicy.frameworkRequestHeaders.forEach { page.setValue($0.value, forHTTPHeaderField: $0.key) }
        startPartTask { session in await session.loadDocument(page) }
    }

    /// Registers a proposal atomically and keeps it for later sessions (rules are reusable: SIM-05).
    func commit(_ proposal: StudioProposal) -> [String] {
        let problems = simulator.register(proposal)
        guard problems.isEmpty else { return problems }
        var next = simulator.spec
        next.updated = Date()
        for rule in proposal.rules {
            let evidence = rule.evidence + proposal.assumptions.map { StudioEvidence(kind: .assumption, detail: $0) }
            let dependency = StudioDependency(id: "\(rule.method) \(rule.path)", mode: .simulated,
                                              note: "\(rule.operation.rawValue)\(rule.entity.map { " \($0)" } ?? "")", evidence: evidence)
            next.dependencies.removeAll { $0.id == dependency.id }
            next.dependencies.append(dependency)
        }
        let assumptions = proposal.assumptions.map { StudioEvidence(kind: .assumption, detail: $0) }
        let realTime = (proposal.channels ?? []).map {
            StudioDependency(id: (StudioIPC.isIPC(path: $0.path) ? "ON " : "WS ") + $0.path, mode: .simulated, note: "\($0.wire.rawValue) channel",
                             evidence: $0.evidence + assumptions)
        } + (proposal.graphQL ?? []).map {
            StudioDependency(id: "GRAPHQL \($0.path) \($0.kind.rawValue) \($0.field)", mode: .simulated,
                             note: "\($0.action.rawValue)\($0.entity.map { " \($0)" } ?? "")", evidence: $0.evidence + assumptions)
        }
        for dependency in realTime {
            next.dependencies.removeAll { $0.id == dependency.id }
            next.dependencies.append(dependency)
        }
        replaceEnvironment(next)
        rebuildDependencies()
        // A preload bridge callback that waited for its channel gets it now (REQ-016).
        requestPath.channels.openListeners()
        return []
    }

    /// Takes `environment` as the session's environment: the simulator serves it, the panels show it, and it is saved for later sessions.
    func replaceEnvironment(_ environment: StudioEnvironmentSpec) {
        simulator.replaceSpec(environment)
        spec = simulator.spec
        persistEnvironment()
    }

    private func persistEnvironment() {
        let spec = simulator.spec, root = root
        io.async { try? StudioStore.saveEnvironment(spec, root: root) }
    }

    /// Takes a reviewed environment in one step (DEC-015): the simulator, the saved file, the dependencies and the channels that wait. The
    /// review has already been applied to a copy; nothing is adopted when it was refused.
    func adoptReview(_ outcome: StudioReview.Outcome) -> [String] {
        var trial = simulator
        let problems = StudioReview.apply(outcome, to: &trial)
        guard problems.isEmpty else { return problems }
        simulator = trial
        spec = simulator.spec
        persistEnvironment()
        rebuildDependencies()
        requestPath.channels.openListeners()
        return []
    }

    private func handle(_ event: StudioBridge.Event) {
        let detail = redactor.redact(text: event.detail)
        switch event.kind {
        case .route:
            if detail != route { sessionLog.add(.navigation, "Route \(route) → \(detail)") }
            route = detail
            repair.noteSignInWall(detail)
            return
        case .idle:
            updateReadiness()
            return
        case .recorded:
            if mode == .record, let data = detail.data(using: .utf8), let step = try? JSONDecoder().decode(StudioStep.self, from: data) {
                recordedSteps.append(step)
            }
            return
        case .buildError where detail.isEmpty:
            // The overlay is gone: the application builds again, so the preview is live, not stale.
            sessionLog.add(.page, "The build error overlay is gone: the application builds again")
            buildError = nil
            stalePreview = nil
            updateReadiness()
            return
        case .buildError:
            buildError = detail
            if stalePreview == nil { stalePreview = captures.last { $0.scenarioId == scenario.id } }
        case .unsupported:
            noteDependency(StudioDependency(id: "unsupported:" + String(detail.prefix(80)), mode: .unsupported, note: detail))
        case .electron:
            noteDependency(StudioDependency(id: "electron:" + detail, mode: .unsupported,
                                            note: "\(detail) is synchronous IPC: it gets undefined at once, so what depends on its answer is not simulated."))
        case .blocked:
            noteDependency(StudioDependency(id: "blocked:" + String(detail.prefix(120)), mode: .unsupported,
                                            note: detail + " (blocked by the application connection policy)"))
        case .browser:
            // Answered by the scenario's browser settings; listed with the latest use (REQ-008).
            let feature = StudioBridge.browserFeature(of: detail) ?? "browser"
            noteDependency(StudioDependency(id: "browser:" + feature, mode: .simulated,
                                            note: "Answered by the scenario's browser settings. Last use: " + String(detail.prefix(300))))
        case .standIn:
            // A simulated SDK is a dependency like a simulated request: listed with what it stands for, never a problem.
            if let standIn = StudioBridge.standIn(of: detail) {
                noteDependency(StudioDependency(id: "sdk:" + standIn.id, mode: .simulated,
                                                note: "The connection policy blocks its script, so a built-in stand-in answers in the page: " + standIn.what))
            }
        case .runtimeError, .logged:
            break
        }
        logPageEvent(event.kind, detail)
        note(event.kind, detail)
        updateReadiness()
        if event.kind == .runtimeError || event.kind == .logged { repair.scheduleAutoRepair() }
    }

    private func note(_ kind: StudioBridge.Event.Kind, _ detail: String) {
        events.append(EventRecord(kind: kind, detail: detail, generation: simulator.generation, scenarioID: scenario.id))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    /// A page event in the log (REQ-011): errors, build error overlays, blocked resources and synchronous IPC are problems.
    private func logPageEvent(_ kind: StudioBridge.Event.Kind, _ detail: String) {
        let problem: Bool
        switch kind {
        case .runtimeError, .logged, .buildError, .blocked, .unsupported, .electron: problem = true
        case .browser, .standIn, .route, .idle, .recorded: problem = false
        }
        sessionLog.add(.page, problem: problem, errorKey: StudioDataFix.isFixable(kind: kind, detail: detail) ? StudioDataFix.key(of: detail) : nil,
                       "\(kind.rawValue): \(detail)")
    }

    /// The development server's output, one entry per line (REQ-011); a line that reads like an error is a problem.
    private func logServerOutput(_ text: String) {
        for line in serverLines.feed(text) {
            sessionLog.add(.server, problem: StudioLogFormat.looksLikeError(line), line)
        }
    }

    /// The start and the end of a rule preparation (REQ-011), those ahead of a page included.
    private func logPreparation(_ record: StudioPreparationQueue.Record) {
        guard let finished = record.finished else {
            return sessionLog.add(.preparation, "Preparing \(record.contract)")
        }
        let seconds = String(format: "%.1f s", finished.timeIntervalSince(record.started))
        let problem = [.failed, .timedOut, .unsupported, .limit].contains(record.status)
        sessionLog.add(.preparation, problem: problem, "\(record.contract): \(record.status.rawValue) after \(seconds)"
                       + (record.message.isEmpty ? "" : " — \(record.message)"))
    }

    private var observed: [String: StudioDependency] = [:]

    func noteDependency(_ dependency: StudioDependency) {
        observed[dependency.id] = dependency
        rebuildDependencies()
    }

    private func rebuildDependencies() {
        var list = spec.dependencies.filter { $0.mode == .simulated }
        for rule in spec.rules where !list.contains(where: { $0.id == "\(rule.method) \(rule.path)" }) {
            list.append(StudioDependency(id: "\(rule.method) \(rule.path)", mode: .simulated,
                                         note: "\(rule.operation.rawValue)\(rule.entity.map { " \($0)" } ?? "")", evidence: rule.evidence))
        }
        let simulatedIDs = Set(list.map(\.id))
        list += observed.values.filter { !simulatedIDs.contains($0.id) || $0.mode == .unsupported }
            .filter { dependency in !(dependency.mode == .unresolved && simulatedIDs.contains(dependency.id)) }
        list += spec.allowedRequests.map { StudioDependency(id: $0, mode: .allowed, note: "Allowed to reach its address.") }
        var seen = Set<String>()
        dependencies = list.filter { seen.insert($0.mode.rawValue + $0.id).inserted }
            .sorted { ($0.mode.rawValue, $0.id) < ($1.mode.rawValue, $1.id) }
    }

    /// ready / degraded / preparing from what the page and the environment report (REQ-001).
    func updateReadiness() {
        guard !closed, appURL != nil, !restoringPage, [.ready, .degraded, .preparing, .starting].contains(state) else { return }
        var reasons: [String] = []
        if let buildError { reasons.append("Build error: " + String(buildError.prefix(160))) }
        let errors = events.filter { $0.kind == .runtimeError && $0.generation == simulator.generation }
        if !errors.isEmpty { reasons.append("\(errors.count) runtime error\(errors.count == 1 ? "" : "s") on the page") }
        let unsupported = dependencies.filter { $0.mode == .unsupported }
        if !unsupported.isEmpty { reasons.append("\(unsupported.count) unsupported dependenc\(unsupported.count == 1 ? "y" : "ies") (not simulated)") }
        let unresolved = dependencies.filter { $0.mode == .unresolved }
        if !unresolved.isEmpty { reasons.append("\(unresolved.count) request\(unresolved.count == 1 ? "" : "s") without a simulation rule") }
        if stalePreview != nil, buildError != nil { reasons.append("The preview is stale") }
        limitations = reasons
        if isPreparing {
            set(.preparing, "Preparing simulation rules for new requests")
        } else if reasons.isEmpty {
            let detail = target?.usesIsolatedBackend == true && ownsServer
                ? "The scenario is loaded. The application uses its separate local test database."
                : "The scenario is loaded and every request it made is simulated."
            set(.ready, detail)
        } else {
            set(.degraded, reasons.joined(separator: "; "))
        }
    }

    // MARK: - Connection policy

    /// Lets an address through on purpose (ENV: explicitly allowed requests); the page reloads under the new policy.
    func allow(_ pattern: String) {
        let text = pattern.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !spec.allowedRequests.contains(text) else { return }
        var next = simulator.spec
        next.allowedRequests.append(text)
        replaceEnvironment(next)
        rebuildDependencies()
        runWork("Applying the connection policy") { session in
            await session.installConnectionPolicy()
            _ = await session.restore()
        }
    }

    func disallow(_ pattern: String) {
        var next = simulator.spec
        next.allowedRequests.removeAll { $0 == pattern }
        replaceEnvironment(next)
        rebuildDependencies()
        runWork("Applying the connection policy") { session in
            await session.installConnectionPolicy()
            _ = await session.restore()
        }
    }

    func retryPreparation(_ contract: String) {
        preparation.retry(contract)
        observed[contract] = nil
        rebuildDependencies()
        reset()
    }

    // MARK: - Scenarios

    /// Makes `next` the scenario the page and the simulator are on. The steps recorded so far belong to the scenario that was left, unless
    /// the trial of a requested scenario keeps them.
    func switchScenario(to next: StudioScenario, keepingRecordedSteps keep: Bool = false) {
        scenario = next
        simulator.activate(next)
        if !keep { recordedSteps = [] }
    }

    func activate(_ next: StudioScenario) {
        switchScenario(to: next)
        // Another scenario keeps the application signed in as the same test user (BUG-088); Reset starts signed out, as before.
        runWork("Resetting the scenario") { session in _ = await session.restore(keepingSignIn: true) }
    }

    /// Makes `next` the scenario and restores the page on it, keeping the sign-in, and says what went wrong, if anything: the check a
    /// prepared screen's first opening needs (REQ-021). Called inside `runWork`.
    func activateReturningProblem(_ next: StudioScenario) async -> String? {
        switchScenario(to: next)
        return await restore(keepingSignIn: true)
    }

    /// Replaces the list of saved scenarios with what is on disk now (after a file was written off the main thread).
    func reloadSavedScenarios(_ scenarios: [StudioScenario]) { savedScenarios = scenarios }

    /// Writes the screen book, off the main thread.
    func persistScreenBook() {
        let book = screenBook, root = root
        io.async { try? StudioStore.saveScreenBook(book, root: root) }
    }

    func setViewport(_ viewport: StudioViewport) {
        scenario.viewport = viewport
        resizeWebView()
    }

    func setTheme(_ theme: StudioScenario.Theme) {
        scenario.theme = theme
        applyTheme()
    }

    func setLocale(_ locale: String) {
        scenario.locale = locale
        simulator.activate(scenario)
        reset()
    }

    /// What the page gets for location, clipboard, camera and microphone, and notifications (REQ-008); the page is reset so
    /// that it starts under them. The default profile is stored as none, so scenario files stay as they were.
    func setBrowserProfile(_ profile: StudioBrowserProfile) {
        guard busy == nil else {
            notice = "Wait for \(busy ?? "the current work") to finish."
            return
        }
        scenario.browser = profile == StudioBrowserProfile() ? nil : profile
        simulator.activate(scenario)
        reset()
    }

    // MARK: - Kept cookies and storage

    func problems(of scenario: StudioScenario) -> [String] {
        scenario.id.hasPrefix("builtin-") ? [] : StudioScenarioCompatibility.problems(scenario, spec: spec)
    }

    /// Saves the current situation as a scenario (SCN-01): route, role, overrides, viewport, theme, locale, seed, test time
    /// and the recorded steps; the baseline data is the environment's seed unless the scenario already had its own.
    func saveScenario(name: String, kind: StudioScenario.Kind) {
        var saved = scenario
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.name = trimmed.isEmpty ? kind.title : trimmed
        saved.kind = kind
        saved.id = StudioStore.safeID(saved.name)
        if !recordedSteps.isEmpty { saved.steps = recordedSteps }
        saved.revision = (savedScenarios.first { $0.id == saved.id }?.revision ?? 0) + 1
        saved.updated = Date()
        saved.contractFingerprint = StudioScenarioCompatibility.fingerprint(saved, spec: spec)
        do {
            try StudioStore.saveScenario(saved, root: root)
            savedScenarios = StudioStore.loadScenarios(root)
            switchScenario(to: saved)
            notice = "Saved scenario \(saved.name) in .markview/studio/scenarios/."
        } catch {
            notice = "The scenario could not be saved: \(error.localizedDescription)"
        }
    }

    /// The explicit update of an incompatible scenario (SCN-04); the change is reported, the baseline is not silently rewritten.
    func updateScenario(_ old: StudioScenario) {
        let (updated, notes) = StudioScenarioCompatibility.updated(old, spec: spec)
        do {
            try StudioStore.saveScenario(updated, root: root)
            savedScenarios = StudioStore.loadScenarios(root)
            notice = "Updated \(updated.name) to revision \(updated.revision)" + (notes.isEmpty ? "." : ": " + notes.joined(separator: " "))
            if scenario.id == updated.id { activate(updated) }
        } catch {
            notice = "The scenario could not be updated: \(error.localizedDescription)"
        }
    }

    func deleteScenario(_ id: String) {
        StudioStore.deleteScenario(id, root: root)
        savedScenarios = StudioStore.loadScenarios(root)
    }

    // MARK: - Modes and selection

    func snapshot(_ rect: CGRect?) async -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        configuration.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Assistant

    /// The application folder relative to the project: empty for the project itself.
    var relativeAppFolder: String {
        appFolder.standardizedFileURL.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Asks the assistant for the application's screens: read-only, without the page. The Screens menu's Refresh and the background
    /// discovery both use it.
    func requestScreens(reportProgress: Bool) async throws -> (screens: [StudioScreen], notes: String) {
        let folder = relativeAppFolder
        var request = CLICompletion.Request(project: root,
                                            prompt: "Application folder (relative to the project): \(folder.isEmpty ? "." : folder)\n"
                                                + "Current route: \(route)\nFind the application's selectable screens and their prerequisites.",
                                            systemPrompt: StudioPrompts.screensSystem, jsonSchema: StudioPrompts.screensSchema,
                                            readableFolder: root)
        request.label = "ui-studio:screens"
        request.timeout = 900
        request.effort = "medium"
        let operation = AIOperation<CLICompletion.Request, (screens: [StudioScreen], notes: String)>(
            name: "ui-studio:screens",
            parse: { result in
                (StudioPrompts.screens(from: result.structured), (result.structured as? [String: Any])?["notes"] as? String ?? "")
            },
            onResult: { [weak self] result in self?.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0) })
        var report: (@Sendable (CLICompletion.Activity) -> Void)?
        if reportProgress {
            report = { [weak self] activity in Task { @MainActor in self?.progress(activity) } }
        }
        return try await operation.execute(request, onActivity: report).output
    }

    /// Inventory screens without changing the page or writing project files. The list is kept in `.markview/studio/screens.json`.
    func discoverScreens() {
        guard appURL != nil, busy == nil else { return }
        runWork("Finding application screens") { session in
            do {
                let (found, notes) = try await session.requestScreens(reportProgress: true)
                guard !Task.isCancelled else { return }
                session.adoptScreens(found)
                session.notice = found.isEmpty ? "No screens with source-backed destination selectors were found. " + notes
                    : "Found \(found.count) screens. Choose one in the Screens menu." + (notes.isEmpty ? "" : " " + notes)
                session.scheduleScreenWork()
            } catch is CancellationError {
                return
            } catch {
                session.notice = "Screen discovery failed: \(error.localizedDescription)"
            }
        }
    }

}

// MARK: - Sign-in and pages outside the application (REQ-010)

extension StudioSession {
    var hasRealSupabase: Bool {
        serverConnections.contains { $0.variable.uppercased().contains("SUPABASE") && $0.mode == .real }
    }

    /// The redirects a simulated navigation follows before it shows where it got to.
    static let simulatedRedirectLimit = 5

    /// The built-in Supabase Auth for a project that uses Supabase (REQ-010), on the server's current connections. What the
    /// application changed of the test user is kept while the addresses stay the same.
    private func configureAuthMock(_ target: WebAppTarget) async {
        let root = root, folder = target.folder
        let uses = await Task.detached { StudioAuthMock.usesSupabase(appFolder: folder, root: root) }.value
        guard !closed else { return }
        let id = StudioAuthMock.dependencyID
        guard uses else {
            simulator.authMock = nil
            if observed.removeValue(forKey: id) != nil { rebuildDependencies() }
            return
        }
        let mock = StudioAuthMock(connections: serverConnections)
        if !mock.sameConfiguration(simulator.authMock) {
            simulator.authMock = mock
            sessionLog.add(.notice, "Supabase Auth is the built-in mock-up. " + mock.note)
        }
        noteDependency(StudioDependency(id: id, mode: .simulated, note: mock.note))
    }

    /// Asked first for every main-frame navigation: the simulated page being shown is allowed once, and any other
    /// navigation brings back the page runtime that a simulated page went without.
    private func allowsSimulatedPage(_ url: URL) -> Bool {
        if let pending = simulatedNavigation.pending {
            simulatedNavigation.pending = nil
            if StudioSimulatedNavigation.samePage(pending, url) { return true }
        }
        if simulatedNavigation.runtimePaused, !closed {
            simulatedNavigation.runtimePaused = false
            _ = installRuntime()
        }
        return false
    }

    /// A main-frame navigation that leaves the application (REQ-010). The address of a simulated service is answered by the
    /// simulation, with its redirects followed; any other site is shown as a local stand-in page. Nothing is sent. False
    /// for an address that is not http(s): it stays blocked.
    private func simulateNavigation(_ action: WKNavigationAction) -> Bool {
        let request = action.request
        guard !closed, let url = request.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        simulatedNavigation.serial += 1
        simulatedNavigation.cancelled = url
        let serial = simulatedNavigation.serial
        let method = request.httpMethod ?? "GET", headers = request.allHTTPHeaderFields ?? [:]
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        startPartTask { session in await session.followNavigation(method: method, url: url, headers: headers, body: body, serial: serial) }
        return true
    }

    /// Whether a failed provisional navigation is the one the session cancelled to answer itself: a server redirect out of
    /// the application ends as "frame load interrupted". It is no failure, and the page that replaces it ends the load.
    private func tookOverNavigation(_ failure: NSError) -> Bool {
        guard let cancelled = simulatedNavigation.cancelled,
              let address = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? navigationURL,
              StudioSimulatedNavigation.samePage(cancelled, address) else { return false }
        simulatedNavigation.cancelled = nil
        sessionLog.add(.navigation, "The server's redirect to \(shown(address)) is answered by the session instead")
        return true
    }

    private func followNavigation(method: String, url start: URL, headers: [String: String], body: String?, serial: Int) async {
        var method = method, url = start, headers = headers, body = body
        for hop in 0...Self.simulatedRedirectLimit {
            guard !closed, serial == simulatedNavigation.serial else { return }
            if let appOrigin, StudioBridge.Origin(url: url)?.sameServer(appOrigin) == true {
                sessionLog.add(.navigation, "Simulated redirect back into the application: \(shown(url))")
                webView.load(URLRequest(url: url))
                return
            }
            guard let logical = simulatedServiceURL(url) else { return showExternalPage(url) }
            sessionLog.add(.navigation, "Navigation \(method) \(shown(logical)) is answered by the simulation"
                           + (hop == 0 ? "" : " (redirect \(hop))"))
            let request = StudioHTTPRequest(method: method, url: logical, headers: headers, body: body, requestId: UUID().uuidString)
            let answer = await withCheckedContinuation { (done: CheckedContinuation<StudioReply, Never>) in
                requestPath.route(request, source: .page) { done.resume(returning: $0) }
            }
            guard !closed, serial == simulatedNavigation.serial else { return }
            switch answer {
            case .respond(let response):
                if response.hang {
                    return sessionLog.add(.navigation, problem: true, "The simulated answer to \(shown(logical)) never comes (the scenario holds it)")
                }
                if response.delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(response.delayMs) * 1_000_000) }
                guard (300..<400).contains(response.status), let location = response.headers["location"],
                      let next = URL(string: location, relativeTo: logical)?.absoluteURL else {
                    return showSimulatedAnswer(response, at: url, logical: logical)
                }
                sessionLog.add(.navigation, "Simulated redirect \(response.status) \(shown(logical)) → \(shown(next))")
                if ![307, 308].contains(response.status) { method = "GET"; body = nil }
                headers = [:]
                url = next
            case .pass:
                return showExternalPage(url)
            case .dropped(let reason):
                return sessionLog.add(.navigation, problem: true, "The simulated answer to \(shown(logical)) was dropped (\(reason))")
            }
        }
        sessionLog.add(.navigation, problem: true, "Navigation stopped after \(Self.simulatedRedirectLimit) simulated redirects at \(shown(url))")
        let html = StudioExternalPage.page(title: "Too many simulated redirects",
                                           body: "<p>The simulated services redirected more than \(Self.simulatedRedirectLimit) times. "
                                               + "The session log lists each step.</p>")
        showPage(Data(html.utf8), type: "text/html; charset=utf-8", status: 200, at: url)
    }

    private func showSimulatedAnswer(_ response: StudioSimResponse, at url: URL, logical: URL) {
        let body = response.body ?? ""
        var type = response.headers["content-type"] ?? ""
        if type.isEmpty {
            type = body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") ? "text/html; charset=utf-8" : "application/json; charset=utf-8"
        }
        sessionLog.add(.navigation, problem: response.status >= 400, "Showing the simulated answer \(response.status) of \(shown(logical))")
        showPage(Data(body.utf8), type: type, status: response.status, at: url)
    }

    private func showExternalPage(_ url: URL) {
        let returnTo = StudioExternalPage.returnURL(for: url, appOrigin: appOrigin?.text)
        note(.blocked, "Navigation to \(shown(url)) was not sent: a simulated external page stands in for it.")
        sessionLog.add(.navigation, "Navigation to \(shown(url)) leaves the application: a simulated external page is shown, nothing is sent; "
                       + (returnTo.map { "Continue as Test User returns to \(shown($0))" } ?? "Continue as Test User goes back"))
        let html = StudioExternalPage.html(for: url, returnTo: returnTo, user: scenario.role.user)
        showPage(Data(html.utf8), type: "text/html; charset=utf-8", status: 200, at: url)
    }

    /// Shows `data` as the page at `url` without a request. The runtime is left out: the page is not the application's,
    /// and its messages would only be rejected.
    private func showPage(_ data: Data, type: String, status: Int, at url: URL) {
        guard !closed, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])
        else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        simulatedNavigation.runtimePaused = true
        simulatedNavigation.pending = url
        webView.loadSimulatedRequest(URLRequest(url: url), response: response, responseData: data)
    }

    /// The service address the simulation answers for `url`: a gateway port, a simulated connection, the built-in Supabase
    /// Auth or the origin of a rule with a full URL; nil for any other site.
    private func simulatedServiceURL(_ url: URL) -> URL? {
        if let logical = requestPath.logicalURL(for: url) { return logical }
        guard let origin = StudioBridge.Origin(url: url) else { return nil }
        func same(_ text: String) -> Bool { URL(string: text).flatMap(StudioBridge.Origin.init(url:)) == origin }
        if serverConnections.contains(where: { $0.mode == .simulated && same($0.origin) }) { return url }
        if simulator.authMock?.endpoint(of: url) != nil { return url }
        if spec.rules.contains(where: { StudioRoute.split($0.path).origin.map(same) ?? false }) { return url }
        return nil
    }

    private func shown(_ url: URL) -> String {
        redactor.redact(text: StudioConnections.redact(url.absoluteString, hashes: secretHashes))
    }
}

// MARK: - Application map (REQ-014)

/// The session's side of the application's map: the mapper registers through the same commit as every preparation, saves
/// the map in the environment, and reports each step in the session log.
extension StudioSession {
    func wireMapping() {
        mapping.queue = preparation
        mapping.load(spec.map)
        mapping.hooks = StudioEnvironmentMapper.Hooks(
            spec: { [weak self] in self?.simulator.spec ?? StudioEnvironmentSpec() },
            state: { [weak self] in self?.simulator.state ?? [:] },
            save: { [weak self] map in self?.saveMap(map) },
            commit: { [weak self] proposal in self?.commit(proposal) ?? ["The session is closed."] },
            replaceSeed: { [weak self] seed in self?.replaceSeed(seed) },
            userRoles: { [weak self] roles, ordinary in self?.applyUserRoles(roles, ordinary: ordinary) },
            log: { [weak self] problem, text in self?.sessionLog.add(.preparation, problem: problem, text) },
            finished: { [weak self] summary, refilled, requested in
                self?.mappingFinished(summary, refilled: refilled, requested: requested)
            })
    }

    /// What the map is made for: the application folder, its origin and the server's simulated connections.
    private var mapContext: StudioMapContext {
        let relative = appFolder.standardizedFileURL.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StudioMapContext(appFolder: relative, appOrigin: appOrigin?.text, connections: serverConnections.filter { $0.mode == .simulated },
                                electron: target?.isElectron ?? false)
    }

    /// Maps the application in the background when its environment has no completed map for this folder, or resumes the map
    /// a closed session left, or extends an older map with what the current inventory lists (REQ-016). The page loads
    /// meanwhile; its requests are prepared as before until their group is ready.
    func beginMapping() {
        let context = mapContext
        guard !closed, StudioEnvironmentMapper.needsMapping(spec.map, appFolder: context.appFolder, electron: context.electron) else { return }
        startMapping(context)
    }

    /// The banner's Cancel: the groups being prepared end, and the map waits for Resume.
    func cancelMapping() {
        mapping.cancel()
    }

    /// Resume in the Environment panel: a cancelled, failed or interrupted map goes on, and groups that failed are tried again.
    func resumeMapping() {
        guard !closed, !mapping.isRunning else { return }
        startMapping(mapContext, retryFailed: true)
    }

    /// Map again: the rules and data the assistant prepared are removed (the project's and the person's stay), and the
    /// application is mapped from the start.
    func mapAgain() {
        guard !closed, !mapping.isRunning, busy == nil else { return }
        let before = simulator.spec
        let next = StudioMapPlanner.withoutPrepared(before)
        replaceEnvironment(next)
        rebuildDependencies()
        aheadTried = []
        sessionLog.add(.preparation, "Mapping the application again: \(before.rules.count - next.rules.count) prepared rule(s) and "
                       + "\(before.entities.count - next.entities.count) entit(ies) were removed")
        mapping.load(nil)
        startMapping(mapContext, fresh: true)
        reset()
    }

    /// Refill data: new seed records for every entity, coherent with each other; the rules stay.
    func refillData() {
        guard !closed, !mapping.isRunning, busy == nil else { return }
        mapping.assistant = makeMapAssistant()
        mapping.refillAll(mapContext)
    }

    private func startMapping(_ context: StudioMapContext, fresh: Bool = false, retryFailed: Bool = false) {
        mapping.assistant = makeMapAssistant()
        mapping.start(context, fresh: fresh, retryFailed: retryFailed)
    }

    private func makeMapAssistant() -> StudioCLIMapAssistant {
        let services = windowServices
        return StudioCLIMapAssistant(project: root) { [weak services] input, output, cost in
            Task { @MainActor in services?.studioRecordUsage(input, output, cost) }
        }
    }

    private func saveMap(_ map: StudioEnvironmentMap?) {
        guard !closed else { return }
        var next = simulator.spec
        next.map = map
        replaceEnvironment(next)
    }

    /// New seed records for these entities. The current records change at the next Reset; a scenario with its own records
    /// keeps them.
    private func replaceSeed(_ seed: [String: [StudioJSON]]) {
        guard !closed else { return }
        var next = simulator.spec
        for (name, records) in seed { next.seed[name] = records }
        next.updated = Date()
        replaceEnvironment(next)
    }

    /// The application checks its own user roles: when the built-in test user's role is not one of them, it gets the
    /// ordinary role, saved in the environment, so a server that accepts only those roles does not refuse it (vivaa's
    /// backend for frontend accepts customer, master, fairy, support and admin, not member).
    private func applyUserRoles(_ roles: [String], ordinary: String) {
        guard !closed else { return }
        let current = spec.testUserRole ?? StudioRole.tester.roleName ?? ""
        guard let next = StudioMapPlanner.testUserRole(current: current, roles: roles, ordinary: ordinary) else { return }
        var updated = simulator.spec
        updated.testUserRole = next
        replaceEnvironment(updated)
        sessionLog.add(.preparation, "The test user's role \(current) is not one the application checks (\(roles.joined(separator: ", "))): "
                       + "the built-in scenarios' test user now has the role \(next)")
        // A built-in scenario with that user signs in with the new role from the next answer on; its records stay.
        guard scenario.id.hasPrefix("builtin-"), scenario.role.name == StudioRole.tester.name, scenario.role.roleName == current else { return }
        let role = scenario.role.withRole(next)
        scenario.role = role
        simulator.replaceRole(role)
        if appURL != nil, [.ready, .degraded].contains(state) {
            notice = "The test user now has the role \(next), one the application checks; Reset signs in with it."
        }
    }

    private func mappingFinished(_ summary: String, refilled: Bool, requested: Bool) {
        guard !closed else { return }
        repair.scheduleAutoRepair()
        scheduleEnvironmentReview()
        scheduleScreenWork()
        if requested, refilled, busy == nil {
            sessionLog.add(.preparation, "The scenario is reset to show the refilled data")
            return reset()
        }
        if refilled {
            notice = summary + " The simulated data was refilled; Reset shows it."
        } else if requested {
            notice = summary
        }
    }
}
