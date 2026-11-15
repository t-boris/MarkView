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
    print("Phase 7 — Web Primitives, Bridge & Workflow Assets Tests")
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fm = FileManager.default

    // 1. AR-28 & AR-29: mv-kit.js provides window.mvKit + window.mvBridge and executes runtime helpers
    let mvKitPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/js/mv-kit.js")
    let mvKitSrc = (try? String(contentsOf: mvKitPath, encoding: .utf8)) ?? ""
    check(!mvKitSrc.isEmpty, "mv-kit.js exists in MarkView/Resources/Editor/js/ (AR-28, AR-29)")

    if let ctx = JSContext() {
        ctx.evaluateScript("var window = this; var __sent = []; window.webkit = { messageHandlers: { bridge: { postMessage: function(m) { __sent.push(m); } } } };")
        ctx.evaluateScript(mvKitSrc)

        let escaped = ctx.evaluateScript("mvKit.escapeHtml(\"<script>'\\\"&\")")?.toString() ?? ""
        check(escaped == "&lt;script&gt;&#39;&quot;&amp;",
              "mvKit.escapeHtml escapes HTML/attribute special characters at runtime (AR-29)")

        let attrEscaped = ctx.evaluateScript("mvKit.escapeAttr(\"`test`\")")?.toString() ?? ""
        check(attrEscaped == "&#96;test&#96;",
              "mvKit.escapeAttr escapes backticks for HTML attributes (AR-29)")

        let sendJSON = ctx.evaluateScript("mvBridge.send('ping', { ok: true }); JSON.stringify(__sent);")?.toString() ?? "[]"
        if let sendData = sendJSON.data(using: .utf8),
           let items = try? JSONSerialization.jsonObject(with: sendData) as? [[String: Any]],
           let first = items.first,
           let payload = first["payload"] as? [String: Any] {
            check((first["type"] as? String) == "ping" && (payload["ok"] as? Bool) == true,
                  "mvBridge.send delivers structured JSON messages to webkit.messageHandlers.bridge (AR-28)")
        } else {
            check(false, "mvBridge.send delivers structured JSON messages")
        }

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
            let callsJSON = ctx.evaluateScript("sendToSwift('headingsExtracted', { count: 2 }); JSON.stringify(__mvBridgeCalls);")?.toString() ?? "[]"
            if let callsData = callsJSON.data(using: .utf8),
               let calls = try? JSONSerialization.jsonObject(with: callsData) as? [[String: Any]],
               let firstCall = calls.first {
                check((firstCall["type"] as? String) == "headingsExtracted" && (firstCall["channel"] as? String) == "bridge",
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

    // 2. HTML entry points and active GitHub workflow files exist; superseded per-feature workflows removed
    for htmlName in ["index.html", "discussion.html", "book.html", "terminal.html"] {
        let htmlPath = repoRoot.appendingPathComponent("MarkView/Resources/Editor/\(htmlName)")
        check(fm.fileExists(atPath: htmlPath.path), "\(htmlName) exists in Resources/Editor/")
    }

    for wf in ["ci.yml", "build-release.yml", "publish-release.yml", "copilot-cockpit.yml", "remote-workspace.yml"] {
        let wfPath = repoRoot.appendingPathComponent(".github/workflows/\(wf)")
        check(fm.fileExists(atPath: wfPath.path), ".github/workflows/\(wf) exists (AR-45)")
    }

    for removedWf in ["bug-validity.yml", "document-files.yml", "editor-diagrams.yml", "pdf-book.yml", "themes.yml"] {
        let removedPath = repoRoot.appendingPathComponent(".github/workflows/\(removedWf)")
        check(!fm.fileExists(atPath: removedPath.path),
              "Superseded workflow \(removedWf) removed in favor of unified ci.yml (AR-45, DEC-008)")
    }

    // 3. tasks/todo.md archive rotation exists on disk
    let todoSrc = (try? String(contentsOf: repoRoot.appendingPathComponent("tasks/todo.md"), encoding: .utf8)) ?? ""
    let archiveExists = fm.fileExists(atPath: repoRoot.appendingPathComponent("tasks/archive/todo-archive-2026-11.md").path)
    check(archiveExists && todoSrc.components(separatedBy: "\n").count < 500,
          "tasks/todo.md rotated into tasks/archive/todo-archive-2026-11.md (AR-49)")
}

runPhase7WebCITests()
if failures > 0 {
    print("FAILED: \(failures) check(s)")
    exit(1)
}
print("All Phase 7 web & workflow checks passed.")
