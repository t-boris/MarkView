import AppKit
import WebKit

/// What the address field turns into a URL: a full URL as typed, `localhost:5173` or an
/// address of this machine over http, a host name over https, anything else a web search.
enum BrowserAddress {
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           ["http", "https", "file", "about"].contains(scheme), scheme == "about" || url.host != nil || scheme == "file" {
            return url
        }
        if !text.contains(" "), let candidate = URL(string: "http://" + text), let host = candidate.host {
            if isLocal(host) { return candidate }
            if host.contains("."), host.split(separator: ".").last.map({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) == true {
                return URL(string: "https://" + text)
            }
        }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }

    /// Loopback names, this Mac's `.local` name and private IPv4 ranges: development servers.
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, host.split(separator: ".").count == 4 else { return false }
        return parts[0] == 127 || parts[0] == 10 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}

/// The page or its selection as Markdown, from `markview-page-markdown.js`.
struct PageCapture {
    enum Mode: String { case selection, page }
    var title: String
    var url: URL?
    var markdown: String
    var hasSelection: Bool
}

/// What a preview tab shows while it looks for the project's web app.
enum WebPreviewState: Equatable {
    case searching
    /// Several apps in the project: the user picks one.
    case choose([WebAppTarget])
    /// Waiting for the app's server; `started` once MarkView ran its dev script.
    case starting(WebAppTarget, started: Bool)
    case timedOut(WebAppTarget)
    case noApp
}

/// Reads a dev server's terminal output for the first local address it prints.
@MainActor
final class DevServerWatch {
    private var tail = ""
    private(set) var url: URL?

    func read(_ data: Data) {
        guard url == nil else { return }
        tail += String(decoding: data, as: UTF8.self)
        if tail.count > 16_000 { tail = String(tail.suffix(8_000)) }
        url = WebAppPreview.firstLocalURL(in: tail)
    }
}

/// One browser tab: its web view and what the tab bar and the toolbar show. Links that
/// ask for a new window open as new browser tabs; other schemes go to their apps.
@MainActor
final class BrowserSession: NSObject, ObservableObject {
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
    /// The terminal tab running the dev server this preview started, if any.
    var previewTerminalID: UUID?
    var startWebApp: ((WebAppTarget) -> Void)?
    var showTerminal: (() -> Void)?
    private(set) var isClosed = false
    /// The window's Preview Web App tab (Preview Web App reuses it).
    var isAppPreview = false
    /// Context menu "Save … as Markdown".
    var onSaveMarkdown: ((PageCapture.Mode) -> Void)?
    /// `target="_blank"` links and `window.open`.
    var onOpenInNewTab: ((URL) -> Void)?
    /// An agent drives this tab (`BrowserAgentExecutor`): page dialogs are answered at once and
    /// recorded in `agentDialogs` instead of stopping the page behind a modal alert.
    var agentControlled = false
    var agentDialogs: [String] = []
    /// The name agents and the user call this tab by: T1, T2… or one the user gave ("Jira").
    @Published var agentName = "T1"
    /// The user stopped agents from using this tab; tool calls are refused until allowed again.
    @Published var agentStopped = false
    /// When an agent last used this tab (the tab shows that an agent is at work).
    @Published var agentLastUsed: Date?

    private(set) lazy var webView: BrowserWebView = makeWebView()
    private var observations: [NSKeyValueObservation] = []
    private var failedURL: URL?

    /// The converter script, from the editor bundle (overridable for tests outside the app).
    static var captureScriptURL = Bundle.main.url(forResource: "markview-page-markdown", withExtension: "js",
                                                  subdirectory: "Editor/vendor/js")

    init(url: URL?) {
        self.url = url
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
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        // The page's console and uncaught errors, kept for agents (`browser_console`).
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.consoleCaptureScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let scriptURL = Self.captureScriptURL, let source = try? String(contentsOf: scriptURL, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        }
        let view = BrowserWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.saveMarkdown = { [weak self] mode in self?.onSaveMarkdown?(mode) }
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
        if let url { view.load(URLRequest(url: url)) }
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

    func load(_ url: URL) {
        loadError = nil
        preview = nil
        self.url = url
        // A local page (opened from a terminal) may read the files next to it.
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
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
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "about", "data", "blob", "file", "ws", "wss"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            // mailto:, tel:, app links: their own apps.
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
        failedURL = nil
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
        if let url = navigationAction.request.url {
            if let onOpenInNewTab { onOpenInNewTab(url) } else { load(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        if agentControlled {
            agentDialogs.append("alert: " + message)
            completionHandler()
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Page"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        if agentControlled {
            agentDialogs.append("confirm (answered OK): " + message)
            completionHandler(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Page"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

extension BrowserSession: WKDownloadDelegate {
    /// Downloads go to ~/Downloads under the suggested name, never over an existing file.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let name = (suggestedFilename as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {}

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        loadError = "Download failed: \(error.localizedDescription)"
    }
}

/// The page's context menu gets "Save Selection / Page as Markdown".
final class BrowserWebView: WKWebView {
    var saveMarkdown: ((PageCapture.Mode) -> Void)?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // WebKit offers Copy only when something is selected.
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        var items: [NSMenuItem] = []
        if hasSelection {
            items.append(menuItem("Save Selection as Markdown…", action: #selector(saveSelection)))
        }
        items.append(menuItem("Save Page as Markdown…", action: #selector(savePage)))
        items.append(.separator())
        for (index, item) in items.enumerated() { menu.insertItem(item, at: index) }
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func saveSelection() { saveMarkdown?(.selection) }
    @objc private func savePage() { saveMarkdown?(.page) }
}
