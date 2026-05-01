import Foundation
import WebKit
import SwiftUI

/// Payload structure for bridge messages
struct BridgeMessage: Codable {
    let type: String
    let data: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
}

/// Type-erased codable wrapper for flexible JSON data
enum AnyCodable: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AnyCodable].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyCodable")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

/// Central bridge for JS-Swift communication
class WebViewBridge: NSObject, WKScriptMessageHandler {
    weak var delegate: WebViewBridgeDelegate?

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Safety wrapper — any crash in message handling must not kill the app
        guard let dict = message.body as? [String: Any],
              let messageType = dict["type"] as? String else {
            Self.logInsightDiag("userContentController: malformed body=\(String(describing: message.body).prefix(120))")
            return
        }

        let payload = dict["payload"]
        // Diag every incoming bridge message so we can prove JS→Swift is alive
        // (filter common high-rate types in the log post-hoc).
        Self.logInsightDiag("userContentController IN type=\(messageType) hasPayload=\(payload != nil)")

        // headingsUpdated sends payload as array directly
        if messageType == "headingsUpdated" {
            if let headingsArray = payload as? [[String: Any]] {
                let headings = headingsArray.compactMap { HeadingItem(from: $0) }
                delegate?.bridge(self, didExtractHeadings: headings)
            }
            return
        }

        // blocksChanged can be large — defer to next run loop to avoid blocking
        if messageType == "blocksChanged" {
            guard let data = payload as? [String: Any] else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let added = (data["added"] as? [[String: Any]])?.compactMap { SemanticBlock(from: $0) } ?? []
                let removed = data["removed"] as? [String] ?? []
                let changed = (data["changed"] as? [[String: Any]])?.compactMap { SemanticBlock(from: $0) } ?? []
                let unchanged = data["unchanged"] as? [String] ?? []
                let delta = BlocksDelta(added: added, removed: removed, changed: changed, unchanged: unchanged)
                self.delegate?.bridge(self, didReceiveBlocksDelta: delta)
            }
            return
        }

        // V2 insight messages — handled inline so each case can carry its own
        // `frameInfo.isMainFrame` defense-in-depth guard (Decision 3).
        // Per Decision 2 the iframe is sandboxed without `allow-same-origin`, so it
        // should never be able to call `webkit.messageHandlers.bridge` directly —
        // only the parent (main) frame relays iframe postMessage events to Swift.
        // The guard rejects any future WebKit semantic surprise.
        switch messageType {
        case "insightIframeReady":
            guard message.frameInfo.isMainFrame else { return }
            handleInsightIframeReady(payload: payload)
            return
        case "insightDeepDiveClicked":
            guard message.frameInfo.isMainFrame else { return }
            handleInsightDeepDiveClicked(payload: payload)
            return
        case "insightBreadcrumbClicked":
            guard message.frameInfo.isMainFrame else { return }
            handleInsightBreadcrumbClicked(payload: payload)
            return
        case "insightRequestSave":
            guard message.frameInfo.isMainFrame else { return }
            delegate?.bridgeRequestInsightSave(self)
            return
        case "insightRequestUp":
            guard message.frameInfo.isMainFrame else { return }
            delegate?.bridgeRequestInsightUp(self)
            return
        case "jsError":
            // Diagnostic-only: route any JS-side window.onerror /
            // unhandledrejection to the diag log file so we can see what's
            // actually failing in the WebKit process.
            if let dict = payload as? [String: Any] {
                let where_ = (dict["where"] as? String) ?? "?"
                let msg = (dict["message"] as? String) ?? "?"
                let src = (dict["source"] as? String) ?? "?"
                let line = (dict["lineno"] as? Int) ?? -1
                let col = (dict["colno"] as? Int) ?? -1
                let stack = (dict["stack"] as? String) ?? ""
                Self.logInsightDiag("JS \(where_): \(msg) at \(src):\(line):\(col)\n  stack: \(stack.prefix(800))")
            } else {
                Self.logInsightDiag("JS error (malformed payload): \(String(describing: payload).prefix(400))")
            }
            return
        default:
            break
        }

        // All other messages
        let data = payload as? [String: Any]
        handleMessage(type: messageType, data: data)
    }

    // MARK: - v2 insight payload validation

    /// Strip `\r`, `\n`, NUL and truncate to 64 chars. Defends NSLog against log forgery
    /// (CWE-117): a compromised JS context could otherwise inject fake `[Insight]` lines
    /// via embedded control chars. Mirrors `WorkspaceManager.sanitizeForLog(_:)` —
    /// duplicated here intentionally to keep `WebViewBridge.swift` self-contained
    /// (T8 may extract a shared `LogSanitizer` utility).
    private static func sanitizeForLog(_ s: String) -> String {
        let stripped = s.replacingOccurrences(
            of: "[\\r\\n\\0]",
            with: "_",
            options: .regularExpression
        )
        return String(stripped.prefix(64))
    }

    /// `insightIframeReady` payload: `{sessionId: String, nodeId: String}`.
    /// Both fields validated as non-empty Strings before forwarding.
    private func handleInsightIframeReady(payload: Any?) {
        guard let dict = payload as? [String: Any],
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty,
              let nodeId = dict["nodeId"] as? String, !nodeId.isEmpty else {
            NSLog("[Insight] Malformed payload for %@", Self.sanitizeForLog("insightIframeReady"))
            return
        }
        delegate?.bridge(self, didReceiveInsightIframeReady: sessionId, nodeId: nodeId)
    }

    /// `insightDeepDiveClicked` payload: `{sessionId: String, sectionId: String, topicIndex: Int}`.
    /// Bounds validation against the live skeleton happens in WorkspaceManager (the
    /// bridge holds no skeleton reference) — bridge enforces only payload schema.
    private func handleInsightDeepDiveClicked(payload: Any?) {
        guard let dict = payload as? [String: Any],
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty,
              let sectionId = dict["sectionId"] as? String, !sectionId.isEmpty,
              let topicIndex = dict["topicIndex"] as? Int, topicIndex >= 0 else {
            NSLog("[Insight] Malformed payload for %@", Self.sanitizeForLog("insightDeepDiveClicked"))
            return
        }
        delegate?.bridge(self, didRequestInsightDeepDive: sessionId, sectionId: sectionId, topicIndex: topicIndex)
    }

    /// `insightBreadcrumbClicked` payload: `{sessionId: String, nodeId: String}`.
    /// Bridge does a quick UUID-shape check (defense-in-depth); manifest membership
    /// is validated in WorkspaceManager.
    private func handleInsightBreadcrumbClicked(payload: Any?) {
        guard let dict = payload as? [String: Any],
              let sessionId = dict["sessionId"] as? String, !sessionId.isEmpty,
              let nodeId = dict["nodeId"] as? String, !nodeId.isEmpty,
              UUID(uuidString: nodeId) != nil else {
            NSLog("[Insight] Malformed payload for %@", Self.sanitizeForLog("insightBreadcrumbClicked"))
            return
        }
        delegate?.bridge(self, didRequestInsightBreadcrumb: sessionId, nodeId: nodeId)
    }

    // MARK: - Message Handling

    private func handleMessage(type: String, data: [String: Any]?) {
        switch type {

        // JS sends: { markdown: "...", html: "..." }
        case "contentChanged":
            if let markdown = data?["markdown"] as? String {
                delegate?.bridge(self, didUpdateContent: markdown)
            }

        // JS sends: payload is the array directly (not nested in "headings" key)
        // We handle this in userContentController by also passing rawPayload
        case "headingsUpdated":
            // Headings come through rawPayload (see userContentController)
            break

        // JS sends: { activeHeadingId: "..." }
        case "scrollPosition":
            if let headingId = data?["activeHeadingId"] as? String {
                delegate?.bridge(self, didSelectHeading: headingId)
            }

        case "ready":
            delegate?.bridgeEditorReady(self)

        case "linkClicked":
            if let href = data?["href"] as? String {
                delegate?.bridge(self, didClickLink: href)
            }

        // blocksChanged handled in userContentController directly (deferred)

        case "textChanged":
            if let payload = data, let blockId = payload["cursorBlock"] as? String {
                delegate?.bridge(self, didChangeCursorBlock: blockId)
            }

        case "saveRequested":
            delegate?.bridgeSaveRequested(self)

        case "translateRequested":
            if let markdown = data?["markdown"] as? String,
               let targetLang = data?["targetLang"] as? String {
                delegate?.bridge(self, didRequestTranslation: markdown, targetLang: targetLang)
            }

        case "selectionAction":
            if let action = data?["action"] as? String,
               let text = data?["text"] as? String {
                delegate?.bridge(self, didRequestSelectionAction: action, text: text)
            }

        case "refreshRequested":
            delegate?.bridgeRefreshRequested(self)

        case "aiTool":
            if let tool = data?["tool"] as? String, let content = data?["content"] as? String {
                delegate?.bridge(self, didRequestAITool: tool, content: content)
            }

        case "generateGraph":
            let type = data?["type"] as? String ?? "architecture"
            if type == "edit" {
                let instruction = data?["editInstruction"] as? String ?? ""
                let currentMermaid = data?["currentMermaid"] as? String ?? ""
                delegate?.bridge(self, didRequestGraph: "edit", prompt: instruction, content: currentMermaid)
            } else {
                delegate?.bridge(self, didRequestGraph: type, prompt: "", content: "")
            }

        // V2 insight messages (insightIframeReady, insightDeepDiveClicked,
        // insightBreadcrumbClicked, insightRequestSave, insightRequestUp) are
        // handled inline in `userContentController(_:didReceive:)` so each case
        // can carry its own `frameInfo.isMainFrame` guard (Decision 3) and never
        // reach this fallthrough.

        default:
            NSLog("Unknown bridge message type: \(type)")
        }
    }

    // MARK: - Encoding Helpers

    /// Encode an arbitrary string for safe JS literal embedding using the array-wrap
    /// idiom: `JSONSerialization` of a single-element array (bare strings cause
    /// `NSInvalidArgumentException`), then drop the surrounding `[` / `]` brackets,
    /// leaving a properly JSON-escaped string literal (with quotes + escaped backslashes
    /// / quotes / control chars / unicode).
    /// Returns nil on encoding failure (caller should log + bail).
    private func encodeStringForJS(_ s: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let arrayString = String(data: data, encoding: .utf8) else {
            return nil
        }
        // ["escaped string"] -> "escaped string"
        return String(arrayString.dropFirst().dropLast())
    }

    // MARK: - Commands to JavaScript

    /// Load markdown content into the editor
    func loadContent(_ markdown: String, into webView: WKWebView, completion: @escaping () -> Void) {
        // Wrap string in an array for valid JSON serialization (bare strings cause NSInvalidArgumentException),
        // then extract the escaped string element for safe JavaScript embedding
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [markdown], options: []),
              let jsonArrayString = String(data: jsonData, encoding: .utf8) else {
            NSLog("Error encoding markdown content")
            completion()
            return
        }
        // ["escaped content"] -> "escaped content"
        let jsonString = String(jsonArrayString.dropFirst().dropLast())
        let js = "window.setContent(\(jsonString))"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting content: \(error)")
            }
            completion()
        }
    }

    /// Load structured data (JSON/XML/YAML) content into the editor
    func loadStructuredContent(_ content: String, fileType: String, into webView: WKWebView, completion: @escaping () -> Void) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [content], options: []),
              let jsonArrayString = String(data: jsonData, encoding: .utf8) else {
            NSLog("Error encoding structured content")
            completion()
            return
        }
        let jsonString = String(jsonArrayString.dropFirst().dropLast())
        let js = "window.setStructuredContent(\(jsonString), '\(fileType)')"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting structured content: \(error)")
            }
            completion()
        }
    }

    // MARK: - v2 Insight commands (Recursive Insight, Task 7)
    //
    // The five Swift→JS setters that drive the parent JS that owns the sandboxed
    // insight iframe (Decision 2). String fields go through `encodeStringForJS`
    // (the array-wrap idiom — never bare interpolation). Bool serialised as
    // JS literal `true`/`false` (NEVER `1`/`0`). Skeleton serialised via
    // `JSONEncoder` then injected verbatim (already valid JSON literal).

    /// Diagnostic logger that bypasses macOS unified-log privacy redaction.
    /// Appends to /tmp/markview-insight-diag.log directly — guarantees visibility
    /// regardless of NSLog/os_log filtering, redaction, or process attribution.
    static func logInsightDiag(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [InsightDiag] \(message)\n"
        if let data = line.data(using: .utf8) {
            let path = "/tmp/markview-insight-diag.log"
            if FileManager.default.fileExists(atPath: path) {
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            FileHandle.standardError.write(data)
        }
        NSLog("%{public}@", line)
    }

    /// Phase-1 paint: tell parent JS to (re)build the iframe srcdoc placeholder
    /// grid for `skeleton` and switch to insight view. Parent owns the iframe;
    /// the bridge speaks only to the parent (not to the iframe).
    /// Calls `window.loadInsightSkeleton(<json>, '<sessionId>', '<nodeId>')`.
    func loadInsightSkeleton(skeleton: InsightSkeleton, sessionId: String, nodeId: String, into webView: WKWebView) {
        let encoder = JSONEncoder()
        guard let jsonData = try? encoder.encode(skeleton),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            NSLog("[Insight] Error in loadInsightSkeleton: failed to JSON-encode skeleton")
            Self.logInsightDiag("loadInsightSkeleton: failed to JSON-encode skeleton")
            return
        }
        guard let sidLit = encodeStringForJS(sessionId),
              let nidLit = encodeStringForJS(nodeId) else {
            NSLog("[Insight] Error in loadInsightSkeleton: failed to encode sessionId/nodeId")
            Self.logInsightDiag("loadInsightSkeleton: failed to encode sessionId/nodeId")
            return
        }
        // `window.loadInsightSkeleton` is `async function` → returns a Promise.
        // WKWebView's `evaluateJavaScript` cannot serialize a Promise back to
        // Swift and reports "JavaScript execution returned a result of an
        // unsupported type" (WKErrorDomain Code=5). The Promise body still
        // executes; only the return value crosses the bridge. Wrapping with
        // `void()` makes the eval return `undefined`, which IS supported.
        let js = "void window.loadInsightSkeleton(\(jsonString), \(sidLit), \(nidLit))"
        Self.logInsightDiag("eval: \(js.prefix(300))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in loadInsightSkeleton: \(error)")
                Self.logInsightDiag("eval failed for loadInsightSkeleton: error=\(error.localizedDescription); fullError=\(String(describing: error))")
                Self.logInsightDiag("failed JS source for loadInsightSkeleton: \(js.prefix(300))")
            }
        }
    }

    /// Phase-2 streaming: forward a per-section HTML delta to parent JS, which
    /// relays into the iframe via `iframe.contentWindow.postMessage` (the iframe
    /// is sandboxed null-origin, so postMessage is the only inbound channel).
    /// Calls `window.updateInsightSection('<sessionId>', '<sectionId>', '<htmlChunk>')`.
    func updateInsightSection(sessionId: String, sectionId: String, htmlChunk: String, into webView: WKWebView) {
        guard let sidLit = encodeStringForJS(sessionId),
              let secIdLit = encodeStringForJS(sectionId),
              let chunkLit = encodeStringForJS(htmlChunk) else {
            NSLog("[Insight] Error in updateInsightSection: failed to encode payload")
            Self.logInsightDiag("updateInsightSection: failed to encode payload")
            return
        }
        let js = "window.updateInsightSection(\(sidLit), \(secIdLit), \(chunkLit))"
        Self.logInsightDiag("eval: \(js.prefix(300))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in updateInsightSection: \(error)")
                Self.logInsightDiag("eval failed for updateInsightSection: error=\(error.localizedDescription); fullError=\(String(describing: error))")
                Self.logInsightDiag("failed JS source for updateInsightSection: \(js.prefix(300))")
            }
        }
    }

    /// Render an error banner in parent chrome (status bar). `retryable` is a
    /// JS boolean LITERAL `true`/`false` — NEVER `1`/`0` (would break JS
    /// truthiness if the empty string `"0"` ever leaked, and the parent JS
    /// branches on the literal). Regression guard from v1 round-2 fix.
    /// Calls `window.setInsightError('<sessionId>', '<message>', <true|false>)`.
    func setInsightError(sessionId: String, message: String, retryable: Bool, into webView: WKWebView) {
        guard let sidLit = encodeStringForJS(sessionId),
              let msgLit = encodeStringForJS(message) else {
            NSLog("[Insight] Error in setInsightError: failed to encode payload")
            Self.logInsightDiag("setInsightError: failed to encode payload")
            return
        }
        let retryableLit = retryable ? "true" : "false"
        let js = "window.setInsightError(\(sidLit), \(msgLit), \(retryableLit))"
        Self.logInsightDiag("eval: \(js.prefix(300))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightError: \(error)")
                Self.logInsightDiag("eval failed for setInsightError: error=\(error.localizedDescription); fullError=\(String(describing: error))")
                Self.logInsightDiag("failed JS source for setInsightError: \(js.prefix(300))")
            }
        }
    }

    /// Update the bottom status bar in parent chrome
    /// (e.g. "Phase 2: 3/7 sections..."). `phase` is a free-form tag the parent
    /// uses for status-bar tinting (`phase-1`, `phase-2`, `ready`, etc.).
    /// Calls `window.setInsightStatus('<sessionId>', '<message>', '<phase>')`.
    func setInsightStatus(sessionId: String, message: String, phase: String, into webView: WKWebView) {
        guard let sidLit = encodeStringForJS(sessionId),
              let msgLit = encodeStringForJS(message),
              let phaseLit = encodeStringForJS(phase) else {
            NSLog("[Insight] Error in setInsightStatus: failed to encode payload")
            Self.logInsightDiag("setInsightStatus: failed to encode payload")
            return
        }
        let js = "window.setInsightStatus(\(sidLit), \(msgLit), \(phaseLit))"
        Self.logInsightDiag("eval: \(js.prefix(300))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightStatus: \(error)")
                Self.logInsightDiag("eval failed for setInsightStatus: error=\(error.localizedDescription); fullError=\(String(describing: error))")
                Self.logInsightDiag("failed JS source for setInsightStatus: \(js.prefix(300))")
            }
        }
    }

    /// Revoke ALL blob URLs created for the closing insight session
    /// (Decision 11 §2). Called by `WorkspaceManager.closeTab` insight branch
    /// as STEP 1 of 4 (BEFORE `await session.cancel()`) so no in-flight
    /// Combine sub fires after revocation.
    /// Calls `window.releaseInsightBlobs()`.
    func releaseInsightBlobs(into webView: WKWebView) {
        let js = "window.releaseInsightBlobs()"
        Self.logInsightDiag("eval: \(js.prefix(300))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in releaseInsightBlobs: \(error)")
                Self.logInsightDiag("eval failed for releaseInsightBlobs: error=\(error.localizedDescription); fullError=\(String(describing: error))")
                Self.logInsightDiag("failed JS source for releaseInsightBlobs: \(js.prefix(300))")
            }
        }
    }

    /// Set the document base URL for resolving relative image/link paths
    func setDocumentBase(_ directoryURL: URL, in webView: WKWebView) {
        var base = directoryURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        let js = "window.setDocumentBase('\(base)')"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting document base: \(error)")
            }
        }
    }

    /// Set the theme for the editor
    func setTheme(_ theme: Theme, in webView: WKWebView) {
        let themeValue = theme == .dark ? "dark" : "light"
        let js = "window.setTheme('\(themeValue)')"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting theme: \(error)")
            }
        }
    }

    /// Scroll to a specific heading
    func scrollToHeading(_ headingId: String, in webView: WKWebView) {
        let js = "window.scrollToHeading('\(headingId)')"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error scrolling to heading: \(error)")
            }
        }
    }

    /// Request the current HTML from the editor
    func requestHTML(from webView: WKWebView, completion: @escaping (String?) -> Void) {
        let js = "window.getHTML()"

        webView.evaluateJavaScript(js) { result, error in
            if let html = result as? String {
                completion(html)
            } else {
                NSLog("Error requesting HTML: \(error?.localizedDescription ?? "Unknown error")")
                completion(nil)
            }
        }
    }

    /// Prepare the document for PDF export
    func preparePrintLayout(in webView: WKWebView) {
        let js = "window.preparePrintLayout()"
        webView.evaluateJavaScript(js)
    }

    /// Restore the editor layout after PDF export
    func restoreEditLayout(in webView: WKWebView) {
        let js = "window.restoreEditLayout()"
        webView.evaluateJavaScript(js)
    }
}

// MARK: - HeadingItem Extension

extension HeadingItem {
    init?(from dict: [String: Any]) {
        guard
            let id = dict["id"] as? String,
            let level = dict["level"] as? Int,
            let text = dict["text"] as? String
        else {
            return nil
        }

        self.init(id: id, level: level, text: text)
    }
}

// MARK: - Bridge Delegate Protocol

protocol WebViewBridgeDelegate: AnyObject {
    func bridge(_ bridge: WebViewBridge, didUpdateContent content: String)
    func bridge(_ bridge: WebViewBridge, didExtractHeadings headings: [HeadingItem])
    func bridge(_ bridge: WebViewBridge, didSelectHeading headingId: String)
    func bridge(_ bridge: WebViewBridge, didClickLink href: String)
    func bridge(_ bridge: WebViewBridge, didChangeScrollPosition position: CGFloat)
    func bridge(_ bridge: WebViewBridge, didReceiveBlocksDelta delta: BlocksDelta)
    func bridge(_ bridge: WebViewBridge, didChangeCursorBlock blockId: String)
    func bridgeEditorReady(_ bridge: WebViewBridge)
    func bridgeSaveRequested(_ bridge: WebViewBridge)
    func bridge(_ bridge: WebViewBridge, didRequestTranslation markdown: String, targetLang: String)
    func bridge(_ bridge: WebViewBridge, didRequestSelectionAction action: String, text: String)
    func bridgeRefreshRequested(_ bridge: WebViewBridge)
    func bridge(_ bridge: WebViewBridge, didRequestGraph type: String, prompt: String, content: String)
    func bridge(_ bridge: WebViewBridge, didRequestAITool tool: String, content: String)

    // MARK: Insight messages (Recursive Insight v2, Task 7)
    //
    // V2 protocol: 5 JS→Swift handlers, all with `frameInfo.isMainFrame` guard.
    // Bridge does payload schema validation (presence + non-empty strings + Int
    // bounds + UUID shape); higher-level validation (skeleton membership,
    // manifest membership, retry rate limit) lives in WorkspaceManager (T8).
    func bridge(_ bridge: WebViewBridge, didReceiveInsightIframeReady sessionId: String, nodeId: String)
    func bridge(_ bridge: WebViewBridge, didRequestInsightDeepDive sessionId: String, sectionId: String, topicIndex: Int)
    func bridge(_ bridge: WebViewBridge, didRequestInsightBreadcrumb sessionId: String, nodeId: String)
    func bridgeRequestInsightSave(_ bridge: WebViewBridge)
    func bridgeRequestInsightUp(_ bridge: WebViewBridge)
}
