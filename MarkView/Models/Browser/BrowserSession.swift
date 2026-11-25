import AppKit
import WebKit
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// The page or its selection as Markdown, from `markview-page-markdown.js`.
struct PageCapture {
    enum Mode: String { case selection, page }
    var title: String
    var url: URL?
    var markdown: String
    var hasSelection: Bool
}

/// What "Save Page as…" writes.
enum PageFormat: String { case markdown, pdf }

/// One browser tab: its web view and what the tab bar and the toolbar show. Links that
/// ask for a new window open as new browser tabs; other schemes go to their apps.
@MainActor
final class BrowserSession: NSObject, ObservableObject, BrowserSaveDelegate {
    let id = UUID()
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    /// Why the last navigation failed (shown over the page with Retry), or nil.
    @Published private(set) var loadError: String?
    /// Preview Web App: what the tab is doing before the app's page is shown; nil for a
    /// plain browser tab and once the page is loaded.
    @Published var preview: WebPreviewState?
    /// "Save as Markdown" was asked for (toolbar or context menu); the tab view shows the sheet.
    @Published var saveRequest: PageCapture.Mode?
    /// The format the sheet opens with; the sheet resets it to Markdown when it closes.
    var saveFormat: PageFormat = .markdown
    /// The last download of this tab, shown in a banner until dismissed.
    @Published var download: BrowserDownload?
    /// A submitted login form the person may save (or update), shown in a bar.
    @Published var passwordPrompt: PasswordPrompt?
    /// A login form is on the page and logins are saved for its site.
    @Published private(set) var fillOffer: PasswordFillOffer?
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    /// A sign-in or auth popup opened by background automation and kept hidden until the user opens it (DEC-002).
    struct PendingPopupInfo: Identifiable, Equatable {
        let id: UUID
        var url: URL?
        var title: String
        var isAvailable: Bool
    }

    enum OpenCause {
        case automated
        case manual
    }

    /// Pending hidden popups opened by automated actions in this tab, kept connected to `window.opener` (DEC-002).
    @Published private(set) var pendingPopups: [PendingPopupInfo] = []
    /// Explanation shown when the user tries to open a pending sign-in popup that is no longer available (DEC-002).
    @Published var unavailablePopupNotice: String?
    /// True while at least one hidden sign-in popup is pending on this tab.
    var hasPendingPopup: Bool { pendingPopups.contains(where: \.isAvailable) }
    /// Monotonic counter bumped whenever an automated action opens a hidden popup, so tools can report it.
    private(set) var deferredPopupSequence = 0
    /// Open `window.open` popups of this tab.
    private var popups: [BrowserPopup] = []
    /// Active browser-tool calls currently running on this tab.
    private(set) var activeAutomationCount = 0
    /// Active interactive background tool calls (`background: true`) on this tab.
    private(set) var backgroundAutomationCount = 0
    /// Brief grace window after a background tool call ends so asynchronous WebKit `el.focus()` IPC cannot steal firstResponder.
    private var suppressFirstResponderUntil: Date?
    private var blockedOpenPanelDuringAutomation = false
    private let provenanceToken = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var pendingOpenCause: (cause: OpenCause, at: Date)?
    private var promptTask: Task<Void, Never>?
    /// The page work the person started from this tab's toolbar (picking an element, filling a login, saving the page as a PDF): a new run
    /// of a kind replaces the one before it, and closing the tab cancels what is left (`AR-19`).
    private let tasks = TaskBag()
    /// The terminal tab running the dev server this preview started, if any.
    var previewTerminalID: UUID?
    /// The user is choosing an element on the page (Pick Element).
    @Published private(set) var isPicking = false
    /// The window of this tab: it opens links in new tabs, takes a picked element to the AI and runs Preview Web App's dev server.
    private(set) weak var host: (any BrowserSessionHost)?
    /// The outcome of the last pick ("Pasted into Claude", an error), shown briefly.
    @Published var pickNotice: String?
    private(set) var isClosed = false
    /// The window's Preview Web App tab (Preview Web App reuses it).
    var isAppPreview = false
    /// An agent drives this tab (`BrowserAgentExecutor`): page dialogs are answered at once and
    /// recorded in `agentDialogs` instead of stopping the page behind a modal alert.
    var agentControlled = false
    var agentDialogs: [String] = []
    let agentFrames = BrowserAgentExecutor.Frames()
    /// The name agents and the user call this tab by: T1, T2… or one the user gave ("Jira").
    @Published var agentName = "T1"
    /// The user stopped agents from using this tab; tool calls are refused until allowed again.
    @Published var agentStopped = false
    /// When an agent last used this tab (the tab shows that an agent is at work).
    @Published var agentLastUsed: Date?

    func requestMarkdownSave(_ mode: PageCapture.Mode) { saveRequest = mode }
    func requestPDFSave() { saveFormat = .pdf; saveRequest = .page }

    var suppressesFirstResponder: Bool {
        if backgroundAutomationCount > 0 { return true }
        if let until = suppressFirstResponderUntil, Date() < until { return true }
        return false
    }

    func noteManualInteraction() {
        suppressFirstResponderUntil = nil
        if activeAutomationCount == 0 {
            agentControlled = false
            pendingOpenCause = nil
        }
    }

    func beginAutomation(background: Bool) {
        activeAutomationCount += 1
        if background { backgroundAutomationCount += 1 }
        agentControlled = true
        blockedOpenPanelDuringAutomation = false
    }

    func endAutomation(background: Bool) {
        activeAutomationCount = max(0, activeAutomationCount - 1)
        if background {
            backgroundAutomationCount = max(0, backgroundAutomationCount - 1)
            suppressFirstResponderUntil = Date().addingTimeInterval(0.35)
        }
    }

    func consumeBlockedOpenPanel() -> Bool {
        let value = blockedOpenPanelDuringAutomation
        blockedOpenPanelDuringAutomation = false
        return value
    }

    /// Ensure an unmounted background web view has a realistic viewport frame so layout and snapshots work.
    func ensureBackgroundLayoutFrame() {
        let view = webView
        if view.window == nil && (view.bounds.width < 1 || view.bounds.height < 1) {
            view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        }
    }

    /// Explicitly displays a pending hidden sign-in popup on user request (DEC-002).
    /// Returns `false` and sets `unavailablePopupNotice` if the popup is no longer available.
    @discardableResult
    func openPendingPopup(_ id: UUID? = nil) -> Bool {
        let targetID = id ?? pendingPopups.last?.id
        guard let targetID, let index = pendingPopups.firstIndex(where: { $0.id == targetID }) else {
            unavailablePopupNotice = "The sign-in window is no longer available. Start sign-in again manually on this page."
            return false
        }
        guard pendingPopups[index].isAvailable,
              let popup = popups.first(where: { $0.id == targetID }),
              !popup.isClosed else {
            pendingPopups.remove(at: index)
            unavailablePopupNotice = "The sign-in window is no longer available. Start sign-in again manually on this page."
            return false
        }
        pendingPopups.remove(at: index)
        unavailablePopupNotice = nil
        popup.show()
        return true
    }

    func dismissPendingPopup(_ id: UUID) {
        pendingPopups.removeAll { $0.id == id }
        if let popup = popups.first(where: { $0.id == id }) {
            popup.close()
        }
    }

    func clearUnavailablePopupNotice() {
        unavailablePopupNotice = nil
    }

    /// Exposes live popups for verification tests without surfacing raw windows to unrelated views.
    var openPopupCount: Int { popups.count }
    var visiblePopupCount: Int { popups.filter(\.isVisible).count }
    func livePopup(id: UUID) -> BrowserPopup? { popups.first { $0.id == id } }

    private func handlePopupClosed(_ closed: BrowserPopup) {
        popups.removeAll { $0 === closed }
        if let index = pendingPopups.firstIndex(where: { $0.id == closed.id }) {
            pendingPopups[index].isAvailable = false
        }
    }

    private func updatePendingPopupMetadata(_ popup: BrowserPopup) {
        guard let index = pendingPopups.firstIndex(where: { $0.id == popup.id }) else { return }
        pendingPopups[index].url = popup.currentURL ?? pendingPopups[index].url
        pendingPopups[index].title = popup.currentTitle
    }

    private func resolveOpenCause(for navigationAction: WKNavigationAction) -> OpenCause {
        if let pending = pendingOpenCause {
            pendingOpenCause = nil
            if Date().timeIntervalSince(pending.at) < 2.0 {
                return pending.cause
            }
        }
        if activeAutomationCount > 0 { return .automated }
        if webView.window == nil { return .automated }
        return .manual
    }

    private(set) lazy var webView: BrowserWebView = makeWebView()
    private var observations: [NSKeyValueObservation] = []
    private var failedURL: URL?
    private var passwordHandler: BrowserPasswordHandler?

    /// The converter script, from the editor bundle (overridable for tests outside the app).
    static var captureScriptURL = Bundle.main.url(forResource: "markview-page-markdown", withExtension: "js",
                                                  subdirectory: "Editor/js")

    /// The element picker script, from the editor bundle.
    static var pickScriptURL = Bundle.main.url(forResource: "markview-pick-element", withExtension: "js",
                                               subdirectory: "Editor/js")

    /// Where the page keeps its cookies and storage; nil is the browser's shared store. A QA player gets a store of its own
    /// (`.nonPersistent()`), so players never share a sign-in.
    private let dataStore: WKWebsiteDataStore?
    /// Page channels the owner of the session adds to the tab's own (the QA player's fault counter).
    private let extraHandlers: [WebHost.Handler]
    /// How a page's own `alert` and `confirm` reach the person (`AR-22`). A session nobody can be asked from (a QA player) has `NoPrompts`.
    private let prompts: any UserPrompts

    init(url: URL?, dataStore: WKWebsiteDataStore? = nil, extraHandlers: [WebHost.Handler] = [], host: (any BrowserSessionHost)? = nil,
         prompts: any UserPrompts) {
        self.host = host
        self.prompts = prompts
        self.url = url
        self.dataStore = dataStore
        self.extraHandlers = extraHandlers
        super.init()
    }

    /// The tab's name: the page title, else its host and port.
    var displayTitle: String {
        if !title.isEmpty { return title }
        guard let url else { return "New Tab" }
        if let host = url.host { return host + (url.port.map { ":\($0)" } ?? "") }
        return url.absoluteString
    }

    private func makeWebView() -> BrowserWebView {
        let passwords = BrowserPasswordHandler()
        passwords.session = self
        passwordHandler = passwords
        var scripts = [
            agentFrames.webHostScript,
            // Causal provenance for automated vs manual new-tab and popup requests (DEC-001, DEC-002).
            WKUserScript(source: BrowserAgentExecutor.Scripts.provenance(token: provenanceToken),
                         injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            // The page's console and uncaught errors, kept for agents (`browser_console`).
            WKUserScript(source: Self.consoleCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page),
        ]
        for url in [Self.captureScriptURL, Self.pickScriptURL] {
            if let url, let source = try? String(contentsOf: url, encoding: .utf8) {
                scripts.append(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            }
        }
        scripts.append(WKUserScript(source: BrowserPasswordScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let configuration = WebHost.makeConfiguration(
            dataStore: dataStore.map(WebHost.DataStore.store) ?? .default,
            handlers: [agentFrames.webHostHandler, .message(BrowserPasswordScript.handlerName, passwords, in: .defaultClient)] + extraHandlers,
            userScripts: scripts,
            allowsPopups: true,
            allowsElementFullscreen: true,
            // Sign-in pages (Google) refuse an embedded browser that does not name itself a Safari.
            applicationName: "Version/17.0 Safari/605.1.15")
        let view = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        WebHost.markInspectable(view)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.saveDelegate = self
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url { self?.url = url } }
            },
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
        if let url {
            if url.isFileURL {
                let folder = url.deletingLastPathComponent()
                let root = localReadRoot.flatMap { folder.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) ? $0 : nil }
                view.loadFileURL(url, allowingReadAccessTo: root ?? folder)
            } else {
                view.load(URLRequest(url: url))
            }
        }
        return view
    }

    /// An Electron app's renderer shown as a web page: its preload APIs do not exist here, so
    /// `window.electron`, `window.api` and similar become no-op stand-ins (each call warns once in
    /// the page's console) instead of errors that stop the page.
    func standInForElectron() {
        guard !electronStandIns else { return }
        electronStandIns = true
        webView.configuration.userContentController.addUserScript(WKUserScript(
            source: Self.electronStandInScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private var electronStandIns = false

    static let consoleCaptureScript = #"""
    (function () {
      if (window.__mvConsole) return;
      var log = window.__mvConsole = [];
      function push(level, args) {
        try {
          var text = Array.prototype.map.call(args, function (a) {
            if (a instanceof Error) return a.stack || String(a);
            if (a && typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
            return String(a);
          }).join(' ');
          log.push(level + ': ' + text.slice(0, 2000));
          if (log.length > 500) log.shift();
        } catch (e) {}
      }
      ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
        var original = console[level];
        console[level] = function () { push(level, arguments); return original.apply(console, arguments); };
      });
      window.addEventListener('error', function (e) { push('error', [e.message + ' (' + e.filename + ':' + e.lineno + ')']); });
      window.addEventListener('unhandledrejection', function (e) {
        push('error', ['Unhandled rejection: ' + ((e.reason && e.reason.stack) || e.reason)]);
      });
    })();
    """#

    static let electronStandInScript = #"""
    (function () {
      if (window.__markviewElectronStandIn) return;
      window.__markviewElectronStandIn = true;
      var warned = {};
      function standIn(path) {
        return new Proxy(function () {}, {
          get: function (_, key) {
            if (key === 'then') return undefined;
            if (key === Symbol.iterator) return function* () {};
            if (key === Symbol.toPrimitive) return function () { return ''; };
            if (typeof key === 'symbol') return undefined;
            return standIn(path + '.' + String(key));
          },
          apply: function () {
            if (!warned[path]) {
              warned[path] = true;
              console.warn('[MarkView web preview] ' + path + '() needs Electron; it does nothing in the browser.');
            }
            return standIn(path + '()');
          }
        });
      }
      ['electron', 'api', 'ipcRenderer', 'electronAPI', 'bridge', 'desktop'].forEach(function (name) {
        if (!(name in window)) window[name] = standIn('window.' + name);
      });
    })();
    """#

    /// Folder a local page may read (its stylesheets, scripts and images); nil = the page's own folder.
    var localReadRoot: URL?

    func load(_ url: URL) {
        loadError = nil
        preview = nil
        self.url = url
        // A local page (opened from a terminal) may read the files next to it.
        if url.isFileURL {
            let folder = url.deletingLastPathComponent()
            let root = localReadRoot.flatMap { folder.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path) ? $0 : nil }
            webView.loadFileURL(url, allowingReadAccessTo: root ?? folder)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    /// The previewed app answers at `url`: leave the waiting state and show it.
    func showPreview(_ url: URL) {
        preview = nil
        load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    func reload() {
        if let failedURL, loadError != nil {
            load(failedURL)
        } else if webView.url == nil, let url {
            load(url)
        } else {
            loadError = nil
            webView.reload()
        }
    }

    func stopLoading() { webView.stopLoading() }

    /// The tab is closing: stop the page (media, timers, connections to the dev server).
    func close() {
        isClosed = true
        observations = []
        tasks.cancelAll()
        promptTask?.cancel()
        passwordPrompt = nil
        pendingPopups = []
        unavailablePopupNotice = nil
        for popup in popups { popup.close() }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: BrowserPasswordScript.handlerName, contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: BrowserAgentExecutor.Frames.handler, contentWorld: .defaultClient)
        agentFrames.reset()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    /// Lets the user choose an element on the page, then hands it over with a screenshot.
    func pickElement() async {
        guard !isPicking else { return }
        isPicking = true
        defer { isPicking = false }
        pickNotice = nil
        do {
            let result = try await webView.callAsyncJavaScript(
                "return window.markviewPickElement ? await window.markviewPickElement() : undefined;",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            guard let object = result as? [String: Any] else {
                if result == nil { pickNotice = "This page cannot be picked from yet. Wait for it to load." }
                return
            }
            guard let element = PickedElement(object) else {
                pickNotice = "That element has no size to capture."
                return
            }
            // The highlight must not be in the screenshot.
            _ = try? await webView.callAsyncJavaScript(
                "window.markviewPickHide && window.markviewPickHide();", arguments: [:], in: nil, contentWorld: .defaultClient)
            try? await Task.sleep(nanoseconds: 60_000_000)
            let screenshot = await snapshot(of: element)
            host?.browserSession(self, picked: element, screenshot: screenshot)
        } catch {
            pickNotice = "The page changed before an element was chosen."
        }
    }

    /// Starts `pickElement` for the toolbar button.
    func startPickElement() {
        tasks.store(Task { [weak self] in await self?.pickElement() }, for: "pick")
    }

    /// Starts `fillPassword` for a menu item: the login of `username`, or the only one.
    func startFillPassword(username: String?) {
        tasks.store(Task { [weak self] in await self?.fillPassword(username: username) }, for: "fill-password")
    }

    /// Renders the whole page to PDF for the save sheet; `finished` gets the document or the reason, and `CancellationError` when the
    /// tab closed or a second render replaced this one.
    func startPagePDF(finished: @escaping (Result<Data, Error>) -> Void) {
        tasks.store(Task { [weak self] in
            guard let self else { return finished(.failure(CancellationError())) }
            do {
                let data = try await pagePDF()
                finished(Task.isCancelled ? .failure(CancellationError()) : .success(data))
            } catch {
                finished(.failure(Task.isCancelled ? CancellationError() : error))
            }
        }, for: "page-pdf")
    }

    func cancelPick() {
        // task: one call into the page that ends at once; it touches only the web view
        Task { _ = try? await webView.callAsyncJavaScript(
            "window.markviewPickCancel && window.markviewPickCancel();", arguments: [:], in: nil, contentWorld: .defaultClient) }
    }

    /// The element's pixels as a PNG file (what is visible of it: it is cut at the window's edge).
    private func snapshot(of element: PickedElement) async -> URL? {
        let zoom = webView.pageZoom
        let view = webView.bounds
        let rect = CGRect(x: element.x * zoom, y: element.y * zoom, width: element.width * zoom, height: element.height * zoom)
            .intersection(view)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
        guard let tiff = image?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let file = BrowserElementPick.screenshotURL()
        return (try? AtomicFile.write(png, to: file)) != nil ? file : nil
    }

    /// The selection or the whole page as Markdown.
    func capture(_ mode: PageCapture.Mode) async throws -> PageCapture {
        let result = try await webView.callAsyncJavaScript(
            "return window.markviewPageMarkdown ? window.markviewPageMarkdown(mode) : null;",
            arguments: ["mode": mode.rawValue], in: nil, contentWorld: .defaultClient)
        guard let object = result as? [String: Any] else {
            throw CaptureError.unavailable
        }
        return PageCapture(title: object["title"] as? String ?? "",
                           url: (object["url"] as? String).flatMap(URL.init(string:)),
                           markdown: object["markdown"] as? String ?? "",
                           hasSelection: object["hasSelection"] as? Bool ?? false)
    }

    enum CaptureError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This page cannot be read yet. Wait for it to load and try again." }
    }
}

extension BrowserSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A link with a `download` attribute (also a blob: or data: one) is a download, not a page.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "about", "data", "blob", "file", "ws", "wss"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // mailto:, tel:, app links: their own apps (only for manual browsing, never during background automation).
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated && activeAutomationCount == 0 && webView.window != nil {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // A file the server sends as an attachment is saved even when the browser could show it.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        let attachment = disposition.trimmingCharacters(in: .whitespaces).hasPrefix("attachment")
        decisionHandler(attachment || !(navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        agentFrames.reset()
        loadError = nil
        failedURL = nil
        fillOffer = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let error = error as NSError
        // A new navigation replaced this one, or a download took it over.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        failedURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url
        if let host = failedURL?.host, BrowserAddress.isLocal(host), error.code == NSURLErrorCannotConnectToHost {
            let port = failedURL?.port.map { ":\($0)" } ?? ""
            loadError = "Nothing is answering at \(host)\(port). Is the development server running?"
        } else {
            loadError = error.localizedDescription
        }
    }

    /// Development servers on this machine often use self-signed certificates.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           BrowserAddress.isLocal(challenge.protectionSpace.host), let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.shouldPerformDownload {
            webView.startDownload(using: navigationAction.request) { [weak self] download in download.delegate = self }
            return nil
        }
        let cause = resolveOpenCause(for: navigationAction)
        // A script's popup (sign-in) stays a window linked to its page; links open as tabs.
        if BrowserPopup.isPopup(windowFeatures) {
            let popup = BrowserPopup(configuration: configuration, features: windowFeatures)
            let popupID = popup.id
            popup.onClose = { [weak self] closed in self?.handlePopupClosed(closed) }
            popups.append(popup)
            if cause == .automated {
                deferredPopupSequence += 1
                unavailablePopupNotice = nil
                pendingPopups.append(PendingPopupInfo(id: popupID, url: navigationAction.request.url, title: "", isAvailable: true))
                popup.onMetadataChange = { [weak self] changed in self?.updatePendingPopupMetadata(changed) }
                // Keep hidden while preserving window.opener until the user explicitly opens it (DEC-002).
            } else {
                popup.show()
            }
            return popup.webView
        }
        if let url = navigationAction.request.url {
            if let host { host.browserSession(self, openInNewTab: url, activate: cause == .manual) } else { load(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        let prefix = "__mv_cause_\(provenanceToken):"
        if prompt.hasPrefix(prefix) {
            let value = String(prompt.dropFirst(prefix.count))
            if value == "auto" { pendingOpenCause = (.automated, Date()) }
            else if value == "manual" { pendingOpenCause = (.manual, Date()) }
            completionHandler("")
            return
        }
        if agentControlled {
            agentDialogs.append("prompt: " + prompt)
            completionHandler(defaultText)
            return
        }
        completionHandler(nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        if agentControlled {
            agentDialogs.append("alert: " + message)
            completionHandler()
            return
        }
        prompts.inform(frame.request.url?.host ?? "Page", message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        if agentControlled {
            agentDialogs.append("confirm (answered OK): " + message)
            completionHandler(true)
            return
        }
        let question = UserPrompt(title: frame.request.url?.host ?? "Page", detail: message, buttons: ["OK", "Cancel"])
        completionHandler(prompts.confirm(question, proceedingWith: 0))
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        if backgroundAutomationCount > 0 || (activeAutomationCount > 0 && webView.window == nil) {
            blockedOpenPanelDuringAutomation = true
            completionHandler(nil)
            return
        }
        // The person is asked through the tab's prompter (`AR-22`): the app shows its panel, a QA player gives its built-in picture.
        completionHandler(prompts.chooseFiles(allowsMultiple: parameters.allowsMultipleSelection, allowsDirectories: parameters.allowsDirectories))
    }
}

extension BrowserSession: WKDownloadDelegate {
    /// Downloads go to ~/Downloads under the suggested name, never over an existing file.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let target = BrowserDownloads.freeURL(in: folder, suggestedName: suggestedFilename) { FileManager.default.fileExists(atPath: $0.path) }
        downloadTargets[ObjectIdentifier(download)] = target
        self.download = .running(target.lastPathComponent)
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let target = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        self.download = .finished(target)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let name = downloadTargets.removeValue(forKey: ObjectIdentifier(download))?.lastPathComponent ?? "the file"
        self.download = .failed("Could not download \(name): \(error.localizedDescription)")
    }
}

// MARK: - Saved passwords

extension BrowserSession {
    /// The tab is driven by an agent (now or a moment ago): nothing is filled into its pages.
    var agentBusy: Bool {
        agentControlled || (agentLastUsed.map { Date().timeIntervalSince($0) < 120 } ?? false)
    }

    /// A login form was submitted on `host`: offer to save the password, or to update it.
    func loginSubmitted(host: String, username: String, password: String) {
        guard !password.isEmpty, !PasswordRules.neverHosts().contains(host) else { return }
        let saved = BrowserPasswordStore.shared.password(host: host, username: username)
        if saved == password { return }
        passwordPrompt = PasswordPrompt(host: host, username: username, password: password, isUpdate: saved != nil)
        promptTask?.cancel()
        // The password is held only for a while; after that the offer is gone.
        promptTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            if !Task.isCancelled { self?.passwordPrompt = nil }
        }
    }

    func savePasswordPrompt() {
        guard let prompt = passwordPrompt else { return }
        BrowserPasswordStore.shared.save(host: prompt.host, username: prompt.username, password: prompt.password)
        dismissPasswordPrompt()
    }

    func dismissPasswordPrompt(neverForSite: Bool = false) {
        if neverForSite, let host = passwordPrompt?.host { PasswordRules.neverSave(host: host) }
        promptTask?.cancel()
        passwordPrompt = nil
    }

    /// The page shows (or no longer shows) a password field.
    func loginFormChanged(host: String, present: Bool) {
        guard present, !agentBusy, host == PasswordRules.host(of: webView.url) else { fillOffer = nil; return }
        let usernames = BrowserPasswordStore.shared.all().filter { $0.host == host }.map(\.username)
        fillOffer = usernames.isEmpty ? nil : PasswordFillOffer(host: host, usernames: usernames)
    }

    /// Fill the saved login of the page's site into its login form, on the person's request.
    /// The logins are those of the exact host the page is on now.
    @discardableResult
    func fillPassword(username: String? = nil) async -> Bool {
        guard !agentBusy, let url = webView.url, let scheme = url.scheme, let host = PasswordRules.host(of: url),
              PasswordRules.isEligible(scheme: scheme, host: host) else { return false }
        let logins = BrowserPasswordStore.shared.logins(for: host)
        guard !logins.isEmpty else { return false }
        let arguments: [String: Any] = ["logins": logins.map { ["username": $0.username, "password": $0.password] },
                                        "username": username ?? ""]
        let filled = try? await webView.callAsyncJavaScript(
            "return window.__mvFill ? window.__mvFill(logins, username) : false;",
            arguments: arguments, in: nil, contentWorld: .defaultClient)
        return filled as? Bool ?? false
    }
}

@MainActor
protocol BrowserSaveDelegate: AnyObject {
    var suppressesFirstResponder: Bool { get }
    func requestMarkdownSave(_ mode: PageCapture.Mode)
    func requestPDFSave()
    func noteManualInteraction()
}

/// The page's context menu gets "Save Selection / Page as Markdown".
final class BrowserWebView: WKWebView {
    weak var saveDelegate: (any BrowserSaveDelegate)?

    override var acceptsFirstResponder: Bool {
        if saveDelegate?.suppressesFirstResponder == true, !isHandlingUserFocusEvent {
            return false
        }
        return super.acceptsFirstResponder
    }

    override func becomeFirstResponder() -> Bool {
        if saveDelegate?.suppressesFirstResponder == true, !isHandlingUserFocusEvent {
            return false
        }
        return super.becomeFirstResponder()
    }

    private var isHandlingUserFocusEvent: Bool {
        guard let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard window != nil else { return false }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point)
        case .keyDown:
            return event.keyCode == 48
        default:
            return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        saveDelegate?.noteManualInteraction()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        saveDelegate?.noteManualInteraction()
        super.keyDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit offers Copy only when something is selected.
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        var items: [NSMenuItem] = []
        if hasSelection {
            items.append(menuItem("Save Selection as Markdown…", action: #selector(saveSelection)))
        }
        items.append(menuItem("Save Page as Markdown…", action: #selector(savePage)))
        items.append(menuItem("Save Page as PDF…", action: #selector(savePageAsPDF)))
        items.append(.separator())
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func saveSelection() { saveDelegate?.requestMarkdownSave(.selection) }
    @objc private func savePage() { saveDelegate?.requestMarkdownSave(.page) }
    @objc private func savePageAsPDF() { saveDelegate?.requestPDFSave() }
}
