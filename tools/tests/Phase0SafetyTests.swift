import Foundation
import WebKit
import Security

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool) {
    if condition {
        passed += 1
        print("ok   \(label)")
    } else {
        failed += 1
        fputs("FAIL \(label)\n", stderr)
    }
}

@MainActor
func loadFile(_ file: URL, allowingReadAccessTo dir: URL, readyJS: String, userScripts: [WKUserScript] = []) async -> WKWebView? {
    let config = WKWebViewConfiguration()
    for script in userScripts { config.userContentController.addUserScript(script) }
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
    webView.loadFileURL(file, allowingReadAccessTo: dir)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if let res = try? await webView.evaluateJavaScript(readyJS) as? Bool, res {
            return webView
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return nil
}

@MainActor
func runPhase0Checks() async throws {
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let editorDir = repoRoot.appendingPathComponent("MarkView/Resources/Editor")
    let indexHTML = try String(contentsOf: editorDir.appendingPathComponent("index.html"), encoding: .utf8)
    let bookHTML = try String(contentsOf: editorDir.appendingPathComponent("book.html"), encoding: .utf8)
    let discussionHTML = try String(contentsOf: editorDir.appendingPathComponent("discussion.html"), encoding: .utf8)

    // AR-01 & AR-03: Strict CSP, no unsafe-inline in script-src across all HTML entry points, vendored Turndown + DOMPurify
    check("AR-01: index.html CSP removes unsafe-inline from script-src",
          indexHTML.contains("script-src 'self' 'wasm-unsafe-eval';") && !indexHTML.contains("'unsafe-inline'") == false && !indexHTML.contains("script-src 'self' 'unsafe-inline'"))
    check("AR-01/FU-13: book.html and discussion.html CSP remove unsafe-inline from script-src",
          bookHTML.contains("script-src 'self';") && !bookHTML.contains("script-src 'self' 'unsafe-inline'") &&
          discussionHTML.contains("script-src 'self';") && !discussionHTML.contains("script-src 'self' 'unsafe-inline'"))
    check("AR-03: index.html has no cdn.jsdelivr.net references",
          !indexHTML.contains("cdn.jsdelivr.net"))
    check("AR-01/AR-03: dompurify.min.js, turndown.min.js, and turndown-plugin-gfm.min.js exist locally",
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/dompurify.min.js").path) &&
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/turndown.min.js").path) &&
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/turndown-plugin-gfm.min.js").path))

    // AR-02 & FU-10: Insight iframe is null-origin sandbox="allow-scripts", uses nonces, no regex-only sanitization fallback
    let insightHandlers = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-insight-handlers.js"), encoding: .utf8)
    let insightSrcdoc = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-insight-srcdoc.js"), encoding: .utf8)
    check("AR-02: markview-insight-handlers sets sandbox='allow-scripts' without allow-same-origin and enforces origin allowlist",
          insightHandlers.contains("setAttribute('sandbox', 'allow-scripts')") &&
          !insightHandlers.contains("setAttribute('sandbox', 'allow-scripts allow-same-origin')") &&
          insightHandlers.contains("ev.origin === 'null'"))
    check("AR-02/FU-10: markview-insight-srcdoc supports per-load CSP nonce and strict Mermaid mode",
          insightSrcdoc.contains("window.__markviewInsightNonce") &&
          insightSrcdoc.contains("securityLevel: 'strict'") &&
          insightSrcdoc.contains("replace(/<\\/(script)/gi"))

    // AR-04: JS.call helper safely encodes quotes, apostrophes, and newlines
    let bridgeSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Bridge/WebViewBridge.swift"), encoding: .utf8)
    check("AR-04: WebViewBridge uses JS.call for setDocumentBase and scrollToHeading",
          bridgeSource.contains("JS.call(\"window.setDocumentBase\"") &&
          bridgeSource.contains("JS.call(\"window.scrollToHeading\""))

    // AR-05: init() is invoked at the end of markview-init.js, not markview-d3-mermaid.js
    let initJS = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-init.js"), encoding: .utf8)
    let d3MermaidJS = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-d3-mermaid.js"), encoding: .utf8)
    check("AR-05: markview-init.js triggers init() after defining it",
          initJS.contains("document.addEventListener('DOMContentLoaded', init)"))
    check("AR-05: markview-d3-mermaid.js does not call init() prematurely",
          !d3MermaidJS.contains("document.addEventListener('DOMContentLoaded', init)"))

    // AR-06: ArchitectureStore resolves PR files off the main actor with a timeout
    let archSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/ArchitectureStore.swift"), encoding: .utf8)
    check("AR-06: ArchitectureStore defines async resolvePRFileURL off the main actor",
          archSource.contains("func resolvePRFileURL(path: String) async -> URL?") &&
          archSource.contains("timeout: 15"))

    // AR-07 / AR-25: InsightArchiveExporter runs zip via MarkViewCore.Subprocess with -q and discards output
    let exporterSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/InsightArchiveExporter.swift"), encoding: .utf8)
    check("AR-07/AR-25: InsightArchiveExporter invokes /usr/bin/zip with -q via Subprocess.run",
          exporterSource.contains("Subprocess.run") &&
          exporterSource.contains("\"-r\", \"-q\", tmpURL.path, \".\""))

    // AR-08: CLICompletion escalates timedOut processes to SIGKILL
    let cliSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/CLICompletion.swift"), encoding: .utf8)
    let sigkillCount = cliSource.components(separatedBy: "SIGKILL").count - 1
    check("AR-08: CLICompletion escalates both cancel and timeout to SIGKILL", sigkillCount >= 2)

    // AR-09 & AR-10: WhisperClient logs character count only, uses Keychain with conditional migration, and WebViewBridge deletes /tmp diag log
    let whisperSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/WhisperClient.swift"), encoding: .utf8)
    check("AR-09: WhisperClient logs character count instead of speech prefix",
          whisperSource.contains("Transcribed \\(text.count) characters") &&
          !whisperSource.contains("text.prefix(100)"))
    check("AR-09: WebViewBridge does not write to /tmp/markview-insight-diag.log",
          !bridgeSource.contains("FileHandle(forWritingTo: URL(fileURLWithPath: path))"))
    check("AR-10/FU-09: WhisperClient stores OpenAI API key in Keychain and removes UserDefaults only on success",
          whisperSource.contains("kSecClassGenericPassword") &&
          whisperSource.contains("if saveAPIKeyToKeychain("))

    // AR-11, AR-12, AR-13, FU-09
    let editorViewSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Views/EditorView.swift"), encoding: .utf8)
    let studioSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/UIStudioSession.swift"), encoding: .utf8)
    let appSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/App/MarkViewApp.swift"), encoding: .utf8)
    let deploySource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/DeploymentExecutor.swift"), encoding: .utf8)
    let intakeSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/FeatureIntake.swift"), encoding: .utf8)
    check("AR-12: developerExtrasEnabled and isInspectable are gated on #if DEBUG",
          editorViewSource.contains("#if DEBUG\n        config.preferences.setValue(true, forKey: \"developerExtrasEnabled\")\n        #endif") &&
          studioSource.contains("#if DEBUG\n        if #available(macOS 13.3, *) { webView.isInspectable = true }\n        #endif"))
    check("FU-10: EditorView injects per-load CSP nonce into index.html and WKUserScript",
          editorViewSource.contains("makeCSPNonce()") && editorViewSource.contains("__markviewInsightNonce"))
    check("AR-12/FU-09: MarkViewApp opens markview_open_path.txt with O_NOFOLLOW + fstat + getuid() in temp & /tmp and shuts down socket on quit",
          appSource.contains("O_RDONLY | O_NOFOLLOW") &&
          appSource.contains("fstat(fd, &st) == 0") &&
          appSource.contains("st.st_uid == getuid()") &&
          appSource.contains("/tmp/markview_open_path.txt") &&
          appSource.contains("BrowserControlServer.shutdown()"))
    check("AR-12: SSHExecutor uses per-user mode-0700 controlSocketDirectory",
          deploySource.contains("controlSocketDirectory()") && deploySource.contains("0o700"))
    check("AR-13: UIStudioSession and FeatureIntake surface file write failures",
          studioSource.contains("Could not write conflict markers") &&
          intakeSource.contains("saving the link into the bug report failed"))

    // Live WebKit check of AR-01/FU-13 sanitization and AR-03 Turndown in shipping index.html
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let nonce = bytes.map { String(format: "%02x", $0) }.joined()
    let nonceScript = WKUserScript(source: "window.__markviewInsightNonce = \"\(nonce)\";", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    let webView = await loadFile(
        editorDir.appendingPathComponent("index.html"),
        allowingReadAccessTo: editorDir,
        readyJS: "typeof window.setContent === 'function' && typeof window.DOMPurify !== 'undefined' && typeof window.DOMPurify.sanitize === 'function' && typeof window.TurndownService === 'function'",
        userScripts: [nonceScript]
    )
    check("AR-01/AR-03: shipping index.html loads DOMPurify and TurndownService offline", webView != nil)

    if let webView {
        let xssCheck = try await webView.evaluateJavaScript(#"""
            (function() {
                window.__xssFired = false;
                window.setContent('# Hello\n\n<script>window.__xssFired = true;</script><img src=x onerror="window.__xssFired=true"><a href="javascript:window.__xssFired=true">js</a><a href="file:///etc/passwd">f</a><a href="data:text/html,<script>1</script>">dh</a><img src="data:image/svg+xml,<svg onload=1>"><img src="data:image/png;base64,AAA=">', 'preview');
                var rendered = document.getElementById('editor-rendered').innerHTML;
                var lower = rendered.toLowerCase();
                var savedPurify = window.DOMPurify;
                var stripWhenMissing = '';
                try {
                    window.DOMPurify = undefined;
                    stripWhenMissing = window.sanitizeMarkdownHTML('<img src=x onerror=alert(1)>');
                } finally {
                    window.DOMPurify = savedPurify;
                }
                return JSON.stringify({
                    xssFired: window.__xssFired,
                    hasScript: lower.indexOf('<script') >= 0,
                    hasOnerror: lower.indexOf('onerror') >= 0,
                    hasJavascriptHref: lower.indexOf('javascript:') >= 0,
                    hasFileScheme: lower.indexOf('file:///') >= 0,
                    hasDataHTML: lower.indexOf('data:text/html') >= 0,
                    hasDataSVG: lower.indexOf('data:image/svg+xml') >= 0,
                    hasPngData: lower.indexOf('data:image/png;base64,aaa=') >= 0,
                    hasHeading: rendered.indexOf('Hello') >= 0,
                    failClosed: stripWhenMissing.indexOf('sanitization-error') >= 0 && stripWhenMissing.indexOf('<img') < 0,
                    cdnStripped: window.stripCDNTags('<canvas data-chart=\'{"type":"bar"}\'></canvas><script>evil()</script><img src=x onerror=alert(1)>')
                });
            })()
        """#) as? String ?? "{}"
        check("AR-01/FU-13: untrusted Markdown script, onerror, javascript:, file:, data:text/html, data:image/svg+xml are stripped while png and heading survive",
              xssCheck.contains("\"xssFired\":false") &&
              xssCheck.contains("\"hasScript\":false") &&
              xssCheck.contains("\"hasOnerror\":false") &&
              xssCheck.contains("\"hasJavascriptHref\":false") &&
              xssCheck.contains("\"hasFileScheme\":false") &&
              xssCheck.contains("\"hasDataHTML\":false") &&
              xssCheck.contains("\"hasDataSVG\":false") &&
              xssCheck.contains("\"hasPngData\":true") &&
              xssCheck.contains("\"hasHeading\":true"))
        check("FU-13/AR-02: sanitizeMarkdownHTML fails closed without DOMPurify and stripCDNTags uses DOMPurify",
              xssCheck.contains("\"failClosed\":true") &&
              xssCheck.contains("data-chart") &&
              !xssCheck.contains("evil()"))
    }

    // Live WebKit check of book.html & discussion.html loading cleanly under script-src 'self' with DOMPurify
    for pageName in ["book.html", "discussion.html"] {
        let pageWeb = await loadFile(
            editorDir.appendingPathComponent(pageName),
            allowingReadAccessTo: editorDir,
            readyJS: "typeof window.DOMPurify === 'function' && typeof window.markdownit === 'function'"
        )
        check("AR-01/FU-13: \(pageName) executes bundled scripts and DOMPurify under script-src 'self'", pageWeb != nil)
    }

    // Live WebKit check of CSP nonce inheritance blocking un-nonced scripts in parent & srcdoc while allowing nonced script
    final class ProbeHandler: NSObject, WKScriptMessageHandler {
        var message: String?
        func userContentController(_ userContentController: WKUserContentController, didReceive msg: WKScriptMessage) {
            message = msg.body as? String
        }
    }
    let handler = ProbeHandler()
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.add(handler, name: "probe")
    let nonceWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: cfg)
    let rawMeta = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'nonce-\(nonce)'; style-src 'self' 'unsafe-inline';\">"
    let childCSP = "default-src 'none'; script-src 'nonce-\(nonce)' blob: data:; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; font-src data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
    let srcdoc = "<!DOCTYPE html><meta http-equiv='Content-Security-Policy' content=\"\(childCSP)\"><script>window.__unnonced=1; parent.postMessage({evil:true},'*');</script><script nonce='\(nonce)'>parent.postMessage({good:true, unnonced: !!window.__unnonced},'*');</script>"
    let srcdocJSON = String(data: try JSONSerialization.data(withJSONObject: srcdoc, options: .fragmentsAllowed), encoding: .utf8)!
    let nonceParentHTML = """
    <!DOCTYPE html><html><head>\(rawMeta)</head><body>
    <script>window.__unnoncedParent = true;</script>
    <script nonce="\(nonce)">
    window.addEventListener('message', function(ev) {
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.probe) {
            window.webkit.messageHandlers.probe.postMessage(JSON.stringify({ origin: ev.origin, data: ev.data, parentUnnonced: !!window.__unnoncedParent }));
        }
    });
    var f = document.createElement('iframe');
    f.sandbox = 'allow-scripts';
    f.srcdoc = \(srcdocJSON);
    document.body.appendChild(f);
    </script></body></html>
    """
    nonceWeb.loadHTMLString(nonceParentHTML, baseURL: nil)
    let nonceDeadline = Date().addingTimeInterval(5)
    while handler.message == nil && Date() < nonceDeadline {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    let msg = handler.message ?? ""
    check("FU-10: Nonced CSP blocks un-nonced parent and srcdoc scripts while allowing nonced Insight iframe execution",
          msg.contains("\"good\":true") && !msg.contains("\"evil\":true") && msg.contains("\"unnonced\":false") && msg.contains("\"parentUnnonced\":false"))
}

let sema = DispatchSemaphore(value: 0)
Task { @MainActor in
    do {
        try await runPhase0Checks()
    } catch {
        failed += 1
        fputs("FAIL unexpected error: \(error)\n", stderr)
    }
    sema.signal()
}
while sema.wait(timeout: .now() + 0.02) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
}
print("Phase 0 safety checks: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
