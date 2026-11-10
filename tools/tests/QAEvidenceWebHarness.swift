// The script that measures a page for the step-by-step review (QAPageEvidence.script, feature end-to-end-qa REQ-008), run in a real
// WKWebView against small fixture pages: tiny text, weak contrast, clipped content, small click targets, a page wider than the window,
// controls with no name, skipped headings, and the guarantee that nothing a person typed ever leaves the page.
// Compiled with Models/QAPageEvidence.swift by tools/tests/qa-evidence-web-tests.sh. The window is never shown: an accessory app, a
// borderless window far off screen with alpha 0 that is never ordered front.
import AppKit
import WebKit

// A hung page must not hang the test run: print every line at once and stop with the last step reached.
setvbuf(stdout, nil, _IONBF, 0)
var lastStep = "start"
var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok  \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(String(detail().prefix(900)))")
    }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
    print("TIMEOUT: no result after 180 s; last step: \(lastStep)")
    exit(1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
}

final class Page: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var loaded = false
    var navigationError: String?

    init(width: CGFloat = 1000, height: CGFloat = 700) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = web
        super.init()
        web.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationError = error.localizedDescription; loaded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationError = error.localizedDescription; loaded = true }

    func load(_ html: String) -> Bool {
        loaded = false
        navigationError = nil
        web.loadHTMLString(html, baseURL: URL(string: "http://localhost/"))
        spin(20) { loaded }
        return loaded && navigationError == nil
    }

    func eval(_ script: String, timeout: TimeInterval = 20) -> (value: Any?, error: String?) {
        var done = false
        var value: Any?
        var message: String?
        web.evaluateJavaScript(script) { result, error in
            value = result
            message = error.map { ($0 as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? $0.localizedDescription }
            done = true
        }
        spin(timeout) { done }
        return done ? (value, message) : (nil, "TIMEOUT")
    }
}

let page = Page()

struct Measured {
    var raw: String
    var evidence: QAPageEvidence?
    var seconds: Double
}

/// Loads a fixture page, optionally runs some JavaScript on it (typing into fields), and runs the measuring script on it.
func measure(_ step: String, body: String, bodyStyle: String = "", before: String? = nil) -> Measured {
    lastStep = step
    let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>Fixture</title>
    <style>body{margin:8px;font:16px/1.4 Helvetica,Arial,sans-serif;color:#111;background:#fff;\(bodyStyle)} button,input,select,textarea{font:inherit}</style></head>
    <body>\(body)</body></html>
    """
    check("\(step): the fixture page loads", page.load(html), page.navigationError ?? "")
    if let before {
        let result = page.eval(before)
        check("\(step): the page was prepared", result.error == nil, result.error ?? "")
    }
    let start = Date()
    let result = page.eval(QAPageEvidence.script)
    let seconds = Date().timeIntervalSince(start)
    let raw = result.value as? String ?? ""
    check("\(step): the script returns a JSON string", result.error == nil && !raw.isEmpty, result.error ?? String(describing: result.value))
    return Measured(raw: raw, evidence: QAPageEvidence.parse(raw), seconds: seconds)
}

let tinyGif = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
func verdict(_ evidence: QAPageEvidence?) -> String {
    guard let evidence else { return "(not readable)" }
    return String(decoding: (try? JSONEncoder().encode(evidence)) ?? Data(), as: UTF8.self)
}

// MARK: - A clean page, and the things that look like problems but are not

do {
    let clean = measure("clean page", body: """
    <h1>Orders</h1>
    <h2>Open requests</h2>
    <p>Ordinary paragraph text in sixteen pixels with <a href="/orders/1">an inline link inside the sentence</a> that is not a click target of its own.</p>
    <p style="font-size:12px">Exactly twelve pixels is not small.</p>
    <p style="color:#767676">Grey text at 4.54 to 1 passes.</p>
    <div style="background:#1a1a1a;color:#fff;padding:8px">White on near black.</div>
    <div style="background:#222"><p style="color:#eee;margin:4px">Light text on a dark ancestor.</p></div>
    <div style="background:linear-gradient(#fff,#000);color:#999;padding:8px">Text on a gradient is not judged.</div>
    <label for="name">Name</label> <input id="name" type="text" style="height:30px;width:200px">
    <label style="display:inline-block;padding:6px 8px"><input type="checkbox" style="margin:0"> Remember me</label>
    <button style="width:100px;height:40px">Save</button>
    <a href="/home" style="display:inline-block;padding:12px">Home</a>
    <div style="overflow:auto;width:300px;height:60px"><div style="width:900px">A wide table inside its own scrolling box</div></div>
    <div style="overflow:hidden;width:300px"><p>Overflow hidden around content that fits.</p></div>
    <div style="overflow:auto;width:120px;height:20px">A very long sentence that scrolls inside this box instead of being cut.</div>
    <a href="#top" style="position:absolute;left:-9999px;top:0">Skip to content</a>
    <a href="/sr" style="position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)">Screen reader only</a>
    <p style="display:none;font-size:9px;color:#eee">Hidden small text</p>
    <p style="visibility:hidden;font-size:9px">Invisible small text</p>
    <p style="opacity:0;font-size:9px">Transparent small text</p>
    <button aria-label="Close" style="width:32px;height:32px"></button>
    <button style="width:32px;height:32px"><svg width="16" height="16"><title>Menu</title><path d="M0 0h16v16H0z"/></svg></button>
    <a href="/profile" style="display:inline-block;padding:10px"><img alt="Profile" width="16" height="16" src="\(tinyGif)"></a>
    <select aria-label="Sort" style="height:30px"><option>A</option></select>
    <input type="text" placeholder="Search" style="height:30px">
    <input type="submit" value="Send" style="height:30px;width:80px">
    <h3>Details</h3>
    """)
    check("clean page: the result is readable", clean.evidence != nil, clean.raw)
    check("clean page: nothing is reported, whatever looks like a problem is not one", clean.evidence?.isClean == true && clean.evidence?.summary.isEmpty == true, clean.raw)
    check("clean page: ... text of exactly 12 px, 4.54:1 grey, scrolling boxes, hidden and off-screen elements and inline links included",
          clean.evidence?.smallText.count == 0 && clean.evidence?.lowContrast.count == 0 && clean.evidence?.clipped.count == 0 && clean.evidence?.smallTargets.count == 0
              && clean.evidence?.unlabeledControls.count == 0 && clean.evidence?.skippedHeadings.count == 0, clean.raw)
    check("clean page: the page does not scroll sideways", clean.evidence?.horizontalScrollPixels == 0 && clean.evidence?.beyondRightEdge.count == 0, clean.raw)
    let load = clean.evidence?.loadMilliseconds
    check("clean page: the load time is a real time or absent", load == nil || (1...120_000).contains(load!), String(describing: load))
}

// MARK: - Small text

do {
    let small = measure("small text", body: """
    <p style="font-size:9px">Fine print terms</p>
    <p style="font-size:11px">Eleven pixel caption</p>
    <p>Normal text</p>
    """)
    let e = small.evidence
    check("small text: both texts under 12 px are counted", e?.smallText.count == 2, small.raw)
    check("small text: the sample names the element, its text and its size",
          e?.smallText.samples.first?.hasPrefix("p \"Fine print terms\" 9px @8,") == true && e?.smallText.samples.last?.contains("\"Eleven pixel caption\" 11px") == true, small.raw)
    check("small text: nothing else is reported", e?.lowContrast.count == 0 && e?.clipped.count == 0 && e?.smallTargets.count == 0 && e?.unlabeledControls.count == 0, small.raw)
}

// MARK: - Weak contrast

do {
    let contrast = measure("contrast", body: """
    <p style="color:#bbb">Light grey on white</p>
    <p style="color:#777">Grey at 4.48 to 1</p>
    <p style="color:#767676">Grey at 4.54 to 1</p>
    <div style="background:#ffcc00"><p style="color:#fff;margin:4px">White on yellow</p></div>
    <div style="background:#222"><p style="color:#333;margin:4px">Dark on dark</p></div>
    <div style="background:#222"><p style="color:#eee;margin:4px">Light on dark</p></div>
    <p style="color:rgba(0,0,0,0.25)">Translucent black over white</p>
    """)
    let e = contrast.evidence
    check("contrast: the five texts below 4.5:1 are counted, the two that pass are not", e?.lowContrast.count == 5 && e?.lowContrast.samples.count == 5, contrast.raw)
    check("contrast: light grey on white reads 1.92:1", e?.lowContrast.samples.first?.contains("\"Light grey on white\" 1.92:1") == true, contrast.raw)
    check("contrast: 4.48:1 is reported as under 4.5 and 4.54:1 is not reported",
          e?.lowContrast.samples.contains { $0.contains("Grey at 4.48 to 1") && $0.contains("4.48:1") } == true && e?.lowContrast.samples.contains { $0.contains("4.54 to 1") } == false, contrast.raw)
    check("contrast: the colour behind the text is found through transparent ancestors",
          e?.lowContrast.samples.contains { $0.contains("White on yellow") } == true && e?.lowContrast.samples.contains { $0.contains("Dark on dark") } == true
              && e?.lowContrast.samples.contains { $0.contains("Light on dark") } == false, contrast.raw)
    check("contrast: a translucent text colour is mixed with its background", e?.lowContrast.samples.contains { $0.contains("Translucent black") } == true, contrast.raw)
    check("contrast: nothing else is reported", e?.smallText.count == 0 && e?.clipped.count == 0, contrast.raw)
}

// MARK: - Clipped content

do {
    let clipped = measure("clipped", body: """
    <div style="width:120px;height:20px;overflow:hidden">A very long sentence that wraps onto several lines and so does not fit this small box</div>
    <div style="width:120px;height:20px;overflow:auto">Scrolling sentence that wraps onto several lines and is therefore not cut off silently</div>
    <div style="width:80px;overflow:hidden;white-space:nowrap;text-overflow:ellipsis">Truncated with an ellipsis for sure</div>
    <div style="width:300px;height:100px;overflow:hidden">Fits</div>
    """)
    let e = clipped.evidence
    check("clipped: the box that hides its overflow and the truncated line are reported, the scrolling box and the box that fits are not", e?.clipped.count == 2, clipped.raw)
    check("clipped: the sample says how much content is in how much room",
          e?.clipped.samples.first?.hasPrefix("div \"A very long sentence that wraps onto se…\" content 120x") == true && e?.clipped.samples.first?.contains("px in 120x20px @8,8") == true, clipped.raw)
    check("clipped: the truncated line is the second", e?.clipped.samples.last?.contains("Truncated with an ellipsis") == true && !(e?.clipped.samples.joined().contains("Scrolling sentence") ?? true), clipped.raw)
}

// MARK: - Small click targets

do {
    let targets = measure("click targets", body: """
    <button aria-label="Close one" style="width:10px;height:10px;padding:0;border:0;background:#333"></button>
    <button aria-label="Close two" style="width:10px;height:10px;padding:0;border:0;background:#333"></button>
    <a href="/x" aria-label="Tiny link" style="display:inline-block;width:20px;height:30px"></a>
    <button aria-label="Exactly" style="width:24px;height:24px;padding:0;border:0"></button>
    <button aria-label="Large" style="width:44px;height:44px"></button>
    <input type="checkbox" aria-label="Small box" style="width:13px;height:13px">
    <button disabled aria-label="Disabled" style="width:8px;height:8px"></button>
    """)
    let e = targets.evidence
    check("click targets: the two 10x10 buttons, the 20 px wide link and the bare checkbox are counted; 24x24, 44x44 and a disabled button are not", e?.smallTargets.count == 4, targets.raw)
    check("click targets: the sample names the element and its size", e?.smallTargets.samples.first?.hasPrefix("button 10x10px @8,") == true && e?.smallTargets.samples.contains { $0.hasPrefix("a 20x30px @") } == true, targets.raw)
    check("click targets: the checkbox is described by its type", e?.smallTargets.samples.contains { $0.hasPrefix("input[checkbox] 13x13px @") } == true, targets.raw)
    check("click targets: the named buttons are not reported as unlabeled", e?.unlabeledControls.count == 0, targets.raw)
}

// MARK: - A page wider than the window

do {
    let wide = measure("wide page", body: """
    <div style="width:2000px;height:20px;background:#ddd"><div style="margin-left:1500px;width:100px">far child</div></div>
    <p>Normal</p>
    <div style="position:fixed;left:1200px;top:0;width:50px;height:20px">fixed</div>
    """)
    let width = Int((page.eval("document.documentElement.clientWidth").value as? NSNumber)?.intValue ?? -1)
    let e = wide.evidence
    check("wide page: the window is as wide as the fixture assumes", (900...1000).contains(width), "\(width)")
    check("wide page: the page is reported as wider than the window by exactly the overflow", e.map { abs($0.horizontalScrollPixels - (2008 - width)) <= 1 } == true, wide.raw)
    check("wide page: only the outermost element past the edge is named, not its far child or the fixed one",
          e?.beyondRightEdge.count == 1 && e?.beyondRightEdge.samples.first?.hasPrefix("div \"far child\" right edge at 2008px @8,8") == true, wide.raw)
    check("wide page: the summary says so", e?.summary.contains("The page scrolls sideways: it is \(e?.horizontalScrollPixels ?? -1) px wider than the window") == true, wide.raw)

    let hidden = measure("wide page with sideways scrolling switched off", body: "<div style=\"width:2000px;height:20px;background:#ddd\">wide</div>", bodyStyle: "overflow-x:hidden")
    check("wide page: a page that cannot scroll sideways is not reported as scrolling", hidden.evidence?.horizontalScrollPixels == 0 && hidden.evidence?.beyondRightEdge.count == 0, hidden.raw)
}

// MARK: - Controls with no name

do {
    let icons = measure("icon-only controls", body: """
    <button style="width:40px;height:40px"><svg width="16" height="16"><path d="M0 0h16v16H0z"/></svg></button>
    <a href="/pic" style="display:inline-block;padding:10px"><img alt="" width="16" height="16" src="\(tinyGif)"></a>
    <button aria-label="Close" style="width:40px;height:40px"></button>
    <button title="Help" style="width:40px;height:40px"></button>
    <button style="width:40px;height:40px"><svg width="16" height="16"><title>Menu</title><path d="M0 0h16v16H0z"/></svg></button>
    <a href="/pic2" style="display:inline-block;padding:10px"><img alt="Profile" width="16" height="16" src="\(tinyGif)"></a>
    <button style="width:80px;height:40px">Save</button>
    <span id="lbl">Delete row</span><button aria-labelledby="lbl" style="width:40px;height:40px"></button>
    """)
    let e = icons.evidence
    check("icon-only controls: the button with only a drawing and the link with an empty alt text are reported; the others have names", e?.unlabeledControls.count == 2, icons.raw)
    check("icon-only controls: the sample is the bare element and its place", e?.unlabeledControls.samples.first?.hasPrefix("button @8,") == true && e?.unlabeledControls.samples.last?.hasPrefix("a @") == true, icons.raw)

    let fields = measure("fields", body: """
    <input type="text" style="height:30px;width:200px">
    <label for="a">Name</label><input id="a" type="text" style="height:30px">
    <label>Email <input type="email" style="height:30px"></label>
    <input type="text" aria-label="City" style="height:30px">
    <input type="text" placeholder="Search" style="height:30px">
    <select style="height:30px"><option>One</option></select>
    <textarea style="height:40px;width:200px"></textarea>
    <input type="hidden" name="token">
    <label for="b"> </label><input id="b" type="text" style="height:30px">
    """)
    let f = fields.evidence
    check("fields: the bare field, the select, the text area and the field whose label is empty are reported", f?.unlabeledControls.count == 4, fields.raw)
    check("fields: labelled, wrapped, aria-labelled, placeholder and hidden fields are not",
          f?.unlabeledControls.samples.filter { $0.hasPrefix("input[text] @") }.count == 2 && f?.unlabeledControls.samples.contains { $0.hasPrefix("select @") } == true
              && f?.unlabeledControls.samples.contains { $0.hasPrefix("textarea @") } == true && f?.unlabeledControls.samples.contains { $0.contains("email") } == false, fields.raw)
}

// MARK: - Headings

do {
    let headings = measure("headings", body: """
    <h1>Alpha</h1><h3>Bravo</h3><h2>Charlie</h2><h4 style="display:none">Hidden</h4><h5>Delta</h5><h6>Echo</h6>
    <div role="heading" aria-level="2">Foxtrot</div>
    """)
    let e = headings.evidence
    check("headings: an h3 after an h1 and an h5 after an h2 are skipped levels; going back up, going down one level and a hidden heading are not",
          e?.skippedHeadings.count == 2, headings.raw)
    check("headings: the sample says what it followed", e?.skippedHeadings.samples.first?.hasPrefix("h3 \"Bravo\" after h1 @") == true && e?.skippedHeadings.samples.last?.hasPrefix("h5 \"Delta\" after h2 @") == true, headings.raw)
}

// MARK: - Nothing a person typed leaves the page

do {
    let secret = measure("typed values", body: """
    <input id="pw" type="password" style="width:10px;height:10px">
    <input id="user" type="text" style="width:10px;height:10px" value="prefilled-attribute-secret">
    <textarea id="note" style="width:10px;height:10px">default-text-in-textarea</textarea>
    <input type="submit" value="Send-secret-label" style="width:10px;height:10px">
    <select id="pick" style="width:10px;height:10px"><option>option-text-secret</option></select>
    <p style="font-size:9px">Visible text only</p>
    """, before: """
    document.getElementById('pw').value = 'hunter2-TYPED';
    document.getElementById('user').value = 'alice@example.com-TYPED';
    document.getElementById('note').value = 'typed-in-textarea';
    """)
    let e = secret.evidence
    let leaks = ["hunter2", "alice@example", "prefilled-attribute-secret", "default-text-in-textarea", "typed-in-textarea", "Send-secret-label", "option-text-secret", "TYPED"]
    check("typed values: none of the typed or default values of fields appears in the result", leaks.allSatisfy { !secret.raw.contains($0) }, secret.raw)
    check("typed values: the fields themselves are in it, by tag and type", e?.smallTargets.samples.contains { $0.hasPrefix("input[password] ") } == true
          && e?.smallTargets.samples.contains { $0.hasPrefix("textarea ") } == true && e?.unlabeledControls.samples.contains { $0.hasPrefix("input[password] @") } == true, secret.raw)
    check("typed values: the visible text of the page still is", e?.smallText.samples.first?.hasPrefix("p \"Visible text only\" 9px @") == true, secret.raw)
}

// MARK: - Many offenders, a measurement that fails

do {
    let many = measure("many offenders", body: (1...200).map { "<p style=\"font-size:9px\">Small paragraph \($0)</p>" }.joined())
    check("many offenders: every one is counted but only five are described", many.evidence?.smallText.count == 200 && many.evidence?.smallText.samples.count == 5, many.raw)
    check("many offenders: the answer stays small and quick", many.raw.utf8.count < 3000 && many.seconds < 5, "\(many.raw.utf8.count) bytes, \(many.seconds) s")

    let broken = measure("failing measurement", body: "<p>Text</p>", before: "window.getComputedStyle = function () { throw new Error('blocked'); }; 'ready'")
    check("failing measurement: the script says it failed instead of reporting a clean page", broken.raw.contains("\"failed\":true"), broken.raw)
    check("failing measurement: and the reader does not take it for evidence", broken.evidence == nil, broken.raw)
}

print(failures == 0 ? "All QA evidence web checks passed" : "\(failures) QA evidence web check(s) failed")
exit(failures == 0 ? 0 : 1)
