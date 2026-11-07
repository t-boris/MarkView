import AppKit
import Foundation
import WebKit

/// The page-to-native handler of a session. A separate object, so the web view's content controller does not keep the
/// session alive.
final class StudioMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: StudioSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let session else {
            replyHandler(nil, "The UI Studio session is closed.")
            return
        }
        session.receive(message, reply: replyHandler)
    }
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
    let mapping = StudioEnvironmentMapper()
    /// What the session did and saw, redacted (REQ-011): the log drawer and `.dde/studio/session.log`.
    let sessionLog: StudioLog

    /// The bounds of rule preparation for new sessions (overridable for tests outside the app).
    static var preparationLimits = StudioPreparationLimits()

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
    @Published private(set) var savedScenarios: [StudioScenario] = []
    @Published private(set) var scenario: StudioScenario {
        didSet { rememberActiveScenario() }
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
    @Published private(set) var mode: Mode = .interact {
        // A page the application loads while recording (a link, a form, a reload) records too (BUG-071).
        didSet { if (oldValue == .record) != (mode == .record) { _ = installRuntime() } }
    }
    @Published var zoom: Double? = nil
    @Published private(set) var selection: StudioSelectionContext?
    @Published var notice: String? {
        didSet { if let notice, notice != oldValue { sessionLog.add(.notice, problem: StudioLogFormat.looksLikeError(notice), notice) } }
    }
    @Published private(set) var history: [StudioOperation] = []
    /// The turn the assistant is answering; nil once it is in `history`, and after a failure or Stop.
    @Published private(set) var pendingTurn: PendingTurn?
    /// The turns of the current conversation: the thread shows them and the assistant remembers them. A UI Studio session
    /// starts with an empty conversation and Clear starts a new one (BUG-075), so yesterday's request about another element
    /// neither fills the thread nor steers today's change (BUG-068). Every operation stays in History, with undo.
    @Published private(set) var conversationIds: Set<String> = []

    /// The images in the request box, waiting to be sent with the next request (REQ-005); the box edits them through a binding.
    @Published var attachments = ImageAttachmentList()

    /// The conversation, oldest first.
    var conversation: [StudioOperation] { history.filter { conversationIds.contains($0.id) } }

    /// Starts a new conversation (BUG-075): the thread is empty and the assistant forgets its turns. History, undo and
    /// versions are not touched.
    func clearConversation() {
        guard busy == nil else { return }
        conversationIds = []
    }
    @Published private(set) var busy: String?
    @Published private(set) var busyDetail = ""
    @Published private(set) var captures: [StudioCapture] = []
    @Published private(set) var packages: [StudioPackage] = []
    @Published private(set) var events: [EventRecord] = []
    @Published private(set) var requests: [RequestRecord] = []
    @Published private(set) var dependencies: [StudioDependency] = []
    @Published private(set) var buildError: String?
    /// The last capture of working code, shown as stale while a change does not build (EDIT-08, AC-15).
    @Published private(set) var stalePreview: StudioCapture?
    @Published private(set) var recordedSteps: [StudioStep] = []
    @Published private(set) var route = "/"
    @Published private(set) var rejectedMessages = 0
    @Published var comparison: Comparison?
    /// Whether the comparison fills the whole tab instead of the narrow Evidence panel (BUG-094).
    @Published var comparisonEnlarged = false
    /// Undo conflicts by operation: the merged text with conflict markers per file.
    @Published private(set) var undoConflicts: [String: [(path: String, merged: String)]] = [:]
    /// What the last "Keep" left out of the kept cookies and storage, and why (names only, never values).
    @Published private(set) var keptSkipped: [String] = []

    /// Unsaved editor buffers of files in the project (path relative to the root → text).
    var editorBuffers: () -> [String: String] = { [:] }
    /// Counts an assistant run in the workspace's usage.
    var recordUsage: (Int, Int, Double) -> Void = { _, _, _ in }
    var openFile: (URL) -> Void = { _ in }
    var featureStore: () -> FeatureStore? = { nil }
    var onFeatureExported: (String) -> Void = { _ in }

    private var simulator: StudioSimulator
    private var server: StudioDevServer?
    private var failedInstallFolder: URL?
    private var ruleListID: String?
    /// Whether the connection policy is in force: without it nothing is blocked and no SDK needs a stand-in.
    private var policyInstalled = false
    private var appOrigin: StudioBridge.Origin?
    /// Main-frame page loads committed so far: tells a replay step that loaded another page from one that failed.
    private var pageCommits = 0
    /// The real time at which the scenario's test clock shows its test time: set by every restore, shared by the page and the
    /// development server, so the clock runs on across page loads (DEC-006).
    private var clockAnchor = Date()
    /// The listeners the simulated connections point at, by variable (REQ-007).
    private var gateway: StudioGateway?
    private var gatewayPorts: [String: UInt16] = [:]
    /// The simulated WebSocket, EventSource and Socket.IO connections of the page and of the server (REQ-015).
    private lazy var channels = makeChannelHub()
    /// Frames pushed to the page, one after the other.
    private var channelDeliveries: Task<Void, Never>?
    /// The gateway's WebSocket and event-stream events, read in order.
    private var gatewayStreams: Task<Void, Never>?
    /// Hashes of the project's secret values (from its env files), to redact them from requests; never the values.
    private var secretHashes: [String: String] = [:] {
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
    private var restoringPage = false
    /// The generation that already reloaded for rules that arrived late (at most once per generation).
    private var reloadedForRules: Int?
    /// Rules arrived for a server request after its page had rendered, and the page was not reloaded by itself because the
    /// person had typed into it: the banner offers Reload (BUG-074).
    @Published private(set) var rulesArrivedLate = false
    /// The development server's output as whole lines for the log.
    private var serverLines = StudioLogLines()
    /// The address of the main frame's provisional navigation, for the "from" of a server redirect.
    private var navigationURL: URL?
    /// Navigations that leave the application and are answered by the session (REQ-010).
    private var simulatedNavigation = StudioSimulatedNavigation()

    /// The Node preload that gives the server the scenario's clock, time zone and locale (DEC-006).
    static var nodePreloadURL = Bundle.main.url(forResource: "markview-ui-studio-node", withExtension: "cjs", subdirectory: "Editor/vendor/js")
    /// The globals an Electron renderer's preload exposes, simulated as the preload bridge (REQ-016).
    private(set) var electronGlobals: [String] = []
    private var pickTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var loadWaiters: [CheckedContinuation<Bool, Never>] = []
    private let handler = StudioMessageHandler()
    private let redactor: StudioRedactor
    private let io = DispatchQueue(label: "markview.ui-studio.io")
    private var closed = false

    /// The page runtime, from the editor bundle (overridable for tests outside the app).
    static var runtimeURL = Bundle.main.url(forResource: "markview-ui-studio", withExtension: "js", subdirectory: "Editor/vendor/js")
    private static var runtimeSource: String? { runtimeURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

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

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15 MarkViewUIStudio"
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: first.viewport.width, height: first.viewport.height), configuration: configuration)
        super.init()
        preparation.onRecord = { [weak self] record in self?.logPreparation(record) }
        wireMapping()
        handler.session = self
        configuration.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: StudioBridge.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        applyTheme()

        history = StudioStore.loadHistory(root)
        captures = StudioStore.loadCaptures(root)
        packages = StudioStore.loadPackages(root)
        savedScenarios = StudioStore.loadScenarios(root)
        rebuildDependencies()
        Self.registerTermination()
        if let needsUpdate { notice = "The scenario \(needsUpdate) needs an update, so UI Studio opened on Populated. Update it in the Scenario menu." }
    }

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
            let installer = StudioDevServer(command: install.command, folder: install.folder)
            installer.onOutput = { [weak self] text in
                Task { @MainActor in self?.refreshServerLog(); self?.logServerOutput(text) }
            }
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
        let server = StudioDevServer(command: target.command, folder: target.folder)
        serverLines = StudioLogLines()
        server.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.refreshServerLog()
                self?.logServerOutput(text)
            }
        }
        // Only the session's current server reports its end: one it stopped or replaced on purpose does not.
        server.onExit = { [weak self, weak server] code in
            Task { @MainActor in
                guard let self, let server, self.server === server else { return }
                self.serverEnded(code)
            }
        }
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
        channels.closeAll(source: "server")
        let simulated = found.connections.filter { $0.mode == .simulated }.map(\.variable)
        if !simulated.isEmpty {
            let gateway = StudioGateway { [weak self] request, reply in
                Task { @MainActor in
                    guard let self else {
                        return reply(StudioGatewayResponse(status: 503, headers: [:], body: nil))
                    }
                    self.handleServerRequest(request, reply: reply)
                }
            }
            var continuation: AsyncStream<StudioGatewayStreamEvent>.Continuation?
            let events = AsyncStream<StudioGatewayStreamEvent> { continuation = $0 }
            if let continuation { gateway.setStreamHandler { event in continuation.yield(event) } }
            gatewayStreams = Task { [weak self] in
                for await event in events { self?.handleServerStream(event, on: gateway) }
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
            return (try? data.write(to: file, options: .atomic)) != nil
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
        simulator.replaceSpec(next)
        spec = next
        persistEnvironment()
        restartServer()
    }

    /// Keeps a secret's real value for the server instead of its test value, or gives it the test value again (REQ-007).
    func setSecretKeptReal(_ name: String, _ kept: Bool) {
        var next = simulator.spec
        var names = Set(next.keptSecrets ?? [])
        guard kept != names.contains(name) else { return }
        if kept { names.insert(name) } else { names.remove(name) }
        next.keptSecrets = names.isEmpty ? nil : names.sorted()
        simulator.replaceSpec(next)
        spec = next
        persistEnvironment()
        restartServer()
    }

    private var serverLogRefreshPending = false

    /// The visible tail of the server's output (BUG-082). Redacting it runs every credential pattern over 12,000
    /// characters, so it is done at most once per `serverLogInterval`, however fast the server prints, and off the main
    /// actor; output that arrives meanwhile is picked up by that refresh.
    private func refreshServerLog() {
        guard !serverLogRefreshPending else { return }
        serverLogRefreshPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.serverLogInterval)
            guard let self else { return }
            self.serverLogRefreshPending = false
            guard let server = self.server else { return }
            let tail = String(server.output.suffix(12_000)), redactor = self.redactor
            let text = await Task.detached(priority: .utility) { redactor.redact(text: tail) }.value
            // A server stopped or replaced meanwhile keeps its log out of the current one.
            guard !self.closed, self.server === server else { return }
            self.serverLog = text
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
        pickTask?.cancel()
        workTask?.cancel()
        startTask?.cancel()
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
        channels.closeAll()
        if let folder = clockFile?.deletingLastPathComponent() {
            await Task.detached { try? FileManager.default.removeItem(at: folder) }.value
        }
        set(.stopped, ownsServer ? "The development server MarkView started was stopped." : "Closed. The development server was already running and was left running.")
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
    private func installRuntime() -> Bool {
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
        webView.load(page)
        // The first load after MarkView started the server includes the framework's first compile (BUG-076).
        let timeout: TimeInterval = firstLoadAfterStart ? 180 : 45
        firstLoadAfterStart = false
        return await waitForLoad(timeout: timeout)
    }

    private func waitForLoad(timeout: TimeInterval) async -> Bool {
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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

    @discardableResult
    func call(_ script: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
    }

    /// Back to the scenario's baseline (SIM-04, AC-04): a new generation (late answers of the old one are dropped), empty
    /// browser storage with only the kept cookies set again (REQ-008; the runtime writes the kept localStorage), a fresh
    /// page and the scenario's restoration steps. Returns why the restore is incomplete, if it is.
    @discardableResult
    func restore(keepingSignIn: Bool = false) async -> String? {
        guard !closed, appURL != nil else { return "The application is not running." }
        mode = mode == .record ? .interact : mode
        pickTask?.cancel()
        simulator.reset()
        servedAnswers = []
        // A preparation in flight is not cancelled: its rules belong to the environment, not to the scenario, and the minute the
        // assistant has spent on them is not thrown away by switching scenarios (BUG-089).
        selection = nil
        clockAnchor = Date()
        gateway?.releaseHeld()
        // The page's connections end with its page; the server's are closed so that they connect again to the baseline.
        channels.closeAll(source: "page")
        channels.closeAll(source: "server", code: 1012, reason: "The simulated service was reset.")
        if ownsServer, serverFollowsClock {
            await writeClockFile()
            // The preload rereads the clock file within 250 ms; the page's first server render must see the new clock.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let signedIn = keepingSignIn ? await signInCookiesToCarry() : []
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await restoreKeptCookies()
        for cookie in signedIn { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
        restoredUser = scenario.role.user
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
        let problem = await replay(scenario.steps)
        if let problem { notice = problem }
        await refreshPageState()
        restoringPage = false
        updateReadiness()
        if mode == .select { startPicking() }
        return problem
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
        sessionLog.add(.navigation, problem: signIn, "Server redirect \(from?.absoluteString ?? "?") → \(to?.absoluteString ?? "?")"
                       + (signIn ? " (a sign-in page)" : ""))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageCommits += 1
        channels.closeAll(source: "page")
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
            handle(request, reply: reply)
        case .success(.channel(let message)):
            handleChannel(message, reply: reply)
        }
    }

    /// A request of the page. One that goes to a gateway port (a public variable inlined in the page's code) is the
    /// service's request and keeps the service's address (REQ-007).
    private func handle(_ request: StudioBridge.Request, reply: @escaping (Any?, String?) -> Void) {
        let http = StudioHTTPRequest(method: request.method, url: logicalURL(for: request.url) ?? request.url, headers: request.headers,
                                     body: request.body, requestId: request.requestId)
        route(http, source: .page) { answer in
            switch answer {
            case .respond(let response): reply(StudioBridge.reply(response), nil)
            case .pass(let headers): reply(headers.isEmpty ? StudioBridge.passThrough : StudioBridge.passThrough(adding: headers), nil)
            case .dropped(let reason): reply(nil, reason)
            }
        }
    }

    /// A request the development server made through a simulated connection (REQ-007): answered by the same simulation as
    /// the page's requests, under the service's own address.
    private func handleServerRequest(_ request: StudioGatewayRequest, reply: @escaping @Sendable (StudioGatewayResponse) -> Void) {
        func plain(_ status: Int, _ text: String) -> StudioGatewayResponse {
            StudioGatewayResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
        guard !closed, let connection = serverConnections.first(where: { $0.variable == request.variable && $0.mode == .simulated }),
              let url = URL(string: connection.origin + request.target) else {
            return reply(plain(503, "MarkView UI Studio has no simulated connection for this address."))
        }
        let http = StudioHTTPRequest(method: request.method, url: url, headers: request.headers,
                                     body: request.body.map { String(decoding: $0, as: UTF8.self) }, requestId: UUID().uuidString)
        route(http, source: .server(variable: request.variable)) { answer in
            switch answer {
            case .respond(let response):
                reply(StudioGatewayResponse(status: response.status, headers: response.headers, body: response.body.map { Data($0.utf8) },
                                            delayMs: response.delayMs, hang: response.hang))
            case .pass:
                reply(plain(502, "MarkView UI Studio answers simulated connections only; switch \(request.variable) to Real to reach the service."))
            case .dropped(let reason):
                reply(plain(503, "The simulated answer was dropped (\(reason))."))
            }
        }
    }

    /// The service address behind a gateway port.
    private func logicalURL(for url: URL) -> URL? {
        guard let host = url.host, ["127.0.0.1", "localhost"].contains(host), let port = url.port,
              let variable = gatewayPorts.first(where: { Int($0.value) == port })?.key,
              let connection = serverConnections.first(where: { $0.variable == variable }),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return URL(string: connection.origin + target)
    }

    /// The simulation's answer to `http`; a write that changed the state is pushed to the channels and GraphQL
    /// subscriptions (REQ-015).
    private func simulate(_ http: StudioHTTPRequest) -> StudioSimOutcome {
        let before = http.isWrite ? simulator.state : nil
        let outcome = simulator.handle(http)
        if let before { channels.entitiesChanged(StudioEntityChange.diff(before: before, after: simulator.state, spec: simulator.spec)) }
        if case .respond(let response, let rule) = outcome {
            noteServed(rule)
            noteAnswer(response, rule: rule)
        }
        return outcome
    }

    /// The latest answers the simulation gave the page since it was loaded, the most recent first, for Fix data (REQ-017):
    /// the rule, the entities it reads and the body as sent, redacted and cut.
    private(set) var servedAnswers: [StudioDataFix.Served] = []

    private func noteAnswer(_ response: StudioSimResponse, rule id: String) {
        guard let rule = simulator.spec.rules.first(where: { $0.id == id }) else { return }
        // Cut first, so a large list costs nothing; redact a longer piece than is kept, so a secret cut at the edge is gone.
        let piece = String((response.body ?? "").prefix(StudioDataFix.answerChars * 3))
        let body = String(StudioLogFormat.redact(piece, redactor: redactor, hashes: secretHashes).prefix(StudioDataFix.answerChars))
        let entities = [rule.entity].compactMap { $0 } + (rule.include ?? []).map(\.entity)
        servedAnswers.insert(StudioDataFix.Served(ruleId: rule.id, method: rule.method.uppercased(), path: rule.path,
                                                  operation: rule.operation.rawValue, entities: entities, status: response.status,
                                                  body: body), at: 0)
        if servedAnswers.count > StudioDataFix.servedKept { servedAnswers.removeLast() }
    }

    /// The rules that answered the page, the most recent first (BUG-084): a context change sees them, and the shape of
    /// their fixed answers, before the environment's other rules.
    private(set) var servedRules: [String] = []

    private func noteServed(_ rule: String) {
        guard servedRules.first != rule else { return }
        servedRules.removeAll { $0 == rule }
        servedRules.insert(rule, at: 0)
        if servedRules.count > Self.servedRulesKept { servedRules.removeLast() }
    }

    static let servedRulesKept = 100

    // MARK: - Fix data (REQ-017)

    /// The page's errors Fix data may be offered for: one per message, the latest first, only those of the page as it is now.
    /// A Reset or a fix starts a new page, so an error is offered again only when it comes back after the fix.
    var fixableErrors: [StudioDataFix.PageError] {
        StudioDataFix.fixable(events.map { StudioDataFix.Seen(kind: $0.kind, detail: $0.detail, generation: $0.generation, date: $0.date) },
                              generation: simulator.generation)
    }

    /// Repairs the simulated data a page error came from (REQ-017), only when the person asks. The assistant reads the error,
    /// what the page was answered with, the records and the code (read-only) and either corrects existing records or says
    /// that data did not cause the error. MarkView checks every correction on a copy; nothing is saved unless all of them pass.
    func fixData(_ key: String? = nil) {
        guard let error = fixableErrors.first(where: { key == nil || $0.key == key }) else {
            notice = "The page reports no error that data could have caused."
            return
        }
        runWork("Fixing data") { session in await session.performDataFix(error) }
    }

    private func performDataFix(_ error: StudioDataFix.PageError) async {
        let generation = simulator.generation, scenarioID = scenario.id
        var retryProblems: [String] = []
        sessionLog.add(.notice, "Fix data: asking the assistant about \"\(String(error.key.prefix(160)))\"")
        for attempt in 1...2 {
            busyDetail = attempt == 1 ? "The assistant is reading the error and the code" : "The assistant is correcting its answer"
            var call = CLICompletion.Request(project: root,
                                             prompt: StudioDataFix.prompt(error: error, route: route, served: servedAnswers, spec: spec,
                                                                          records: scenario.data ?? spec.seed, scenario: scenario,
                                                                          redactor: redactor, hashes: secretHashes, retryProblems: retryProblems),
                                             systemPrompt: StudioDataFix.system, jsonSchema: StudioDataFix.schema, readableFolder: root)
            call.timeout = StudioDataFix.timeout
            call.effort = "medium"
            call.label = "ui-studio:fix-data"
            let plan: StudioDataFix.Plan
            do {
                let result = try await CLICompletion.run(call, onActivity: { [weak self] activity in
                    Task { @MainActor in self?.progress(activity) }
                })
                recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
                guard let parsed = StudioDataFix.plan(from: result.structured) else {
                    notice = "Fix data: the assistant's answer was not a set of corrections. Nothing was changed."
                    return
                }
                plan = parsed
            } catch is CancellationError {
                return
            } catch {
                notice = "Fix data failed: \(error.localizedDescription) Nothing was changed."
                return
            }
            // The page the assistant looked at is gone (a Reset, another scenario): its corrections would be for other data.
            guard !closed, simulator.generation == generation, scenario.id == scenarioID else {
                notice = "Fix data was dropped: the scenario was reset while the assistant worked. Nothing was changed."
                return
            }
            if plan.kind == .notData {
                let where_ = plan.codePointer.isEmpty ? "" : " Look at \(plan.codePointer)."
                notice = "Fix data: data did not cause this error. \(plan.summary)\(where_) Nothing was changed."
                return
            }
            let outcome = StudioDataFix.apply(plan.changes, spec: spec, scenarioData: scenario.data, redactor: redactor)
            let problems = plan.unreadable + outcome.problems
            if problems.isEmpty, outcome.ok {
                await commitDataFix(outcome, error: error)
                return
            }
            if attempt == 1 {
                retryProblems = problems
                continue
            }
            for problem in problems.prefix(10) { sessionLog.add(.notice, problem: true, "Fix data refused a correction: " + problem) }
            notice = "Fix data: the assistant's corrections were refused (\(problems.first ?? "no correction")). Nothing was changed."
        }
    }

    /// Saves checked corrections and reloads the page on them: the scenario's own records first (a failure there changes
    /// nothing), then the environment's seed, then a restore, which is a new page generation.
    private func commitDataFix(_ outcome: StudioDataFix.Outcome, error: StudioDataFix.PageError) async {
        busyDetail = "Saving the corrected data"
        var changedScenario: StudioScenario?
        if outcome.applied.contains(where: \.inScenario), let data = outcome.scenarioData {
            var next = scenario
            next.data = data
            next.updated = Date()
            next.revision += 1
            if !next.id.hasPrefix("builtin-") {
                let root = root, saving = next
                do {
                    savedScenarios = try await Task.detached { () throws -> [StudioScenario] in
                        try StudioStore.saveScenario(saving, root: root)
                        return StudioStore.loadScenarios(root)
                    }.value
                } catch {
                    notice = "Fix data: the scenario could not be saved (\(error.localizedDescription)). Nothing was changed."
                    return
                }
            }
            changedScenario = next
        }
        var environment = simulator.spec
        // Only the entities that were corrected: the map's refill or a preparation may have changed others while the scenario was saved.
        let seeded = Set(outcome.applied.filter(\.inSeed).map(\.entity))
        if !seeded.isEmpty {
            for name in seeded { environment.seed[name] = outcome.seed[name] }
            environment.updated = Date()
        }
        simulator.replaceSpec(environment)
        spec = simulator.spec
        persistEnvironment()
        if let changedScenario {
            scenario = changedScenario
            simulator.activate(changedScenario)
        }
        notice = nil
        notice = StudioDataFix.summary(outcome.applied)
        for reason in StudioDataFix.reasons(outcome.applied) { sessionLog.add(.notice, reason) }
        busyDetail = "Reloading the page on the corrected data"
        let problem = await restore()
        if let problem { sessionLog.add(.notice, problem: true, "After Fix data the page was not restored completely: " + problem) }
        if fixableErrors.contains(where: { $0.key == error.key }) {
            sessionLog.add(.notice, problem: true, "The page still reports \"\(String(error.key.prefix(160)))\" on the corrected data. Fix data can run again.")
        }
    }

    // MARK: - Channels (REQ-015)

    private func makeChannelHub() -> StudioChannelHub {
        StudioChannelHub(environment: StudioChannelHub.Environment(
            spec: { [weak self] in self?.simulator.spec ?? StudioEnvironmentSpec() },
            state: { [weak self] in self?.simulator.state ?? [:] },
            appOrigin: { [weak self] in self?.appOrigin?.text },
            perform: { [weak self] operation, entity, id, fields in
                guard let self else { return .json(503, nil) }
                let before = self.simulator.state
                let response = self.simulator.perform(operation, entity: entity, id: id, fields: fields)
                self.pushChanges(since: before)
                return response
            },
            graphQL: { [weak self] url, payload in
                guard let self else { return .null }
                let http = StudioHTTPRequest(method: "POST", url: url, headers: ["content-type": "application/json"], body: payload.text,
                                             requestId: UUID().uuidString)
                let before = self.simulator.state
                let outcome = self.simulator.handle(http)
                self.pushChanges(since: before)
                func errors(_ message: String) -> StudioJSON { .object(["errors": .array([StudioGraphQLExecutor.error(message)])]) }
                switch outcome {
                case .respond(let response, _):
                    return response.body.flatMap { StudioJSON(text: $0) } ?? .null
                case .unknown(let contract):
                    // Prepared now, so the client's next try is answered.
                    self.prepare(http, contract: contract, source: .page) { _ in }
                    return errors("MarkView UI Studio is preparing a simulation rule for \(contract); try again in a moment.")
                case .unsupported(_, let reason):
                    return errors("MarkView UI Studio does not simulate \(reason).")
                }
            },
            redact: { [weak self] json in self?.redactor.redact(json) ?? json },
            log: { [weak self] text, problem in self?.sessionLog.add(.request, problem: problem, text) }
        ))
    }

    /// Writes made while a channel message is answered reach the subscribers after that answer.
    private func pushChanges(since before: [String: [StudioJSON]]) {
        let changes = StudioEntityChange.diff(before: before, after: simulator.state, spec: simulator.spec)
        guard !changes.isEmpty else { return }
        Task { [weak self] in self?.channels.entitiesChanged(changes) }
    }

    /// A page WebSocket or EventSource on a simulated channel. One to a gateway port (a public variable inlined in the
    /// page's code) keeps the service's address, like a request.
    private func handleChannel(_ message: StudioBridge.Channel, reply: @escaping (Any?, String?) -> Void) {
        let id = "page-" + message.id
        switch message.action {
        case .open:
            guard let asked = message.url else { return reply(nil, "No URL.") }
            let answer: (StudioChannelHub.Opening) -> Void = { opening in
                switch opening {
                case .accepted(let chosen, let frames):
                    reply(["ok": true, "protocol": chosen ?? "", "frames": frames.map(\.bridgeValue)], nil)
                case .refused(let reason), .unknown(let reason):
                    reply(["ok": false, "code": 1006, "reason": String(reason.prefix(120))], nil)
                }
            }
            if message.transport == .ipc {
                // A callback of the Electron preload bridge (REQ-016): it listens until a channel answers its address, and
                // is never prepared on its own; the bridge's methods are.
                let shown = redactor.redact(text: StudioConnections.redact(asked.absoluteString, hashes: secretHashes))
                return answer(channels.listen(id: id, url: asked, transport: .ipc, source: "page", shown: shown, sink: pageSink(message.id)))
            }
            let http = StudioChannelRoute.httpURL(asked)
            let transport: StudioChannelTransport = message.transport == .eventSource ? .eventSource : .webSocket
            openChannel(id: id, url: logicalURL(for: http) ?? http, protocols: message.protocols, transport: transport, source: .page,
                        sink: pageSink(message.id), done: answer)
        case .send:
            var frames: [StudioChannelFrame] = []
            if let text = message.text { frames = channels.receive(id: id, text: text) }
            else if let data = message.binary { frames = channels.receive(id: id, binary: data) }
            reply(["frames": frames.map(\.bridgeValue)], nil)
        case .close:
            channels.close(id: id, code: message.code)
            reply(["ok": true], nil)
        }
    }

    /// Tell the person about a page-initiated protocol that cannot be simulated without disturbing a pending turn.
    private func noteUnsupportedChannel(contract: String, reason: String) {
        let request = redactor.redact(text: "Unsupported connection: " + contract)
        let answer = redactor.redact(text: "MarkView UI Studio does not simulate \(contract): \(reason)")
        guard !conversation.contains(where: { $0.request == request && $0.answer == answer }) else { return }
        var operation = StudioOperation(id: newOperationID(), kind: .question, request: request, status: .answered)
        operation.answer = answer
        history.append(operation)
        conversationIds.insert(operation.id)
        persistHistory()
    }

    /// Frames for page connection `pageID`, delivered in order to the page of the current generation.
    private func pageSink(_ pageID: String) -> StudioChannelHub.Sink {
        { [weak self] frames in
            guard let self, !frames.isEmpty else { return }
            let generation = self.simulator.generation
            let values = frames.map(\.bridgeValue)
            let previous = self.channelDeliveries
            self.channelDeliveries = Task { [weak self] in
                await previous?.value
                guard let self, !self.closed, self.simulator.generation == generation else { return }
                _ = try? await self.call("return window.__markviewStudio ? window.__markviewStudio.deliver(id, frames) : false;",
                                         ["id": pageID, "frames": values])
            }
        }
    }

    /// Opens a channel connection; an address no channel answers yet is prepared first (the connection waits), like an
    /// unknown request. It never reaches a real service.
    private func openChannel(id: String, url: URL, protocols: [String], transport: StudioChannelTransport, source: StudioRequestSource,
                             sink: @escaping StudioChannelHub.Sink, done: @escaping (StudioChannelHub.Opening) -> Void) {
        let shown = redactor.redact(text: StudioConnections.redact(url.absoluteString, hashes: secretHashes))
        let opening = channels.open(id: id, url: url, protocols: protocols, transport: transport, source: source.transport, shown: shown, sink: sink)
        guard case .unknown(let contract) = opening else { return done(opening) }
        let kind = transport.label
        sessionLog.add(.request, "\(kind) \(shown) · \(source.transport) · preparing")
        var headers = transport == .eventSource ? ["accept": "text/event-stream"] : ["upgrade": "websocket"]
        if !protocols.isEmpty { headers["sec-websocket-protocol"] = protocols.joined(separator: ", ") }
        let context = StudioPreparationContext(contract: contract, method: "GET", url: shown, headers: headers, body: nil, attempt: 1, problems: [],
                                               serverVariable: source.variable, group: StudioBridge.Origin(url: url)?.text)
        let generation = simulator.generation
        let preparer = makePreparer()
        updateReadiness()
        Task { [weak self] in
            guard let self else { return done(.refused("The session is closed.")) }
            let outcome = await self.preparation.resolve(context, generation: generation, preparer: preparer,
                                                         currentGeneration: { [weak self] in self?.simulator.generation ?? -1 },
                                                         commit: { [weak self] proposal in self?.commit(proposal) ?? ["The session is closed."] })
            guard !self.closed else { return done(.refused("The session is closed.")) }
            var reason: String?
            switch outcome {
            case .registered:
                let again = self.channels.open(id: id, url: url, protocols: protocols, transport: transport, source: source.transport,
                                               shown: shown, sink: sink)
                if case .unknown = again { reason = "the rules registered for it do not answer this connection." } else { done(again) }
            case .unsupported(let why):
                self.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: why))
                self.noteUnsupportedChannel(contract: contract, reason: why)
                self.sessionLog.add(.request, problem: true, "\(kind) \(shown) · \(source.transport) · unsupported: \(why)")
                done(.refused("MarkView UI Studio does not simulate \(contract): \(why)"))
            case .stale:
                done(.refused("The simulation was reset."))
            default:
                reason = self.preparation.records[contract]?.message ?? "it could not be prepared."
            }
            if let reason {
                self.noteDependency(StudioDependency(id: contract, mode: .unresolved, note: reason))
                self.sessionLog.add(.request, problem: true, "\(kind) \(shown) · \(source.transport) · unresolved: \(reason)")
                done(.refused("MarkView UI Studio has no simulation rule for \(contract): \(reason)"))
            }
            self.updateReadiness()
        }
    }

    /// A WebSocket or event stream the development server opened to a simulated connection's gateway port.
    private func handleServerStream(_ event: StudioGatewayStreamEvent, on gateway: StudioGateway) {
        switch event {
        case .open(let stream, let kind, let request):
            guard !closed, let connection = serverConnections.first(where: { $0.variable == request.variable && $0.mode == .simulated }),
                  let url = URL(string: connection.origin + request.target) else {
                return gateway.refuseStream(stream, status: 503, "MarkView UI Studio has no simulated connection for this address.")
            }
            var protocols: [String] = []
            var transport = StudioChannelTransport.eventSource
            if case .webSocket(let asked) = kind {
                protocols = asked
                transport = .webSocket
            }
            openChannel(id: "server-\(stream)", url: url, protocols: protocols, transport: transport, source: .server(variable: request.variable),
                        sink: { [weak gateway] frames in frames.forEach { gateway?.sendStream(stream, $0) } }) { [weak gateway] opening in
                switch opening {
                case .accepted(let chosen, let frames):
                    gateway?.acceptStream(stream, protocol: chosen)
                    frames.forEach { gateway?.sendStream(stream, $0) }
                case .refused(let reason), .unknown(let reason):
                    gateway?.refuseStream(stream, status: 404, reason)
                }
            }
        case .text(let stream, let text):
            channels.receive(id: "server-\(stream)", text: text).forEach { gateway.sendStream(stream, $0) }
        case .binary(let stream, let data):
            channels.receive(id: "server-\(stream)", binary: data).forEach { gateway.sendStream(stream, $0) }
        case .closed(let stream, let code):
            channels.close(id: "server-\(stream)", code: code)
        }
    }

    /// The session's decision for any request, from the page or from the server: pass it to its address, answer it from
    /// the simulation, or prepare rules for it.
    private func route(_ http: StudioHTTPRequest, source: StudioRequestSource, reply: @escaping (StudioReply) -> Void) {
        let shown = redactor.redact(text: StudioConnections.redact(http.url.absoluteString, hashes: secretHashes))
        let contract = StudioRoute.contractKey(method: http.method, url: http.url, appOrigin: appOrigin?.text)
        let transport = source.transport
        let sameServer = source == .page && (StudioBridge.Origin(url: http.url).map { appOrigin?.sameServer($0) == true } ?? false)
        // The Electron preload bridge (REQ-016) is a logical address: always simulated, never passed through.
        let ipc = StudioIPC.isIPC(http.url)
        if sameServer && StudioConnectionPolicy.isFrameworkRequest(http.url, headers: http.headers) {
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil, transport: transport))
            return reply(.pass(adding: StudioConnectionPolicy.frameworkRequestHeaders))
        }
        // The server's connections are switched by the person (Simulated or Real), not by the page's allowed addresses.
        if (sameServer && ownsServer && target?.usesIsolatedBackend == true)
            || (sameServer && StudioConnectionPolicy.isDevelopmentResource(http.url, appFolder: appFolder))
            || (source == .page && !ipc && spec.allowedRequests.contains(where: { StudioRoute.allows($0, url: http.url, appOrigin: appOrigin?.text) })) {
            if !sameServer { noteDependency(StudioDependency(id: contract, mode: .allowed, note: "Allowed by the connection policy.")) }
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil, transport: transport))
            return reply(.pass(adding: [:]))
        }
        if !ipc, channels.poll(http, source: transport, shown: shown, reply: { reply(.respond($0)) }) { return }
        switch simulate(http) {
        case .respond(let response, _):
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status, transport: transport))
            reply(.respond(response))
        case .unsupported(let contract, let reason):
            noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason + " are not simulated."))
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "unsupported", status: 501, transport: transport))
            reply(.respond(.unsupported(contract, reason: reason)))
            updateReadiness()
        case .unknown(let contract):
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "preparing", status: nil, transport: transport))
            prepare(http, contract: contract, source: source, reply: reply)
        }
    }

    /// An unknown request (SIM-07): the assistant prepares rules for it within the session's limits; the request waits for
    /// them or ends in a controlled error. It never goes to a real service.
    private func prepare(_ http: StudioHTTPRequest, contract: String, source: StudioRequestSource, reply: @escaping (StudioReply) -> Void) {
        let generation = simulator.generation
        let hashes = secretHashes
        var body = http.body.map { redactor.redact(body: StudioConnections.redact($0, hashes: hashes)) }
        if let text = body, text.count > 4_000 { body = String(text.prefix(4_000)) }
        let headers = redactor.redact(headers: http.headers).mapValues { StudioConnections.redact($0, hashes: hashes) }
        let shown = redactor.redact(text: StudioConnections.redact(http.url.absoluteString, hashes: hashes))
        let group = StudioBridge.Origin(url: http.url)?.text
        let baseContext = StudioPreparationContext(contract: contract, method: http.method, url: shown, headers: headers, body: body,
                                                   attempt: 1, problems: [], serverVariable: source.variable, group: group)
        let preparer = makePreparer()
        let asked = Date()
        updateReadiness()
        Task { [weak self] in
            guard let self else { return reply(.dropped("closed")) }
            var context = baseContext
            // A page's request answers within `provisionalAfter` seconds, whatever the preparation needs (BUG-089); the rule that
            // arrives later loads the page again once. Requests of the development server keep waiting: it renders from them.
            let answer = StudioReplyOnce(reply)
            let provisionalTimer: Task<Void, Never>? = source.variable == nil ? Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.provisionalAfter * 1_000_000_000))
                guard !Task.isCancelled, let self, !self.closed, self.simulator.generation == generation, answer.reply(.respond(.preparing(contract))) else { return }
                self.provisional[generation, default: []].insert(contract)
                self.log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "preparing", status: 503, transport: source.transport))
                self.sessionLog.add(.notice, "\(contract) has no rule yet: the page got a 503 \"preparing\" after \(Int(Self.provisionalAfter)) s and is loaded again when the rule is ready")
            } : nil
            defer { provisionalTimer?.cancel() }
            if source.variable == nil, let hint = await self.handlerHint(for: http) {
                context.handlerFile = hint.file
                context.handlerText = hint.text
            }
            // A request whose endpoint a group of the application's map is preparing waits for that group (REQ-014).
            await self.mapping.waitForEndpoint(http.method, url: http.url)
            // A request to a service that is being prepared waits for it: that preparation often registers this rule too.
            if let group {
                await self.preparation.waitForGroup(group)
                guard !self.closed else { return answer(.dropped("closed")) }
                if self.simulator.generation == generation, case .respond(let response, _) = self.simulate(http) {
                    self.log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status,
                                           transport: source.transport))
                    answer(.respond(response))
                    self.noteLateRules(source: source, asked: asked)
                    return self.updateReadiness()
                }
            }
            // A rule belongs to the environment: it is registered even when the scenario changed while it was prepared (BUG-089).
            let outcome = await self.preparation.resolve(context, generation: generation, preparer: preparer,
                                                         currentGeneration: { generation },
                                                         commit: { [weak self] proposal in self?.commit(proposal) ?? ["The session is closed."] })
            guard !self.closed else { return answer(.dropped("closed")) }
            var registered = false
            switch outcome {
            case .registered:
                registered = true
                if answer.delivered {
                    // The page was answered "preparing": it is loaded again below and then served from this rule.
                } else if self.simulator.generation != generation {
                    answer(.dropped("stale"))
                } else if case .respond(let response, _) = self.simulate(http) {
                    self.log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status,
                                           transport: source.transport))
                    answer(.respond(response))
                } else {
                    answer(.respond(.unresolved(contract, reason: "the rules registered for it do not answer this request.")))
                }
                self.noteLateRules(source: source, asked: asked)
            case .unsupported(let reason):
                self.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason))
                answer(.respond(.unsupported(contract, reason: reason)))
            case .stale:
                answer(.dropped("stale"))
            default:
                let reason = self.preparation.records[contract]?.message ?? "it could not be prepared."
                self.noteDependency(StudioDependency(id: contract, mode: .unresolved, note: reason))
                answer(.respond(.unresolved(contract, reason: reason)))
            }
            if self.provisional[generation]?.contains(contract) == true {
                self.provisionalEnded(contract, generation: generation, registered: registered)
            }
            self.updateReadiness()
        }
    }

    /// A request that was answered "preparing" has its rule (or has none): once every such request of the generation has ended and
    /// one of them has a rule, the page is loaded again so that it renders with the real answers (BUG-089). Text typed into the
    /// page since its route is never thrown away: the banner offers the reload instead.
    private func provisionalEnded(_ contract: String, generation: Int, registered: Bool) {
        provisional[generation]?.remove(contract)
        if registered { provisionalReady.insert(generation) }
        guard provisional[generation]?.isEmpty ?? true, provisionalReady.contains(generation), simulator.generation == generation,
              !closed, appURL != nil else { return }
        provisionalReady.remove(generation)
        Task { [weak self] in
            guard let self else { return }
            let typed = (try? await self.call("return !!(window.__markviewStudio && window.__markviewStudio.typedSinceRoute && window.__markviewStudio.typedSinceRoute());")) as? Bool ?? false
            guard !self.closed, self.simulator.generation == generation else { return }
            if typed {
                self.sessionLog.add(.notice, "Rules arrived for requests the page was answered \"preparing\"; text was typed into the page, so it is not reloaded by itself (Reload in the banner)")
                self.rulesArrivedLate = true
            } else {
                self.sessionLog.add(.notice, "Rules arrived for requests the page was answered \"preparing\"; the page is loaded again once to render with them")
                self.reloadPage()
            }
        }
    }

    /// The route handlers of the application's own server, read from its folders once per session (BUG-089, BUG-090).
    private var routeIndex: [StudioRouteHandler]?

    func routeHandlers() async -> [StudioRouteHandler] {
        if let routeIndex { return routeIndex }
        let root = root, folder = appFolder
        let found = await Task.detached(priority: .utility) { StudioRouteScanner.scan(project: root, appFolder: folder) }.value
        routeIndex = found
        return found
    }

    /// The handler that serves a page request to the application's own origin, with the start of its text (redacted): the
    /// agent is told where to look instead of searching the project, which took it a minute or more (BUG-089).
    private func handlerHint(for http: StudioHTTPRequest) async -> (file: String, text: String)? {
        guard let app = appURL, let host = http.url.host, host == app.host, http.url.port == app.port else { return nil }
        let handlers = await routeHandlers()
        guard let handler = StudioRouteScanner.handler(for: http.method, path: http.url.path, in: handlers) else { return nil }
        let file = root.appendingPathComponent(handler.file)
        let text = await Task.detached(priority: .utility) { () -> String in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
            defer { try? handle.close() }
            return String(decoding: (try? handle.read(upToCount: 6_000)) ?? Data(), as: UTF8.self)
        }.value
        return (handler.file, redactor.redact(text: text))
    }

    /// The project's assistant, read-only, preparing rules against the environment as it is now.
    private func makePreparer() -> StudioCLIPreparer {
        let relative = appFolder.standardizedFileURL.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let usage = recordUsage
        return StudioCLIPreparer(project: root, appFolder: relative, spec: simulator.spec) { input, output, cost in
            Task { @MainActor in usage(input, output, cost) }
        }
    }

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
        let preparer = makePreparer()
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
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
    }

    /// How long a server request may wait for its rules before its page has most likely rendered without them: an
    /// application gives its own calls a deadline of a few seconds (vivaa: 5 s).
    static let lateRules: TimeInterval = 3
    /// How long a page's request waits for its rule to be prepared before it gets the "preparing" answer (BUG-089); a variable
    /// so that a test can shorten it.
    static var provisionalAfter: TimeInterval = 8
    /// Contracts a page's request was answered "preparing" for, by generation, and whether one of them has a rule by now.
    private var provisional: [Int: Set<String>] = [:]
    private var provisionalReady: Set<Int> = []

    /// A server request whose rules arrived after its page rendered without them (BUG-074): the page reloads once so it
    /// renders with the simulation, unless the person typed into it; then the banner offers Reload.
    private func noteLateRules(source: StudioRequestSource, asked: Date) {
        guard source.variable != nil, Date().timeIntervalSince(asked) > Self.lateRules, !closed, appURL != nil else { return }
        let generation = simulator.generation
        guard reloadedForRules != generation else { return }
        reloadedForRules = generation
        Task { [weak self] in
            guard let self else { return }
            let typed = (try? await self.call("return !!(window.__markviewStudio && window.__markviewStudio.typedSinceRoute && window.__markviewStudio.typedSinceRoute());")) as? Bool ?? false
            guard !self.closed, self.simulator.generation == generation else { return }
            let late = "Rules for a request of the server arrived after its page had rendered without them"
            if typed {
                self.sessionLog.add(.notice, late + "; text was typed into the page, so it is not reloaded by itself (Reload in the banner)")
                self.rulesArrivedLate = true
            } else {
                self.sessionLog.add(.notice, late + "; the page is loaded again once to render with them")
                self.reloadPage()
            }
        }
    }

    /// Loads the current address again, as a fresh server render, keeping the scenario's state (the banner's Reload).
    func reloadPage() {
        rulesArrivedLate = false
        guard let url = webView.url ?? appURL else { return }
        sessionLog.add(.navigation, "Loading \(url.absoluteString) again")
        var page = URLRequest(url: url)
        StudioConnectionPolicy.frameworkRequestHeaders.forEach { page.setValue($0.value, forHTTPHeaderField: $0.key) }
        webView.load(page)
    }

    /// Registers a proposal atomically and keeps it for later sessions (rules are reusable: SIM-05).
    private func commit(_ proposal: StudioProposal) -> [String] {
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
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
        rebuildDependencies()
        // A preload bridge callback that waited for its channel gets it now (REQ-016).
        channels.openListeners()
        return []
    }

    private func persistEnvironment() {
        let spec = simulator.spec, root = root
        io.async { try? StudioStore.saveEnvironment(spec, root: root) }
    }

    private func handle(_ event: StudioBridge.Event) {
        let detail = redactor.redact(text: event.detail)
        switch event.kind {
        case .route:
            if detail != route { sessionLog.add(.navigation, "Route \(route) → \(detail)") }
            route = detail
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
    }

    private func note(_ kind: StudioBridge.Event.Kind, _ detail: String) {
        events.append(EventRecord(kind: kind, detail: detail, generation: simulator.generation))
        if events.count > 300 { events.removeFirst(events.count - 300) }
    }

    private func log(_ record: RequestRecord) {
        requests.append(record)
        if requests.count > 400 { requests.removeFirst(requests.count - 400) }
        let answer = record.outcome + (record.status.map { " \($0)" } ?? "")
        sessionLog.add(.request, problem: record.outcome == "unsupported" || (record.status ?? 0) >= 500,
                       "\(record.method) \(record.url) · \(record.transport) · \(answer)")
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

    private func noteDependency(_ dependency: StudioDependency) {
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
        simulator.replaceSpec(next)
        spec = next
        persistEnvironment()
        rebuildDependencies()
        runWork("Applying the connection policy") { session in
            await session.installConnectionPolicy()
            _ = await session.restore()
        }
    }

    func disallow(_ pattern: String) {
        var next = simulator.spec
        next.allowedRequests.removeAll { $0 == pattern }
        simulator.replaceSpec(next)
        spec = next
        persistEnvironment()
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

    func activate(_ next: StudioScenario) {
        scenario = next
        simulator.activate(next)
        recordedSteps = []
        // Another scenario keeps the application signed in as the same test user (BUG-088); Reset starts signed out, as before.
        runWork("Resetting the scenario") { session in _ = await session.restore(keepingSignIn: true) }
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

    /// Keeps the page's cookies (httpOnly ones included) and localStorage for later restores (REQ-008): a restore empties
    /// the browser storage, so the application would ask again (cookie consent). Cookies of the application's host only;
    /// entries that look confidential are left out and named, because environment.json may be committed. Replaces what
    /// was kept before.
    func keepBrowserData() {
        runWork("Keeping the page's cookies and storage") { session in
            guard let host = session.appURL?.host else { return }
            let cookies = await session.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let page = (try? await session.call("return window.__markviewStudio ? window.__markviewStudio.storage() : null;")) as? [String: Any]
            else {
                session.notice = "The page did not report its storage; nothing was kept. Wait until it has loaded and try again."
                return
            }
            let storage = StudioKeptBrowserData.storageEntries(page["entries"])
            let outcome = StudioKeptBrowserData.collect(cookies: cookies.map(StudioKeptCookie.init), storage: storage, appHost: host,
                                                        origin: session.appOrigin?.text, redactor: session.redactor)
            session.keptSkipped = outcome.skipped
            session.replaceKept(outcome.kept.isEmpty ? nil : outcome.kept)
            let kept = outcome.kept
            session.notice = "Kept \(kept.cookies.count) cookie\(kept.cookies.count == 1 ? "" : "s") and \(kept.localStorage.count) "
                + "localStorage entr\(kept.localStorage.count == 1 ? "y" : "ies") in .markview/studio/environment.json; they are set again after every restore."
                + (outcome.skipped.isEmpty ? "" : " Not kept because they look confidential: \(outcome.skipped.count).")
        }
    }

    func forgetKeptCookie(_ id: String) {
        updateKept { $0.cookies.removeAll { $0.id == id } }
    }

    func forgetKeptStorage(_ key: String) {
        updateKept { $0.localStorage.removeAll { $0.key == key } }
    }

    /// Forgets every kept cookie and storage entry; the next restore starts from empty browser storage again.
    func forgetKeptBrowserData() {
        keptSkipped = []
        replaceKept(nil)
    }

    private func updateKept(_ change: (inout StudioKeptBrowserData) -> Void) {
        guard var kept = spec.keptBrowserData else { return }
        change(&kept)
        replaceKept(kept.isEmpty ? nil : kept)
    }

    private func replaceKept(_ kept: StudioKeptBrowserData?) {
        var next = simulator.spec
        next.keptBrowserData = kept
        simulator.replaceSpec(next)
        spec = next
        persistEnvironment()
    }

    /// The kept cookies go back into the emptied store before the page loads (REQ-008).
    /// The test user the browser data was last restored for: its sign-in cookies are carried over to the next restore only for the
    /// same user, so a scenario of another role starts signed out.
    private var restoredUser: StudioJSON?

    /// The cookies that keep the application signed in, when the page is signed in as the test user the new scenario also has
    /// (BUG-088). A page on its sign-in page has nothing to carry. They live in memory for the restore only, never on disk.
    private func signInCookiesToCarry() async -> [HTTPCookie] {
        guard restoredUser == scenario.role.user, let host = appURL?.host,
              let path = webView.url?.path, !StudioLogFormat.isSignInPath(path) else { return [] }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return (host == domain || host.hasSuffix("." + domain)) && StudioSignInCookies.isSignIn(name: cookie.name)
        }
    }

    private func restoreKeptCookies() async {
        guard let cookies = spec.keptBrowserData?.cookies, !cookies.isEmpty, let host = appURL?.host else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let now = Date()
        for cookie in cookies {
            guard let http = cookie.httpCookie(appHost: host, now: now) else { continue }
            await store.setCookie(http)
        }
    }

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
            scenario = saved
            simulator.activate(saved)
            recordedSteps = []
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

    func setMode(_ next: Mode) {
        guard next != mode else { return }
        if next == .record, let busy {
            // Recording starts from a restored baseline, which waits for the current work.
            notice = "Wait for \(busy) to finish before recording."
            return
        }
        let previous = mode
        mode = next
        if previous == .record { Task { _ = try? await call("return window.__markviewStudio.setRecording(false);") } }
        switch next {
        case .interact:
            pickTask?.cancel()
            Task { _ = try? await call("return window.__markviewStudio && window.__markviewStudio.setSelecting(false);") }
        case .select:
            startPicking()
        case .record:
            pickTask?.cancel()
            // Steps are recorded from the scenario's baseline, so that replaying them rebuilds the same state.
            recordedSteps = []
            runWork("Restoring the scenario before recording") { session in
                _ = await session.restore()
                session.mode = .record
                _ = try? await session.call("return window.__markviewStudio.setRecording(true);")
            }
        }
    }

    private func startPicking() {
        pickTask?.cancel()
        pickTask = Task { [weak self] in
            while let self, self.mode == .select, !Task.isCancelled {
                do {
                    let result = try await self.call("return window.__markviewStudio ? await window.__markviewStudio.pick() : undefined;")
                    guard self.mode == .select, !Task.isCancelled else { return }
                    if let object = result as? [String: Any] {
                        await self.adopt(object)
                    } else if result is NSNull {
                        // Escape in the page.
                        self.mode = .interact
                        return
                    } else {
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                } catch {
                    // The page reloaded while selecting: pick again in the new page.
                    try? await Task.sleep(nanoseconds: 400_000_000)
                }
            }
        }
    }

    func selectParent() {
        Task {
            guard let object = try? await call("return window.__markviewStudio.parent();") as? [String: Any] else { return }
            await adopt(object)
        }
    }

    func selectChild() {
        Task {
            guard let object = try? await call("return window.__markviewStudio.child();") as? [String: Any] else { return }
            await adopt(object)
        }
    }

    func clearSelection() {
        selection = nil
        Task { _ = try? await call("return window.__markviewStudio.clear();") }
    }

    /// The selection as the session keeps it (PRE-06…PRE-08): the source path checked against the project, the source
    /// around the mapped line, a picture of the element, the route, the scenario and the code revision.
    private func adopt(_ object: [String: Any]) async {
        guard var context = StudioSelectionContext(object) else {
            notice = "That element has no size to select."
            return
        }
        let root = root, appFolder = appFolder, origin = appOrigin
        let tagName = String(context.tag.prefix { $0.isLetter || $0.isNumber || $0 == "-" })
        let reported = context
        let resolved = await Task.detached { () -> StudioSourceResolution in
            // A bundled chunk (Turbopack, Next.js 16) is mapped to its source file through its source map (BUG-069).
            let mapped = await StudioSourceMap.mapped(reported, appOrigin: origin, root: root, appFolder: appFolder)
            return StudioSourceResolution.resolve(mapped, root: root, appFolder: appFolder, tagName: tagName)
        }.value
        context.sourcePath = resolved.path
        context.line = resolved.line
        context.snippet = resolved.snippet
        context.snippetHash = resolved.lineHash
        if resolved.mapping != context.mapping { context.mapping = resolved.mapping }
        if let note = resolved.note { context.boundary = [context.boundary, note].compactMap { $0 }.joined(separator: " ") }
        context.scenarioId = scenario.id
        context.imagePath = await selectionPicture(context)
        context.revision = await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers()).0
        selection = context
    }

    private func selectionPicture(_ context: StudioSelectionContext) async -> String? {
        _ = try? await call("return window.__markviewStudio.prepareCapture();")
        let rect = CGRect(x: context.rect.x, y: context.rect.y, width: context.rect.width, height: context.rect.height)
            .intersection(webView.bounds)
        defer { Task { _ = try? await self.call("return window.__markviewStudio.finishCapture();") } }
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let image = await snapshot(rect) else { return nil }
        let folder = StudioStore.selectionFolder(root)
        StudioStore.prepareLocalFolder(root)
        let file = folder.appendingPathComponent("selection-\(context.id).png")
        let written = await Task.detached { StudioImageDiff.writePNG(image, to: file) }.value
        return written ? file.path : nil
    }

    private func snapshot(_ rect: CGRect?) async -> CGImage? {
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        configuration.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// The selection is found again after the page was reloaded (PRE-09, BUG-068): the same instance is kept, a moved source
    /// is remapped, an element that is not the same one is never taken in its place. The old selector is tried first; when
    /// it no longer leads to the element (the page is laid out differently), the page is searched for the element itself.
    /// `afterEdit` is the check after a change, which may have altered the element's classes and text.
    @discardableResult
    private func revalidateSelection(_ previous: StudioSelectionContext, afterEdit: Bool) async -> Bool {
        func candidates(_ script: String, _ arguments: [String: Any]) async -> [StudioSelectionContext] {
            ((try? await call(script, arguments)) as? [[String: Any]] ?? []).compactMap { StudioSelectionContext($0) }
        }
        func position(of chosen: StudioSelectionContext, in list: [StudioSelectionContext]) -> Int {
            list.firstIndex { $0.rect == chosen.rect && $0.tag == chosen.tag && $0.sourceNodeId == chosen.sourceNodeId } ?? 0
        }
        let bySelector = await candidates("return window.__markviewStudio.candidates(selector);", ["selector": previous.selector])
        var decision = StudioSelectionRevalidation.decide(previous: previous, candidates: bySelector, afterEdit: afterEdit)
        var select: (script: String, arguments: [String: Any])?
        switch decision {
        case .kept(let next), .remapped(let next):
            select = ("return window.__markviewStudio.selectMatching(selector, index);",
                      ["selector": previous.selector, "index": position(of: next, in: bySelector)])
        case .cleared:
            let similar = await candidates("return window.__markviewStudio.similar(fingerprint);", ["fingerprint": previous.fingerprint])
            decision = StudioSelectionRevalidation.decide(previous: previous, candidates: similar, afterEdit: afterEdit)
            switch decision {
            case .kept(let next), .remapped(let next):
                select = ("return window.__markviewStudio.selectSimilar(fingerprint, index);",
                          ["fingerprint": previous.fingerprint, "index": position(of: next, in: similar)])
            case .cleared: break
            }
        }
        if case .cleared(let reason) = decision {
            selection = nil
            notice = reason + (afterEdit ? "" : " The change uses the element as it was selected; select it again to see it.")
            return false
        }
        guard let select, let object = try? await call(select.script, select.arguments) as? [String: Any] else {
            selection = nil
            return false
        }
        await adopt(object)
        selection?.revalidated = true
        return true
    }

    // MARK: - Assistant

    /// Runs one piece of work at a time. `pending` is the conversation turn it answers, shown until the work appends it
    /// to the history; whatever way the work ends (answered, failed, cancelled), no pending turn outlives it.
    func runWork(_ title: String, pending: PendingTurn? = nil, _ work: @escaping @MainActor (StudioSession) async -> Void) {
        guard busy == nil, !closed else {
            notice = "Wait for \(busy ?? "the current work") to finish."
            return
        }
        busy = title
        busyDetail = ""
        pendingTurn = pending
        workTask = Task { [weak self] in
            guard let self else { return }
            await work(self)
            self.busy = nil
            self.busyDetail = ""
            self.pendingTurn = nil
        }
    }

    /// The element as a turn records it: its tag and, when known, its source file.
    private static func turnElement(_ selection: StudioSelectionContext) -> String {
        selection.tag + (selection.sourcePath.map { " · \($0)" } ?? "")
    }

    func cancelWork() {
        workTask?.cancel()
        preparation.cancelEverything()
    }

    private func progress(_ activity: CLICompletion.Activity) {
        switch activity {
        case .read(let path): busyDetail = "Reading " + (path as NSString).lastPathComponent
        case .search(let pattern): busyDetail = "Searching for " + String(pattern.prefix(40))
        case .run: busyDetail = "Looking at the project"
        case .thinking: busyDetail = "Thinking"
        case .writing(let count): busyDetail = "Writing (\(count) characters)"
        case .webSearch, .webFetch, .answerDelta: break
        }
    }

    private func newOperationID() -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "op-\(stamp)-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// One request of the request box (DEC-010; EDIT-01…EDIT-08, AC-11…AC-15, REQ-013). The assistant chooses its kind: an
    /// answer changes nothing; a context change is checked (and corrected once) and becomes a new saved scenario derived
    /// from the current one; a code change names the scope and proposes exact edits, which MarkView checks against the
    /// working tree as it was when the request started, writes after restoring and capturing the scenario, and verifies in
    /// the rebuilt application. A selection is optional: without one, the request is about the current page. The images
    /// attached to the request (REQ-005) are saved under `.dde/studio/attachments/`, recorded on the turn, given to the
    /// assistant with the request, and named in its prompt; a request of images alone is allowed. Answering a clarification
    /// sends the images of the turn again.
    func change(_ text: String, attachments: [ImageAttachment] = [], clarification: String? = nil, replacing pending: StudioOperation? = nil) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = typed.isEmpty && !attachments.isEmpty ? StudioPrompts.imageOnlyRequest : typed
        guard !request.isEmpty, appURL != nil else { return }
        var selection = self.selection
        let pageRoute = route
        let element = selection.map(Self.turnElement) ?? StudioPrompts.pageElement(pageRoute)
        // An answer to the assistant's question is what the person just said; the question itself stays in the thread.
        let turn = PendingTurn(kind: .edit, request: clarification ?? request, element: element, attachments: pending?.attachedImages ?? [])
        let newImages = attachments.map(\.data)
        runWork("Working on the request", pending: turn) { session in
            let (revision, snapshot) = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers())
            var operation = pending ?? StudioOperation(id: session.newOperationID(), kind: .edit, request: request, status: .applied)
            operation.status = .applied
            operation.question = nil
            operation.options = []
            operation.selection = element
            operation.scenarioId = session.scenario.id
            operation.baseRevision = revision
            // The images of the request: those of the turn being answered, then the ones just attached, saved now.
            var attached = operation.attachedImages
            if !newImages.isEmpty {
                do {
                    attached += try await StudioSession.saveAttachments(newImages, root: session.root)
                } catch {
                    operation.status = .failed
                    operation.answer = "The attached images could not be saved, so the request was not sent: \(error.localizedDescription)"
                    return session.append(operation)
                }
                operation.attachments = attached
                session.pendingTurn?.attachments = attached
            }
            // Only files that are there are sent: an image of an earlier turn may have been deleted since.
            let sentImages = attached.filter { StudioStore.isAttachmentPath($0) && FileManager.default.fileExists(atPath: session.root.appendingPathComponent($0).path) }
            // Without a selection the assistant sees the page as it is.
            let pageImage = selection == nil ? await session.pagePicture() : nil
            var retryProblem: String?
            var refusedContext: [String]?
            var restored = false
            for attempt in 1...2 {
                session.busyDetail = attempt == 1 ? "The assistant is reading the project"
                    : refusedContext != nil ? "The assistant is correcting its context change" : "The assistant is correcting its edits"
                // The history includes a clarification being answered: its turn says what the assistant asked.
                var call = CLICompletion.Request(project: session.root,
                                                 prompt: StudioPrompts.editPrompt(request, selection: selection, scenario: session.scenario,
                                                                                  revision: revision, history: session.conversation,
                                                                                  redactor: session.redactor, clarification: clarification,
                                                                                  retryProblem: retryProblem, route: pageRoute,
                                                                                  pageImage: pageImage, spec: session.spec,
                                                                                  refusedContext: refusedContext,
                                                                                  reached: session.servedRules, attachments: sentImages),
                                                 systemPrompt: StudioPrompts.editSystem, jsonSchema: StudioPrompts.editSchema,
                                                 readableFolder: session.root)
                call.images = (selection?.imagePath ?? pageImage).map { [URL(fileURLWithPath: $0)] } ?? []
                call.images += sentImages.map { session.root.appendingPathComponent($0) }
                call.timeout = 900
                call.effort = "medium"
                call.label = "ui-studio:edit"
                let plan: StudioEditPlan
                do {
                    let result = try await CLICompletion.run(call, onActivity: { activity in
                        Task { @MainActor in session.progress(activity) }
                    })
                    session.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
                    guard let parsed = StudioPrompts.editPlan(from: result.structured) else {
                        operation.status = .failed
                        operation.answer = "The assistant's answer was not a set of edits."
                        return session.append(operation)
                    }
                    plan = parsed
                } catch is CancellationError {
                    return
                } catch {
                    operation.status = .failed
                    operation.answer = error.localizedDescription
                    return session.append(operation)
                }
                switch plan.kind {
                case .answer:
                    operation.kind = .question
                    operation.status = .answered
                    operation.answer = plan.answer.isEmpty ? plan.summary : plan.answer
                    let after = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
                    operation.finalRevision = after
                    operation.checks = [StudioCheck(name: "Project files unchanged", passed: after.id == revision.id,
                                                    detail: after.id == revision.id ? "" : "The working tree changed while the request ran; the assistant itself had read-only access.")]
                    return session.append(operation)
                case .context:
                    let context = plan.context ?? StudioContextPlan(structured: nil)
                    var problems = StudioContextValidator.problems(context, current: session.scenario, spec: session.spec)
                    // Giving up on data the application can change is asked about once, and never blocks a second answer.
                    if attempt == 1 {
                        problems += StudioContextValidator.givenUpProblems(context, current: session.scenario, spec: session.spec)
                    }
                    if problems.isEmpty {
                        return await session.applyContext(context, operation: operation, summary: plan.summary, snapshot: snapshot,
                                                          selection: selection)
                    }
                    if attempt == 1 {
                        refusedContext = problems
                        retryProblem = nil
                        continue
                    }
                    operation.kind = .context
                    operation.status = .failed
                    operation.summary = plan.summary
                    operation.answer = "The context change was refused, so the scenario did not change: "
                        + problems.prefix(5).joined(separator: " ") + (problems.count > 5 ? " (and \(problems.count - 5) more)" : "")
                    operation.context = StudioContextChange(previousScenarioId: session.scenario.id, previousScenarioName: session.scenario.name,
                                                            unsupported: context.unsupported)
                    return session.append(operation)
                case .code:
                    break
                }
                operation.scope = plan.scope
                operation.scopeNote = plan.scopeNote
                operation.summary = plan.summary
                operation.changeKind = plan.changeKind
                operation.changeReason = plan.changeReason.isEmpty ? nil : plan.changeReason
                if plan.needsClarification && clarification == nil {
                    operation.status = .clarification
                    operation.question = plan.question
                    operation.options = plan.options
                    return session.append(operation)
                }
                if plan.edits.isEmpty {
                    operation.status = .answered
                    operation.answer = plan.scope == .recordData
                        ? "The text comes from the simulated data of one record, not from the source code. " + plan.summary
                        : (plan.summary.isEmpty ? "The assistant proposed no change." : plan.summary)
                    return session.append(operation)
                }
                if !restored {
                    // The scenario's baseline and its picture before anything is written.
                    restored = true
                    session.busyDetail = "Restoring the scenario"
                    _ = await session.restore()
                    if let previous = selection, session.selection == nil {
                        await session.revalidateSelection(previous, afterEdit: false)
                        if let current = session.selection { selection = current }
                    }
                    operation.beforeCapture = await session.capture(label: "Before: " + String(request.prefix(60)))?.id
                }
                do {
                    let unsaved = Set(session.editorBuffers().keys)
                    let changes = try await StudioChanges.plan(plan.edits, snapshot: snapshot, unsavedNow: unsaved)
                    let root = session.root
                    try await Task.detached { try StudioChanges.write(changes, root: root) }.value
                    operation.files = changes
                    retryProblem = nil
                    break
                } catch StudioChangeError.conflict(let paths) {
                    operation.status = .conflict
                    operation.conflict = StudioChangeError.conflict(paths).localizedDescription
                    return session.append(operation)
                } catch let error as StudioChangeError where attempt == 1 {
                    retryProblem = error.localizedDescription
                    refusedContext = nil
                } catch {
                    operation.status = .failed
                    operation.answer = error.localizedDescription
                    return session.append(operation)
                }
            }
            guard !operation.files.isEmpty else {
                operation.status = .failed
                operation.answer = retryProblem ?? "No edit could be applied."
                return session.append(operation)
            }
            operation.patch = await StudioChanges.unifiedDiff(operation.files)
            session.append(operation)
            await session.verify(&operation, previous: selection, label: "After: " + String(request.prefix(60)))
            await session.trackChange(&operation)
            session.replace(operation)
        }
    }

    /// Answers the assistant's question and runs the change with it. The images of the request are sent again, with any the
    /// person added to the answer.
    func answerClarification(_ operation: StudioOperation, choice: String, attachments: [ImageAttachment] = []) {
        // The question being answered belongs to the conversation.
        conversationIds.insert(operation.id)
        let answer = choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !attachments.isEmpty ? StudioPrompts.imageOnlyAnswer : choice
        change(operation.request, attachments: attachments, clarification: answer, replacing: operation)
    }

    /// Saves the PNG images of a request under `.dde/studio/attachments/` (ignored by Git) and returns their project-relative
    /// paths, in order. When one cannot be written, the ones written before it are removed again.
    private static func saveAttachments(_ pngs: [Data], root: URL) async throws -> [String] {
        try await Task.detached {
            StudioStore.prepareLocalFolder(root)
            var written: [URL] = []
            do {
                for png in pngs { written.append(try ImageAttachments.save(png, into: StudioStore.attachmentsFolder(root))) }
            } catch {
                for url in written { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return written.map { StudioStore.attachmentsPath + "/" + $0.lastPathComponent }
        }.value
    }

    /// A picture of the page as it is, for a request made without a selection (DEC-010). It is overwritten by the next one.
    private func pagePicture() async -> String? {
        _ = try? await call("return window.__markviewStudio.prepareCapture();")
        let image = await snapshot(nil)
        _ = try? await call("return window.__markviewStudio.finishCapture();")
        guard let image else { return nil }
        let root = root, file = StudioStore.selectionFolder(root).appendingPathComponent("page.png")
        let written = await Task.detached { () -> Bool in
            StudioStore.prepareLocalFolder(root)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            return StudioImageDiff.writePNG(image, to: file)
        }.value
        return written ? file.path : nil
    }

    /// Applies a checked context change (REQ-013, DEC-009): the new scenario derived from the current one is saved, made the
    /// active one and restored, and the turn records what changed and what could not be done. No source file is written;
    /// Undo returns to the scenario it was made from.
    private func applyContext(_ plan: StudioContextPlan, operation start: StudioOperation, summary: String,
                              snapshot: StudioWorkingSnapshot, selection: StudioSelectionContext?) async {
        var operation = start
        operation.kind = .context
        operation.summary = summary.isEmpty ? plan.description : summary
        let current = scenario
        let next = StudioContextValidator.scenario(plan, from: current, spec: spec, request: operation.request,
                                                   taken: savedScenarios + presets)
        var change = StudioContextValidator.change(from: current, to: next, spec: spec,
                                                   unsupported: plan.unsupported + StudioContextValidator.notes(plan, spec: spec))
        guard change.changesAnything else {
            // Nothing to show differently: no scenario is made.
            change.previous = nil
            change.scenarioId = ""
            change.scenarioName = ""
            operation.context = change
            operation.status = .answered
            if operation.summary.isEmpty { operation.answer = "Nothing in the scenario needed to change." }
            return append(operation)
        }
        busyDetail = "Saving the new scenario"
        let root = root
        do {
            savedScenarios = try await Task.detached { () throws -> [StudioScenario] in
                try StudioStore.saveScenario(next, root: root)
                return StudioStore.loadScenarios(root)
            }.value
        } catch {
            operation.status = .failed
            operation.answer = "The new scenario could not be saved, so the scenario did not change: \(error.localizedDescription)"
            change.scenarioId = ""
            change.previous = nil
            operation.context = change
            return append(operation)
        }
        operation.beforeCapture = await capture(label: "Before: " + String(operation.request.prefix(60)))?.id
        operation.context = change
        operation.scenarioId = next.id
        operation.status = .applied
        scenario = next
        simulator.activate(next)
        recordedSteps = []
        append(operation)
        busyDetail = "Restoring the new scenario"
        let problem = await restore()
        let errors = events.filter { $0.kind == .runtimeError && $0.generation == simulator.generation }
        let (revision, after) = await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers())
        let pageLoaded = problem == nil || problem?.hasPrefix("Restoration step") == true
        var checks = [StudioCheck(name: "Scenario saved", passed: true, detail: ".markview/studio/scenarios/\(StudioStore.safeID(next.id)).json"),
                      StudioCheck(name: "Page loaded in the new scenario", passed: pageLoaded, detail: pageLoaded ? next.name : problem ?? "")]
        if !next.steps.isEmpty { checks.append(StudioCheck(name: "Restoration steps replayed", passed: problem == nil, detail: problem ?? "")) }
        checks.append(StudioCheck(name: "No runtime errors", passed: errors.isEmpty,
                                  detail: errors.prefix(3).map { String($0.detail.prefix(300)) }.joined(separator: "\n")))
        let same = StudioContextValidator.sameSources(snapshot, after)
        checks.append(StudioCheck(name: "Project files unchanged", passed: same,
                                  detail: same ? "" : "The working tree changed while the request ran; the context change itself writes no source file."))
        operation.checks = checks
        operation.finalRevision = revision
        if pageLoaded, let capture = await capture(label: "After: " + String(operation.request.prefix(60)), operationId: operation.id) {
            operation.afterCapture = capture.id
        }
        if let selection { await revalidateSelection(selection, afterEdit: true) }
        await trackContextChange(&operation)
        replace(operation)
    }

    /// Undo of a context change (REQ-013): the scenario it was made from is active again and the turn is marked undone. The
    /// new scenario is never deleted; it stays saved in the Scenario menu.
    private func undoContext(_ operation: StudioOperation) {
        guard let change = operation.context, !change.scenarioId.isEmpty, [.applied, .kept].contains(operation.status) else { return }
        guard let previous = change.previous ?? (savedScenarios + presets).first(where: { $0.id == change.previousScenarioId }) else {
            notice = "The scenario \(change.previousScenarioName) is no longer available."
            return
        }
        runWork("Returning to the previous scenario") { session in
            session.scenario = previous
            session.simulator.activate(previous)
            session.recordedSteps = []
            _ = await session.restore()
            var next = operation
            next.status = .undone
            session.trackUndo(next)
            session.replace(next)
            session.notice = "Back to \(previous.name). \(change.scenarioName) stays saved in the Scenario menu."
        }
    }

    /// Waits for the rebuilt application, restores the scenario and records the checks (EDIT-08, AC-15).
    private func verify(_ operation: inout StudioOperation, previous: StudioSelectionContext?, label: String) async {
        busyDetail = "Waiting for the application to rebuild"
        let mark = server?.output.count ?? 0
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        busyDetail = "Restoring the scenario"
        let problem = await restore()
        let logErrors = serverErrors(since: mark)
        let errors = events.filter { $0.kind == .runtimeError && $0.generation == simulator.generation }
        var checks = [StudioCheck(name: "Application rebuilt and reloaded", passed: buildError == nil && logErrors == nil,
                                  detail: buildError ?? logErrors ?? "")]
        checks.append(StudioCheck(name: "Scenario restored", passed: problem == nil, detail: problem ?? scenario.name))
        checks.append(StudioCheck(name: "No runtime errors", passed: errors.isEmpty,
                                  detail: errors.prefix(3).map { String($0.detail.prefix(300)) }.joined(separator: "\n")))
        operation.checks = checks
        operation.finalRevision = await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers()).0
        if buildError == nil && logErrors == nil {
            stalePreview = nil
            if let after = await capture(label: label, operationId: operation.id) { operation.afterCapture = after.id }
            if let previous { await revalidateSelection(previous, afterEdit: true) }
        } else {
            buildError = buildError ?? logErrors
            if stalePreview == nil, let before = operation.beforeCapture { stalePreview = captures.first { $0.id == before } }
            updateReadiness()
        }
        await revalidatePackages()
    }

    private func serverErrors(since mark: Int) -> String? {
        guard let output = server?.output, output.count > mark else { return nil }
        return Self.buildFailure(in: String(output.suffix(output.count - mark))).map { redactor.redact(text: $0) }
    }

    /// The first line of a dev server's log that reports a failed build, or nil. Only compile and bundle
    /// failures count: an application that built also logs errors (a handled `console.error`, a failed
    /// request, a runtime exception), and those are not a reason to call the preview stale.
    nonisolated static func buildFailure(in log: String) -> String? {
        let markers = [
            #"failed to compile"#, #"module not found"#, #"cannot find module"#, #"failed to resolve import"#,
            #"module build failed"#, #"(?-i:^\s*ERROR in )"#, #"✘ \[ERROR\]"#, #"\berror TS\d+"#,
            #"\[vite\] internal server error"#, #"\[plugin:[^\]]+\]"#, #"parsing \S+ source code failed"#,
            #"SyntaxError: \S+\.(?:[cm]?[jt]sx?|vue|svelte|astro)\b"#, #"^\s*syntax error\s*$"#,
        ]
        let pattern = "(?im)^.*(?:" + markers.joined(separator: "|") + ").*$"
        guard let range = log.range(of: pattern, options: .regularExpression) else { return nil }
        return String(log[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Keeps a change (it stays in the history and can still be undone).
    func keep(_ id: String) {
        guard var operation = history.first(where: { $0.id == id }), operation.status == .applied else { return }
        operation.status = .kept
        replace(operation)
    }

    /// Selective undo (EDIT-07, AC-14): the operation's reverse change is merged into the files as they are now; later
    /// independent edits stay. Overlapping edits are a conflict, shown for resolution, and nothing is written.
    func undo(_ id: String) {
        if let operation = history.first(where: { $0.id == id }), operation.kind == .context { return undoContext(operation) }
        guard let operation = history.first(where: { $0.id == id }), operation.kind == .edit, !operation.files.isEmpty,
              [.applied, .kept, .conflict].contains(operation.status) else { return }
        runWork("Undoing the change") { session in
            var plans: [StudioChanges.UndoPlan] = []
            for change in operation.files { plans.append(await StudioChanges.undoPlan(change, root: session.root)) }
            let unsaved = Set(session.editorBuffers().keys)
            var conflicts: [(path: String, merged: String)] = []
            var writes: [StudioFileChange] = []
            for plan in plans {
                switch plan {
                case .clean(let path, let text):
                    if unsaved.contains(path) {
                        conflicts.append((path, "The file has unsaved changes in the editor. Save or revert them, then undo again."))
                    } else {
                        let current = try? String(contentsOf: session.root.appendingPathComponent(path), encoding: .utf8)
                        writes.append(StudioFileChange(path: path, before: current, after: text))
                    }
                case .conflict(let path, let merged, _):
                    conflicts.append((path, merged))
                case .unchanged:
                    break
                }
            }
            var next = operation
            guard conflicts.isEmpty else {
                session.undoConflicts[id] = conflicts
                next.status = .conflict
                next.conflict = "Undo overlaps later changes in " + conflicts.map(\.path).joined(separator: ", ")
                    + ". Nothing was written; resolve the conflict or keep the change."
                return session.replace(next)
            }
            do {
                let root = session.root
                try await Task.detached { try StudioChanges.write(writes, root: root) }.value
            } catch {
                session.notice = error.localizedDescription
                return
            }
            session.undoConflicts[id] = nil
            next.status = .undone
            next.conflict = nil
            await session.verify(&next, previous: session.selection, label: "After undo: " + String(operation.request.prefix(50)))
            session.trackUndo(next)
            session.replace(next)
        }
    }

    /// Writes an undo conflict into its files with conflict markers, so it can be resolved in the editor.
    func resolveUndoConflictInEditor(_ id: String) {
        guard let conflicts = undoConflicts[id] else { return }
        for conflict in conflicts where conflict.merged.contains("<<<<<<<") {
            guard let url = StudioChanges.validatedURL(conflict.path, root: root) else { continue }
            try? conflict.merged.write(to: url, atomically: true, encoding: .utf8)
            openFile(url)
        }
        undoConflicts[id] = nil
        notice = "The conflict markers are in the files; resolve them in the editor."
    }

    private func append(_ operation: StudioOperation) {
        history.removeAll { $0.id == operation.id }
        history.append(operation)
        conversationIds.insert(operation.id)
        // The turn is in the thread now (a change may still be verifying, under the busy banner).
        pendingTurn = nil
        persistHistory()
    }

    func replace(_ operation: StudioOperation) {
        if let index = history.firstIndex(where: { $0.id == operation.id }) { history[index] = operation } else { history.append(operation) }
        persistHistory()
    }

    private func persistHistory() {
        let history = history, root = root
        io.async { try? StudioStore.saveHistory(history, root: root) }
    }

    // MARK: - Captures

    /// A picture of the preview linked to the code revision, the scenario and the rendering conditions (CAP-01, CAP-02).
    @discardableResult
    func capture(label: String, operationId: String? = nil) async -> StudioCapture? {
        guard appURL != nil else { return nil }
        let info = (try? await call("return await window.__markviewStudio.prepareCapture();")) as? [String: Any] ?? [:]
        let image = await snapshot(nil)
        _ = try? await call("return window.__markviewStudio.finishCapture();")
        guard let image else { return nil }
        let id = "cap-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "") + "-" + UUID().uuidString.prefix(4).lowercased()
        let relative = ".dde/studio/captures/\(id).png"
        let file = root.appendingPathComponent(relative)
        StudioStore.prepareLocalFolder(root)
        guard await Task.detached(operation: { StudioImageDiff.writePNG(image, to: file) }).value else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let rendering = StudioRendering(
            engine: info["engine"] as? String ?? "WebKit",
            os: "macOS \(os.majorVersion).\(os.minorVersion)",
            viewport: StudioViewport(width: (info["width"] as? NSNumber)?.intValue ?? scenario.viewport.width,
                                     height: (info["height"] as? NSNumber)?.intValue ?? scenario.viewport.height),
            devicePixelRatio: (info["devicePixelRatio"] as? NSNumber)?.doubleValue ?? 1,
            fonts: info["fonts"] as? [String] ?? [],
            locale: info["locale"] as? String ?? scenario.locale,
            timeZone: info["timeZone"] as? String ?? TimeZone.current.identifier,
            colorScheme: info["colorScheme"] as? String ?? scenario.theme.rawValue)
        let revision = await StudioRevisionProbe.compute(root: root, editorBuffers: editorBuffers()).0
        let capture = StudioCapture(id: id, label: label, file: relative, revision: revision, scenarioId: scenario.id,
                                    scenarioRevision: scenario.revision,
                                    contractFingerprint: StudioScenarioCompatibility.fingerprint(scenario, spec: spec),
                                    rendering: rendering, operationId: operationId)
        captures.append(capture)
        let all = captures, root = root
        io.async { try? StudioStore.saveCaptures(all, root: root) }
        return capture
    }

    func captureNow() {
        runWork("Capturing") { session in
            if let capture = await session.capture(label: "Capture of \(session.scenario.name)") {
                session.notice = "Saved a capture of \(session.scenario.name)."
            }
        }
    }

    func url(of capture: StudioCapture) -> URL { root.appendingPathComponent(capture.file) }

    /// Side by side and the pixel difference of two captures (CAP-03, CAP-04); different conditions are named, not hidden.
    /// `enlarge` shows the result at the size of the whole tab (the chat's Compare button), otherwise in the Evidence panel.
    func compare(_ beforeID: String, _ afterID: String, enlarge: Bool = false) {
        guard let before = captures.first(where: { $0.id == beforeID }), let after = captures.first(where: { $0.id == afterID }) else { return }
        let reasons = StudioImageDiff.incomparability(before, after)
        let a = url(of: before), b = url(of: after)
        let output = StudioStore.capturesFolder(root).appendingPathComponent("diff-\(before.id)-\(after.id).png")
        Task {
            let result = await Task.detached { () -> (URL?, Double?, CGRect?) in
                guard let first = StudioImageDiff.load(a), let second = StudioImageDiff.load(b),
                      let diff = StudioImageDiff.compare(first, second) else { return (nil, nil, nil) }
                return (StudioImageDiff.writePNG(diff.image, to: output) ? output : nil, diff.ratio, diff.bounds)
            }.value
            comparison = Comparison(before: before, after: after, diffFile: result.0, changedRatio: result.1, changedBounds: result.2, reasons: reasons)
            comparisonEnlarged = enlarge
        }
    }

    // MARK: - Feature packages

    /// The operations a feature package can be made of: applied code changes and the context changes that made a scenario.
    var exportableOperations: [StudioOperation] {
        history.filter { [.applied, .kept].contains($0.status)
            && ($0.kind == .edit ? !$0.files.isEmpty : $0.kind == .context && $0.context?.scenarioId.isEmpty == false) }
    }

    /// Exports the chosen operations as a feature (CAP-05) through the feature store, with a package in
    /// `.markview/studio/packages/` that is revalidated when its files change later (CAP-06).
    func exportFeature(title: String, summary: String, operations ids: [String]) {
        let chosen = exportableOperations.filter { ids.contains($0.id) }
        guard !chosen.isEmpty, let store = featureStore() else { return }
        runWork("Exporting the feature") { session in
            guard let baseline = chosen.first?.baseRevision, let final = chosen.last?.finalRevision ?? chosen.last?.baseRevision else { return }
            let paths = Array(Set(chosen.flatMap { $0.files.map(\.path) })).sorted()
            let root = session.root
            let hashes = await Task.detached { StudioRevisionProbe.currentHashes(paths, root: root) }.value
            var pictures: [StudioPackage.Picture] = []
            let pictureIDs = [chosen.first?.beforeCapture, chosen.last?.afterCapture].compactMap { $0 }
            for id in pictureIDs {
                guard let capture = session.captures.first(where: { $0.id == id }) else { continue }
                let size = (try? FileManager.default.attributesOfItem(atPath: session.url(of: capture).path)[.size] as? Int) ?? 0
                pictures.append(StudioPackage.Picture(label: capture.label, captureId: capture.id, file: capture.file,
                                                      inFeature: size <= StudioPackage.inFeatureLimit, bytes: size))
            }
            let checks = chosen.flatMap(\.checks)
            let rendering = pictureIDs.compactMap { id in session.captures.first { $0.id == id }?.rendering }.last
            var package = StudioPackage(id: StudioStore.safeID(title) + "-" + String(UUID().uuidString.prefix(4)).lowercased(),
                                        featureSlug: "", title: title, summary: summary,
                                        requests: chosen.map(\.request), operations: chosen.map(\.id), scenario: session.scenario,
                                        baselineRevision: baseline, finalRevision: final, files: hashes,
                                        patch: chosen.map(\.patch).joined(), rendering: rendering, pictures: pictures, checks: checks)
            do {
                let created = try await StudioFeatureWriter.write(package, operations: chosen, root: root, redactor: session.redactor, into: store)
                package.featureSlug = created
                try StudioStore.savePackage(package, root: root)
                session.packages = StudioStore.loadPackages(root)
                session.notice = "Exported feature \(created)."
                session.onFeatureExported(created)
            } catch {
                session.notice = error.localizedDescription
            }
        }
    }

    /// Marks packages whose files changed since they were exported (CAP-06); their captures stay as history.
    func revalidatePackages() async {
        let current = packages, root = root
        let next = await Task.detached { current.map { $0.revalidated(root: root) } }.value
        packages = next
        let changed = zip(current, next).filter { $0.0.status != $0.1.status || $0.0.changedSince != $0.1.changedSince }.map(\.1)
        guard !changed.isEmpty else { return }
        io.async { for package in changed { try? StudioStore.savePackage(package, root: root) } }
    }
}

// MARK: - Sign-in and pages outside the application (REQ-010)

extension StudioSession {
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
        Task { [weak self] in await self?.followNavigation(method: method, url: url, headers: headers, body: body, serial: serial) }
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
                route(request, source: .page) { done.resume(returning: $0) }
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
        if let logical = logicalURL(for: url) { return logical }
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
        mapping.routeScanner = { [weak self] in await self?.routeHandlers() ?? [] }
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
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
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
        let usage = recordUsage
        return StudioCLIMapAssistant(project: root) { input, output, cost in
            Task { @MainActor in usage(input, output, cost) }
        }
    }

    private func saveMap(_ map: StudioEnvironmentMap?) {
        guard !closed else { return }
        var next = simulator.spec
        next.map = map
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
    }

    /// New seed records for these entities. The current records change at the next Reset; a scenario with its own records
    /// keeps them.
    private func replaceSeed(_ seed: [String: [StudioJSON]]) {
        guard !closed else { return }
        var next = simulator.spec
        for (name, records) in seed { next.seed[name] = records }
        next.updated = Date()
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
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
        simulator.replaceSpec(updated)
        spec = simulator.spec
        persistEnvironment()
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

/// Where a selected element's source is, checked against the project (PRE-07, PRE-10): a reported path must be a file of
/// the project, a line must look like the element, and without metadata a search proposes candidates — never a guess
/// presented as certain.
struct StudioSourceResolution: Sendable {
    var path: String?
    var line: Int?
    var mapping: StudioSelectionContext.Mapping
    var snippet: String?
    var lineHash: String?
    var note: String?

    static func resolve(_ context: StudioSelectionContext, root: URL, appFolder: URL, tagName: String) -> StudioSourceResolution {
        var outside: String?
        if let reported = context.sourcePath {
            if let path = StudioSelectionContext.projectPath(reported, root: root, appFolder: appFolder), !StudioSourceMap.isGenerated(path) {
                let text = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
                var line = context.line
                if let given = line { line = refine(text, line: given, tagName: tagName) }
                else if let found = locate(text, tagName: tagName, context: context) { line = found }
                let snippet = line.map { StudioSelectionContext.snippet(of: text, line: $0) }
                return StudioSourceResolution(path: path, line: line, mapping: context.mapping, snippet: snippet,
                                              lineHash: line.flatMap { StudioSelectionContext.lineHash(of: text, line: $0) })
            }
            // A bundled chunk without a usable source map, or a file outside the project: never read; search instead.
            outside = "The framework named a bundled or outside file, not a project source."
        }
        // No usable location: search the sources for the component and the element, and say it is a candidate.
        let candidates = search(context, root: root, appFolder: appFolder)
        if candidates.count == 1, let first = candidates.first {
            let text = (try? String(contentsOf: root.appendingPathComponent(first.path), encoding: .utf8)) ?? ""
            return StudioSourceResolution(path: first.path, line: first.line, mapping: .candidate,
                                          snippet: StudioSelectionContext.snippet(of: text, line: first.line),
                                          lineHash: StudioSelectionContext.lineHash(of: text, line: first.line),
                                          note: "Found by searching the sources, not by development metadata: check it.")
        }
        if candidates.count > 1 {
            return StudioSourceResolution(path: nil, line: nil, mapping: .candidate,
                                          note: "\(candidates.count) candidate files: " + candidates.prefix(5).map { "\($0.path):\($0.line)" }.joined(separator: ", ") + ".")
        }
        return StudioSourceResolution(path: nil, line: nil, mapping: .none, note: outside)
    }

    /// A framework's line can be off by one (0- or 1-based); the line that opens the element's tag wins.
    static func refine(_ text: String, line: Int, tagName: String) -> Int {
        guard !tagName.isEmpty else { return line }
        let lines = text.components(separatedBy: "\n")
        for candidate in [line, line + 1, line - 1] where candidate >= 1 && candidate <= lines.count {
            if lines[candidate - 1].localizedCaseInsensitiveContains("<" + tagName) { return candidate }
        }
        return line
    }

    /// In a component file without a line: the only line that opens the tag with the element's first class.
    static func locate(_ text: String, tagName: String, context: StudioSelectionContext) -> Int? {
        let classes = context.tag.split(separator: ".").dropFirst().map(String.init)
        let lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { index in
            let line = lines[index]
            return line.contains("<" + tagName) && (classes.first.map { line.contains($0) } ?? true)
        }
        return matches.count == 1 ? matches[0] + 1 : nil
    }

    /// Source files that contain the element's id, an Angular component's class, its first class name or its short text.
    static func search(_ context: StudioSelectionContext, root: URL, appFolder: URL) -> [(path: String, line: Int)] {
        var needles: [String] = []
        if let component = context.component, !component.isEmpty, component.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
            needles.append("class \(component)")
            // A function component's definition (React, Solid, Preact).
            if context.framework == "react" || context.framework.isEmpty {
                needles += ["function \(component)(", "function \(component)<", "const \(component) =", "const \(component): "]
            }
        }
        let parts = context.tag.split(separator: "#", maxSplits: 1)
        if parts.count == 2 { needles.append("id=\"\(parts[1].split(separator: ".").first ?? "")\"") }
        if let firstClass = context.tag.split(separator: ".").dropFirst().first, firstClass.count >= 3 { needles.append(String(firstClass)) }
        let text = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (4...80).contains(text.count), !text.contains("\n") { needles.append(text) }
        guard !needles.isEmpty, let enumerator = FileManager.default.enumerator(at: appFolder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                              options: [.skipsHiddenFiles]) else { return [] }
        let extensions: Set<String> = ["tsx", "jsx", "ts", "js", "vue", "svelte", "html", "astro", "hbs", "erb", "njk"]
        let skipped = StudioSourceMap.generatedFolders.union(["node_modules", "coverage", "vendor"])
        let base = root.standardizedFileURL.path
        var files: [URL] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if extensions.contains(url.pathExtension.lowercased()) { files.append(url) }
            if files.count >= 3_000 { break }
        }
        for needle in needles {
            var found: [(String, Int)] = []
            for file in files {
                guard let content = try? String(contentsOf: file, encoding: .utf8), let range = content.range(of: needle) else { continue }
                let line = content[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                found.append((String(path.dropFirst(base.count + 1)), line))
                if found.count > 8 { break }
            }
            if !found.isEmpty { return found.map { (path: $0.0, line: $0.1) } }
        }
        return []
    }
}

/// Writes the feature a UI Studio package creates (CAP-05), through the feature store like the prototype hand-off: the
/// overview carries the evidence, small captures are attached as sources, and each change becomes a requirement.
@MainActor
enum StudioFeatureWriter {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func write(_ package: StudioPackage, operations: [StudioOperation], root: URL, redactor: StudioRedactor,
                      into store: FeatureStore) async throws -> String {
        guard let slug = store.createFeature(title: package.title, idea: package.summary) else {
            throw Failure(message: store.lastError ?? "The feature could not be created.")
        }
        let provenance = "Exported from MarkView UI Studio"
        store.updateFeature(slug) { front, body in
            front.set("provenance", provenance)
            front.set("intake", "ui-studio")
            front.set("questions_left", "0")
            body = package.overview(redactor: redactor)
        }
        // The package hands the work to implementation: a specification stage, then the hand-off as start evidence.
        store.moveFeature(slug, to: "draft", by: .system("UI Studio"))
        store.markImplementing(slug, handoff: "UI Studio")
        var sources: [String] = []
        for picture in package.pictures where picture.inFeature {
            guard let source = store.create(.source, in: slug, title: picture.label,
                                            fields: [("origin", .string("ui-studio")), ("file", .string("")),
                                                     ("role", .string("screenshot")), ("facts", .list([]))],
                                            body: "## Origin\n\nCapture \(picture.captureId) from MarkView UI Studio.\n",
                                            provenance: provenance) else { continue }
            let name = "\(source.id)-\(picture.captureId).png"
            let copy = source.url.deletingLastPathComponent().appendingPathComponent(name)
            let from = root.appendingPathComponent(picture.file)
            let copied = await Task.detached { (try? FileManager.default.copyItem(at: from, to: copy)) != nil }.value
            guard copied else { _ = store.deleteObjects(slug, ids: [source.id]); continue }
            store.update(source.id, in: slug) { front, body in
                front.set("file", name)
                body += "\nFile: [\(name)](\(name))\n"
            }
            sources.append(source.id)
        }
        for operation in operations {
            let criteria = operation.checks.map { "\($0.name)" + ($0.passed ? "" : " (failed when exported)") }
            let statement = redactor.redact(text: operation.summary.isEmpty ? operation.request : operation.summary)
            let body = ProjectAgentTools.requirementBody(statement: statement,
                                                         criteria: ["Request: " + redactor.redact(text: operation.request)] + criteria)
                + (operation.patch.isEmpty ? "" : "\n## Code changes\n\n```diff\n" + redactor.redact(text: operation.patch) + "```\n")
            _ = store.create(.requirement, in: slug, title: String(operation.request.prefix(80)),
                             fields: [("status", .string("approved")), ("req_type", .string("functional")),
                                      ("depends_on", .list([])), ("decisions", .list([])),
                                      ("sources", .list(sources.map { .string($0) })), ("issues", .list([]))],
                             body: body, provenance: provenance)
        }
        store.reloadSync(slug)
        return slug
    }
}

/// Who made a request the session answers: the page in the preview, or the development server through a simulated
/// connection (REQ-007).
enum StudioRequestSource: Equatable {
    case page
    case server(variable: String)

    var transport: String { self == .page ? "page" : "server" }
    var variable: String? { if case .server(let variable) = self { return variable } else { return nil } }
}

/// The session's answer to a request, before it takes the page bridge's or the gateway's form.
enum StudioReply {
    case respond(StudioSimResponse)
    /// To its address, with these headers added (the page only).
    case pass(adding: [String: String])
    /// No answer any more: the session closed or the scenario was reset meanwhile.
    case dropped(String)
}


/// Delivers one reply of a request, once: the "preparing" answer and the real one race, and the first wins (BUG-089).
@MainActor
final class StudioReplyOnce {
    private let deliver: (StudioReply) -> Void
    private(set) var delivered = false

    init(_ deliver: @escaping (StudioReply) -> Void) { self.deliver = deliver }

    /// True when this call delivered the reply.
    @discardableResult
    func reply(_ value: StudioReply) -> Bool {
        guard !delivered else { return false }
        delivered = true
        deliver(value)
        return true
    }

    func callAsFunction(_ value: StudioReply) { reply(value) }
}
