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

    // 1. Vendored offline dependencies & externalized scripts exist on disk (AR-01, AR-03)
    for relPath in [
        "vendor/js/dompurify.min.js",
        "vendor/js/turndown.min.js",
        "vendor/js/turndown-plugin-gfm.min.js",
        "js/mv-kit.js",
        "js/markview-terminal.js"
    ] {
        check("AR-01/AR-03: \(relPath) exists locally",
              FileManager.default.fileExists(atPath: editorDir.appendingPathComponent(relPath).path))
    }

    // 2. Live WebKit check of AR-01/AR-02/AR-03/FU-10/FU-13 sanitization, style filtering, TOC escaping, SVG sanitization & CSP
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let nonce = bytes.map { String(format: "%02x", $0) }.joined()
    let nonceScript = WKUserScript(source: "window.__markviewInsightNonce = \"\(nonce)\";", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    let webView = await loadFile(
        editorDir.appendingPathComponent("index.html"),
        allowingReadAccessTo: editorDir,
        readyJS: "typeof window.setContent === 'function' && typeof window.DOMPurify !== 'undefined' && typeof window.mvKit === 'object' && typeof window.mvKit.sanitizeHtml === 'function' && typeof window.TurndownService === 'function'",
        userScripts: [nonceScript]
    )
    check("AR-01/AR-03: shipping index.html loads DOMPurify, mvKit, and TurndownService offline", webView != nil)

    if let webView {
        let indexCspMeta = (try? await webView.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
        check("AR-01: index.html runtime CSP enforces script-src without unsafe-inline",
              indexCspMeta.contains("script-src 'self' 'wasm-unsafe-eval'") && !indexCspMeta.contains("script-src 'self' 'unsafe-inline'"))

        let mdCheck = try await webView.evaluateJavaScript(#"""
            (function() {
                window.__xssFired = false;
                window.setContent(
                    '# &lt;img id="toc-evil" src="x"&gt;SafeHeading\n\n' +
                    '<style>body { background: url(https://evil.example/leak); }</style>' +
                    '<div id="styled-bad" style="position:fixed;z-index:9999;background-image:url(https://evil.example/s.png);color:red">styled</div>' +
                    '<span class="katex-like" style="height:1.5em;top:-0.2em">math</span>' +
                    '<script>window.__xssFired = true;</script>' +
                    '<img src=x onerror="window.__xssFired=true">' +
                    '<a href="javascript:window.__xssFired=true">js</a>' +
                    '<a href="file:///etc/passwd">f</a>' +
                    '<a href="data:text/html,<script>1</script>">dh</a>' +
                    '<img src="data:image/svg+xml,<svg onload=1>">' +
                    '<img src="data:image/png;base64,AAA=">',
                    'preview'
                );
                var rendered = document.getElementById('editor-rendered').innerHTML;
                var lower = rendered.toLowerCase();
                var styledBad = document.getElementById('styled-bad');
                var badStyle = styledBad ? (styledBad.getAttribute('style') || '') : '';
                var mathEl = document.querySelector('.katex-like');
                var mathStyle = mathEl ? (mathEl.getAttribute('style') || '') : '';
                var tocImgCount = document.querySelectorAll('#toc-status img').length;
                var tocText = (document.getElementById('toc-status') || {}).textContent || '';

                var svgClean = window.mvKit.sanitizeMermaidSvg('<svg viewBox="0 0 10 10"><style>body{display:none}</style><script>evil()</script><rect width="10" height="10" onclick="evil()"/></svg>');

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
                    hasStyleTag: lower.indexOf('<style') >= 0,
                    hasOnerror: lower.indexOf('onerror') >= 0,
                    hasJavascriptHref: lower.indexOf('javascript:') >= 0,
                    hasFileScheme: lower.indexOf('file:///') >= 0,
                    hasDataHTML: lower.indexOf('data:text/html') >= 0,
                    hasDataSVG: lower.indexOf('data:image/svg+xml') >= 0,
                    hasPngData: lower.indexOf('data:image/png;base64,aaa=') >= 0,
                    hasHeading: rendered.indexOf('SafeHeading') >= 0,
                    badStyleStripped: badStyle.indexOf('fixed') < 0 && badStyle.indexOf('9999') < 0 && badStyle.indexOf('url(') < 0 && badStyle.indexOf('color:red') >= 0,
                    mathStyleKept: mathStyle.indexOf('height:1.5em') >= 0,
                    tocEscaped: tocImgCount === 0 && tocText.indexOf('SafeHeading') >= 0,
                    svgSafe: svgClean.indexOf('<svg') >= 0 && svgClean.indexOf('<rect') >= 0 && svgClean.indexOf('<script') < 0 && svgClean.indexOf('<style') < 0 && svgClean.indexOf('onclick') < 0,
                    failClosed: stripWhenMissing.indexOf('sanitization-error') >= 0 && stripWhenMissing.indexOf('<img') < 0,
                    cdnStripped: window.stripCDNTags('<canvas data-chart=\'{"type":"bar"}\'></canvas><style>p{color:red}</style><script>evil()</script><img src=x onerror=alert(1)>')
                });
            })()
        """#) as? String ?? "{}"

        if let mdData = mdCheck.data(using: .utf8),
           let mdObj = try? JSONSerialization.jsonObject(with: mdData) as? [String: Any] {
            check("AR-01/FU-13: untrusted Markdown script, <style>, dangerous CSS, onerror, javascript:, file:, data:text/html, and data:image/svg+xml are stripped while safe PNG, KaTeX styles, and heading survive",
                  (mdObj["xssFired"] as? Bool) == false &&
                  (mdObj["hasScript"] as? Bool) == false &&
                  (mdObj["hasStyleTag"] as? Bool) == false &&
                  (mdObj["hasOnerror"] as? Bool) == false &&
                  (mdObj["hasJavascriptHref"] as? Bool) == false &&
                  (mdObj["hasFileScheme"] as? Bool) == false &&
                  (mdObj["hasDataHTML"] as? Bool) == false &&
                  (mdObj["hasDataSVG"] as? Bool) == false &&
                  (mdObj["hasPngData"] as? Bool) == true &&
                  (mdObj["hasHeading"] as? Bool) == true &&
                  (mdObj["badStyleStripped"] as? Bool) == true &&
                  (mdObj["mathStyleKept"] as? Bool) == true)
            check("AR-01 (10.3): updateTOCStatus escapes heading HTML instead of injecting live DOM nodes",
                  (mdObj["tocEscaped"] as? Bool) == true)
            check("AR-01 (10.3): mvKit.sanitizeMermaidSvg strips <script>, <style>, and event handlers from SVG",
                  (mdObj["svgSafe"] as? Bool) == true)
            let cdnStripped = (mdObj["cdnStripped"] as? String) ?? ""
            check("FU-13/AR-02: sanitizeMarkdownHTML fails closed without DOMPurify and stripCDNTags uses shared sanitizer",
                  (mdObj["failClosed"] as? Bool) == true &&
                  cdnStripped.contains("data-chart") &&
                  !cdnStripped.contains("evil()") &&
                  !cdnStripped.lowercased().contains("<style"))
        } else {
            check("AR-01/FU-13: live index.html check returned valid JSON", false)
        }

        // Verify buildInsightSrcdoc uses strict nonce-only policy (no blob:/data:) and fails closed to 'none' without nonce
        _ = try? await webView.evaluateJavaScript(#"""
            (function() {
                window.__srcdocCheckResult = null;
                Promise.resolve().then(async function() {
                    var parser = new DOMParser();
                    function extractScriptSrc(html) {
                        var doc = parser.parseFromString(html, 'text/html');
                        var m = doc.querySelector('meta[http-equiv="Content-Security-Policy"]');
                        var content = m ? (m.getAttribute('content') || '') : '';
                        var match = content.match(/(?:^|;)\s*(script-src\s+[^;]+)/i);
                        return match ? match[1].trim() : '';
                    }
                    var withNonceHtml = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
                    var savedNonce = window.__markviewInsightNonce;
                    var withoutNonceHtml = '';
                    try {
                        window.__markviewInsightNonce = undefined;
                        withoutNonceHtml = await window.buildInsightSrcdoc({ title: 'T', sections: [] }, '');
                    } finally {
                        window.__markviewInsightNonce = savedNonce;
                    }
                    window.__srcdocCheckResult = JSON.stringify({
                        withNonceScriptSrc: extractScriptSrc(withNonceHtml),
                        withoutNonceScriptSrc: extractScriptSrc(withoutNonceHtml)
                    });
                }).catch(function(err) {
                    window.__srcdocCheckResult = JSON.stringify({ error: String(err) });
                });
            })()
        """#)
        var srcdocRes: String?
        let srcdocDeadline = Date().addingTimeInterval(5)
        while srcdocRes == nil && Date() < srcdocDeadline {
            if let value = try? await webView.evaluateJavaScript("window.__srcdocCheckResult") as? String {
                srcdocRes = value
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        if let sData = (srcdocRes ?? "{}").data(using: .utf8),
           let sObj = try? JSONSerialization.jsonObject(with: sData) as? [String: String] {
            let withNonceScriptSrc = sObj["withNonceScriptSrc"] ?? ""
            let withoutNonceScriptSrc = sObj["withoutNonceScriptSrc"] ?? ""
            check("FU-10/AR-02: buildInsightSrcdoc uses nonce-only script-src without blob: or data:",
                  withNonceScriptSrc == "script-src 'nonce-\(nonce)'")
            check("FU-10/AR-02: buildInsightSrcdoc fails closed to script-src 'none' when nonce is missing",
                  withoutNonceScriptSrc == "script-src 'none'")
        } else {
            check("FU-10/AR-02: buildInsightSrcdoc async check returned valid JSON", false)
        }
    }

    // 3. Live WebKit check of book.html, discussion.html, and terminal.html strict CSP + external scripts
    for pageName in ["book.html", "discussion.html"] {
        let pageWeb = await loadFile(
            editorDir.appendingPathComponent(pageName),
            allowingReadAccessTo: editorDir,
            readyJS: "typeof window.DOMPurify === 'function' && typeof window.markdownit === 'function' && typeof window.mvKit === 'object' && typeof window.mvKit.sanitizeHtml === 'function'"
        )
        var cspOK = false
        var inlineCount = -1
        if let pageWeb {
            let csp = (try? await pageWeb.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
            inlineCount = (try? await pageWeb.evaluateJavaScript("document.querySelectorAll('script:not([src])').length") as? Int) ?? -1
            cspOK = csp.contains("script-src 'self';") && !csp.contains("script-src 'self' 'unsafe-inline'")
        }
        check("AR-01/FU-13: \(pageName) runs offline under script-src 'self' with mvKit and 0 inline scripts (inline=\(inlineCount))",
              pageWeb != nil && cspOK && inlineCount == 0)
    }

    let termWeb = await loadFile(
        editorDir.appendingPathComponent("terminal.html"),
        allowingReadAccessTo: editorDir,
        readyJS: "typeof window.mvWrite === 'function' && typeof window.mvSetTheme === 'function' && typeof window.mvKit === 'object'"
    )
    var termCSPOK = false
    var termInlineCount = -1
    if let termWeb {
        let csp = (try? await termWeb.evaluateJavaScript("document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')?.content || ''") as? String) ?? ""
        termInlineCount = (try? await termWeb.evaluateJavaScript("document.querySelectorAll('script:not([src])').length") as? Int) ?? -1
        termCSPOK = csp.contains("script-src 'self';") && !csp.contains("script-src 'self' 'unsafe-inline'")
    }
    check("AR-01 (10.3): terminal.html runs under strict CSP script-src 'self' with 0 inline scripts (inline=\(termInlineCount))",
          termWeb != nil && termCSPOK && termInlineCount == 0)

    // 4. Live WebKit check of CSP nonce blocking un-nonced scripts in parent & srcdoc while allowing nonced script
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
    let childCSP = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src 'none'; img-src data: blob:; font-src data:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'"
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
    if let msgData = msg.data(using: .utf8),
       let msgObj = try? JSONSerialization.jsonObject(with: msgData) as? [String: Any],
       let dataObj = msgObj["data"] as? [String: Any] {
        check("FU-10: Nonced CSP blocks un-nonced parent and srcdoc scripts while allowing nonced Insight iframe execution",
              (dataObj["good"] as? Bool) == true &&
              dataObj["evil"] == nil &&
              (dataObj["unnonced"] as? Bool) == false &&
              (msgObj["parentUnnonced"] as? Bool) == false)
    } else {
        check("FU-10: Nonced CSP iframe test received structured probe message", false)
    }
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
