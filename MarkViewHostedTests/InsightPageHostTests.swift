import AppKit
import Combine
import Foundation
import MarkViewCore
import WebKit
import XCTest
@testable import MarkView

final class InsightPageLoad: NSObject, WKNavigationDelegate {
    var done = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done = true }
}


extension EditorHostTests {
    func testResearchDocumentRules() {
        func check(_ name: String, _ condition: Bool, line: UInt = #line) {
            XCTAssertTrue(condition, name, line: line)
        }
        let repo: Set<String> = ["README.md", "src/app.swift", "docs/guide.md"]
        let exists: (String) -> Bool = { repo.contains($0) }
        typealias R = ResearchDocument

        // MARK: Path (DEC-006)

        check("slug from question", R.slug("How do we replace App A with App B?") == "how-do-we-replace-app-a-with-app")
        check("slug transliterates Cyrillic", R.slug("Как заменить приложение") == "kak-zamenit-prilozenie")
        check("slug fallback", R.slug("???") == "research")
        check("slug at most 60 chars", R.slug(String(repeating: "abcdefghij", count: 3) + " " + String(repeating: "x", count: 40)).count <= 60)
        check("path date-slug", R.relativePath(question: "Why?", date: "2026-09-27", exists: { _ in false }) == "docs/research/2026-09-27-why.md")
        let taken: Set<String> = ["docs/research/2026-09-27-why.md", "docs/research/2026-09-27-why-2.md"]
        check("path collision suffix", R.relativePath(question: "Why", date: "2026-09-27", exists: { taken.contains($0) }) == "docs/research/2026-09-27-why-3.md")
        check("id from path", R.id(forPath: "docs/research/2026-09-27-why-3.md") == "2026-09-27-why-3")

        // MARK: Detection (DEC-007)

        check("type research detected anywhere", R.isResearch("---\ntype: research\nid: x\n---\n\n# T\n"))
        check("other type not research", !R.isResearch("---\ntype: bug\n---\n\n# T\n"))
        check("no front matter not research", !R.isResearch("# type: research\n"))

        // MARK: Answer parsing

        let answer = R.parseAnswer("""
        I will look at the files first.

        ## Summary

        App B covers most needs.

        ## Findings

        - [Project fact] Entry point is `src/app.swift:12`.
        - [External fact] B supports SSO, see https://b.example.com/docs/sso.
          Second line of the same finding.
        1. [AI inference] Migration takes 2 weeks.

        ## Recommendations

        Start with a pilot.

        ## Sources

        - ignored, the app builds Sources
        """)
        check("narration dropped", answer.summary == "App B covers most needs.")
        check("three findings", answer.findings.count == 3)
        check("continuation joined", answer.findings[1].contains("Second line"))
        check("recommendations", answer.recommendations == "Start with a pilot.")
        check("cut-off answer is summary", R.parseAnswer("partial thoughts").summary == "partial thoughts")
        let titled = R.parseAnswer("Reading files…\n\n## Title\n**“Offline sync: keep CRDTs, drop polling”**\n\n## Summary\nKeep it.\n")
        check("the AI's title is read without decoration", titled.title == "Offline sync: keep CRDTs, drop polling" && titled.summary == "Keep it.")
        check("no title section leaves the title empty", answer.title.isEmpty)
        check("a long title is cut", R.cleanTitle(String(repeating: "word ", count: 60)).count <= 120)

        // MARK: Labels (REQ-004)

        check("project fact with existing path kept", R.checkedFinding("[Project fact] Entry is src/app.swift:12.", pathExists: exists) == ("[Project fact] Entry is src/app.swift:12.", false))
        check("project fact with backticked path kept", !R.checkedFinding("[Project fact] See `README.md`", pathExists: exists).relabelled)
        check("project fact without path relabelled", R.checkedFinding("[Project fact] It uses SwiftUI.", pathExists: exists).text.hasPrefix("[AI inference] It uses SwiftUI."))
        check("project fact with missing path relabelled", R.checkedFinding("[Project fact] See src/missing.swift", pathExists: exists).relabelled)
        check("external fact with URL kept", !R.checkedFinding("[External fact] B has SSO (https://b.example.com/sso).", pathExists: exists).relabelled)
        check("external fact without URL relabelled", R.checkedFinding("[External fact] B is popular.", pathExists: exists).text.contains("no source URL cited"))
        check("unlabelled relabelled", R.checkedFinding("Plain claim", pathExists: exists).text.hasPrefix("[AI inference] Plain claim"))
        check("two labels relabelled", R.checkedFinding("[Project fact] [AI inference] x README.md", pathExists: exists).text.contains("more than one label"))
        check("bold label normalised", R.checkedFinding("**[Open assumption]** Users want it", pathExists: exists) == ("[Open assumption] Users want it", false))
        check("inference and assumption need no source", !R.checkedFinding("[AI inference] likely", pathExists: exists).relabelled)
        check("URLs trimmed", R.citedURLs("see (https://a.example.com/x).") == ["https://a.example.com/x"])
        check("URL with parentheses kept", R.citedURLs("https://en.wikipedia.org/wiki/A_(b)") == ["https://en.wikipedia.org/wiki/A_(b)"])
        check("paths only existing", R.citedPaths("src/app.swift and e.g. foo/bar.md and docs/guide.md:3", pathExists: exists) == ["src/app.swift", "docs/guide.md"])

        // MARK: New document (DEC-008, DEC-016)

        var run = R.Run(question: "Replace A with B?", answer: answer)
        run.filesRead = ["README.md"]
        run.webQueries = ["app B SSO support"]
        let doc = R.newDocument(id: "2026-09-27-replace", title: "Replace A with B?", created: "2026-09-27", run: run, pathExists: exists)
        let (front, body) = FrontMatter.split(doc)
        check("front type", front.string("type") == "research")
        check("front status complete", front.string("status") == "complete")
        check("front web_queries", front.strings("web_queries") == ["app B SSO support"])
        check("front question", front.string("question") == "Replace A with B?")
        check("sections in order", ["# Replace", "## Question", "## Summary", "## Findings", "## Recommendations", "## Sources"]
            .map { body.range(of: $0)!.lowerBound }.sorted() == ["# Replace", "## Question", "## Summary", "## Findings", "## Recommendations", "## Sources"].map { body.range(of: $0)!.lowerBound })
        check("every finding labelled", body.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count == 3)
        check("inference note on relabel", !body.contains("labelled as inference"))
        check("sources list cited and read files", body.contains("- `src/app.swift`") && body.contains("- `README.md`"))
        check("sources list URL", body.contains("<https://b.example.com/docs/sso>"))
        check("sources list web search", body.contains("- \"app B SSO support\""))
        var failed = run
        failed.incomplete = "cancelled after 3:10; web search unavailable"
        let partial = R.newDocument(id: "x", title: "T", created: "2026-09-27", run: failed, pathExists: exists)
        check("incomplete status", FrontMatter.split(partial).0.string("status") == "incomplete")
        check("incomplete callout at top", FrontMatter.split(partial).1.hasPrefix("# T\n\n> ⚠️ Incomplete: cancelled"))
        var empty = R.Run(question: "Q", answer: R.Answer())
        empty.noProjectFiles = true
        let emptyDoc = R.newDocument(id: "e", title: "Q", created: "2026-09-27", run: empty, pathExists: exists)
        check("empty repo summary says no project facts", emptyDoc.contains("## Summary\n\nNo project facts were available"))

        // MARK: Follow-ups and retries (DEC-005, DEC-013, DEC-014)

        check("first follow-up is 1", R.nextFollowUpNumber(doc) == 1)
        var follow = R.Run(question: "What about cost?", answer: R.Answer(summary: "Cheaper.", findings: ["[AI inference] 20% less"], recommendations: ""))
        follow.incomplete = "the assistant stopped: timed out after 20 min"
        let f1 = R.followUpSection(number: 1, date: "2026-09-28", retryOf: nil, run: follow, pathExists: exists)
        let userEdited = doc.replacingOccurrences(of: "Start with a pilot.", with: "Start with a pilot. (my note)")
        let withF1 = R.appending(f1, to: userEdited, webQueries: ["b pricing"])!
        check("earlier content and user edits unchanged", FrontMatter.split(withF1).1.hasPrefix(FrontMatter.split(userEdited).1.trimmingCharacters(in: .newlines)))
        check("delimiter and heading", withF1.contains("\n\n---\n\n## Follow-up 1: What about cost? (2026-09-28)\n\n> ⚠️ Incomplete:"))
        check("follow-up subsections", withF1.contains("### Findings") && withF1.contains("### Recommendations") && withF1.contains("### Sources"))
        check("status incomplete after failed follow-up", FrontMatter.split(withF1).0.string("status") == "incomplete")
        check("web queries merged", FrontMatter.split(withF1).0.strings("web_queries") == ["app B SSO support", "b pricing"])
        let secs = R.sections(withF1)
        check("two sections", secs.map(\.name) == ["original research", "Follow-up 1"])
        check("follow-up question parsed", secs[1].question == "What about cost?")
        check("original question from front matter", secs[0].question == "Replace A with B?")
        check("unresolved is follow-up 1", R.unresolved(secs).map(\.name) == ["Follow-up 1"])
        check("next number 2", R.nextFollowUpNumber(withF1) == 2)
        var retry = R.Run(question: "What about cost?", answer: R.Answer(summary: "Cheaper by 20%.", findings: [], recommendations: ""))
        let failedRetry = { () -> String in var r = retry; r.incomplete = "cancelled"; return R.followUpSection(number: 2, date: "2026-09-28", retryOf: "Follow-up 1", run: r, pathExists: exists) }()
        let withF2 = R.appending(failedRetry, to: withF1, webQueries: [])!
        check("failed retry keeps incomplete", FrontMatter.split(withF2).0.string("status") == "incomplete")
        check("retry reference parsed", R.sections(withF2)[2].retryOf == "Follow-up 1")
        let f3 = R.followUpSection(number: 3, date: "2026-09-28", retryOf: "Follow-up 2", run: retry, pathExists: exists)
        let withF3 = R.appending(f3, to: withF2, webQueries: [])!
        check("retry of a retry resolves the chain", FrontMatter.split(withF3).0.string("status") == "complete")
        check("earlier incomplete callouts stay", withF3.components(separatedBy: "> ⚠️ Incomplete:").count == 3)
        check("front matter otherwise unchanged", FrontMatter.split(withF3).0.string("question") == "Replace A with B?")
        let incompleteOriginal = R.appending(R.followUpSection(number: 1, date: "d", retryOf: "original research", run: retry, pathExists: exists), to: partial, webQueries: [])!
        check("retry of original research completes it", FrontMatter.split(incompleteOriginal).0.string("status") == "complete")
        check("lossy front matter refused", R.appending(f1, to: "---\ntype: research\n# comment\n---\n\nbody\n", webQueries: []) == nil)

        // MARK: Comments (DEC-017)

        let commented = """
        ---
        type: research
        status: complete
        web_queries: []
        ---

        # Title

        ## Summary

        App B covers **most** needs.

        ## Findings

        - [Project fact] Entry point is [app](src/app.swift).
        - [AI inference] Migration takes 2 weeks.

        ### Detail

        Deep detail text.

        ## Recommendations

        Start with a pilot.
        """
        func sectionText(_ passage: String) -> String? {
            R.enclosingSection(of: passage, in: commented).map { String(commented[$0]) }
        }
        check("phrase in Summary -> Summary", sectionText("covers most needs")?.hasPrefix("## Summary") == true)
        check("section ends before next heading", sectionText("covers most needs")?.contains("## Findings") == false)
        check("smallest section wins", sectionText("Deep detail")?.hasPrefix("### Detail") == true)
        check("rendered link text matches", sectionText("Entry point is app")?.hasPrefix("## Findings") == true)
        check("selection across items matches", sectionText("Entry point is app. [AI inference] Migration takes")?.hasPrefix("## Findings") == true)
        check("parent includes subsection", sectionText("Migration takes 2 weeks. Detail Deep detail")?.hasPrefix("## Findings") == true)
        check("typographic quotes and dashes match plain ones", sectionText("Start with a pilot") != nil
            && R.plain("It doesn’t — “really”… work") == R.plain("It doesn't - \"really\"... work"))
        check("unknown passage", sectionText("not in the document") == nil)
        check("front matter never matched", sectionText("web_queries") == nil)
        let range = R.enclosingSection(of: "Migration takes 2 weeks", in: commented)!
        check("range is the Findings section with Detail", String(commented[range]).contains("### Detail"))
        let summaryRange = R.enclosingSection(of: "covers most needs", in: commented)!
        let revised = R.replacing(summaryRange, in: commented, with: "## Summary\n\nApp B covers all needs except SSO.\n", webQueries: ["q1"])!
        check("revised section replaced", revised.contains("## Summary\n\nApp B covers all needs except SSO.\n\n## Findings"))
        check("other sections unchanged", revised.hasSuffix("## Recommendations\n\nStart with a pilot.\n"))
        check("comment web queries recorded", FrontMatter.split(revised).0.strings("web_queries") == ["q1"])
        let lastRange = R.enclosingSection(of: "Start with a pilot", in: commented)!
        check("last section replaced with trailing newline", R.replacing(lastRange, in: commented, with: "## Recommendations\n\nPilot first.", webQueries: [])!.hasSuffix("## Recommendations\n\nPilot first.\n"))
        let checked = R.checkingLabels(in: "## Findings\n\n- [Project fact] no path here\n- unlabelled\n\n## Recommendations\n\n- do it\n- [External fact] claim", pathExists: exists)
        check("revised Findings relabelled", checked.contains("- [AI inference] no path here *(labelled as inference: no repository file cited)*"))
        check("revised unlabelled finding relabelled", checked.contains("- [AI inference] unlabelled"))
        check("plain recommendation untouched", checked.contains("- do it"))
        check("labelled item outside Findings checked", checked.contains("- [AI inference] claim *(labelled as inference: no source URL cited)*"))

    }

    @MainActor func testCachedInsightPageSecurityAndRendering() throws {
        func check(_ condition: Bool, _ message: String, _ detail: String = "", line: UInt = #line) {
            XCTAssertTrue(condition, message + " " + String(detail.prefix(900)), line: line)
        }
        let deadline = Date().addingTimeInterval(240)
        func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = min(Date().addingTimeInterval(seconds), deadline)
            while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02)) }
        }
        // The page's own text, exactly as the app writes it: the shipping template into a real cache.
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("insight-page-web-tests-\(UUID().uuidString)", isDirectory: true)
        let workspace = sandbox.appendingPathComponent("notes", isDirectory: true)
        try! fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let cache = try! InsightCache(workspaceURL: workspace, sessionId: UUID(), pagePolicy: InsightHTMLTemplate.policyKey)

        let pixel = "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
        func section(_ id: String, _ type: SectionType, _ title: String) -> InsightSection {
            InsightSection(id: id, type: type, title: title, scopeHint: nil, metadata: [:], deepDiveTopics: nil)
        }
        let skeleton = InsightSkeleton(title: "Notes <script>window.__title = 1</script>", suggestedTheme: nil, sections: [
            section("s1", .prose, "Hostile <script>window.__sectionTitle = 1</script>"),
            section("s2", .mermaidDiagram, "Diagram"),
            section("s3", .chartJsChart, "Chart"),
        ])
        let states = [
            "s1": SectionState(buffer: """
                <p id="plain">plain text</p>
                <script>window.__injected = 1;</script>
                <img id="broken" src="missing.png" onerror="window.__handler = 1">
                <svg onload="window.__svg = 1" width="1" height="1"></svg>
                <a id="jslink" href="javascript:window.__link = 1">link</a>
                <img id="pic" src="\(pixel)" width="40" height="40">
                """, status: .ready),
            "s2": SectionState(buffer: "<pre><code class=\"language-mermaid\">graph TD\n  A[Start] --> B[End]</code></pre>", status: .ready),
            "s3": SectionState(buffer: "<canvas id=\"chart\" data-chart='{\"type\":\"bar\",\"data\":{\"labels\":[\"a\",\"b\"],\"datasets\":[{\"label\":\"n\",\"data\":[1,2]}]},\"options\":{\"animation\":false}}'></canvas>", status: .ready),
        ]
        let crumbs: [(nodeId: String, title: String)] = [("ROOT", "Notes <script>window.__crumb = 1</script>")]
        let page = InsightHTMLTemplate.html(skeleton: skeleton, sectionStates: states, breadcrumbs: crumbs, cache: cache)
        let nodeId = UUID()
        try! cache.writeNode(nodeId: nodeId, html: page)
        // The control page: the same text with the policy of 6.27.x, which let every inline script run.
        let olderPolicy = InsightHTMLTemplate.policy.replacingOccurrences(of: "script-src 'self' \(InsightHTMLTemplate.bootstrapHash)", with: "script-src 'self' 'unsafe-inline'")
        let controlId = UUID()
        try! cache.writeNode(nodeId: controlId, html: page.replacingOccurrences(of: InsightHTMLTemplate.policy, with: olderPolicy))
        check(olderPolicy != InsightHTMLTemplate.policy, "the control page carries the older policy")

        // Every policy violation the page reports, kept for the checks.
        let recordViolations = WKUserScript(source: """
            window.__violations = [];
            document.addEventListener('securitypolicyviolation', function (e) { window.__violations.push(e.violatedDirective + ' ' + (e.blockedURI || '')); });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true)

        var keep: [AnyObject] = []   // windows and delegates live as long as the run
                defer {
                    for case let window as NSWindow in keep {
                        (window.contentView as? WKWebView)?.stopLoading()
                        (window.contentView as? WKWebView)?.navigationDelegate = nil
                        window.contentView = nil
                        window.close()
                    }
                }
        func open(_ id: UUID) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(recordViolations)
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400), configuration: config)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.contentView = web
            let loaded = InsightPageLoad()
            web.navigationDelegate = loaded
            keep += [loaded, window]
            let url = cache.rootDirectory.appendingPathComponent("nodes/\(id.uuidString).html")
            web.loadFileURL(url, allowingReadAccessTo: cache.rootDirectory)
            spin(60) { loaded.done }
            return web
        }

        func js(_ web: WKWebView, _ body: String, timeout: TimeInterval = 60) -> String {
            var out: String?
            web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): out = value as? String ?? "\(String(describing: value))"
                case .failure(let error): out = "JSERROR: " + ((error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
                }
            }
            spin(timeout) { out != nil }
            return out ?? "TIMEOUT"
        }

        let probe = """
            const w = window;
            const seen = k => String(typeof w[k] === 'undefined' ? 'no' : w[k]);
            return JSON.stringify({
                injected: seen('__injected'), handler: seen('__handler'), svg: seen('__svg'), link: seen('__link'),
                title: seen('__title'), sectionTitle: seen('__sectionTitle'), crumb: seen('__crumb'),
                violations: w.__violations || [],
                mermaid: typeof w.mermaid, chart: typeof w.Chart
            });
            """
        func state(_ web: WKWebView) -> [String: Any] {
            let text = js(web, probe)
            return ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]) ?? ["error": text]
        }

        // 1. The page under the policy in force.
        let web = open(nodeId)
        spin(1)
        let before = state(web)
        check(before["mermaid"] as? String == "object" && before["chart"] as? String == "function",
              "the bundled libraries load from 'self' (Mermaid and Chart.js are defined)", "\(before)")

        // The bootstrap runs: Mermaid draws the diagram, Chart.js the chart.
        let drawn = js(web, """
            for (let i = 0; i < 200 && !document.querySelector('.mermaid svg'); i++) await new Promise(r => setTimeout(r, 100));
            const svg = document.querySelector('.mermaid svg');
            const chart = window.Chart && window.Chart.getChart(document.getElementById('chart'));
            return JSON.stringify({
                diagram: !!svg, labels: svg ? Array.from(svg.querySelectorAll('.nodeLabel, text')).map(e => e.textContent.trim()).filter(Boolean) : [],
                chart: !!chart, bars: chart ? chart.data.datasets[0].data.length : 0
            });
            """)
        let drawnState = ((try? JSONSerialization.jsonObject(with: Data(drawn.utf8))) as? [String: Any]) ?? [:]
        let labels = (drawnState["labels"] as? [String]) ?? []
        check(drawnState["diagram"] as? Bool == true && labels.contains("Start") && labels.contains("End"), "the page draws the Mermaid diagram with its labels", drawn)
        check(drawnState["chart"] as? Bool == true && drawnState["bars"] as? Int == 2, "the page draws the Chart.js chart from the section's data", drawn)

        // The lightbox opens on a click on an image of a section.
        let lightbox = js(web, """
            document.getElementById('pic').click();
            const lb = document.getElementById('lb');
            return JSON.stringify({ exists: !!lb, on: !!lb && lb.classList.contains('on'), content: !!lb && lb.querySelectorAll('.lb-content img').length });
            """)
        check(lightbox.contains("\"on\":true") && lightbox.contains("\"content\":1"), "a click on an image opens the lightbox (the bootstrap's listeners work)", lightbox)

        // Nothing the assistant's text or a label carries has run. Handlers fire asynchronously: wait for the broken image to report.
        spin(1.5)
        let after = state(web)
        for (name, key) in [("an inline script in a section", "injected"), ("an onerror handler on an image", "handler"), ("an onload handler on an svg", "svg"),
                            ("a script in the page title", "title"), ("a script in a section title", "sectionTitle"), ("a script in a breadcrumb", "crumb")] {
            check(after[key] as? String == "no", "\(name) does not run", "\(after)")
        }
        let violations = (after["violations"] as? [String]) ?? []
        check(violations.contains { $0.hasPrefix("script-src") && $0.hasSuffix("inline") }, "WebKit reports the injected inline script as a policy violation", "\(violations)")
        check(violations.contains { $0.hasPrefix("script-src-attr") || $0.hasPrefix("script-src") }, "the inline handlers are blocked too", "\(violations)")
        let clicked = js(web, """
            document.getElementById('jslink').click();
            await new Promise(r => setTimeout(r, 300));
            return String(typeof window.__link);
            """)
        check(clicked == "undefined", "a javascript: link does not run when it is clicked", clicked)

        // 2. The control: the older policy lets every one of them run.
        let control = open(controlId)
        spin(1.5)
        let older = state(control)
        _ = js(control, "document.getElementById('jslink').click(); await new Promise(r => setTimeout(r, 300)); return ''")
        let olderAfterClick = state(control)
        check(older["injected"] as? String == "1" && older["handler"] as? String == "1" && older["svg"] as? String == "1",
              "control: under the older policy the inline script, the onerror handler and the svg onload do run", "\(older)")
        check(olderAfterClick["link"] as? String == "1", "control: under the older policy a javascript: link runs", "\(olderAfterClick)")
        check((older["violations"] as? [String])?.isEmpty == true, "control: the older policy reports no violation", "\(older)")
        XCTAssertLessThan(Date(), deadline, "Insight page test exceeded its deadline")
    }
}

@MainActor
private final class InsightFixtureHost: InsightHost {
    var sessions: [InsightSession] = []
    var active: InsightSession?
    var events: [String] = []
    var insightSessions: [InsightSession] { sessions }
    var activeInsightSession: InsightSession? { active }
    func showInsightTab(_ session: InsightSession, placeholder: URL) {
        sessions.append(session)
        active = session
        events.append("show")
    }
    func removeInsightTab(sessionID: UUID) {
        sessions.removeAll { $0.id == sessionID }
        if active?.id == sessionID { active = nil }
        events.append("remove")
    }
}

/// The editor page: it listens to the coordinator while an insight tab is routed, and records that it was asked to drop the blobs.
@MainActor
private final class InsightFixturePage {
    let host: InsightFixtureHost
    private var listening: AnyCancellable?
    init(host: InsightFixtureHost, coordinator: InsightCoordinator) {
        self.host = host
        listening = coordinator.blobReleases.sink { [weak self] in self?.host.events.append("release") }
    }
}


extension EditorHostTests {
    @MainActor func testInsightCoordinatorRules() async {
        func check(_ condition: Bool, _ label: String, line: UInt = #line) {
            XCTAssertTrue(condition, label, line: line)
        }
        func skeleton(title: String, topics: [String]) -> InsightSkeleton {
            InsightSkeleton(title: title, suggestedTheme: nil, sections: [
                InsightSection(id: "s1", type: .prose, title: "Overview", scopeHint: nil, metadata: [:],
                               deepDiveTopics: topics.enumerated().map {
                                   InsightDeepDiveTopic(id: "t\($0.offset)", label: $0.element, hint: "hint \($0.element)", scopeHint: [])
                               })
            ])
        }

        func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return await condition()
        }

        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("insight-coordinator-tests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        func write(_ text: String, to url: URL) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        @MainActor
        func run() async {
            print("=== Recursive Insight coordinator (AR-14 step 2) ===")

            // 1. File names of the archive.
            print("\n-- archive file names")
            check(InsightArchiveExport.sanitizeFilename("My docs/2026 (draft)") == "My_docs_2026_draft", "a folder name keeps strict ASCII letters, digits and underscores")
            check(InsightArchiveExport.sanitizeFilename("Мои заметки") == "insight", "a name with no ASCII letters falls back to `insight`")
            check(InsightArchiveExport.sanitizeFilename("__a__b__") == "a_b", "runs of underscores collapse and the ends are trimmed")
            let name = InsightArchiveExport.defaultFilename(folderName: "notes", date: Date(timeIntervalSince1970: 1_800_000_000))
            check(name.hasPrefix("notes_insight_") && name.hasSuffix("Z.zip") && !name.contains(":"), "the default archive name carries a colon-free ISO timestamp (\(name))")

            // The cache copies the vendored libraries from the bundle; the script puts the real ones next to the executable.
            let analysed = sandbox.appendingPathComponent("analysed", isDirectory: true)
            let first = analysed.appendingPathComponent("one.md"), second = analysed.appendingPathComponent("two.md")
            write("# one", to: first)
            write("# two", to: second)
            guard let cache = try? InsightCache(workspaceURL: analysed, sessionId: UUID(), pagePolicy: InsightHTMLTemplate.policyKey) else {
                check(false, "the cache opens on a real folder with the vendored libraries")
                return
            }
            check(true, "the cache opens on a real folder with the vendored libraries")

            // 2. The archive on a real cache: pages built by the shipping template, rewritten for a standalone browser.
            print("\n-- standalone archive")
            let rootId = InsightCache.deterministicRootUUID(forFolderPath: analysed.path)
            let childId = UUID()
            let rootNode = InsightNode(id: rootId, parentId: nil, level: 0, title: "Analysed", scope: .folderRoot)
            rootNode.skeleton = skeleton(title: "Analysed", topics: ["Auth flow", "Storage"])
            rootNode.children = [childId]
            let childNode = InsightNode(id: childId, parentId: rootId, level: 1, title: "Auth flow",
                                        scope: .topic(label: "Auth flow", hint: "hint Auth flow", files: [first]))
            childNode.skeleton = skeleton(title: "Auth flow", topics: [])
            let nodes = [rootId: rootNode, childId: childNode]

            let map = InsightArchiveExport.childMap(nodes: nodes)
            check(map[rootId]?["s1"]?[0] == childId && map[rootId]?["s1"]?[1] == nil && map[childId] == nil,
                  "the deep dive whose topic label is a child's title maps to that child; the other topic maps to none")

            for (id, node) in nodes {
                var crumbs: [(nodeId: String, title: String)] = []
                var cursor: InsightNode? = node
                while let current = cursor {
                    crumbs.insert((current.id.uuidString, current.title), at: 0)
                    cursor = current.parentId.flatMap { nodes[$0] }
                }
                let html = InsightHTMLTemplate.html(skeleton: node.skeleton!, sectionStates: [:], breadcrumbs: crumbs, cache: cache)
                try? cache.writeNode(nodeId: id, html: html)
            }
            let liveRootBefore = (try? cache.readNode(nodeId: rootId)) ?? ""
            check(liveRootBefore.contains("<button class=\"deep-dive\"") && liveRootBefore.contains("\"../_assets/"),
                  "the shipping template emits deep-dive buttons and `../_assets/` library references")

            do {
                let staging = try await cache.archiveStagingDirectory()
                let exportRoot = try InsightArchiveExport.makeStagingCopy(from: staging)
                defer { try? fm.removeItem(at: exportRoot) }
                check(exportRoot != staging && fm.fileExists(atPath: exportRoot.appendingPathComponent("nodes").path)
                      && fm.fileExists(atPath: exportRoot.appendingPathComponent("_assets").path),
                      "the staging copy is a new folder holding nodes/ and _assets/ at its root")
                try InsightArchiveExport.rewriteForStandalone(exportRoot: exportRoot, rootNodeId: rootId, nodeChildMap: map)
                let index = (try? String(contentsOf: exportRoot.appendingPathComponent("index.html"), encoding: .utf8)) ?? ""
                check(!index.isEmpty && !index.contains("\"../_assets/") && index.contains("\"_assets/"),
                      "the root page is promoted to index.html with its library references one level shallower")
                check(index.contains("<a class=\"deep-dive\" href=\"nodes/\(childId.uuidString).html\""),
                      "a deep dive that has a child page becomes a link to nodes/<child>.html")
                check(index.contains("<button class=\"deep-dive\" data-section-id=\"s1\" data-topic-index=\"1\""),
                      "a deep dive without a child stays an inert button")
                let childPage = (try? String(contentsOf: exportRoot.appendingPathComponent("nodes/\(childId.uuidString).html"), encoding: .utf8)) ?? ""
                check(childPage.contains("<a class=\"crumb\" href=\"../index.html\">") && !childPage.contains("href=\"#"),
                      "a node page's breadcrumb to the root points at ../index.html, and no `#` breadcrumb is left")
                let rootPage = (try? String(contentsOf: exportRoot.appendingPathComponent("nodes/\(rootId.uuidString).html"), encoding: .utf8)) ?? ""
                check(rootPage.contains("<a class=\"deep-dive\" href=\"\(childId.uuidString).html\""),
                      "the root's copy under nodes/ links its child as a sibling")
                let liveRootAfter = (try? cache.readNode(nodeId: rootId)) ?? ""
                check(liveRootAfter == liveRootBefore, "rewriting the copy leaves the live cache untouched")
            } catch {
                check(false, "the archive staging and rewrite run without error: \(error)")
            }

            // 3. The coordinator over a session restored from that cache.
            print("\n-- coordinator")
            rootNode.sectionStates = ["s1": SectionState(buffer: "<p>root</p>", status: .ready)]
            childNode.sectionStates = ["s1": SectionState(buffer: "<p>auth</p>", status: .ready)]
            rootNode.status = .ready
            childNode.status = .ready
            let snapshot = InsightTreeSnapshot(rootId: rootId, folderPath: analysed.path, nodes: [rootNode, childNode])
            check(InsightTreeSnapshot.decode(try! snapshot.encoded())?.rootId == rootId, "a saved tree reads back")
            check(InsightTreeSnapshot.decode(Data("{ \"rootId\": ".utf8)) == nil, "a saved tree that cannot be read is a miss (logged), not a crash")
            try? cache.writeSnapshotData(try! snapshot.encoded())

            let session = InsightSession(folderURL: analysed, mdFiles: [first, second], graphRAG: nil, cache: cache)
            await session.generateRoot()
            check(session.nodes.count == 2 && session.currentNodeId == rootId && session.skeletonReady,
                  "the session restores the root and its child from the cache snapshot")

            let host = InsightFixtureHost()
            let project = StubProject(aiProjectTracksRoot: true)
            project.root = analysed
            host.sessions = [session]
            host.active = session
            let tasks = TaskBag()
            let prompts = ScriptedPrompts()
            let coordinator = InsightCoordinator(host: host, project: project, tasks: tasks, prompts: prompts)
            let page = InsightFixturePage(host: host, coordinator: coordinator)
            let sid = session.id.uuidString

            coordinator.didRequestInsightDeepDive(sessionId: UUID().uuidString, sectionId: "s1", topicIndex: 0)
            coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "nope", topicIndex: 0)
            coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 2)
            coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: -1)
            check(tasks.activeCount == 0 && session.currentNodeId == rootId,
                  "a deep dive for a closed session, an unknown section or an index out of range starts nothing")

            coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 0)
            check(tasks.contains(key: "insight.expand.\(session.id)"), "a valid deep dive runs on a task the window's bag owns")
            check(await waitUntil { session.currentNodeId == childId }, "the deep dive of a topic that already has a child shows that child, no assistant call")

            tasks.cancelAll()
            coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: "not-a-uuid")
            coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: UUID().uuidString)
            check(tasks.activeCount == 0 && session.currentNodeId == childId, "a breadcrumb with an invalid id or an id outside the manifest starts nothing")
            coordinator.didRequestInsightBreadcrumb(sessionId: sid, nodeId: rootId.uuidString)
            check(await waitUntil { session.currentNodeId == rootId }, "a breadcrumb to a node of the manifest navigates to it")

            tasks.cancelAll()
            coordinator.didRequestInsightUp()
            check(tasks.activeCount == 0 && session.currentNodeId == rootId, "↑ Up at the root does nothing")
            coordinator.didRequestInsightDeepDive(sessionId: sid, sectionId: "s1", topicIndex: 0)
            _ = await waitUntil { session.currentNodeId == childId }
            tasks.cancelAll()
            coordinator.didRequestInsightUp()
            check(await waitUntil { session.currentNodeId == rootId }, "↑ Up at a child navigates to its parent")

            host.active = nil
            tasks.cancelAll()
            coordinator.didRequestInsightUp()
            coordinator.didRequestInsightRegenerate()
            coordinator.didRequestInsightExploreAll(depth: 1)
            coordinator.didRequestInsightCustomDeepDive(topic: "x")
            coordinator.didRequestInsightRetrySection(sectionId: "s1")
            coordinator.didRequestInsightSave()
            check(tasks.activeCount == 0, "with no insight tab selected, none of the messages without a session id starts anything (and Save opens no panel)")
            host.active = session

            // Starting a session that cannot start tells the person why through the prompter (AR-22), and starts nothing.
            let shownBefore = host.sessions.count
            let noFolder = StubProject(aiProjectTracksRoot: true)
            let unopened = InsightCoordinator(host: host, project: noFolder, tasks: tasks, prompts: prompts)
            prompts.script = [.press("OK")]
            unopened.start()
            check(prompts.asked == [UserPrompt(title: "No folder open", detail: "Open a folder before starting Recursive Insight.")],
                  "starting with no folder open says so, with the text it always had (\(prompts.asked))")
            check(host.sessions.count == shownBefore && tasks.activeCount == 0, "and shows no tab and starts no task")
            prompts.script = []
            coordinator.start()
            check(prompts.asked.count == 2 && prompts.asked[1].buttons.isEmpty && host.sessions.count == shownBefore && tasks.activeCount == 0,
                  "a folder whose assistant or database is not ready is refused with one notice nobody has to answer (\(prompts.asked.last?.title ?? ""))")

            coordinator.cancelSessions()
            check(tasks.contains(key: "insight.cancel.\(session.id)"), "cancelling the sessions of a closing folder runs on an owned task")
            tasks.cancelAll()
            check(tasks.activeCount == 0, "the window's bag cancels everything the coordinator started")

            // Closing the tab: the page revokes its blob URLs first, the session ends, then the tab goes.
            coordinator.close(session)
            check(tasks.contains(key: "insight.close.\(session.id)"), "closing a tab runs on an owned task")
            check(await waitUntil { host.sessions.isEmpty }, "the tab is removed once the session has ended")
            check(host.events == ["release", "remove"], "the page releases its blobs before the tab is removed (events: \(host.events))")
            check((try? cache.readNode(nodeId: rootId)) == liveRootBefore, "closing keeps the cache, so reopening the folder's insight reuses it")
            withExtendedLifetime(page) {}

            // 4. FU-25: pages are served from the cache only under the policy the manifest names.
            print("\n-- page policy")
            let policy = InsightHTMLTemplate.policyKey
            let manifest = InsightManifest(sessionId: UUID(), folderName: "analysed", createdAt: Date(), nodes: [], pagePolicy: policy)
            try? cache.updateManifest(manifest)
            let sameCache = try? InsightCache(workspaceURL: analysed, sessionId: UUID(), pagePolicy: policy)
            check(sameCache?.droppedStalePages == false && (try? sameCache?.readNode(nodeId: rootId)) == liveRootBefore,
                  "a cache whose manifest names the policy in force keeps its pages")

            // A page an older version wrote: its policy allowed every inline script.
            let olderPage = liveRootBefore.replacingOccurrences(of: "script-src 'self' \(InsightHTMLTemplate.bootstrapHash)", with: "script-src 'self' 'unsafe-inline'")
            check(olderPage != liveRootBefore && olderPage.contains("script-src 'self' 'unsafe-inline'"), "the older page of the scenario allows every inline script")
            try? cache.writeNode(nodeId: rootId, html: olderPage)
            try? cache.updateManifest(InsightManifest(sessionId: UUID(), folderName: "analysed", createdAt: Date(), nodes: []))   // no policy recorded: as before FU-25
            guard let reopened = try? InsightCache(workspaceURL: analysed, sessionId: UUID(), pagePolicy: policy) else {
                check(false, "the cache opens again")
                return
            }
            check(reopened.droppedStalePages && (try? reopened.readNode(nodeId: rootId)) == nil,
                  "a cache written before the policy had a key loses its pages when it is opened, so the older page is not served")
            check(reopened.readSnapshotData() != nil && reopened.vendoredLibURL(matching: "mermaid", extension: "js") != nil,
                  "the saved tree and the bundled libraries stay")
            check((try? reopened.loadManifest())?.pagePolicy == policy, "the manifest names the policy now")
            let again = try? InsightCache(workspaceURL: analysed, sessionId: UUID(), pagePolicy: policy)
            check(again?.droppedStalePages == false, "opening it a second time drops nothing")

            let restored = InsightSession(folderURL: analysed, mdFiles: [first, second], graphRAG: nil, cache: reopened)
            await restored.generateRoot()
            let rewritten = (try? reopened.readNode(nodeId: rootId)) ?? ""
            let rewrittenScriptSources = rewritten.components(separatedBy: "script-src ").dropFirst().first?.components(separatedBy: ";").first ?? ""
            check(restored.nodes.count == 2 && rewrittenScriptSources == "'self' \(InsightHTMLTemplate.bootstrapHash)"
                  && (try? reopened.readNode(nodeId: childId)) != nil && rewritten.contains("<p>root</p>"),
                  "restoring the saved tree writes the pages of every node again, from that tree, under the policy in force")

            let moved = try? InsightCache(workspaceURL: analysed, sessionId: UUID(), pagePolicy: "another-policy")
            check(moved?.droppedStalePages == true && (try? moved?.readNode(nodeId: rootId)) == nil && (try? moved?.loadManifest())?.pagePolicy == "another-policy",
                  "a change of the policy drops the pages again")
        }
        await run()
    }
}

/// The assistant of the explore-all tests. A node's skeleton (`insight-skeleton`; the prompt's "Topic / scope:" line names the
/// node) has two sections titled after the node and, in the first, two deep-dive topics: `A` has `A.1` and `A.2`. A section
/// (`insight-section`; the prompt's "Section title:" line names its node) streams one fragment. A skeleton waits until three nodes
/// are in flight, or half a second, so a walk that can run that many side by side does. A node is in flight from the start of its
/// skeleton to the end of its last section. With `holdingSections`, the second section of every node but the first one to ask
/// for it waits until it is cancelled, so the walk can be stopped while nodes are half written.
private actor InsightExploreFixture {
    let holdingSections: Bool
    private var clock = 0
    private var inFlight = 0
    private var sectionsLeft: [String: Int] = [:]
    private(set) var peak = 0
    private(set) var calls = 0
    private(set) var skeletonCalls: [String: Int] = [:]
    private(set) var skeletonStarted: [String: Int] = [:]
    private(set) var skeletonEnded: [String: Int] = [:]
    private(set) var sectionsStarted: [String: [Int]] = [:]
    /// The node whose second section answers while the others wait (`holdingSections`), and how many wait.
    private(set) var released: String?
    private(set) var held = 0

    init(holdingSections: Bool = false) {
        self.holdingSections = holdingSections
    }

    func run(_ request: CLICompletion.Request, onDelta: (@Sendable (String) -> Void)?) async throws -> CLICompletion.Result {
        calls += 1
        if request.label == "insight-skeleton" {
            return try await skeleton(of: Self.line("Topic / scope: ", in: request.prompt))
        }
        return try await section(Self.line("Section title: ", in: request.prompt), onDelta: onDelta)
    }

    private static func line(_ prefix: String, in prompt: String) -> String {
        let found = prompt.split(separator: "\n").first { $0.hasPrefix(prefix) }
        return found.map { String($0.dropFirst(prefix.count)) } ?? ""
    }

    private func tick() -> Int {
        clock += 1
        return clock
    }

    private func skeleton(of node: String) async throws -> CLICompletion.Result {
        skeletonCalls[node, default: 0] += 1
        skeletonStarted[node] = tick()
        inFlight += 1
        peak = max(peak, inFlight)
        sectionsLeft[node] = 2
        let deadline = Date().addingTimeInterval(0.5)
        do {
            while inFlight < 3 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        } catch {
            inFlight -= 1
            throw error
        }
        skeletonEnded[node] = tick()
        let topics: [[String: Any]] = ["1", "2"].map { index -> [String: Any] in
            ["id": "t\(index)", "label": "\(node).\(index)", "hint": "hint \(node).\(index)", "scopeHint": [String]()]
        }
        let first: [String: Any] = ["id": "s1", "type": "prose", "title": "\(node) · 1", "metadata": [String: Any](), "deepDiveTopics": topics]
        let second: [String: Any] = ["id": "s2", "type": "prose", "title": "\(node) · 2", "metadata": [String: Any]()]
        let skeleton: [String: Any] = ["title": node, "sections": [first, second]]
        return try CLICompletion.Result(text: "", structured: skeleton, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }

    private func section(_ title: String, onDelta: (@Sendable (String) -> Void)?) async throws -> CLICompletion.Result {
        let node = title.components(separatedBy: " · ").first ?? title
        sectionsStarted[node, default: []].append(tick())
        defer {
            sectionsLeft[node, default: 0] -= 1
            if sectionsLeft[node] == 0 { inFlight -= 1 }
        }
        var wait: UInt64 = 20_000_000
        if holdingSections && title.hasSuffix(" · 2") {
            if released == nil { released = node }
            if released == node {
                // Long enough for the first sections of the others to land before this node's tree is saved.
                wait = 200_000_000
            } else {
                wait = 60_000_000_000
                held += 1
            }
        }
        try await Task.sleep(nanoseconds: wait)
        let html = "<p>Body of \(title)</p>"
        onDelta?(html)
        return try CLICompletion.Result(text: html, structured: nil, inputTokens: 0, outputTokens: 0, costUSD: nil)
    }
}

/// A session restored on a root page whose deep-dive topics are A to E, with A twice, over a real GraphRAG and a temporary
/// database, so a walk runs the app's own prompts and parsing against the fixture assistant.
@MainActor
private func exploreAllSession(in sandbox: URL) async throws -> (session: InsightSession, cache: InsightCache, rootId: UUID) {
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let files = [sandbox.appendingPathComponent("one.md"), sandbox.appendingPathComponent("two.md")]
    for file in files { try "# \(file.lastPathComponent)\n".write(to: file, atomically: true, encoding: .utf8) }
    let database = try await SemanticDatabase.open(workspacePath: sandbox)
    let cache = try InsightCache(workspaceURL: sandbox, sessionId: UUID(), pagePolicy: InsightHTMLTemplate.policyKey)

    func topics(_ labels: [String]) -> [InsightDeepDiveTopic] {
        labels.enumerated().map { InsightDeepDiveTopic(id: "t\($0.offset)", label: $0.element, hint: "hint \($0.element)", scopeHint: []) }
    }
    let rootId = InsightCache.deterministicRootUUID(forFolderPath: sandbox.path)
    let root = InsightNode(id: rootId, parentId: nil, level: 0, title: "Root", scope: .folderRoot)
    root.skeleton = InsightSkeleton(title: "Root", suggestedTheme: nil, sections: [
        InsightSection(id: "s1", type: .prose, title: "Overview", scopeHint: nil, metadata: [:], deepDiveTopics: topics(["A", "B", "C"])),
        InsightSection(id: "s2", type: .prose, title: "More", scopeHint: nil, metadata: [:], deepDiveTopics: topics(["D", "E", "A"])),
    ])
    root.sectionStates = ["s1": SectionState(buffer: "<p>root</p>", status: .ready), "s2": SectionState(buffer: "<p>more</p>", status: .ready)]
    root.status = .ready
    try cache.writeSnapshotData(try InsightTreeSnapshot(rootId: rootId, folderPath: sandbox.path, nodes: [root]).encoded())

    let session = InsightSession(folderURL: sandbox, mdFiles: files, graphRAG: GraphRAG(db: database), cache: cache)
    await session.generateRoot()
    return (session, cache, rootId)
}

extension EditorHostTests {
    /// Explore all at depth 2 over the root's five topics: the 15 nodes run side by side, three at a time over the whole walk;
    /// each node keeps its own order (skeleton, then sections) and each child's subtree waits for the child's skeleton; the
    /// topic named twice gets one child; every page carries its own breadcrumbs; and the view stays on the root.
    @MainActor func testInsightExploreAllRunsSiblingsSideBySide() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("insight-explore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fixture = InsightExploreFixture()
        AIAssistantRunner.setTestRunner { request, onDelta, _ in try await fixture.run(request, onDelta: onDelta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let (session, cache, rootId) = try await exploreAllSession(in: sandbox)
        XCTAssertEqual(session.currentNodeId, rootId, "the root comes back from its snapshot")

        var shown: Set<UUID?> = []
        var statuses: [String] = []
        let watching = [session.$currentNodeId.sink { shown.insert($0) }, session.$statusMessage.sink { statuses.append($0) }]
        await session.expandAllTopicsOnCurrentNode(depth: 2)
        withExtendedLifetime(watching) {}

        let peak = await fixture.peak
        XCTAssertEqual(peak, CLICompletion.sideBySide, "three nodes are generated side by side, and never more")

        let root = try XCTUnwrap(session.nodes[rootId])
        XCTAssertEqual(root.children.compactMap { session.nodes[$0]?.title }.sorted(), ["A", "B", "C", "D", "E"],
                       "the topic named twice on the root has one child")
        var expectedSkeletons: [String: Int] = [:]
        for child in ["A", "B", "C", "D", "E"] {
            expectedSkeletons[child] = 1
            expectedSkeletons["\(child).1"] = 1
            expectedSkeletons["\(child).2"] = 1
        }
        let skeletonCalls = await fixture.skeletonCalls
        XCTAssertEqual(skeletonCalls, expectedSkeletons, "one skeleton per node of the two levels: the duplicated topic is reused, nothing deeper is asked")

        let started = await fixture.skeletonStarted
        let ended = await fixture.skeletonEnded
        let sections = await fixture.sectionsStarted
        for (node, end) in ended {
            let starts = sections[node] ?? []
            XCTAssertEqual(starts.count, 2, "\(node) asks for both of its sections")
            XCTAssertTrue(starts.allSatisfy { $0 > end }, "the sections of \(node) start after its own skeleton ends")
            guard let dot = node.lastIndex(of: ".") else { continue }
            let parent = String(node[..<dot])
            XCTAssertGreaterThan(started[node] ?? 0, ended[parent] ?? .max, "the skeleton of \(node) starts after the skeleton of \(parent) ends")
        }

        XCTAssertEqual(session.nodes.count, 16, "the root, five children and ten grandchildren")
        for node in session.nodes.values where node.id != rootId {
            XCTAssertEqual(node.status, .ready, "\(node.title) is generated")
            var chain = [node]
            while let parentId = chain[0].parentId, let parent = session.nodes[parentId] { chain.insert(parent, at: 0) }
            var crumbs = ""
            for ancestor in chain.dropLast() {
                crumbs += "<a class=\"crumb\" href=\"#\(ancestor.id.uuidString)\">\(ancestor.title)</a><span class=\"crumb-sep\"> / </span>"
            }
            crumbs += "<span class=\"crumb crumb-active\">\(node.title)</span>"
            let page = (try? cache.readNode(nodeId: node.id)) ?? ""
            XCTAssertTrue(page.contains(crumbs), "the cached page of \(node.title) carries its own breadcrumbs, not those of the page in view")
        }

        XCTAssertEqual(shown, [rootId], "the view stays on the page the walk started from")
        XCTAssertTrue(statuses.contains { $0.hasPrefix("Explore all (depth 2): 3 running") },
                      "the status line counts the nodes running side by side (\(statuses.suffix(4)))")
        XCTAssertEqual(session.statusMessage, "Explore all (depth 2): done, 15/15 ready, 0 failed")
    }

    /// Stopping explore all mid-walk (closing the tab or the folder and Regenerate all come through `cancel()`): no assistant
    /// call starts after it, and the tree saved mid-walk holds the nodes that were ready, not those still streaming their text.
    @MainActor func testInsightExploreAllStopsOnCancel() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("insight-explore-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fixture = InsightExploreFixture(holdingSections: true)
        AIAssistantRunner.setTestRunner { request, onDelta, _ in try await fixture.run(request, onDelta: onDelta) }
        defer { AIAssistantRunner.setTestRunner(nil) }
        let (session, cache, rootId) = try await exploreAllSession(in: sandbox)

        func halfWritten() -> [InsightNode] {
            session.nodes.values.filter { node in
                node.status == .streamingContent && node.sectionStates.values.contains { !$0.buffer.isEmpty }
            }
        }
        func saved() -> Set<UUID> {
            let snapshot = cache.readSnapshotData().flatMap(InsightTreeSnapshot.decode)
            return Set(snapshot?.nodes?.map(\.nodeId) ?? [])
        }

        let walking = Task { await session.expandAllTopicsOnCurrentNode(depth: 2) }
        // One node is done and its tree saved; three others have their first section and hold their second.
        var releasedId: UUID?
        for _ in 0..<500 {
            let held = await fixture.held
            let released = await fixture.released
            releasedId = session.nodes.values.first { $0.title == released && $0.status == .ready }?.id
            if held == 3, halfWritten().count == 3, let releasedId, saved().contains(releasedId) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let held = await fixture.held
        XCTAssertEqual(held, 3, "three nodes are half written side by side when the walk is stopped")
        XCTAssertEqual(halfWritten().count, 3, "each of them has text and is not done")

        await session.cancel()
        let callsAtStop = await fixture.calls
        try await Task.sleep(nanoseconds: 600_000_000)
        let callsAfter = await fixture.calls
        XCTAssertEqual(callsAfter, callsAtStop, "no assistant call starts once the walk is stopped")

        var expectedSaved: Set<UUID> = [rootId]
        if let releasedId { expectedSaved.insert(releasedId) }
        XCTAssertEqual(saved(), expectedSaved, "the tree saved mid-walk holds the ready nodes, not the half-written ones (they would come back ready)")

        // Ends the walk whatever happened above, so the test never waits on a held section.
        walking.cancel()
        await session.cancel()
        await walking.value
    }
}
