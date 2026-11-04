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
        var date = Date()
    }

    /// A question or change request the assistant is working on: shown at the end of the conversation from the moment
    /// it is sent until its turn is in the history, or the work fails or is cancelled.
    struct PendingTurn: Equatable {
        var kind: StudioOperation.Kind
        var request: String
        /// The selected element as the turn will record it (tag and source file).
        var element: String
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
    let preparation = StudioPreparationQueue()

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
    @Published private(set) var scenario: StudioScenario
    @Published private(set) var mode: Mode = .interact {
        // A page the application loads while recording (a link, a form, a reload) records too (BUG-071).
        didSet { if (oldValue == .record) != (mode == .record) { _ = installRuntime() } }
    }
    @Published var zoom: Double? = nil
    @Published private(set) var selection: StudioSelectionContext?
    @Published var notice: String?
    @Published private(set) var history: [StudioOperation] = []
    /// The turn the assistant is answering; nil once it is in `history`, and after a failure or Stop.
    @Published private(set) var pendingTurn: PendingTurn?
    /// The turns of this session: the assistant's memory. The thread shows the whole saved history, but turns of earlier
    /// sessions are not sent, so yesterday's request about another element cannot steer today's change (BUG-068).
    private var conversationIds: Set<String> = []

    /// What the assistant remembers of this conversation, oldest first.
    private var conversation: [StudioOperation] { history.filter { conversationIds.contains($0.id) } }
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
    /// Undo conflicts by operation: the merged text with conflict markers per file.
    @Published private(set) var undoConflicts: [String: [(path: String, merged: String)]] = [:]

    /// Unsaved editor buffers of files in the project (path relative to the root → text).
    var editorBuffers: () -> [String: String] = { [:] }
    /// Counts an assistant run in the workspace's usage.
    var recordUsage: (Int, Int, Double) -> Void = { _, _, _ in }
    var openFile: (URL) -> Void = { _ in }
    var featureStore: () -> FeatureStore? = { nil }
    var onFeatureExported: (String) -> Void = { _ in }

    private var simulator: StudioSimulator
    private var server: StudioDevServer?
    private var ruleListID: String?
    private var appOrigin: StudioBridge.Origin?
    /// Main-frame page loads committed so far: tells a replay step that loaded another page from one that failed.
    private var pageCommits = 0
    private var electronGlobals: [String] = []
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
        let first = StudioScenarioCompatibility.presets(spec: loaded, base: StudioScenario(id: "builtin-populated", name: "Populated", kind: .populated))[0]
        scenario = first
        simulator = StudioSimulator(spec: loaded, scenario: first)

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15 MarkViewUIStudio"
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: first.viewport.width, height: first.viewport.height), configuration: configuration)
        super.init()
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
                    self.set(.failed, "No web application with a development server was found in this project.")
                } else {
                    self.set(.analyzing, "Choose the application to open.")
                }
                return
            }
            await self.launch(target)
        }
    }

    private func launch(_ target: WebAppTarget) async {
        self.target = target
        disclosures = StudioTargetLimits.disclosures(for: target)
        if target.isElectron {
            let folder = target.folder
            electronGlobals = await Task.detached { StudioTargetLimits.electronGlobals(in: folder) }.value
        }
        set(.starting, "Looking for a running development server")
        var url = await WebAppPreview.firstAnswering(target.ports)
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
        await installConnectionPolicy()
        set(.starting, "Loading the application")
        await restore()
    }

    private func startServer(_ target: WebAppTarget) async -> URL? {
        let launch = await StudioLaunchEnvironment.make()
        removedEnvironment = launch.removed
        let server = StudioDevServer(command: target.command, folder: target.folder)
        server.onOutput = { [weak self] _ in Task { @MainActor in self?.refreshServerLog() } }
        server.onExit = { [weak self] code in Task { @MainActor in self?.serverEnded(code) } }
        do {
            try server.start(environment: launch.environment)
        } catch {
            set(.failed, error.localizedDescription)
            return nil
        }
        self.server = server
        ownsServer = true
        StudioDevServer.track(server)
        let deadline = Date().addingTimeInterval(180)
        var round = 0
        while Date() < deadline, !closed {
            if let code = server.exitStatus {
                set(.failed, "The development server stopped (exit \(code)). See its output below.")
                return nil
            }
            if let printed = WebAppPreview.firstLocalURL(in: server.output),
               await WebAppPreview.firstAnswering([printed.port ?? 80], timeout: 1) != nil {
                return URL(string: "\(printed.scheme ?? "http")://\(printed.host ?? "localhost"):\(printed.port ?? 80)/")
            }
            if round % 4 == 3, let answering = await WebAppPreview.firstAnswering(target.ports) { return answering }
            round += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if !closed { set(.failed, "The development server did not print an address within 3 minutes.") }
        return nil
    }

    private func refreshServerLog() {
        guard let server else { return }
        serverLog = redactor.redact(text: String(server.output.suffix(12_000)))
    }

    private func serverEnded(_ code: Int32) {
        refreshServerLog()
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
        preparation.cancelAll()
        resumeLoadWaiters(false)
        webView.stopLoading()
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllScriptMessageHandlers()
        controller.removeAllContentRuleLists()
        if let ruleListID { StudioConnectionPolicy.remove(identifier: ruleListID) }
        webView.loadHTMLString("", baseURL: nil)
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        if ownsServer, let server {
            await server.stop()
            StudioDevServer.untrack(server)
        }
        server = nil
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
        if let list = await StudioConnectionPolicy.compile(identifier: identifier, json: json) {
            controller.add(list)
            if let old = ruleListID, old != identifier { StudioConnectionPolicy.remove(identifier: old) }
            ruleListID = identifier
        } else {
            notice = "The connection policy could not be installed; requests are still answered only by the simulation."
        }
    }

    private func runtimeScript() -> WKUserScript? {
        guard let source = Self.runtimeSource else { return nil }
        let config: [String: Any] = [
            "session": token, "generation": simulator.generation, "seed": Int(scenario.seed),
            "testTime": scenario.testTime.timeIntervalSince1970 * 1000, "locale": scenario.locale,
            "timeZone": scenario.timeZone ?? NSNull(), "electron": target?.isElectron ?? false, "electronGlobals": electronGlobals,
            "recording": mode == .record,
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
        var page = URLRequest(url: target)
        // A fresh server render: Next.js serves cached server fetches in development unless the request says no-cache.
        StudioConnectionPolicy.frameworkRequestHeaders.forEach { page.setValue($0.value, forHTTPHeaderField: $0.key) }
        webView.load(page)
        return await waitForLoad(timeout: 45)
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
    /// browser storage, a fresh page and the scenario's restoration steps. Returns why the restore is incomplete, if it is.
    @discardableResult
    func restore() async -> String? {
        guard !closed, appURL != nil else { return "The application is not running." }
        mode = mode == .record ? .interact : mode
        pickTask?.cancel()
        simulator.reset()
        preparation.cancelAll()
        selection = nil
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        guard await loadPage() else {
            if state != .failed { set(.degraded, "The page did not finish loading.") }
            return "The page did not finish loading."
        }
        _ = try? await call("return await window.__markviewStudio.whenIdle(40000, 400);")
        let problem = await replay(scenario.steps)
        if let problem { notice = problem }
        await refreshPageState()
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
            guard let origin = StudioBridge.Origin(url: url), origin.sameServer(appOrigin) else {
                note(.blocked, "Navigation to \(url.absoluteString) was blocked: it leaves the application.")
                return decisionHandler(.cancel)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageCommits += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeLoadWaiters(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resumeLoadWaiters(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { notice = "The page did not load: \(error.localizedDescription)" }
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
        }
    }

    private func handle(_ request: StudioBridge.Request, reply: @escaping (Any?, String?) -> Void) {
        let http = StudioHTTPRequest(method: request.method, url: request.url, headers: request.headers, body: request.body,
                                     requestId: request.requestId)
        let shown = redactor.redact(text: request.url.absoluteString)
        let contract = StudioRoute.contractKey(method: http.method, url: http.url, appOrigin: appOrigin?.text)
        let sameServer = StudioBridge.Origin(url: request.url).map { appOrigin?.sameServer($0) == true } ?? false
        if sameServer && StudioConnectionPolicy.isFrameworkRequest(request.url, headers: request.headers) {
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil))
            return reply(StudioBridge.passThrough(adding: StudioConnectionPolicy.frameworkRequestHeaders), nil)
        }
        if (sameServer && StudioConnectionPolicy.isDevelopmentResource(request.url, appFolder: appFolder))
            || spec.allowedRequests.contains(where: { StudioRoute.allows($0, url: request.url, appOrigin: appOrigin?.text) }) {
            if !sameServer { noteDependency(StudioDependency(id: contract, mode: .allowed, note: "Allowed by the connection policy.")) }
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil))
            return reply(StudioBridge.passThrough, nil)
        }
        switch simulator.handle(http) {
        case .respond(let response, _):
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status))
            reply(StudioBridge.reply(response), nil)
        case .unsupported(let contract, let reason):
            noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason + " are outside the first release."))
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "unsupported", status: 501))
            reply(StudioBridge.reply(.unsupported(contract, reason: reason + " are not simulated in the first release.")), nil)
            updateReadiness()
        case .unknown(let contract):
            log(RequestRecord(method: http.method, url: shown, contract: contract, outcome: "preparing", status: nil))
            prepare(http, contract: contract, reply: reply)
        }
    }

    /// An unknown request (SIM-07): the assistant prepares rules for it within the session's limits; the request waits for
    /// them or ends in a controlled error. It never goes to a real service.
    private func prepare(_ http: StudioHTTPRequest, contract: String, reply: @escaping (Any?, String?) -> Void) {
        let generation = simulator.generation
        var body = http.body.map { redactor.redact(body: $0) }
        if let text = body, text.count > 4_000 { body = String(text.prefix(4_000)) }
        let context = StudioPreparationContext(contract: contract, method: http.method, url: redactor.redact(text: http.url.absoluteString),
                                               headers: redactor.redact(headers: http.headers), body: body, attempt: 1, problems: [])
        let relative = appFolder.standardizedFileURL.path.dropFirst(root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let usage = recordUsage
        let preparer = StudioCLIPreparer(project: root, appFolder: relative, spec: simulator.spec) { input, output, cost in
            Task { @MainActor in usage(input, output, cost) }
        }
        updateReadiness()
        Task { [weak self] in
            guard let self else { return reply(nil, "closed") }
            let outcome = await self.preparation.resolve(context, generation: generation, preparer: preparer,
                                                         currentGeneration: { [weak self] in self?.simulator.generation ?? -1 },
                                                         commit: { [weak self] proposal in self?.commit(proposal) ?? ["The session is closed."] })
            guard !self.closed else { return reply(nil, "closed") }
            switch outcome {
            case .registered:
                if self.simulator.generation == generation, case .respond(let response, _) = self.simulator.handle(http) {
                    self.log(RequestRecord(method: http.method, url: self.redactor.redact(text: http.url.absoluteString), contract: contract,
                                           outcome: "simulated", status: response.status))
                    reply(StudioBridge.reply(response), nil)
                } else {
                    reply(StudioBridge.reply(.unresolved(contract, reason: "the rules registered for it do not answer this request.")), nil)
                }
            case .unsupported(let reason):
                self.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason))
                reply(StudioBridge.reply(.unsupported(contract, reason: reason)), nil)
            case .stale:
                reply(nil, "stale")
            default:
                let reason = self.preparation.records[contract]?.message ?? "it could not be prepared."
                self.noteDependency(StudioDependency(id: contract, mode: .unresolved, note: reason))
                reply(StudioBridge.reply(.unresolved(contract, reason: reason)), nil)
            }
            self.updateReadiness()
        }
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
        simulator.replaceSpec(next)
        spec = simulator.spec
        persistEnvironment()
        rebuildDependencies()
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
                                            note: "\(detail) is a stand-in that does nothing: what depends on it is not simulated."))
        case .blocked:
            noteDependency(StudioDependency(id: "blocked:" + String(detail.prefix(120)), mode: .unsupported,
                                            note: detail + " (blocked by the application connection policy)"))
        case .runtimeError:
            break
        }
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
        guard !closed, appURL != nil, [.ready, .degraded, .preparing, .starting].contains(state) else { return }
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
            set(.ready, "The scenario is loaded and every request it made is simulated.")
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
        reset()
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
    private func runWork(_ title: String, pending: PendingTurn? = nil, _ work: @escaping @MainActor (StudioSession) async -> Void) {
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
        preparation.cancelAll()
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

    /// A question about the selected element (EDIT-01, AC-11): read-only, nothing in the project changes.
    func ask(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let selection else { return }
        let element = Self.turnElement(selection)
        runWork("Asking the assistant", pending: PendingTurn(kind: .question, request: text, element: element)) { session in
            var operation = StudioOperation(id: session.newOperationID(), kind: .question, request: text, status: .answered)
            operation.selection = element
            operation.scenarioId = session.scenario.id
            let before = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
            operation.baseRevision = before
            var request = CLICompletion.Request(project: session.root,
                                                prompt: StudioPrompts.questionPrompt(text, selection: selection, scenario: session.scenario,
                                                                                     revision: before, history: session.conversation,
                                                                                     redactor: session.redactor),
                                                systemPrompt: StudioPrompts.questionSystem, readableFolder: session.root)
            request.images = selection.imagePath.map { [URL(fileURLWithPath: $0)] } ?? []
            request.timeout = 600
            request.effort = "medium"
            request.label = "ui-studio:question"
            do {
                let result = try await CLICompletion.run(request, onActivity: { activity in
                    Task { @MainActor in session.progress(activity) }
                })
                session.recordUsage(result.inputTokens, result.outputTokens, result.costUSD ?? 0)
                operation.answer = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch is CancellationError {
                return
            } catch {
                operation.status = .failed
                operation.answer = error.localizedDescription
            }
            let after = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers()).0
            operation.finalRevision = after
            operation.checks = [StudioCheck(name: "Project files unchanged", passed: after.id == before.id,
                                            detail: after.id == before.id ? "" : "The working tree changed while the question ran; the assistant itself had read-only access.")]
            session.append(operation)
        }
    }

    /// A change request for the selected element (EDIT-02…EDIT-08, AC-12, AC-13, AC-15): the scenario is restored and
    /// captured, the assistant names the scope and proposes exact edits, MarkView checks them against the working tree as
    /// it was when the request started, writes them, waits for the rebuilt application, restores the scenario again and
    /// verifies it.
    func change(_ text: String, clarification: String? = nil, replacing pending: StudioOperation? = nil) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, var selection else { return }
        // An answer to the assistant's question is what the person just said; the question itself stays in the thread.
        let turn = PendingTurn(kind: .edit, request: clarification ?? request, element: Self.turnElement(selection))
        runWork("Changing the interface", pending: turn) { session in
            session.busyDetail = "Restoring the scenario"
            _ = await session.restore()
            if session.selection == nil {
                await session.revalidateSelection(selection, afterEdit: false)
                if let current = session.selection { selection = current }
            }
            let before = await session.capture(label: "Before: " + String(request.prefix(60)))
            let (revision, snapshot) = await StudioRevisionProbe.compute(root: session.root, editorBuffers: session.editorBuffers())
            var operation = pending ?? StudioOperation(id: session.newOperationID(), kind: .edit, request: request, status: .applied)
            operation.status = .applied
            operation.question = nil
            operation.options = []
            operation.selection = Self.turnElement(selection)
            operation.scenarioId = session.scenario.id
            operation.baseRevision = revision
            operation.beforeCapture = before?.id
            var retryProblem: String?
            for attempt in 1...2 {
                session.busyDetail = attempt == 1 ? "The assistant is reading the project" : "The assistant is correcting its edits"
                // The history includes a clarification being answered: its turn says what the assistant asked.
                var call = CLICompletion.Request(project: session.root,
                                                 prompt: StudioPrompts.editPrompt(request, selection: selection, scenario: session.scenario,
                                                                                  revision: revision, history: session.conversation,
                                                                                  redactor: session.redactor, clarification: clarification,
                                                                                  retryProblem: retryProblem),
                                                 systemPrompt: StudioPrompts.editSystem, jsonSchema: StudioPrompts.editSchema,
                                                 readableFolder: session.root)
                call.images = selection.imagePath.map { [URL(fileURLWithPath: $0)] } ?? []
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
                operation.scope = plan.scope
                operation.scopeNote = plan.scopeNote
                operation.summary = plan.summary
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
            session.replace(operation)
        }
    }

    /// Answers the assistant's question and runs the change with it.
    func answerClarification(_ operation: StudioOperation, choice: String) {
        // The question being answered belongs to the conversation, even when an earlier session asked it.
        conversationIds.insert(operation.id)
        change(operation.request, clarification: choice, replacing: operation)
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

    private func replace(_ operation: StudioOperation) {
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
    func compare(_ beforeID: String, _ afterID: String) {
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
        }
    }

    // MARK: - Feature packages

    /// The edit operations a feature package can be made of.
    var exportableOperations: [StudioOperation] {
        history.filter { $0.kind == .edit && [.applied, .kept].contains($0.status) && !$0.files.isEmpty }
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
            front.set("status", "implementing")
            front.set("intake", "ui-studio")
            front.set("questions_left", "0")
            body = package.overview(redactor: redactor)
        }
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
