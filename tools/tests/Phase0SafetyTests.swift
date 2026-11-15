import Foundation
import WebKit

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
func runPhase0Checks() async throws {
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let editorDir = repoRoot.appendingPathComponent("MarkView/Resources/Editor")
    let indexHTML = try String(contentsOf: editorDir.appendingPathComponent("index.html"), encoding: .utf8)

    // AR-01 & AR-03: Strict CSP, no unsafe-inline in script-src, no cdn.jsdelivr.net, vendored Turndown + DOMPurify
    check("AR-01: index.html CSP removes unsafe-inline from script-src",
          indexHTML.contains("script-src 'self' 'wasm-unsafe-eval';") && !indexHTML.contains("script-src 'self' 'unsafe-inline'"))
    check("AR-03: index.html has no cdn.jsdelivr.net references",
          !indexHTML.contains("cdn.jsdelivr.net"))
    check("AR-01/AR-03: dompurify.min.js, turndown.min.js, and turndown-plugin-gfm.min.js exist locally",
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/dompurify.min.js").path) &&
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/turndown.min.js").path) &&
          FileManager.default.fileExists(atPath: editorDir.appendingPathComponent("vendor/js/turndown-plugin-gfm.min.js").path))

    // AR-02: Insight iframe is null-origin sandbox="allow-scripts"
    let insightHandlers = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-insight-handlers.js"), encoding: .utf8)
    let insightSrcdoc = try String(contentsOf: editorDir.appendingPathComponent("vendor/js/markview-insight-srcdoc.js"), encoding: .utf8)
    check("AR-02: markview-insight-handlers sets sandbox='allow-scripts' without allow-same-origin",
          insightHandlers.contains("setAttribute('sandbox', 'allow-scripts')") &&
          !insightHandlers.contains("setAttribute('sandbox', 'allow-scripts allow-same-origin')"))
    check("AR-02: markview-insight-srcdoc inlines libraries with escaped </script>",
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

    // AR-07: InsightArchiveExporter passes -q and discards stdout via nullDevice
    let exporterSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/InsightArchiveExporter.swift"), encoding: .utf8)
    check("AR-07: InsightArchiveExporter passes -q and uses FileHandle.nullDevice",
          exporterSource.contains("[\"-r\", \"-q\", tmpURL.path, \".\"]") &&
          exporterSource.contains("FileHandle.nullDevice"))

    // AR-08: CLICompletion escalates timedOut processes to SIGKILL
    let cliSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/CLICompletion.swift"), encoding: .utf8)
    let sigkillCount = cliSource.components(separatedBy: "SIGKILL").count - 1
    check("AR-08: CLICompletion escalates both cancel and timeout to SIGKILL", sigkillCount >= 2)

    // AR-09 & AR-10: WhisperClient logs character count only, uses Keychain, and WebViewBridge deletes /tmp diag log
    let whisperSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/WhisperClient.swift"), encoding: .utf8)
    check("AR-09: WhisperClient logs character count instead of speech prefix",
          whisperSource.contains("Transcribed \\(text.count) characters") &&
          !whisperSource.contains("text.prefix(100)"))
    check("AR-09: WebViewBridge does not write to /tmp/markview-insight-diag.log",
          !bridgeSource.contains("FileHandle(forWritingTo: URL(fileURLWithPath: path))"))
    check("AR-10: WhisperClient stores OpenAI API key in Keychain with migration",
          whisperSource.contains("kSecClassGenericPassword") &&
          whisperSource.contains("saveAPIKeyToKeychain"))

    // AR-11, AR-12, AR-13
    let editorViewSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Views/EditorView.swift"), encoding: .utf8)
    let studioSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/UIStudioSession.swift"), encoding: .utf8)
    let appSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/App/MarkViewApp.swift"), encoding: .utf8)
    let deploySource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/DeploymentExecutor.swift"), encoding: .utf8)
    let intakeSource = try String(contentsOf: repoRoot.appendingPathComponent("MarkView/Models/FeatureIntake.swift"), encoding: .utf8)
    check("AR-12: developerExtrasEnabled and isInspectable are gated on #if DEBUG",
          editorViewSource.contains("#if DEBUG\n        config.preferences.setValue(true, forKey: \"developerExtrasEnabled\")\n        #endif") &&
          studioSource.contains("#if DEBUG\n        if #available(macOS 13.3, *) { webView.isInspectable = true }\n        #endif"))
    check("AR-12: MarkViewApp checks lstat and getuid() in temporaryDirectory",
          appSource.contains("lstat(path, &st) == 0") && appSource.contains("st.st_uid == getuid()"))
    check("AR-12: SSHExecutor uses per-user mode-0700 controlSocketDirectory",
          deploySource.contains("controlSocketDirectory()") && deploySource.contains("0o700"))
    check("AR-13: UIStudioSession and FeatureIntake surface file write failures",
          studioSource.contains("Could not write conflict markers") &&
          intakeSource.contains("saving the link into the bug report failed"))

    // Live WebKit check of AR-01 sanitization and AR-03 Turndown in shipping index.html
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    webView.loadFileURL(editorDir.appendingPathComponent("index.html"), allowingReadAccessTo: editorDir)
    let deadline = Date().addingTimeInterval(10)
    var loaded = false
    while Date() < deadline {
        if let res = try? await webView.evaluateJavaScript("typeof window.setContent === 'function' && typeof window.DOMPurify !== 'undefined' && typeof window.DOMPurify.sanitize === 'function' && typeof window.TurndownService === 'function'") as? Bool, res {
            loaded = true
            break
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    check("AR-01/AR-03: shipping index.html loads DOMPurify and TurndownService offline", loaded)

    let xssCheck = try await webView.evaluateJavaScript("""
        (function() {
            window.__xssFired = false;
            window.setContent('# Hello\\n\\n<script>window.__xssFired = true;</script><img src=x onerror="window.__xssFired=true"><a href="javascript:window.__xssFired=true">bad</a>', 'preview');
            var rendered = document.getElementById('editor-rendered').innerHTML;
            return JSON.stringify({
                xssFired: window.__xssFired,
                hasScript: rendered.toLowerCase().indexOf('<script') >= 0,
                hasOnerror: rendered.toLowerCase().indexOf('onerror') >= 0,
                hasJavascriptHref: rendered.toLowerCase().indexOf('javascript:') >= 0,
                hasHeading: rendered.indexOf('Hello') >= 0
            });
        })()
    """) as? String ?? "{}"
    check("AR-01: untrusted Markdown script, onerror, and javascript: URLs are stripped before innerHTML",
          xssCheck.contains("\"xssFired\":false") &&
          xssCheck.contains("\"hasScript\":false") &&
          xssCheck.contains("\"hasOnerror\":false") &&
          xssCheck.contains("\"hasJavascriptHref\":false") &&
          xssCheck.contains("\"hasHeading\":true"))
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
