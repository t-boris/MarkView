import Foundation
import WebKit
import SwiftUI

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

/// Shared helper for constructing safe Swift-to-JavaScript function calls with JSON-encoded arguments (AR-04).
enum JS {
    static func call(_ functionName: String, args: [Any] = []) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: []),
              let arrayJSON = String(data: data, encoding: .utf8),
              arrayJSON.first == "[", arrayJSON.last == "]" else {
            return nil
        }
        let inner = arrayJSON.dropFirst().dropLast()
        return "\(functionName)(\(inner))"
    }
}

/// Central bridge for JS-Swift communication.
///
/// The page's messages are declared in `Editor/js/bridge-contract.json` (channel "bridge"). `messages` checks each one against
/// the contract, decodes its payload into one of the `EditorMessage` types and calls the handler registered below, which passes
/// it to the delegate. A message that is not declared, or does not match its declaration, never reaches the delegate.
class WebViewBridge: NSObject {
    weak var delegate: WebViewBridgeDelegate?

    /// The handler of the page's `bridge` message channel (`WKUserContentController.add(_:name:)`).
    let messages: TypedWebBridge

    init(contract: BridgeContract = .bundled) {
        messages = TypedWebBridge(channel: "bridge", contract: contract)
        super.init()
        registerHandlers()
    }

    // MARK: - Message handlers

    private func registerHandlers() {
        messages.on(EditorMessage.Ready.self) { [weak self] _ in
            guard let self else { return }
            self.delegate?.bridgeEditorReady(self)
        }
        messages.on(EditorMessage.ContentChanged.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didUpdateContent: message.payload.markdown, documentID: EditorDocumentRouting.documentID(from: message.doc))
        }
        messages.on(EditorMessage.HeadingsUpdated.self) { [weak self] message in
            guard let self else { return }
            let headings = message.payload.headings.map { HeadingItem(id: $0.id, level: $0.level, text: $0.text) }
            self.delegate?.bridge(self, didExtractHeadings: headings)
        }
        messages.on(EditorMessage.ScrollPosition.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didSelectHeading: message.payload.activeHeadingId)
        }
        messages.on(EditorMessage.LinkClicked.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didClickLink: message.payload.href)
        }
        // The editor slider's document text size (mirror only); the range is the app's rule, not the contract's.
        messages.on(EditorMessage.EditorFontSize.self) { [weak self] message in
            guard let self, EditorTextSize.range.contains(message.payload.size) else { return }
            self.delegate?.bridge(self, didChangeEditorFontSize: message.payload.size)
        }
        // One of the choices the page keeps for its window (`EditorWindowPrefs`).
        messages.on(EditorMessage.EditorWindowPref.self) { [weak self] message in
            guard let self, EditorWindowPrefs.accepts(key: message.payload.key, value: message.payload.value) else { return }
            self.delegate?.bridge(self, didSetWindowPref: message.payload.key, value: message.payload.value)
        }
        // Can be large: the delegate is told on the next run loop so the page's message returns first.
        messages.on(EditorMessage.BlocksChanged.self) { [weak self] message in
            let delta = BlocksDelta(added: message.payload.added.map(SemanticBlock.init), removed: message.payload.removed,
                                    changed: message.payload.changed.map(SemanticBlock.init), unchanged: message.payload.unchanged)
            DispatchQueue.main.async {
                guard let self else { return }
                self.delegate?.bridge(self, didReceiveBlocksDelta: delta)
            }
        }
        messages.on(EditorMessage.CanvasOpenFile.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestCanvasOpenFile: message.payload.path)
        }
        messages.on(EditorMessage.SaveRequested.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridgeSaveRequested(self, documentID: EditorDocumentRouting.documentID(from: message.doc))
        }
        messages.on(EditorMessage.TranslateRequested.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestTranslation: message.payload.markdown, targetLang: message.payload.targetLang)
        }
        messages.on(EditorMessage.SelectionAction.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestSelectionAction: message.payload.action, text: message.payload.text)
        }
        // Contextual feature actions on the selection; the action name is checked in Swift.
        messages.on(EditorMessage.FeatureAction.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestFeatureAction: message.payload.action, text: message.payload.text, question: message.payload.question ?? "")
        }
        messages.on(EditorMessage.RefreshRequested.self) { [weak self] _ in
            guard let self else { return }
            self.delegate?.bridgeRefreshRequested(self)
        }
        messages.on(EditorMessage.GenerateGraph.self) { [weak self] message in
            guard let self else { return }
            let type = message.payload.type ?? "architecture"
            if type == "edit" {
                self.delegate?.bridge(self, didRequestGraph: "edit", prompt: message.payload.editInstruction ?? "", content: message.payload.currentMermaid ?? "")
            } else {
                self.delegate?.bridge(self, didRequestGraph: type, prompt: "", content: "")
            }
        }
        // The sub-protocols: the contract fixes the action, the delegate's owner reads the rest of the fields by action.
        messages.on(EditorMessage.CodeAction.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didReceiveCodeAction: message.payload.action, payload: message.rawDictionary)
        }
        messages.on(EditorMessage.ArchitectureAction.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didReceiveArchitectureAction: message.payload.action, payload: message.rawDictionary)
        }
        messages.on(EditorMessage.ResearchMapAction.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didReceiveResearchMapAction: message.payload.action, payload: message.rawDictionary,
                                  documentID: EditorDocumentRouting.documentID(from: message.doc))
        }
        // Diagnostic-only: a JS-side window.onerror / unhandledrejection, routed to the diag log.
        messages.on(EditorMessage.JSError.self) { message in
            let error = message.payload
            Self.logInsightDiag("JS \(error.where ?? "?"): \(error.message ?? "?") at \(error.source ?? "?"):\(error.lineno.map { Int($0) } ?? -1):\(error.colno.map { Int($0) } ?? -1)\n  stack: \((error.stack ?? "").prefix(800))")
        }

        // The Recursive Insight messages. Their schema is checked by the contract (non-empty ids, the UUID shape, the depth bounds);
        // higher-level validation (skeleton membership, manifest membership, retry rate limit) lives in WorkspaceManager.
        messages.on(EditorMessage.InsightIframeReady.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didReceiveInsightIframeReady: message.payload.sessionId, nodeId: message.payload.nodeId)
        }
        messages.on(EditorMessage.InsightDeepDiveClicked.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestInsightDeepDive: message.payload.sessionId, sectionId: message.payload.sectionId, topicIndex: message.payload.topicIndex)
        }
        messages.on(EditorMessage.InsightBreadcrumbClicked.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridge(self, didRequestInsightBreadcrumb: message.payload.sessionId, nodeId: message.payload.nodeId)
        }
        messages.on(EditorMessage.InsightRequestSave.self) { [weak self] _ in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightSave(self)
        }
        messages.on(EditorMessage.InsightRequestUp.self) { [weak self] _ in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightUp(self)
        }
        messages.on(EditorMessage.InsightRequestRegenerate.self) { [weak self] _ in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightRegenerate(self)
        }
        messages.on(EditorMessage.InsightRequestCustomDeepDive.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightCustomDeepDive(self, topic: message.payload.topic)
        }
        messages.on(EditorMessage.InsightRequestExploreAll.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightExploreAll(self, depth: message.payload.depth ?? 1)
        }
        messages.on(EditorMessage.InsightRequestRetrySection.self) { [weak self] message in
            guard let self else { return }
            self.delegate?.bridgeRequestInsightRetrySection(self, sectionId: message.payload.sectionId)
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

    /// Script that tells the page which tab its next document belongs to; the page names it in every message
    /// (`sendToSwift`). It runs in the same script as the load so no message can pair the new id with the old
    /// document. An empty id means the page shows no tab's document. `mvSetDocument` first hands unsaved WYSIWYG
    /// edits of the previous document to the app under the previous id (BUG-043); a page that has not defined it
    /// yet just takes the id.
    private static func documentIDScript(_ id: UUID?) -> String {
        let id = id?.uuidString ?? ""
        return "if (window.mvSetDocument) { window.mvSetDocument(\"\(id)\"); } else { window.mvDocumentId = \"\(id)\"; } "
    }

    /// Tell the page that no tab's document is on screen (an insight or the X-Ray replaces it).
    func clearDocument(in webView: WKWebView) {
        webView.evaluateJavaScript(Self.documentIDScript(nil))
    }

    /// Load markdown content into the editor; `documentID` is the tab that owns it.
    func loadContent(_ markdown: String, documentID: UUID?, into webView: WKWebView, completion: @escaping () -> Void) {
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
        let js = Self.documentIDScript(documentID) + "window.setContent(\(jsonString))"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting content: \(error)")
            }
            completion()
        }
    }

    /// Load structured data (JSON/XML/YAML) content into the editor
    /// Render the Architecture tab (markview-architecture.js). `json` is a JSON object literal.
    func showArchitecture(_ json: String, in webView: WKWebView) {
        webView.evaluateJavaScript("window.showArchitecture && window.showArchitecture(\(json))") { _, error in
            if let error { NSLog("Error rendering architecture: \(error)") }
        }
    }

    /// Live AI-analysis progress for the Architecture tab. `json` is an object literal or "null".
    func setArchitectureProgress(_ json: String, in webView: WKWebView) {
        webView.evaluateJavaScript("window.setArchitectureProgress && window.setArchitectureProgress(\(json))")
    }

    /// Project operations are updated independently of the much larger X-Ray snapshot.
    func setProjectOperations(_ json: String, in webView: WKWebView) {
        webView.evaluateJavaScript("window.setProjectOperations && window.setProjectOperations(\(json))")
    }

    /// The state of the research map the page shows (markview-research-map.js). `json` is an object literal.
    func setResearchMap(_ json: String, documentID: UUID?, in webView: WKWebView) {
        let id = documentID?.uuidString ?? ""
        webView.evaluateJavaScript("window.mvResearchMapSet && window.mvResearchMapSet(\"\(id)\", \(json))") { _, error in
            if let error { NSLog("Error sending the research map: \(error)") }
        }
    }

    /// Show source code read-only in the code viewer (markview-code.js).
    func loadCodeContent(_ content: String, language: String, fileName: String, returnLabel: String = "", documentID: UUID?, into webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: [content, language, fileName, returnLabel]),
              let args = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(Self.documentIDScript(documentID) + "window.setCodeContent.apply(null, \(args))") { _, error in
            if let error { NSLog("Error setting code content: \(error)") }
        }
    }

    /// Margin notes for the file in the code viewer (markview-code.js). `json` is an object literal.
    func setCodeNotes(_ json: String, in webView: WKWebView) {
        webView.evaluateJavaScript("window.setCodeNotes && window.setCodeNotes(\(json))")
    }

    /// A go-to-definition / usages result or an AI answer for the code viewer.
    func sendCodeNavEvent(_ json: String, in webView: WKWebView) {
        webView.evaluateJavaScript("window.onCodeNavEvent && window.onCodeNavEvent(\(json))")
    }

    /// Select and centre 1-based lines in the code viewer (queued while it loads).
    func revealCodeLine(_ line: Int, endLine: Int?, in webView: WKWebView) {
        webView.evaluateJavaScript("window.codeGotoLine && window.codeGotoLine(\(line), \(endLine ?? line))")
    }

    /// Show a key of a JSON / YAML file: its node in the tree viewer, or its line in a source view.
    func revealStructure(pathJSON: String, line: Int, in webView: WKWebView) {
        let path = (try? JSONSerialization.data(withJSONObject: [pathJSON]))
            .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"[]\""
        webView.evaluateJavaScript("window.revealStructure && window.revealStructure(\(path), \(line))")
    }

    func revealDocumentLine(_ line: Int, in webView: WKWebView) {
        webView.evaluateJavaScript("window.documentGotoLine && window.documentGotoLine(\(line))")
    }

    /// Show a data file (table, Parquet, SQLite, log): the page fetches it from `markview-data:`.
    /// `reload`: the same file changed on disk (a followed log keeps following).
    func loadDataContent(_ url: URL, fileType: String, reload: Bool, documentID: UUID?, into webView: WKWebView) {
        let source = DataFileSchemeHandler.address(of: url)
        let payload: [String: Any] = ["src": source, "kind": fileType, "name": url.lastPathComponent, "reload": reload]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(Self.documentIDScript(documentID) + "window.setDataContent && window.setDataContent(\(json))")
    }

    func loadStructuredContent(_ content: String, fileType: String, documentID: UUID?, into webView: WKWebView, completion: @escaping () -> Void) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [content], options: []),
              let jsonArrayString = String(data: jsonData, encoding: .utf8) else {
            NSLog("Error encoding structured content")
            completion()
            return
        }
        let jsonString = String(jsonArrayString.dropFirst().dropLast())
        let js = Self.documentIDScript(documentID) + "window.setStructuredContent(\(jsonString), '\(fileType)')"

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

    /// Diagnostic logger for Insight bridge events (AR-09: never writes to world-readable /tmp files
    /// and never logs document or section contents).
    static func logInsightDiag(_ message: String) {
        try? FileManager.default.removeItem(atPath: "/tmp/markview-insight-diag.log")
        #if DEBUG
        NSLog("[InsightDiag] %@", message)
        #endif
    }

    /// Phase-1 paint: tell parent JS to (re)build the iframe srcdoc placeholder
    /// grid for `skeleton` and switch to insight view. Parent owns the iframe;
    /// the bridge speaks only to the parent (not to the iframe).
    /// Calls `window.loadInsightSkeleton(<json>, '<sessionId>', '<nodeId>')`.
    func loadInsightSkeleton(skeleton: InsightSkeleton, sessionId: String, nodeId: String, breadcrumbs: [(String, String)] = [], into webView: WKWebView) {
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
        // Encode breadcrumbs as JSON array [{nodeId, title}, ...]. Empty array
        // means "use the skeleton title as a single root crumb" — that's the
        // JS fallback. Pass breadcrumbs separately so the Codable InsightSkeleton
        // schema (used for cache snapshots + tool_use validation) stays
        // unchanged.
        let breadcrumbObjs = breadcrumbs.map { ["nodeId": $0.0, "title": $0.1] }
        let breadcrumbJSON: String
        if let cdata = try? JSONSerialization.data(withJSONObject: breadcrumbObjs, options: []),
           let cstr = String(data: cdata, encoding: .utf8) {
            breadcrumbJSON = cstr
        } else {
            breadcrumbJSON = "[]"
        }
        // `window.loadInsightSkeleton` is `async function` → returns a Promise.
        // void() wrapper avoids "unsupported type" error from evaluateJavaScript.
        let js = "void window.loadInsightSkeleton(\(jsonString), \(sidLit), \(nidLit), \(breadcrumbJSON))"
        Self.logInsightDiag("eval loadInsightSkeleton (bytes=\(js.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in loadInsightSkeleton: \(error)")
                Self.logInsightDiag("eval failed for loadInsightSkeleton: error=\(error.localizedDescription)")
            }
        }
    }

    /// Phase-2 streaming: forward a per-section HTML delta to parent JS, which
    /// relays into the iframe via `iframe.contentWindow.postMessage` (the iframe
    /// is sandboxed null-origin, so postMessage is the only inbound channel).
    /// Calls `window.updateInsightSection('<sessionId>', '<sectionId>', '<htmlChunk>')`.
    func updateInsightSection(sessionId: String, sectionId: String, htmlChunk: String, into webView: WKWebView) {
        guard let js = JS.call("window.updateInsightSection", args: [sessionId, sectionId, htmlChunk]) else {
            NSLog("[Insight] Error in updateInsightSection: failed to encode payload")
            Self.logInsightDiag("updateInsightSection: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval updateInsightSection (chunkBytes=\(htmlChunk.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in updateInsightSection: \(error)")
                Self.logInsightDiag("eval failed for updateInsightSection: error=\(error.localizedDescription)")
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
        Self.logInsightDiag("eval setInsightError (msgBytes=\(message.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightError: \(error)")
                Self.logInsightDiag("eval failed for setInsightError: error=\(error.localizedDescription)")
            }
        }
    }

    /// Update the bottom status bar in parent chrome
    /// (e.g. "Phase 2: 3/7 sections..."). `phase` is a free-form tag the parent
    /// uses for status-bar tinting (`phase-1`, `phase-2`, `ready`, etc.).
    /// Calls `window.setInsightStatus('<sessionId>', '<message>', '<phase>')`.
    func setInsightStatus(sessionId: String, message: String, phase: String, into webView: WKWebView) {
        guard let js = JS.call("window.setInsightStatus", args: [sessionId, message, phase]) else {
            NSLog("[Insight] Error in setInsightStatus: failed to encode payload")
            Self.logInsightDiag("setInsightStatus: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval setInsightStatus (phase=\(phase))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightStatus: \(error)")
                Self.logInsightDiag("eval failed for setInsightStatus: error=\(error.localizedDescription)")
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
        Self.logInsightDiag("eval releaseInsightBlobs")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in releaseInsightBlobs: \(error)")
                Self.logInsightDiag("eval failed for releaseInsightBlobs: error=\(error.localizedDescription)")
            }
        }
    }

    /// Set the document base URL for resolving relative image/link paths (AR-04: JSON-encoded argument)
    func setDocumentBase(_ directoryURL: URL, in webView: WKWebView) {
        var base = directoryURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        guard let js = JS.call("window.setDocumentBase", args: [base]) else { return }

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting document base: \(error)")
            }
        }
    }

    /// Set the theme for the editor
    /// `arguments` come from `WindowTheme.webArguments`: the appearance id and the accent or null.
    func setTheme(_ arguments: String, in webView: WKWebView) {
        let js = "window.setTheme(\(arguments))"

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error setting theme: \(error)")
            }
        }
    }

    /// Scroll to a specific heading (AR-04: JSON-encoded argument)
    func scrollToHeading(_ headingId: String, in webView: WKWebView) {
        guard let js = JS.call("window.scrollToHeading", args: [headingId]) else { return }

        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("Error scrolling to heading: \(error)")
            }
        }
    }
}

extension SemanticBlock {
    /// A block of a `blocksChanged` message. An unknown block type is a paragraph.
    init(_ block: EditorMessage.BlocksChanged.Block) {
        id = block.id
        documentId = block.documentId ?? ""
        type = BlockType(rawValue: block.type) ?? .paragraph
        level = block.level
        content = block.content
        plainText = block.plainText ?? block.content
        contentHash = block.contentHash
        semanticHash = block.semanticHash
        headingPath = block.headingPath ?? []
        parentBlockId = block.parentBlockId
        lineStart = block.lineStart
        lineEnd = block.lineEnd
        position = block.position
        language = block.language
        anchor = block.anchor
    }
}

// MARK: - Bridge Delegate Protocol

protocol WebViewBridgeDelegate: AnyObject {
    func bridge(_ bridge: WebViewBridge, didUpdateContent content: String, documentID: UUID?)
    func bridge(_ bridge: WebViewBridge, didExtractHeadings headings: [HeadingItem])
    func bridge(_ bridge: WebViewBridge, didSelectHeading headingId: String)
    func bridge(_ bridge: WebViewBridge, didClickLink href: String)
    func bridge(_ bridge: WebViewBridge, didReceiveBlocksDelta delta: BlocksDelta)
    func bridgeEditorReady(_ bridge: WebViewBridge)
    /// The document text size the page's slider shows, for the document text this window hosts natively.
    func bridge(_ bridge: WebViewBridge, didChangeEditorFontSize size: Double)
    /// A choice the page keeps for its own window (`EditorWindowPrefs.keys`).
    func bridge(_ bridge: WebViewBridge, didSetWindowPref key: String, value: String)
    func bridgeSaveRequested(_ bridge: WebViewBridge, documentID: UUID?)
    func bridge(_ bridge: WebViewBridge, didRequestTranslation markdown: String, targetLang: String)
    func bridge(_ bridge: WebViewBridge, didRequestSelectionAction action: String, text: String)
    func bridge(_ bridge: WebViewBridge, didRequestFeatureAction action: String, text: String, question: String)
    func bridgeRefreshRequested(_ bridge: WebViewBridge)
    func bridge(_ bridge: WebViewBridge, didRequestGraph type: String, prompt: String, content: String)
    func bridge(_ bridge: WebViewBridge, didRequestCanvasOpenFile path: String)
    func bridge(_ bridge: WebViewBridge, didReceiveArchitectureAction action: String, payload: [String: Any])
    func bridge(_ bridge: WebViewBridge, didReceiveCodeAction action: String, payload: [String: Any])
    func bridge(_ bridge: WebViewBridge, didReceiveResearchMapAction action: String, payload: [String: Any], documentID: UUID?)

    // MARK: Insight messages (Recursive Insight v2, Task 7)
    //
    // V2 protocol: JS→Swift messages only the top frame may send (`mainFrameOnly` in the contract).
    // The contract validates the payload schema (presence, non-empty strings, Int bounds, UUID
    // shape); higher-level validation (skeleton membership, manifest membership, retry rate
    // limit) lives in WorkspaceManager (T8).
    func bridge(_ bridge: WebViewBridge, didReceiveInsightIframeReady sessionId: String, nodeId: String)
    func bridge(_ bridge: WebViewBridge, didRequestInsightDeepDive sessionId: String, sectionId: String, topicIndex: Int)
    func bridge(_ bridge: WebViewBridge, didRequestInsightBreadcrumb sessionId: String, nodeId: String)
    func bridgeRequestInsightSave(_ bridge: WebViewBridge)
    func bridgeRequestInsightUp(_ bridge: WebViewBridge)
    func bridgeRequestInsightRegenerate(_ bridge: WebViewBridge)
    func bridgeRequestInsightCustomDeepDive(_ bridge: WebViewBridge, topic: String)
    func bridgeRequestInsightExploreAll(_ bridge: WebViewBridge, depth: Int)
    func bridgeRequestInsightRetrySection(_ bridge: WebViewBridge, sectionId: String)
}
