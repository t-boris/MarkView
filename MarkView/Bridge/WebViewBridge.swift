import Foundation
import WebKit
import SwiftUI
#if canImport(MarkViewCore)
import MarkViewCore
#endif

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

    // MARK: - Commands to JavaScript
    //
    // Every command is a `JS.call` of a page function with JSON-encoded arguments (AR-04): no value is ever spliced into script text.

    /// Names the tab whose document the page shows next; the page names it in every message (`sendToSwift`). It runs in the same
    /// script as the load so no message can pair the new id with the old document. An empty id means the page shows no tab's
    /// document. `mvSetDocument` first hands unsaved WYSIWYG edits of the previous document to the app under the previous id
    /// (BUG-043).
    private static func documentIDCall(_ id: UUID?) -> String? {
        JS.call("window.mvSetDocument", args: [id?.uuidString ?? ""])
    }

    /// Runs `script` and logs `what` when the page reports an error; nil (a value that could not be encoded) is logged and dropped.
    private func run(_ script: String?, what: String, in webView: WKWebView, completion: (() -> Void)? = nil) {
        guard let script else {
            AppLog.bridge.error("Error \(what): the arguments could not be encoded")
            completion?()
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error { AppLog.bridge.error("Error \(what): \(error)") }
            completion?()
        }
    }

    /// Tell the page that no tab's document is on screen (an insight or the X-Ray replaces it).
    func clearDocument(in webView: WKWebView) {
        guard let script = Self.documentIDCall(nil) else { return }
        webView.evaluateJavaScript(script)
    }

    /// Load markdown content into the editor; `documentID` is the tab that owns it.
    func loadContent(_ markdown: String, documentID: UUID?, into webView: WKWebView, completion: @escaping () -> Void) {
        run(JS.sequence([Self.documentIDCall(documentID), JS.call("window.setContent", args: [markdown])]),
            what: "setting content", in: webView, completion: completion)
    }

    /// Render the Architecture tab (markview-architecture-*.js). `json` is a JSON object text.
    func showArchitecture(_ json: String, in webView: WKWebView) {
        run(JS.call("window.showArchitecture", args: [JS.JSONText(json)], ifDefined: true), what: "rendering architecture", in: webView)
    }

    /// Live AI-analysis progress for the Architecture tab. `json` is a JSON object text or "null".
    func setArchitectureProgress(_ json: String, in webView: WKWebView) {
        run(JS.call("window.setArchitectureProgress", args: [JS.JSONText(json)], ifDefined: true), what: "sending the architecture progress", in: webView)
    }

    /// Project operations are updated independently of the much larger X-Ray snapshot.
    func setProjectOperations(_ json: String, in webView: WKWebView) {
        run(JS.call("window.setProjectOperations", args: [JS.JSONText(json)], ifDefined: true), what: "sending the project operations", in: webView)
    }

    /// The state of the research map the page shows (markview-research-map-*.js). `json` is a JSON object text.
    func setResearchMap(_ json: String, documentID: UUID?, in webView: WKWebView) {
        run(JS.call("window.mvResearchMapSet", args: [documentID?.uuidString ?? "", JS.JSONText(json)], ifDefined: true),
            what: "sending the research map", in: webView)
    }

    /// Show source code read-only in the code viewer (markview-code.js).
    func loadCodeContent(_ content: String, language: String, fileName: String, returnLabel: String = "", documentID: UUID?, into webView: WKWebView) {
        run(JS.sequence([Self.documentIDCall(documentID), JS.call("window.setCodeContent", args: [content, language, fileName, returnLabel])]),
            what: "setting code content", in: webView)
    }

    /// Margin notes for the file in the code viewer (markview-code.js). `json` is a JSON object text.
    func setCodeNotes(_ json: String, in webView: WKWebView) {
        run(JS.call("window.setCodeNotes", args: [JS.JSONText(json)], ifDefined: true), what: "sending the code notes", in: webView)
    }

    /// A go-to-definition / usages result or an AI answer for the code viewer.
    func sendCodeNavEvent(_ json: String, in webView: WKWebView) {
        run(JS.call("window.onCodeNavEvent", args: [JS.JSONText(json)], ifDefined: true), what: "sending the code navigation event", in: webView)
    }

    /// Select and centre 1-based lines in the code viewer (queued while it loads).
    func revealCodeLine(_ line: Int, endLine: Int?, in webView: WKWebView) {
        run(JS.call("window.codeGotoLine", args: [line, endLine ?? line], ifDefined: true), what: "revealing a code line", in: webView)
    }

    /// Show a key of a JSON / YAML file: its node in the tree viewer, or its line in a source view. `pathJSON` is the key path as JSON text.
    func revealStructure(pathJSON: String, line: Int, in webView: WKWebView) {
        run(JS.call("window.revealStructure", args: [pathJSON, line], ifDefined: true), what: "revealing a key", in: webView)
    }

    func revealDocumentLine(_ line: Int, in webView: WKWebView) {
        run(JS.call("window.documentGotoLine", args: [line], ifDefined: true), what: "revealing a document line", in: webView)
    }

    /// Show a data file (table, Parquet, SQLite, log): the page fetches it from `markview-data:`.
    /// `reload`: the same file changed on disk (a followed log keeps following).
    func loadDataContent(_ url: URL, fileType: String, reload: Bool, documentID: UUID?, into webView: WKWebView) {
        let source = DataFileSchemeHandler.address(of: url)
        let payload: [String: Any] = ["src": source, "kind": fileType, "name": url.lastPathComponent, "reload": reload]
        run(JS.sequence([Self.documentIDCall(documentID), JS.call("window.setDataContent", args: [payload], ifDefined: true)]),
            what: "setting data content", in: webView)
    }

    func loadStructuredContent(_ content: String, fileType: String, documentID: UUID?, into webView: WKWebView, completion: @escaping () -> Void) {
        run(JS.sequence([Self.documentIDCall(documentID), JS.call("window.setStructuredContent", args: [content, fileType])]),
            what: "setting structured content", in: webView, completion: completion)
    }

    // MARK: - v2 Insight commands (Recursive Insight, Task 7)
    //
    // The Swift→JS setters that drive the parent JS that owns the sandboxed insight iframe (Decision 2). Booleans are JSON
    // `true`/`false` (never `1`/`0`: the parent JS branches on the literal). The skeleton is encoded with `JSONEncoder`
    // and handed over as `JS.JSONText`.

    /// Diagnostic logger for Insight bridge events (AR-09: never writes to world-readable /tmp files
    /// and never logs document or section contents).
    static func logInsightDiag(_ message: String) {
        try? FileManager.default.removeItem(atPath: "/tmp/markview-insight-diag.log")
        #if DEBUG
        AppLog.insight.debug("\(message)")
        #endif
    }

    /// Phase-1 paint: tell parent JS to (re)build the iframe srcdoc placeholder
    /// grid for `skeleton` and switch to insight view. Parent owns the iframe;
    /// the bridge speaks only to the parent (not to the iframe).
    /// Calls `window.loadInsightSkeleton(skeleton, sessionId, nodeId, breadcrumbs)`.
    func loadInsightSkeleton(skeleton: InsightSkeleton, sessionId: String, nodeId: String, breadcrumbs: [(String, String)] = [], into webView: WKWebView) {
        // Empty breadcrumbs mean "use the skeleton title as a single root crumb" — that's the JS fallback. They are passed
        // separately so the Codable InsightSkeleton schema (used for cache snapshots + tool_use validation) stays unchanged.
        let crumbs = breadcrumbs.map { ["nodeId": $0.0, "title": $0.1] }
        guard let skeletonJSON = JS.JSONText(encoding: skeleton),
              // `window.loadInsightSkeleton` is `async function` → returns a Promise; discarding it avoids the
              // "unsupported type" error from evaluateJavaScript.
              let js = JS.call("window.loadInsightSkeleton", args: [skeletonJSON, sessionId, nodeId, crumbs], discardingResult: true) else {
            AppLog.insight.error("Error in loadInsightSkeleton: failed to encode payload")
            Self.logInsightDiag("loadInsightSkeleton: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval loadInsightSkeleton (bytes=\(js.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLog.insight.error("Error in loadInsightSkeleton: \(error)")
                Self.logInsightDiag("eval failed for loadInsightSkeleton: error=\(error.localizedDescription)")
            }
        }
    }

    /// Phase-2 streaming: forward a per-section HTML delta to parent JS, which
    /// relays into the iframe via `iframe.contentWindow.postMessage` (the iframe
    /// is sandboxed null-origin, so postMessage is the only inbound channel).
    /// Calls `window.updateInsightSection(sessionId, sectionId, htmlChunk)`.
    func updateInsightSection(sessionId: String, sectionId: String, htmlChunk: String, into webView: WKWebView) {
        guard let js = JS.call("window.updateInsightSection", args: [sessionId, sectionId, htmlChunk]) else {
            AppLog.insight.error("Error in updateInsightSection: failed to encode payload")
            Self.logInsightDiag("updateInsightSection: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval updateInsightSection (chunkBytes=\(htmlChunk.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLog.insight.error("Error in updateInsightSection: \(error)")
                Self.logInsightDiag("eval failed for updateInsightSection: error=\(error.localizedDescription)")
            }
        }
    }

    /// Render an error banner in parent chrome (status bar). `retryable` is a
    /// JSON boolean `true`/`false` — NEVER `1`/`0` (the parent JS branches on the
    /// literal). Regression guard from v1 round-2 fix.
    /// Calls `window.setInsightError(sessionId, message, retryable)`.
    func setInsightError(sessionId: String, message: String, retryable: Bool, into webView: WKWebView) {
        guard let js = JS.call("window.setInsightError", args: [sessionId, message, retryable]) else {
            AppLog.insight.error("Error in setInsightError: failed to encode payload")
            Self.logInsightDiag("setInsightError: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval setInsightError (msgBytes=\(message.utf8.count))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLog.insight.error("Error in setInsightError: \(error)")
                Self.logInsightDiag("eval failed for setInsightError: error=\(error.localizedDescription)")
            }
        }
    }

    /// Update the bottom status bar in parent chrome
    /// (e.g. "Phase 2: 3/7 sections..."). `phase` is a free-form tag the parent
    /// uses for status-bar tinting (`phase-1`, `phase-2`, `ready`, etc.).
    /// Calls `window.setInsightStatus(sessionId, message, phase)`.
    func setInsightStatus(sessionId: String, message: String, phase: String, into webView: WKWebView) {
        guard let js = JS.call("window.setInsightStatus", args: [sessionId, message, phase]) else {
            AppLog.insight.error("Error in setInsightStatus: failed to encode payload")
            Self.logInsightDiag("setInsightStatus: failed to encode payload")
            return
        }
        Self.logInsightDiag("eval setInsightStatus (phase=\(phase))")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLog.insight.error("Error in setInsightStatus: \(error)")
                Self.logInsightDiag("eval failed for setInsightStatus: error=\(error.localizedDescription)")
            }
        }
    }

    /// Revoke ALL blob URLs created for the closing insight session
    /// (Decision 11 §2). Called by `InsightCoordinator.close` (through its page)
    /// as STEP 1 of 4 (BEFORE `await session.cancel()`) so no in-flight
    /// Combine sub fires after revocation.
    /// Calls `window.releaseInsightBlobs()`.
    func releaseInsightBlobs(into webView: WKWebView) {
        guard let js = JS.call("window.releaseInsightBlobs") else { return }
        Self.logInsightDiag("eval releaseInsightBlobs")
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                AppLog.insight.error("Error in releaseInsightBlobs: \(error)")
                Self.logInsightDiag("eval failed for releaseInsightBlobs: error=\(error.localizedDescription)")
            }
        }
    }

    /// Set the document base URL for resolving relative image/link paths.
    func setDocumentBase(_ directoryURL: URL, in webView: WKWebView) {
        var base = directoryURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        run(JS.call("window.setDocumentBase", args: [base]), what: "setting the document base", in: webView)
    }

    /// Set the theme for the editor
    /// `arguments` come from `WindowTheme.webArguments`: the theme id, the accent or null, and the theme's data.
    func setTheme(_ arguments: WebThemeArguments, in webView: WKWebView) {
        run(JS.call("window.setTheme", args: arguments.list), what: "setting the theme", in: webView)
    }

    /// Scroll to a specific heading.
    func scrollToHeading(_ headingId: String, in webView: WKWebView) {
        run(JS.call("window.scrollToHeading", args: [headingId]), what: "scrolling to a heading", in: webView)
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
