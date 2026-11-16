import Foundation
import JavaScriptCore

private var failures = 0

private func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)")
        failures += 1
    }
}

private func runPhase7WebCITests() {
    print("Phase 7 — Web Primitives & Bridge Tests")
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    // 1. AR-28 & AR-29: mv-kit.js provides window.mvKit + window.mvBridge and executes runtime helpers
    let mvKitPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/js/mv-kit.js")
    let mvKitSrc = (try? String(contentsOf: mvKitPath, encoding: .utf8)) ?? ""
    check(!mvKitSrc.isEmpty, "mv-kit.js exists in MarkView/Resources/Editor/js/ (AR-28, AR-29)")

    if let ctx = JSContext() {
        ctx.evaluateScript("var window = this; var __sent = []; window.webkit = { messageHandlers: { bridge: { postMessage: function(m) { __sent.push(m); } } } };")
        // The page gets the contract from the app before mv-kit.js runs (bridge-contract.json, AR-28).
        let contractText = (try? String(contentsOf: repoRoot.appendingPathComponent("MarkView/Resources/Editor/js/bridge-contract.json"), encoding: .utf8)) ?? ""
        ctx.evaluateScript("window.mvBridgeContract = \(contractText);")
        ctx.evaluateScript(mvKitSrc)

        let escaped = ctx.evaluateScript("mvKit.escapeHtml(\"<script>'\\\"&\")")?.toString() ?? ""
        check(escaped == "&lt;script&gt;&#39;&quot;&amp;",
              "mvKit.escapeHtml escapes HTML/attribute special characters at runtime (AR-29)")

        let attrEscaped = ctx.evaluateScript("mvKit.escapeAttr(\"`test`\")")?.toString() ?? ""
        check(attrEscaped == "&#96;test&#96;",
              "mvKit.escapeAttr escapes backticks for HTML attributes (AR-29)")

        let sendJSON = ctx.evaluateScript("mvBridge.send('linkClicked', { href: 'https://example.com' }); JSON.stringify(__sent);")?.toString() ?? "[]"
        if let sendData = sendJSON.data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: sendData) as? [[String: Any]],
           let first = items.first,
           let payload = first["payload"] as? [String: Any] {
            check((first["type"] as? String) == "linkClicked" && (payload["href"] as? String) == "https://example.com",
                  "mvBridge.send delivers structured JSON messages to webkit.messageHandlers.bridge (AR-28)")
        } else {
            check(false, "mvBridge.send delivers structured JSON messages")
        }
        let refusedJSON = ctx.evaluateScript("var __refused = mvBridge.send('ping', { ok: true }); JSON.stringify({ refused: __refused === false, posted: __sent.length });")?.toString() ?? ""
        check(refusedJSON == "{\"refused\":true,\"posted\":1}", "mvBridge.send refuses a message the contract does not declare and posts nothing (AR-28)")

        // Fail-closed sanitization behavior when DOMPurify is absent in JSContext
        let failClosedHtml = ctx.evaluateScript("mvKit.sanitizeHtml('<img src=x onerror=alert(1)>', 'markdown')")?.toString() ?? ""
        let failClosedSvg = ctx.evaluateScript("mvKit.sanitizeMermaidSvg('<svg><script>1</script></svg>')")?.toString() ?? ""
        check(failClosedHtml.hasPrefix("<pre class=\"sanitization-error\">") && !failClosedHtml.contains("<img"),
              "mvKit.sanitizeHtml fails closed when DOMPurify is absent (AR-01)")
        check(failClosedSvg == "<pre class=\"sanitization-error\">Sanitizer unavailable.</pre>",
              "mvKit.sanitizeMermaidSvg fails closed when DOMPurify is absent (AR-01)")

        // Load markview-themes stub + markview-bridge.js and verify sendToSwift routes through mvBridge.send
        let bridgeJSPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/js/markview-bridge.js")
        if let bridgeSrc = try? String(contentsOf: bridgeJSPath, encoding: .utf8) {
            ctx.evaluateScript("""
            var __mvBridgeCalls = [];
            var _origSend = window.mvBridge.send;
            window.mvBridge.send = function(type, payload, channel) {
                __mvBridgeCalls.push({ type: type, payload: payload, channel: channel });
                return _origSend(type, payload, channel);
            };
            var DOM = { editor: { value: '' } };
            var state = { theme: 'dark', markdown: '' };
            var MarkViewThemes = { apply: function(id, accent) { return { mode: 'dark' }; }, mermaid: function() { return {}; } };
            var wysiwygDirty = false;
            function initTurndown() {}
            function switchToPreview() {}
            """)
            ctx.evaluateScript(bridgeSrc)
            let callsJSON = ctx.evaluateScript("sendToSwift('headingsUpdated', [{ id: 'h', level: 1, text: 'T' }]); JSON.stringify(__mvBridgeCalls);")?.toString() ?? "[]"
            if let callsData = callsJSON.data(using: .utf8),
               let calls = try? JSONSerialization.jsonObject(with: callsData) as? [[String: Any]],
               let firstCall = calls.first {
                check((firstCall["type"] as? String) == "headingsUpdated" && (firstCall["channel"] as? String) == "bridge",
                      "markview-bridge.js routes sendToSwift through window.mvBridge.send (AR-28)")
            } else {
                check(false, "markview-bridge.js routes sendToSwift through window.mvBridge.send")
            }
        } else {
            check(false, "markview-bridge.js loads cleanly")
        }
    } else {
        check(false, "JavaScriptCore context initializes cleanly")
    }
}

runPhase7WebCITests()
if failures > 0 {
    print("FAILED: \(failures) check(s)")
    exit(1)
}
print("All Phase 7 web checks passed.")
