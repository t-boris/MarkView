import SwiftUI
import WebKit
import Combine

/// NSViewRepresentable wrapper for WKWebView markdown editor
struct EditorView: NSViewRepresentable {
    @EnvironmentObject var workspaceManager: WorkspaceManager
    @EnvironmentObject var themeManager: ThemeManager

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userController = WKUserContentController()

        // Set up script message handler — name must match JS: window.webkit.messageHandlers.bridge
        let bridge = context.coordinator.bridge
        userController.add(bridge, name: "bridge")

        config.userContentController = userController
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        // Read the HTML template and inject the current theme
        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor") ??
           Bundle.main.url(forResource: "index", withExtension: "html"),
           var html = try? String(contentsOf: htmlURL, encoding: .utf8) {
            let currentTheme = themeManager.effectiveTheme == .dark ? "dark" : "light"
            html = html.replacingOccurrences(of: "data-theme=\"dark\"", with: "data-theme=\"\(currentTheme)\"")
            context.coordinator.editorHTML = html
        }

        // Always load the editor from the app bundle so local vendor assets resolve reliably.
        context.coordinator.loadEditorPage()

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator

        // Load content when tab changes
        if workspaceManager.activeTabIndex >= 0,
           workspaceManager.activeTabIndex < workspaceManager.openTabs.count {
            let tab = workspaceManager.openTabs[workspaceManager.activeTabIndex]
            coordinator.pendingTab = tab
            coordinator.loadContentIfNeeded(tab.content, documentURL: tab.url, tab: tab)
        }

        // Update theme
        coordinator.setTheme(themeManager.effectiveTheme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: EditorView
        let bridge = WebViewBridge()
        weak var webView: WKWebView?

        var editorHTML: String?
        private let editorResourceBaseURL: URL
        private var currentDocumentBaseURL: URL?
        private var lastLoadedContent: String = ""
        private var lastTheme: Theme?
        private var isEditorReady = false
        private var pendingContent: String?
        private var pendingDocumentURL: URL?
        /// Cache of the last `OpenTab` requested by `updateNSView` — read by
        /// `webView(_:didFinish:)` (the second `loadContentIfNeeded` call site) so it
        /// can route by `tab.kind` instead of falling back to the file-only path.
        var pendingTab: OpenTab?
        private var pdfExportObserver: Any?
        private var scrollToHeadingObserver: Any?

        // MARK: Insight subscription state (Recursive Insight v2, Task 7)

        /// Combine subscriptions for the currently routed insight session. Cleared on
        /// every kind switch (and on switch to a different insight session) to avoid
        /// retain cycles and stale forwarding.
        var insightCancellables = Set<AnyCancellable>()
        /// id (uuidString) of the insight session the coordinator is currently subscribed
        /// to. nil for `.file` tabs. Used to early-return on duplicate `loadContentIfNeeded`
        /// calls for the same insight session.
        var currentInsightSessionId: String?
        /// Per-section forwarded length (Swift `String.count`) — keyed by
        /// `InsightSection.id`. The next `$currentNodeSections` emission forwards
        /// only `String(buffer.dropFirst(lastForwardedSectionLength[id, default: 0]))`
        /// for each section. Cleared on every `$skeleton` emission (skeleton replace
        /// = new node = new section ids). Per-key shrink-detection: if the section's
        /// buffer becomes shorter than the cursor (retry path replaced the buffer),
        /// the cursor is reset to 0 and the whole new buffer is forwarded.
        var lastForwardedSectionLength: [String: Int] = [:]

        init(_ parent: EditorView) {
            self.parent = parent
            self.editorResourceBaseURL = Self.resolveEditorResourceBaseURL()
            super.init()
            bridge.delegate = self

            // Listen for PDF export requests
            pdfExportObserver = NotificationCenter.default.addObserver(
                forName: .performPDFExport,
                object: nil, queue: .main
            ) { [weak self] notification in
                let fileName = notification.object as? String ?? "document.pdf"
                self?.exportPDF(fileName: fileName)
            }

            // Listen for TOC scroll-to-heading requests
            scrollToHeadingObserver = NotificationCenter.default.addObserver(
                forName: .scrollToHeading,
                object: nil, queue: .main
            ) { [weak self] notification in
                if let headingId = notification.object as? String {
                    self?.scrollToHeading(headingId)
                }
            }

            // Listen for scroll-to-text requests (from Semantic Panel)
            NotificationCenter.default.addObserver(
                forName: .scrollToText,
                object: nil, queue: .main
            ) { [weak self] notification in
                if let text = notification.object as? String {
                    self?.scrollToText(text)
                }
            }
        }

        deinit {
            if let observer = pdfExportObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scrollToHeadingObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        // MARK: - Page Loading

        /// Load the editor HTML from the app bundle so bundled vendor assets remain available.
        func loadEditorPage() {
            guard let webView = webView, let html = editorHTML else { return }
            isEditorReady = false
            lastLoadedContent = ""
            webView.loadHTMLString(html, baseURL: editorResourceBaseURL)
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isEditorReady = true
            // Probe: did the inline <script> in index.html actually execute and
            // define our v2 functions? Result is independent of any bridge call.
            let probeJS = """
            (function() {
                try {
                    var scripts = Array.from(document.scripts).map(function(s, i) {
                        return { i: i, src: s.src || '', tlen: s.textContent ? s.textContent.length : 0, type: s.type || '' };
                    });
                    var inlineScripts = scripts.filter(function(s) { return s.tlen > 0; });
                    return JSON.stringify({
                        bridgeAvailable: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bridge),
                        loadInsightSkeleton: typeof window.loadInsightSkeleton,
                        setContent: typeof window.setContent,
                        scriptCount: scripts.length,
                        inlineScriptCount: inlineScripts.length,
                        inlineScriptTotalLen: inlineScripts.reduce(function(a,s){return a+s.tlen;}, 0),
                        firstInlineLen: inlineScripts[0] ? inlineScripts[0].tlen : 0,
                        firstInlineHead: inlineScripts[0] ? document.scripts[inlineScripts[0].i].textContent.substr(0, 200) : '',
                        readyState: document.readyState,
                        href: location.href,
                        bodyLen: document.body ? document.body.innerHTML.length : -1,
                        htmlLen: document.documentElement ? document.documentElement.outerHTML.length : -1
                    });
                } catch (e) { return 'probe-threw: ' + String(e); }
            })()
            """
            webView.evaluateJavaScript(probeJS) { result, error in
                if let error = error {
                    WebViewBridge.logInsightDiag("didFinish PROBE error=\(error.localizedDescription)")
                } else {
                    WebViewBridge.logInsightDiag("didFinish PROBE result=\(String(describing: result).prefix(600))")
                }
            }
            // Load any pending content
            if let content = pendingContent {
                let docURL = pendingDocumentURL
                let tab = pendingTab
                pendingContent = nil
                pendingDocumentURL = nil
                // pendingTab intentionally retained — `updateNSView` re-writes it on
                // every redraw and subsequent `loadContentIfNeeded` calls read it.
                loadContentIfNeeded(content, documentURL: docURL, tab: tab)
            }
        }

        func webView(_ webView: WKWebView,
                      decidePolicyFor navigationAction: WKNavigationAction,
                      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Allow programmatic loads (initial page load, evaluateJavaScript, etc.)
            if navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""

            // Fragment-only navigation (anchor links within the page)
            if url.fragment != nil, url.path == webView.url?.path {
                decisionHandler(.allow)
                return
            }

            // Local .md file links → open in a new tab
            if scheme == "file" {
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" {
                    decisionHandler(.cancel)
                    Task { @MainActor in
                        self.parent.workspaceManager.openFile(url)
                    }
                    return
                }
                // Other local files → open in Finder/default app
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
                return
            }

            // External links → open in default browser
            if scheme == "http" || scheme == "https" || scheme == "mailto" {
                decisionHandler(.cancel)
                NSWorkspace.shared.open(url)
                return
            }

            // Everything else → cancel for safety
            decisionHandler(.cancel)
        }

        // MARK: - Content Management

        func loadContentIfNeeded(_ markdown: String, documentURL: URL? = nil, tab: OpenTab? = nil) {
            guard let webView = webView else { return }

            guard isEditorReady else {
                pendingContent = markdown
                pendingDocumentURL = documentURL
                // pendingTab is set by updateNSView; webView(_:didFinish:) will read it.
                return
            }

            // Route by tab kind. `.insight` branches early — completely bypasses the
            // standard markdown loading pipeline (no setDocumentBase, no image resolve,
            // no setContent). `.file` (or no tab — initial-load fallback) flows through
            // the existing path unchanged.
            let kind: TabKind = tab?.kind ?? .file
            switch kind {
            case .insight(let session):
                routeInsight(session: session, webView: webView)
                return
            case .file:
                // If we were previously routed to an insight session, drop those subs
                // before falling back to the file pipeline (avoid leaking + stale forward).
                if currentInsightSessionId != nil {
                    insightCancellables.removeAll()
                    currentInsightSessionId = nil
                    lastForwardedSectionLength.removeAll()
                }
            }

            if let documentURL {
                let documentBaseURL = documentURL.deletingLastPathComponent()
                if currentDocumentBaseURL != documentBaseURL {
                    currentDocumentBaseURL = documentBaseURL
                    bridge.setDocumentBase(documentBaseURL, in: webView)
                }
            }

            guard markdown != lastLoadedContent else { return }
            lastLoadedContent = markdown

            // Route by file type
            let fileType = documentURL.map { FileType.from(url: $0) } ?? .markdown
            if fileType != .markdown {
                bridge.loadStructuredContent(markdown, fileType: fileType.rawValue, into: webView) {}
                return
            }

            // Resolve relative image paths to data URIs so WKWebView can display them
            // (WKWebView sandbox blocks direct file:// access to user files)
            let resolved = documentURL != nil
                ? Self.resolveImagePaths(in: markdown, relativeTo: documentURL!)
                : markdown
            bridge.loadContent(resolved, into: webView) {}
        }

        // MARK: - Insight routing (Recursive Insight v2, Task 7)

        /// Route an `.insight` tab to the bridge using the v2 protocol: subscribe to
        /// `session.$skeleton`, `$currentNodeSections`, `$lastError`, `$statusMessage`
        /// and forward to the corresponding `bridge.*` setters. Idempotent: re-rendering
        /// the same session is a no-op (subscriptions are kept). All sinks capture
        /// `[weak self, weak session, weak webView]` to preserve no-retain-cycle invariant.
        private func routeInsight(session: InsightSession, webView: WKWebView) {
            let sessionId = session.id.uuidString

            WebViewBridge.logInsightDiag("routeInsight ENTRY sid=\(sessionId.prefix(8)) currentSid=\(self.currentInsightSessionId?.prefix(8) ?? "nil") skeletonAtEntry=\(session.skeleton == nil ? "nil" : "PRESENT(\(session.skeleton!.sections.count) sections)")")

            // Same session as before — already subscribed and streaming. No-op.
            if currentInsightSessionId == sessionId {
                WebViewBridge.logInsightDiag("routeInsight EARLY-RETURN: same sessionId — subscriptions already wired")
                return
            }

            // Different session (or first .insight after .file) — drop old subs, reset
            // state. The `$skeleton` subscription's first non-nil emission will paint
            // the iframe; if the skeleton is already present it replays on subscribe.
            insightCancellables.removeAll()
            currentInsightSessionId = sessionId
            lastForwardedSectionLength.removeAll()
            // Invalidate file-side dedupe so a subsequent switch back to a .file tab
            // is forced to re-render from scratch (the WebView's content is now insight).
            lastLoadedContent = ""
            currentDocumentBaseURL = nil

            // Wire `WorkspaceManager.releaseInsightBlobsHook` so closeTab Step 1
            // (Decision 11 §4) can synchronously revoke this session's blob URLs
            // BEFORE `await session.cancel()` allows new Combine emissions. Hook
            // captures THIS coordinator's webView + bridge weakly — if the
            // WebView has been deallocated by tab teardown when the hook fires,
            // it no-ops safely (closing the WebView itself GCs the blobs).
            self.parent.workspaceManager.releaseInsightBlobsHook = { [weak self] in
                guard let self = self, let webView = self.webView else { return }
                self.bridge.releaseInsightBlobs(into: webView)
            }

            // Skeleton paint. compactMap drops the initial `nil` (T6 init) so the
            // iframe srcdoc is built only when a real skeleton is available. Reset
            // `lastForwardedSectionLength` BEFORE forwarding so the next
            // `$currentNodeSections` emission computes deltas from 0 against the new
            // section ids (skeleton replace = new node = new section keys).
            WebViewBridge.logInsightDiag("routeInsight SUBSCRIBE \\$skeleton sid=\(sessionId.prefix(8))")
            session.$skeleton
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session, weak webView] skeleton in
                    WebViewBridge.logInsightDiag("\\$skeleton SINK FIRED — self=\(self == nil ? "nil" : "ok") session=\(session == nil ? "nil" : "ok") webView=\(webView == nil ? "nil" : "ok") sections=\(skeleton.sections.count)")
                    guard let self = self,
                          let session = session,
                          let webView = webView else {
                        WebViewBridge.logInsightDiag("\\$skeleton SINK aborted by guard")
                        return
                    }
                    self.lastForwardedSectionLength.removeAll()
                    let nodeId = session.currentNode()?.id.uuidString ?? ""
                    WebViewBridge.logInsightDiag("\\$skeleton SINK calling bridge.loadInsightSkeleton sid=\(session.id.uuidString.prefix(8)) nid=\(nodeId.prefix(8))")
                    self.bridge.loadInsightSkeleton(
                        skeleton: skeleton,
                        sessionId: session.id.uuidString,
                        nodeId: nodeId,
                        into: webView
                    )
                }
                .store(in: &insightCancellables)

            // Per-section streaming deltas. dropFirst() because @Published replays the
            // current dict on subscribe — at session-route time it's either empty or
            // already mid-stream; in either case the skeleton subscription drives the
            // initial paint and we only want subsequent appends here.
            //
            // Per-key delta: for each section, compute the suffix not yet forwarded.
            // Shrink-detection (retry path may replace `buffer` with a shorter retry
            // value): if `state.buffer.count < lastLen` reset cursor to 0 and forward
            // the whole new buffer.
            session.$currentNodeSections
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session, weak webView] sections in
                    guard let self = self,
                          let session = session,
                          let webView = webView else { return }
                    if sections.isEmpty { return }
                    let sid = session.id.uuidString
                    for (sectionId, state) in sections {
                        let bufferLen = state.buffer.count
                        var lastLen = self.lastForwardedSectionLength[sectionId, default: 0]
                        if bufferLen < lastLen {
                            // Shrink: retry replaced the buffer with a shorter value.
                            lastLen = 0
                        }
                        if bufferLen <= lastLen { continue }
                        let delta = String(state.buffer.dropFirst(lastLen))
                        if delta.isEmpty { continue }
                        self.lastForwardedSectionLength[sectionId] = bufferLen
                        self.bridge.updateInsightSection(
                            sessionId: sid,
                            sectionId: sectionId,
                            htmlChunk: delta,
                            into: webView
                        )
                    }
                }
                .store(in: &insightCancellables)

            // Error forwarding. Use the session's lastErrorRetryable flag
            // (Decision 11 §3) — non-retryable errors (noAPIKey, parse failures, 4xx,
            // retry rate limit) must NOT show a [Retry] affordance in JS.
            session.$lastError
                .compactMap { $0 }
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session, weak webView] errorMsg in
                    guard let self = self,
                          let session = session,
                          let webView = webView else { return }
                    self.bridge.setInsightError(
                        sessionId: session.id.uuidString,
                        message: errorMsg,
                        retryable: session.lastErrorRetryable,
                        into: webView
                    )
                }
                .store(in: &insightCancellables)

            // Status bar updates. Filter empty strings INSIDE the sink (rather
            // than .dropFirst()) so the very first non-empty status — which is
            // the "Phase 1: analyzing N files…" message published by
            // generateRoot — is always delivered. With .dropFirst() there was
            // a race: if generateRoot ran before this sink subscribed, the
            // current value at subscribe time was the Phase-1 message, and
            // .dropFirst() then swallowed it, leaving the user with NO visible
            // progress until Phase 1 finished (~60 s).
            session.$statusMessage
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak session, weak webView] status in
                    guard let self = self,
                          let session = session,
                          let webView = webView else { return }
                    if status.isEmpty { return } // skip the @Published empty initial value
                    let phase = Self.derivePhaseTag(from: status)
                    self.bridge.setInsightStatus(
                        sessionId: session.id.uuidString,
                        message: status,
                        phase: phase,
                        into: webView
                    )
                }
                .store(in: &insightCancellables)
        }

        /// Coarse status-phase tag derived from `InsightSession.statusMessage`. The
        /// parent JS uses this for status-bar tinting; loose match is fine because
        /// T6 emits a small set of canonical messages (see InsightSession.swift).
        private static func derivePhaseTag(from message: String) -> String {
            let lower = message.lowercased()
            if lower.contains("phase 1") { return "phase-1" }
            if lower.contains("phase 2") { return "phase-2" }
            if lower.hasPrefix("ready") { return "ready" }
            return ""
        }

        /// Replace relative image paths in markdown with base64 data URIs.
        /// Swift can read user-selected files (NSOpenPanel grants access),
        /// but WKWebView's content process cannot — so we inline them.
        static func resolveImagePaths(in markdown: String, relativeTo documentURL: URL) -> String {
            let dir = documentURL.deletingLastPathComponent()

            guard let regex = try? NSRegularExpression(
                pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#
            ) else { return markdown }

            let nsString = markdown as NSString
            let fullRange = NSRange(location: 0, length: nsString.length)
            let matches = regex.matches(in: markdown, range: fullRange)

            // Process in reverse to preserve ranges
            var result = nsString as String
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let pathRange = Range(match.range(at: 2), in: result) else { continue }

                let path = String(result[pathRange])

                // Skip absolute URLs
                if path.hasPrefix("http://") || path.hasPrefix("https://")
                    || path.hasPrefix("data:") || path.hasPrefix("file://") { continue }

                // Resolve relative to document directory
                let imageURL = dir.appendingPathComponent(path)

                guard let imageData = try? Data(contentsOf: imageURL) else { continue }

                let ext = imageURL.pathExtension.lowercased()
                let mime: String
                switch ext {
                case "png": mime = "image/png"
                case "jpg", "jpeg": mime = "image/jpeg"
                case "gif": mime = "image/gif"
                case "svg": mime = "image/svg+xml"
                case "webp": mime = "image/webp"
                case "bmp": mime = "image/bmp"
                case "ico": mime = "image/x-icon"
                default: mime = "application/octet-stream"
                }

                let dataURI = "data:\(mime);base64,\(imageData.base64EncodedString())"
                result = result.replacingCharacters(in: pathRange, with: dataURI)
            }

            return result
        }

        func setTheme(_ theme: Theme) {
            guard let webView = webView, isEditorReady, theme != lastTheme else { return }
            lastTheme = theme
            bridge.setTheme(theme, in: webView)
        }

        func scrollToHeading(_ headingId: String) {
            guard let webView = webView else { return }
            bridge.scrollToHeading(headingId, in: webView)
        }

        func scrollToText(_ text: String) {
            guard let webView = webView, isEditorReady else { return }
            // Escape for JS string
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            let js = "window.scrollToText && window.scrollToText('\(escaped)')"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func exportPDF(fileName: String) {
            guard let webView = webView else { return }
            PDFExporter.exportPDF(from: webView, fileName: fileName, bridge: bridge)
        }

        private static func resolveEditorResourceBaseURL() -> URL {
            if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor") {
                return htmlURL.deletingLastPathComponent()
            }

            return Bundle.main.resourceURL ?? Bundle.main.bundleURL
        }
    }
}

// MARK: - WebViewBridge Delegate

extension EditorView.Coordinator: WebViewBridgeDelegate {
    func bridge(_ bridge: WebViewBridge, didUpdateContent content: String) {
        Task { @MainActor in
            self.lastLoadedContent = content  // Prevent re-sending
            self.parent.workspaceManager.updateActiveTabContent(content)
        }
    }

    func bridge(_ bridge: WebViewBridge, didExtractHeadings headings: [HeadingItem]) {
        Task { @MainActor in
            self.parent.workspaceManager.updateActiveTabHeadings(headings)
        }
    }

    func bridge(_ bridge: WebViewBridge, didSelectHeading headingId: String) {
        Task { @MainActor in
            self.parent.workspaceManager.updateActiveHeading(headingId)
        }
    }

    func bridge(_ bridge: WebViewBridge, didClickLink href: String) {
        Task { @MainActor in
            guard let url = URL(string: href) else { return }
            let scheme = url.scheme?.lowercased() ?? ""

            if scheme == "file" {
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" || ext == "mdown" || ext == "mkd" {
                    self.parent.workspaceManager.openFile(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
            } else if scheme == "http" || scheme == "https" || scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func bridge(_ bridge: WebViewBridge, didChangeScrollPosition position: CGFloat) {
        Task { @MainActor in
            self.parent.workspaceManager.updateActiveTabScrollPosition(position)
        }
    }

    func bridge(_ bridge: WebViewBridge, didReceiveBlocksDelta delta: BlocksDelta) {
        Task { @MainActor in
            self.parent.workspaceManager.handleBlocksDelta(delta)
        }
    }

    func bridge(_ bridge: WebViewBridge, didChangeCursorBlock blockId: String) {
        Task { @MainActor in
            self.parent.workspaceManager.handleCursorBlockChange(blockId)
        }
    }

    func bridgeEditorReady(_ bridge: WebViewBridge) {
        Task { @MainActor in
            self.isEditorReady = true
            // Apply theme that was deferred while editor was loading
            self.setTheme(self.parent.themeManager.effectiveTheme)
            let idx = self.parent.workspaceManager.activeTabIndex
            if idx >= 0, idx < self.parent.workspaceManager.openTabs.count {
                let tab = self.parent.workspaceManager.openTabs[idx]
                self.pendingTab = tab
                self.loadContentIfNeeded(tab.content, documentURL: tab.url, tab: tab)
            }
        }
    }

    func bridgeSaveRequested(_ bridge: WebViewBridge) {
        // Insight tabs have their own Save flow (didRequestInsightSave) — the
        // generic save bridge must not touch them. WorkspaceManager.saveActiveFile
        // also guards the placeholder URL as defense-in-depth.
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            let idx = wm.activeTabIndex
            if idx >= 0, idx < wm.openTabs.count,
               case .insight = wm.openTabs[idx].kind {
                return
            }
            wm.saveActiveFile()
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestTranslation markdown: String, targetLang: String) {
        Task { @MainActor in
            await self.parent.workspaceManager.translateDocument(markdown: markdown, targetLang: targetLang)
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestSelectionAction action: String, text: String) {
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            await wm.handleSelectionAction(action: action, text: text) { title, result in
                if let webView = self.webView {
                    let titleJSON = (try? JSONSerialization.data(withJSONObject: [title]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .map { String($0.dropFirst().dropLast()) } ?? "\"\(title)\""
                    let resultJSON = (try? JSONSerialization.data(withJSONObject: [result]))
                        .flatMap { String(data: $0, encoding: .utf8) }
                        .map { String($0.dropFirst().dropLast()) } ?? "\"\""
                    webView.evaluateJavaScript("window.showSelectionResult(\(titleJSON), \(resultJSON))") { _, _ in }
                }
            }
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestGraph type: String, prompt: String, content: String) {
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            if type == "edit" {
                wm.runGraphEdit(instruction: prompt, currentMermaid: content)
            } else {
                wm.presentGraphCreator(for: type)
            }
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestAITool tool: String, content: String) {
        Task { @MainActor in
            self.parent.workspaceManager.runAITool(named: tool, contentOverride: content)
        }
    }

    func bridgeRefreshRequested(_ bridge: WebViewBridge) {
        // Insight tabs are ephemeral — reloading from the placeholder URL would
        // either fail (no file) or clobber session state if a stray write ever
        // produced one. WorkspaceManager.reloadActiveTabFromDisk also no-ops.
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            let idx = wm.activeTabIndex
            if idx >= 0, idx < wm.openTabs.count,
               case .insight = wm.openTabs[idx].kind {
                return
            }
            if let content = wm.reloadActiveTabFromDisk() {
                self.lastLoadedContent = content
                if let webView = self.webView {
                    self.bridge.loadContent(content, into: webView) {}
                }
            }
        }
    }

    // MARK: - Insight delegate methods (Recursive Insight v2, Task 7)
    //
    // Forward UI events from the v2 insight iframe player to `WorkspaceManager`,
    // which resolves the target `InsightSession` by `sessionId` and dispatches
    // the appropriate session method (expand / navigateTo / up / save).
    // T8 fully implements the WorkspaceManager forwarders; T7 wires the delegate
    // stubs to the new v2 method names.

    func bridge(_ bridge: WebViewBridge, didReceiveInsightIframeReady sessionId: String, nodeId: String) {
        Task { @MainActor in
            self.parent.workspaceManager.didReceiveInsightIframeReady(sessionId: sessionId, nodeId: nodeId)
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestInsightDeepDive sessionId: String, sectionId: String, topicIndex: Int) {
        Task { @MainActor in
            self.parent.workspaceManager.didRequestInsightDeepDive(sessionId: sessionId, sectionId: sectionId, topicIndex: topicIndex)
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestInsightBreadcrumb sessionId: String, nodeId: String) {
        Task { @MainActor in
            self.parent.workspaceManager.didRequestInsightBreadcrumb(sessionId: sessionId, nodeId: nodeId)
        }
    }

    func bridgeRequestInsightSave(_ bridge: WebViewBridge) {
        Task { @MainActor in
            self.parent.workspaceManager.didRequestInsightSave()
        }
    }

    func bridgeRequestInsightUp(_ bridge: WebViewBridge) {
        Task { @MainActor in
            self.parent.workspaceManager.didRequestInsightUp()
        }
    }
}

#Preview {
    EditorView()
        .environmentObject(WorkspaceManager())
        .environmentObject(ThemeManager())
}
