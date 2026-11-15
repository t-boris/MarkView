import Foundation
import SwiftUI

// Shared by tools/tests/bridge-contract-tests.sh and bridge-contract-web-tests.sh.

// Stand-ins for types that cannot be compiled on their own (they pull in the whole app).
struct HeadingItem { let id: String; let level: Int; let text: String }
struct DiscussionTurn: Equatable { var question: String; var answer: String }
enum DiscussionStore { struct Live: Equatable { var question: String; var text: String; var status: String } }
final class WindowTheme: ObservableObject { var firstPaintScript = ""; var webArguments = WebThemeArguments(id: "", accent: nil, payload: "{}") }

/// What the delegate was told, in order.
final class RecordingDelegate: WebViewBridgeDelegate {
    var calls: [String] = []
    var documentIDs: [UUID?] = []
    var lastDepth: Int?
    var lastQuestion: String?
    var lastHeadings: [HeadingItem] = []
    var lastDelta: BlocksDelta?
    var lastPayload: [String: Any] = [:]
    var lastContent: String?
    func bridge(_ bridge: WebViewBridge, didUpdateContent content: String, documentID: UUID?) { calls.append("didUpdateContent"); documentIDs.append(documentID); lastContent = content }
    func bridge(_ bridge: WebViewBridge, didExtractHeadings headings: [HeadingItem]) { calls.append("didExtractHeadings"); lastHeadings = headings }
    func bridge(_ bridge: WebViewBridge, didSelectHeading headingId: String) { calls.append("didSelectHeading") }
    func bridge(_ bridge: WebViewBridge, didClickLink href: String) { calls.append("didClickLink") }
    func bridge(_ bridge: WebViewBridge, didReceiveBlocksDelta delta: BlocksDelta) { calls.append("didReceiveBlocksDelta"); lastDelta = delta }
    func bridgeEditorReady(_ bridge: WebViewBridge) { calls.append("bridgeEditorReady") }
    func bridge(_ bridge: WebViewBridge, didChangeEditorFontSize size: Double) { calls.append("didChangeEditorFontSize") }
    func bridge(_ bridge: WebViewBridge, didSetWindowPref key: String, value: String) { calls.append("didSetWindowPref") }
    func bridgeSaveRequested(_ bridge: WebViewBridge, documentID: UUID?) { calls.append("bridgeSaveRequested"); documentIDs.append(documentID) }
    func bridge(_ bridge: WebViewBridge, didRequestTranslation markdown: String, targetLang: String) { calls.append("didRequestTranslation") }
    func bridge(_ bridge: WebViewBridge, didRequestSelectionAction action: String, text: String) { calls.append("didRequestSelectionAction") }
    func bridge(_ bridge: WebViewBridge, didRequestFeatureAction action: String, text: String, question: String) { calls.append("didRequestFeatureAction"); lastQuestion = question }
    func bridgeRefreshRequested(_ bridge: WebViewBridge) { calls.append("bridgeRefreshRequested") }
    func bridge(_ bridge: WebViewBridge, didRequestGraph type: String, prompt: String, content: String) { calls.append("didRequestGraph:\(type):\(prompt):\(content)") }
    func bridge(_ bridge: WebViewBridge, didRequestCanvasOpenFile path: String) { calls.append("didRequestCanvasOpenFile") }
    func bridge(_ bridge: WebViewBridge, didReceiveArchitectureAction action: String, payload: [String: Any]) { calls.append("didReceiveArchitectureAction"); lastPayload = payload }
    func bridge(_ bridge: WebViewBridge, didReceiveCodeAction action: String, payload: [String: Any]) { calls.append("didReceiveCodeAction"); lastPayload = payload }
    func bridge(_ bridge: WebViewBridge, didReceiveResearchMapAction action: String, payload: [String: Any], documentID: UUID?) {
        calls.append("didReceiveResearchMapAction"); documentIDs.append(documentID); lastPayload = payload
    }
    func bridge(_ bridge: WebViewBridge, didReceiveInsightIframeReady sessionId: String, nodeId: String) { calls.append("didReceiveInsightIframeReady") }
    func bridge(_ bridge: WebViewBridge, didRequestInsightDeepDive sessionId: String, sectionId: String, topicIndex: Int) { calls.append("didRequestInsightDeepDive") }
    func bridge(_ bridge: WebViewBridge, didRequestInsightBreadcrumb sessionId: String, nodeId: String) { calls.append("didRequestInsightBreadcrumb") }
    func bridgeRequestInsightSave(_ bridge: WebViewBridge) { calls.append("bridgeRequestInsightSave") }
    func bridgeRequestInsightUp(_ bridge: WebViewBridge) { calls.append("bridgeRequestInsightUp") }
    func bridgeRequestInsightRegenerate(_ bridge: WebViewBridge) { calls.append("bridgeRequestInsightRegenerate") }
    func bridgeRequestInsightCustomDeepDive(_ bridge: WebViewBridge, topic: String) { calls.append("bridgeRequestInsightCustomDeepDive") }
    func bridgeRequestInsightExploreAll(_ bridge: WebViewBridge, depth: Int) { calls.append("bridgeRequestInsightExploreAll"); lastDepth = depth }
    func bridgeRequestInsightRetrySection(_ bridge: WebViewBridge, sectionId: String) { calls.append("bridgeRequestInsightRetrySection") }
}
