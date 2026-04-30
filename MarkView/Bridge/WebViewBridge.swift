import Foundation
import WebKit
import SwiftUI

/// Message types for JS → Swift communication
/// Must match the strings used in sendToSwift() calls in index.html:
///   - "contentChanged"   : { markdown, html }
///   - "headingsUpdated"  : [{ id, level, text }]
///   - "scrollPosition"   : { activeHeadingId }
///   - "ready"            : {}

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
              let messageType = dict["type"] as? String else { return }

        let payload = dict["payload"]

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

        // All other messages
        let data = payload as? [String: Any]
        handleMessage(type: messageType, data: data)
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

        // MARK: Insight messages (Recursive Insight feature, Task 6)

        case "insightDeepDiveClicked":
            if let sessionId = data?["sessionId"] as? String,
               let topicIndex = data?["topicIndex"] as? Int {
                delegate?.bridge(self, didRequestInsightDeepDive: sessionId, topicIndex: topicIndex)
            }

        case "insightSaveRequested":
            if let sessionId = data?["sessionId"] as? String {
                delegate?.bridge(self, didRequestInsightSave: sessionId)
            }

        case "insightBreadcrumbClicked":
            if let sessionId = data?["sessionId"] as? String,
               let nodeId = data?["nodeId"] as? String {
                delegate?.bridge(self, didRequestInsightBreadcrumb: sessionId, nodeId: nodeId)
            }

        case "insightUpClicked":
            if let sessionId = data?["sessionId"] as? String {
                delegate?.bridge(self, didRequestInsightUp: sessionId)
            }

        case "insightRetryRequested":
            if let sessionId = data?["sessionId"] as? String {
                delegate?.bridge(self, didRequestInsightRetry: sessionId)
            }

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

    // MARK: Insight commands (Recursive Insight feature, Task 6)

    /// Load a full insight view snapshot (markdown + topics + breadcrumbs) into the
    /// WebView. Encodes the entire `InsightViewSnapshot` as JSON and calls
    /// `window.loadInsightView(<json>)`. Used both on initial render of an insight tab
    /// and on full repaint after navigation (breadcrumb / up / expand / retry).
    func loadInsightView(snapshot: InsightViewSnapshot, into webView: WKWebView) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot),
              let jsonString = String(data: data, encoding: .utf8) else {
            NSLog("[Insight] Error encoding InsightViewSnapshot")
            return
        }
        let js = "window.loadInsightView(\(jsonString))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in loadInsightView: \(error)")
            }
        }
    }

    /// Append a streaming delta chunk to the live buffer for a given session.
    /// JS side coalesces re-renders via a debounce timer (~150 ms).
    func appendInsightDelta(sessionId: String, text: String, into webView: WKWebView) {
        guard let sessionLiteral = encodeStringForJS(sessionId),
              let textLiteral = encodeStringForJS(text) else {
            NSLog("[Insight] Error encoding appendInsightDelta payload")
            return
        }
        let js = "window.appendInsightDelta(\(sessionLiteral), \(textLiteral))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in appendInsightDelta: \(error)")
            }
        }
    }

    /// Replace the deep-dive topic list for a given session (after the marker is parsed
    /// or after a full snapshot reload).
    func setInsightDeepDives(sessionId: String, topics: [DeepDiveTopic], into webView: WKWebView) {
        guard let sessionLiteral = encodeStringForJS(sessionId) else {
            NSLog("[Insight] Error encoding setInsightDeepDives sessionId")
            return
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(topics),
              let topicsJSON = String(data: data, encoding: .utf8) else {
            NSLog("[Insight] Error encoding setInsightDeepDives topics")
            return
        }
        let js = "window.setInsightDeepDives(\(sessionLiteral), \(topicsJSON))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightDeepDives: \(error)")
            }
        }
    }

    /// Show a loading indicator with an optional message.
    func showInsightLoading(sessionId: String, message: String, into webView: WKWebView) {
        guard let sessionLiteral = encodeStringForJS(sessionId),
              let messageLiteral = encodeStringForJS(message) else {
            NSLog("[Insight] Error encoding showInsightLoading payload")
            return
        }
        let js = "window.showInsightLoading(\(sessionLiteral), \(messageLiteral))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in showInsightLoading: \(error)")
            }
        }
    }

    /// Display an error banner for the given session. The `retryable` flag controls
    /// whether the JS UI shows a `[Retry]` button (Decision 11 §3 — non-retryable
    /// errors like noAPIKey / parse failures must not show Retry).
    func setInsightError(sessionId: String, message: String, retryable: Bool, into webView: WKWebView) {
        guard let sessionLiteral = encodeStringForJS(sessionId),
              let messageLiteral = encodeStringForJS(message) else {
            NSLog("[Insight] Error encoding setInsightError payload")
            return
        }
        // Bool MUST serialise as the JS literal `true` / `false` (not Python-style
        // `True` / `False`, not `1` / `0`).
        let retryableLiteral = retryable ? "true" : "false"
        let js = "window.setInsightError(\(sessionLiteral), \(messageLiteral), \(retryableLiteral))"
        webView.evaluateJavaScript(js) { _, error in
            if let error = error {
                NSLog("[Insight] Error in setInsightError: \(error)")
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

    // MARK: Insight messages (Recursive Insight feature, Task 6)
    func bridge(_ bridge: WebViewBridge, didRequestInsightDeepDive sessionId: String, topicIndex: Int)
    func bridge(_ bridge: WebViewBridge, didRequestInsightSave sessionId: String)
    func bridge(_ bridge: WebViewBridge, didRequestInsightBreadcrumb sessionId: String, nodeId: String)
    func bridge(_ bridge: WebViewBridge, didRequestInsightUp sessionId: String)
    func bridge(_ bridge: WebViewBridge, didRequestInsightRetry sessionId: String)
}
