import SwiftUI
import WebKit

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
            coordinator.loadContentIfNeeded(tab.content, documentURL: tab.url)
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
        private var pdfExportObserver: Any?
        private var scrollToHeadingObserver: Any?

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
            // Load any pending content
            if let content = pendingContent {
                let docURL = pendingDocumentURL
                pendingContent = nil
                pendingDocumentURL = nil
                loadContentIfNeeded(content, documentURL: docURL)
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

        func loadContentIfNeeded(_ markdown: String, documentURL: URL? = nil) {
            guard let webView = webView else { return }

            guard isEditorReady else {
                pendingContent = markdown
                pendingDocumentURL = documentURL
                return
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

            // Resolve relative image paths to data URIs so WKWebView can display them
            // (WKWebView sandbox blocks direct file:// access to user files)
            let resolved = documentURL != nil
                ? Self.resolveImagePaths(in: markdown, relativeTo: documentURL!)
                : markdown
            bridge.loadContent(resolved, into: webView) {}
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
            let idx = self.parent.workspaceManager.activeTabIndex
            if idx >= 0, idx < self.parent.workspaceManager.openTabs.count {
                self.parent.workspaceManager.openTabs[idx].scrollPosition = position
            }
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
                self.loadContentIfNeeded(tab.content, documentURL: tab.url)
            }
        }
    }

    func bridgeSaveRequested(_ bridge: WebViewBridge) {
        Task { @MainActor in
            self.parent.workspaceManager.saveActiveFile()
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestTranslation markdown: String, targetLang: String) {
        Task { @MainActor in
            await self.parent.workspaceManager.translateDocument(markdown: markdown, targetLang: targetLang)
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestGraph type: String, prompt: String, content: String) {
        Task { @MainActor in
            if type == "edit" {
                // AI edit of existing graph
                let wm = self.parent.workspaceManager
                guard let engine = wm.aiConsoleEngine else { return }

                let editPrompt = """
                I have a Mermaid diagram. Please modify it according to this instruction:

                INSTRUCTION: \(prompt)

                CURRENT MERMAID CODE:
                ```mermaid
                \(content)
                ```

                RULES:
                1. Modify the diagram as requested
                2. Keep ALL other components that weren't mentioned
                3. Maintain the subgraph structure and layers
                4. Return the COMPLETE updated mermaid code
                5. The FIRST LINE inside the mermaid block MUST be: %%INTERACTIVE
                6. Update the current file with the new diagram (replace the old mermaid block)

                Save the updated diagram to the currently open file.
                """

                engine.sendMessage(editPrompt)
                wm.showTOC = true
                wm.showSemanticPanel = true
            } else {
                // New graph — open creator sheet
                NotificationCenter.default.post(name: .openGraphCreator, object: type)
            }
        }
    }

    func bridge(_ bridge: WebViewBridge, didRequestAITool tool: String, content: String) {
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            guard let engine = wm.aiConsoleEngine else { return }

            let fileName = wm.activeTabIndex >= 0 && wm.activeTabIndex < wm.openTabs.count
                ? wm.openTabs[wm.activeTabIndex].url.lastPathComponent : "document"

            if tool == "critic" {
                let prompt = """
                You are a CONSTRUCTIVE CRITIC reviewing documentation. Analyze the following document thoroughly.

                Create a file called "review-\(fileName)" with your review. Structure it as:

                # Constructive Review: \(fileName)

                ## Summary
                Brief overview of what the document covers and its overall quality.

                ## Strengths
                What's done well — be specific with examples.

                ## Issues Found
                For each issue:
                ### Issue N: [Title]
                - **Severity**: Critical / Major / Minor / Suggestion
                - **Location**: Where in the document
                - **Problem**: What's wrong
                - **Recommendation**: How to fix it
                - **Example**: Show the fix if applicable

                ## Missing Content
                What should be documented but isn't.

                ## Consistency Issues
                Terminology, formatting, style inconsistencies.

                ## Action Items
                Numbered list of concrete tasks to improve this document.
                Each with priority (P1/P2/P3) and estimated effort.

                ## Overall Score
                Rate 1-10 with brief justification.

                ---
                Also create a file called "tasks/review-tasks-\(fileName)" with just the action items as a task list:
                - [ ] P1: task description
                - [ ] P2: task description
                etc.

                Document to review:
                \(content)
                """
                engine.sendMessage(prompt)
            } else if tool == "audit" {
                engine.sendMessage(AIConsoleEngine.codebaseAuditPrompt)
            } else if tool == "codemap" || tool == "fulldocs" {
                NotificationCenter.default.post(name: .triggerAITool, object: tool)
            } else if tool == "research" {
                let prompt = """
                You are a DEEP RESEARCHER. Analyze the following document and identify research points.

                STEP 1: Read the document and identify all:
                - External APIs, services, and integrations mentioned
                - Technologies, frameworks, libraries referenced
                - Architectural patterns and approaches used
                - Claims about performance, scalability, or capabilities
                - Third-party dependencies

                STEP 2: For each research point, search online to find:
                - Current status (is it still maintained? latest version?)
                - Best practices and recommendations
                - Known issues or limitations
                - Alternatives and comparisons
                - How it applies to this project specifically

                STEP 3: Create a file called "research-\(fileName)" with findings:

                # Deep Research Report: \(fileName)

                ## Research Points Identified
                List all points found.

                ## Detailed Findings

                ### 1. [Technology/API Name]
                - **What it is**: Brief description
                - **Current status**: Version, maintenance status
                - **How it's used here**: Context from the document
                - **Best practices**: What experts recommend
                - **Risks/Issues**: Known problems
                - **Alternatives**: Other options to consider
                - **Recommendation**: Keep / Replace / Update / Investigate

                (repeat for each research point)

                ## Summary & Recommendations
                Overall findings and priority actions.

                Document to research:
                \(content)
                """
                engine.sendMessage(prompt)
            }

            wm.showTOC = true
            wm.showSemanticPanel = true
        }
    }

    func bridgeRefreshRequested(_ bridge: WebViewBridge) {
        Task { @MainActor in
            let wm = self.parent.workspaceManager
            let idx = wm.activeTabIndex
            guard idx >= 0, idx < wm.openTabs.count else { return }
            let url = wm.openTabs[idx].url
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                wm.openTabs[idx].content = content
                wm.openTabs[idx].isModified = false
                self.lastLoadedContent = content
                if let webView = self.webView {
                    self.bridge.loadContent(content, into: webView) {}
                }
            }
        }
    }
}

#Preview {
    EditorView()
        .environmentObject(WorkspaceManager())
        .environmentObject(ThemeManager())
}
