import Foundation
import JavaScriptCore
import SwiftUI

// AR-28: one declared bridge contract (MarkView/Resources/Editor/js/bridge-contract.json) used by both sides.
//   1. Every handler the app registers is in the contract and every contract message has a handler (both directions, per channel).
//   2. A message that matches the contract decodes into its payload type and reaches its handler; one that does not is refused.
//   3. The page's validator (mv-kit.js, run in JavaScriptCore) and the app's validator (BridgeContract.problem) agree on every
//      case: contract-valid samples, and the same samples broken one rule at a time.
//   4. A refusal is logged by type and field name only, never by value.
// The real sources run: TypedWebBridge, PageMessages, WebViewBridge and the discussion page's coordinator are compiled in; only the
// collaborators of the last two are replaced by the small stand-ins in BridgeContractSupport.swift. Run through tools/tests/bridge-contract-tests.sh
// (argument 1: the bundled editor folder).

var failures = 0
func check(_ ok: Bool, _ message: String, _ detail: String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(message) \(ok ? "" : String(detail.prefix(500)))")
}

let editor = CommandLine.arguments[1]
let contractURL = URL(fileURLWithPath: editor + "/js/bridge-contract.json")
BridgeContract.bundledURL = contractURL
let contract: BridgeContract
do { contract = try BridgeContract(contentsOf: contractURL) } catch { print("FAIL cannot load the contract: \(error)"); exit(1) }
let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: contractURL)) as! [String: Any]
let definitions = raw["definitions"] as? [String: Any] ?? [:]
let rawChannels = raw["channels"] as! [String: Any]

check(Set(contract.channels.keys) == ["bridge", "discussion", "terminal"], "the contract declares the channels bridge, discussion and terminal", "\(contract.channels.keys)")
let counts = contract.channels.mapValues { $0.count }
print("contract messages per channel: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

// MARK: - 1. Handlers and contract, both directions

func compare(_ channel: String, registered: Set<String>, label: String? = nil) {
    let declared = contract.messageTypes(in: channel)
    let name = label ?? channel
    check(registered.subtracting(declared).isEmpty, "\(name): every registered handler is in the contract (\(registered.count) handlers)",
          "handlers not in the contract: \(registered.subtracting(declared).sorted())")
    check(declared.subtracting(registered).isEmpty, "\(name): every contract message has a handler (\(declared.count) messages)",
          "contract messages without a handler: \(declared.subtracting(registered).sorted())")
}

let delegate = RecordingDelegate()
let editorBridge = WebViewBridge(contract: contract)
editorBridge.delegate = delegate
var refusals: [String] = []
editorBridge.messages.reject = { refusals.append($0) }
compare("bridge", registered: editorBridge.messages.registeredTypes)
compare("discussion", registered: DiscussionThreadView.Coordinator().messages.registeredTypes)

// The terminal and discussion payload types, for the decode check below. The terminal host (TerminalSession) is compared with the
// contract by the terminal suites, which run the real session.
let terminalBridge = TypedWebBridge(channel: "terminal", contract: contract)
var terminalHandled: [String] = []
terminalBridge.on(TerminalMessage.Ready.self) { _ in terminalHandled.append("ready") }
terminalBridge.on(TerminalMessage.Input.self) { _ in terminalHandled.append("input") }
terminalBridge.on(TerminalMessage.Resize.self) { _ in terminalHandled.append("resize") }
terminalBridge.on(TerminalMessage.PasteFiles.self) { _ in terminalHandled.append("pasteFiles") }
terminalBridge.on(TerminalMessage.Link.self) { _ in terminalHandled.append("link") }
terminalBridge.on(TerminalMessage.ResolveLinks.self) { _ in terminalHandled.append("resolveLinks") }
compare("terminal", registered: terminalBridge.registeredTypes, label: "terminal payload types")
let discussionBridge = TypedWebBridge(channel: "discussion", contract: contract)
var discussionHandled: [String] = []
discussionBridge.on(DiscussionMessage.Ready.self) { _ in discussionHandled.append("ready") }
discussionBridge.on(DiscussionMessage.Copy.self) { _ in discussionHandled.append("copy") }
discussionBridge.on(DiscussionMessage.Save.self) { _ in discussionHandled.append("save") }
compare("discussion", registered: discussionBridge.registeredTypes, label: "discussion payload types")

// MARK: - Samples built from the contract

func parts(_ spec: Any) -> (type: String, optional: Bool, options: [String: Any]) {
    if let name = spec as? String { return name.hasSuffix("?") ? (String(name.dropLast()), true, [:]) : (name, false, [:]) }
    let object = spec as! [String: Any]
    var name = object["type"] as! String
    var optional = object["optional"] as? Bool ?? false
    if name.hasSuffix("?") { name.removeLast(); optional = true }
    return (name, optional, object)
}

/// The spec a definition name stands for, or the spec itself.
func resolved(_ spec: Any) -> (type: String, optional: Bool, options: [String: Any]) {
    let p = parts(spec)
    if let definition = definitions[p.type] {
        let inner = parts(definition)
        return (inner.type, p.optional || inner.optional, inner.options)
    }
    return p
}

func sample(_ spec: Any) -> Any {
    let p = resolved(spec)
    switch p.type {
    case "string":
        if let allowed = p.options["enum"] as? [String] { return allowed[0] }
        if p.options["format"] as? String == "uuid" { return "8E1C4B52-0C2E-4D77-9A53-0F0B2E5A7C11" }
        return "sample"
    case "int":
        return Int(p.options["min"] as? Double ?? 0)
    case "number":
        return 12.5
    case "boolean":
        return true
    case "object":
        var out: [String: Any] = [:]
        for (name, field) in (p.options["fields"] as? [String: Any] ?? [:]) { out[name] = sample(field) }
        return out
    case "array":
        return p.options["items"].map { [sample($0)] } ?? []
    default:
        return "any"
    }
}

func payloadSpec(_ message: [String: Any]) -> Any {
    if let fields = message["fields"] { return ["type": "object", "fields": fields] as [String: Any] }
    return ["type": "array", "items": message["items"]!] as [String: Any]
}

/// Copies of `value` broken one rule at a time: (what was broken, the broken value).
func mutations(_ spec: Any, _ value: Any) -> [(String, Any)] {
    let p = resolved(spec)
    var out: [(String, Any)] = []
    switch p.type {
    case "string":
        out.append(("not a string", 7))
        if p.options["nonEmpty"] as? Bool == true { out.append(("empty", "")) }
        if p.options["enum"] != nil { out.append(("not a declared value", "no-such-value")) }
        if p.options["format"] as? String == "uuid" { out.append(("not a UUID", "not-a-uuid")) }
    case "int", "number":
        out.append(("not a number", "7"))
        out.append(("a boolean", true))
        if p.type == "int" { out.append(("fractional", 1.5)) }
        if let min = p.options["min"] as? Double { out.append(("below minimum", min - 1)) }
        if let max = p.options["max"] as? Double { out.append(("above maximum", max + 1)) }
    case "boolean":
        out.append(("not a boolean", "true"))
        out.append(("a number", 1))
    case "object":
        out.append(("not an object", "text"))
        let fields = p.options["fields"] as? [String: Any] ?? [:]
        let object = value as! [String: Any]
        for (name, field) in fields {
            if !resolved(field).optional {
                var broken = object; broken.removeValue(forKey: name)
                out.append(("\(name) missing", broken))
                var nulled = object; nulled[name] = NSNull()
                out.append(("\(name) null", nulled))
            }
            for (what, replacement) in mutations(field, object[name]!) {
                var broken = object; broken[name] = replacement
                out.append(("\(name): \(what)", broken))
            }
        }
    case "array":
        out.append(("not an array", "text"))
        if let items = p.options["items"], let array = value as? [Any], let first = array.first {
            for (what, replacement) in mutations(items, first) { out.append(("[0]: \(what)", [replacement])) }
        }
        if let maxItems = p.options["maxItems"] as? Int { out.append(("too many items", Array(repeating: "x", count: maxItems + 1))) }
    default:
        break
    }
    return out
}

// MARK: - 2. Delivery through the real handlers

let expectedCall: [String: String] = [
    "ready": "bridgeEditorReady", "contentChanged": "didUpdateContent", "headingsUpdated": "didExtractHeadings",
    "scrollPosition": "didSelectHeading", "linkClicked": "didClickLink", "editorFontSize": "didChangeEditorFontSize",
    "editorWindowPref": "didSetWindowPref", "blocksChanged": "didReceiveBlocksDelta", "canvasOpenFile": "didRequestCanvasOpenFile",
    "saveRequested": "bridgeSaveRequested", "translateRequested": "didRequestTranslation", "selectionAction": "didRequestSelectionAction",
    "featureAction": "didRequestFeatureAction", "refreshRequested": "bridgeRefreshRequested", "generateGraph": "didRequestGraph:sample::",
    "code": "didReceiveCodeAction", "arch": "didReceiveArchitectureAction", "researchMap": "didReceiveResearchMapAction",
    "insightIframeReady": "didReceiveInsightIframeReady", "insightDeepDiveClicked": "didRequestInsightDeepDive",
    "insightBreadcrumbClicked": "didRequestInsightBreadcrumb", "insightRequestSave": "bridgeRequestInsightSave",
    "insightRequestUp": "bridgeRequestInsightUp", "insightRequestRegenerate": "bridgeRequestInsightRegenerate",
    "insightRequestCustomDeepDive": "bridgeRequestInsightCustomDeepDive", "insightRequestExploreAll": "bridgeRequestInsightExploreAll",
    "insightRequestRetrySection": "bridgeRequestInsightRetrySection",
]
func entry(_ channel: String) -> [String: [String: Any]] {
    ((rawChannels[channel] as! [String: Any])["messages"] as! [String: Any]).mapValues { $0 as! [String: Any] }
}
let editorMessages = entry("bridge")
// `jsError` only logs; every other message of the editor reaches one delegate call.
for (type, message) in editorMessages.sorted(by: { $0.key < $1.key }) {
    // The app's own rule for the window prefs lets only the four keys it keeps through.
    let payload: Any = type == "editorWindowPref" ? ["key": "markview-font-size", "value": "13"] : sample(payloadSpec(message))
    // A top-level payload is the object itself, or the array.
    let envelope: [String: Any] = ["type": type, "payload": payload, "doc": "8E1C4B52-0C2E-4D77-9A53-0F0B2E5A7C11"]
    delegate.calls.removeAll()
    let outcome = editorBridge.messages.receive(body: envelope, isMainFrame: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))   // blocksChanged tells the delegate on the next run loop
    if type == "jsError" {
        check(outcome == .handled, "bridge/jsError: a contract-valid sample is handled (it is logged, not forwarded)", "\(outcome)")
    } else {
        let want = expectedCall[type] ?? "?"
        check(outcome == .handled && delegate.calls == [want], "bridge/\(type): a contract-valid sample reaches \(want)", "\(outcome) \(delegate.calls)")
    }
}
check(editorMessages.count == 28, "the editor channel declares 28 messages", "\(editorMessages.count)")

for (type, message) in entry("terminal").sorted(by: { $0.key < $1.key }) {
    terminalHandled.removeAll()
    let outcome = terminalBridge.receive(body: ["type": type, "payload": sample(payloadSpec(message))], isMainFrame: true)
    check(outcome == .handled && terminalHandled == [type], "terminal/\(type): a contract-valid sample reaches its payload type", "\(outcome)")
}
for (type, message) in entry("discussion").sorted(by: { $0.key < $1.key }) {
    discussionHandled.removeAll()
    let outcome = discussionBridge.receive(body: ["type": type, "payload": sample(payloadSpec(message))], isMainFrame: true)
    check(outcome == .handled && discussionHandled == [type], "discussion/\(type): a contract-valid sample reaches its payload type", "\(outcome)")
}

// What the handlers do with the decoded payload.
do {
    let tab = UUID()
    let d = editorBridge.messages
    delegate.calls.removeAll(); delegate.documentIDs.removeAll()
    d.receive(body: ["type": "contentChanged", "payload": ["markdown": "# A"], "doc": tab.uuidString], isMainFrame: true)
    check(delegate.documentIDs == [tab], "contentChanged names the tab the page showed (BUG-031)", "\(delegate.documentIDs)")
    delegate.documentIDs.removeAll()
    d.receive(body: ["type": "saveRequested", "payload": [String: Any]()], isMainFrame: true)
    check(delegate.documentIDs == [nil], "a message that names no tab names none", "\(delegate.documentIDs)")
    d.receive(body: ["type": "headingsUpdated", "payload": [["id": "h1", "level": 2, "text": "Two"]]], isMainFrame: true)
    check(delegate.lastHeadings.map { "\($0.id)/\($0.level)/\($0.text)" } == ["h1/2/Two"], "headingsUpdated decodes the array payload", "\(delegate.lastHeadings)")
    d.receive(body: ["type": "blocksChanged", "payload": [
        "added": [["id": "b1", "type": "no-such-type", "content": "text", "contentHash": "h", "lineStart": 1, "lineEnd": 2, "position": 0, "level": NSNull(), "headingPath": ["A"]]],
        "removed": ["b0"], "changed": [], "unchanged": ["b2"]]], isMainFrame: true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    check(delegate.lastDelta.map { $0.added.count == 1 && $0.added[0].type == .paragraph && $0.added[0].plainText == "text" && $0.added[0].headingPath == ["A"] && $0.removed == ["b0"] && $0.unchanged == ["b2"] } == true,
          "blocksChanged decodes the blocks (an unknown block type is a paragraph)")
    d.receive(body: ["type": "insightRequestExploreAll", "payload": ["sessionId": NSNull()]], isMainFrame: true)
    check(delegate.lastDepth == 1, "an exploreAll without a depth explores one level", "\(String(describing: delegate.lastDepth))")
    d.receive(body: ["type": "featureAction", "payload": ["action": "ask", "text": "t"]], isMainFrame: true)
    check(delegate.lastQuestion == "", "a featureAction without a question carries an empty one")
    delegate.calls.removeAll()
    d.receive(body: ["type": "generateGraph", "payload": ["type": "edit", "editInstruction": "i", "currentMermaid": "m"]], isMainFrame: true)
    check(delegate.calls == ["didRequestGraph:edit:i:m"], "generateGraph edit passes the instruction and the diagram", "\(delegate.calls)")
    d.receive(body: ["type": "arch", "payload": ["action": "openFile", "path": "a/b.swift", "line": 3]], isMainFrame: true)
    check(delegate.lastPayload["path"] as? String == "a/b.swift" && delegate.lastPayload["line"] as? Int == 3,
          "a sub-protocol message hands the delegate every field of the page's payload")
    delegate.calls.removeAll()
    d.receive(body: ["type": "editorFontSize", "payload": ["size": 99.0]], isMainFrame: true)
    d.receive(body: ["type": "editorWindowPref", "payload": ["key": "not-a-pref", "value": "1"]], isMainFrame: true)
    check(delegate.calls.isEmpty, "the app's own rules (text size range, the window pref keys) still apply after the contract", "\(delegate.calls)")
}

// MARK: - Refusals

refusals.removeAll()
let secret = "TOPSECRET-4711"
var outcomes: [BridgeOutcome] = []
outcomes.append(editorBridge.messages.receive(body: ["type": "linkClicked", "payload": ["href": 42, "extra": secret]], isMainFrame: true))
outcomes.append(editorBridge.messages.receive(body: ["type": "no-such-type\nFAKE LOG LINE", "payload": ["a": secret]], isMainFrame: true))
outcomes.append(editorBridge.messages.receive(body: ["type": "contentChanged", "payload": ["markdown": ["nested": secret]]], isMainFrame: true))
outcomes.append(editorBridge.messages.receive(body: "not a dictionary \(secret)", isMainFrame: true))
outcomes.append(editorBridge.messages.receive(body: ["payload": ["a": 1]], isMainFrame: true))
outcomes.append(editorBridge.messages.receive(body: ["type": 5, "payload": [String: Any]()], isMainFrame: true))
check(outcomes.allSatisfy { if case .rejected = $0 { return true } else { return false } }, "a malformed, undeclared or mistyped message is refused", "\(outcomes)")
check(refusals.count == 6, "each refusal is logged once", "\(refusals)")
check(!refusals.contains { $0.contains(secret) || $0.contains("42") }, "a refusal names the type and the field, never a value", "\(refusals)")
check(!refusals.contains { $0.contains("\n") }, "a type name from the page cannot forge a log line", "\(refusals)")
check(refusals.allSatisfy { $0.count < 200 }, "a refusal line stays short", "\(refusals.map { $0.count })")

// A message only the top frame may send, from a sub-frame.
for (type, message) in editorMessages where message["mainFrameOnly"] as? Bool == true {
    let body: [String: Any] = ["type": type, "payload": sample(payloadSpec(message))]
    let fromFrame = editorBridge.messages.receive(body: body, isMainFrame: false)
    let fromTop = editorBridge.messages.receive(body: body, isMainFrame: true)
    check(fromFrame != .handled && fromTop == .handled, "bridge/\(type): refused from a sub-frame, taken from the top frame", "\(fromFrame) \(fromTop)")
}
check(editorMessages.filter { $0.value["mainFrameOnly"] as? Bool == true }.count == 10, "ten editor messages are top-frame only (researchMap and the nine insight messages)")

// MARK: - 3. The page's validator and the app's validator agree

let context = JSContext()!
var jsErrors: [String] = []
var jsPosted: [[String: Any]] = []
let consoleErrors: @convention(block) (JSValue) -> Void = { jsErrors.append($0.toString() ?? "") }
let post: @convention(block) (JSValue) -> Void = { jsPosted.append($0.toDictionary() as? [String: Any] ?? [:]) }
context.evaluateScript("var window = this; var console = {};")
context.objectForKeyedSubscript("console")!.setObject(consoleErrors, forKeyedSubscript: "error" as NSString)
context.evaluateScript("window.webkit = { messageHandlers: {} };")
for channel in ["bridge", "discussion", "terminal"] {
    let handler = JSValue(newObjectIn: context)!
    handler.setObject(post, forKeyedSubscript: "postMessage" as NSString)
    context.evaluateScript("window.webkit.messageHandlers")!.setObject(handler, forKeyedSubscript: channel as NSString)
}
// The page gets exactly what the app's user script hands it.
context.evaluateScript(contract.userScript.source)
context.evaluateScript(try! String(contentsOfFile: editor + "/js/mv-kit.js", encoding: .utf8))
check(context.evaluateScript("typeof mvBridge.send")!.toString() == "function" && context.evaluateScript("typeof mvBridge.register")!.toString() == "undefined",
      "mv-kit.js gives the page mvBridge.send and nothing of the old string registry")

func jsSends(_ channel: String, _ type: String, _ payload: Any) -> (sent: Bool, error: String) {
    jsPosted.removeAll(); jsErrors.removeAll()
    let json = String(data: try! JSONSerialization.data(withJSONObject: [payload]), encoding: .utf8)!
    let result = context.evaluateScript("mvBridge.send(\(String(data: try! JSONSerialization.data(withJSONObject: [type]), encoding: .utf8)!.dropFirst().dropLast()), JSON.parse('\(json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))')[0], '\(channel)')")!
    return (result.toBool() && jsPosted.count == 1, jsErrors.joined(separator: " | "))
}

var compared = 0
var disagreements: [String] = []
for channel in ["bridge", "discussion", "terminal"] {
    for (type, message) in entry(channel).sorted(by: { $0.key < $1.key }) {
        let spec = payloadSpec(message)
        let valid = sample(spec)
        var cases: [(String, Any, Bool)] = [("valid sample", valid, true)]
        if var object = valid as? [String: Any] {
            object["unlisted"] = "extra"
            cases.append(("an unlisted field", object, true))
            for (name, field) in (message["fields"] as? [String: Any] ?? [:]) where resolved(field).optional {
                var absent = object; absent.removeValue(forKey: name)
                cases.append(("\(name) absent", absent, true))
                var nulled = object; nulled[name] = NSNull()
                cases.append(("\(name) null", nulled, true))
            }
        }
        for (what, broken) in mutations(spec, valid) { cases.append((what, broken, false)) }
        for (what, payload, expected) in cases {
            let swiftSays = contract.problem(with: payload, against: contract.channels[channel]![type]!.payload, at: "payload") == nil
            let jsSays = jsSends(channel, type, payload)
            compared += 1
            if swiftSays != expected || jsSays.sent != expected {
                disagreements.append("\(channel)/\(type) \(what): expected \(expected ? "accept" : "refuse"), app \(swiftSays ? "accepts" : "refuses"), page \(jsSays.sent ? "sends" : "refuses")")
            }
            if !expected && !jsSays.sent && jsSays.error.contains("TOPSECRET") { disagreements.append("\(channel)/\(type) \(what): the page's refusal names a value") }
        }
    }
}
check(disagreements.isEmpty, "the page and the app accept and refuse the same \(compared) cases", disagreements.prefix(8).joined(separator: "\n"))
check(compared > 400, "enough cases were compared (\(compared))")

// What only the page can see: channel and type.
check(!jsSends("bridge", "no-such-type", [String: Any]()).sent && jsErrors.joined().contains("bridge/no-such-type is not in the contract"), "the page refuses a type that is not declared, and says so on the console", jsErrors.joined())
check(!jsSends("nope", "ready", [String: Any]()).sent && jsErrors.joined().contains("channel nope is not in the contract"), "the page refuses a channel that is not declared", jsErrors.joined())
check(!jsSends("terminal", "contentChanged", ["markdown": "x"]).sent, "a type of another channel is refused")
check(jsSends("bridge", "ready", [String: Any]()).sent && jsPosted.first?["type"] as? String == "ready" && jsPosted.first?["payload"] != nil && jsPosted.first?["doc"] as? String == "",
      "a valid message is posted as {type, payload, doc}")
context.evaluateScript("window.mvDocumentId = 'tab-1'")
_ = jsSends("bridge", "ready", [String: Any]())
check(jsPosted.first?["doc"] as? String == "tab-1", "the message names the tab the page shows")
jsPosted.removeAll()
context.evaluateScript("mvBridge.send('ready')")
check(jsPosted.count == 1 && (jsPosted[0]["payload"] as? [String: Any])?.isEmpty == true, "a message without a payload posts an empty one where the contract allows")
// A page with no contract sends nothing, and says so once.
jsPosted.removeAll(); jsErrors.removeAll()
context.evaluateScript("delete window.mvBridgeContract; mvBridge.send('ready', {}, 'bridge'); mvBridge.send('ready', {}, 'bridge');")
check(jsPosted.isEmpty && jsErrors.count == 1 && jsErrors[0].contains("no bridge contract"), "a page without a contract posts nothing and says so once", "\(jsPosted) \(jsErrors)")

print("\(failures) failures")
exit(failures == 0 ? 0 : 1)
