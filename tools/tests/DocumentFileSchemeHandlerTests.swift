import AppKit
import WebKit

// Standalone check of DocumentFileSchemeHandler in a real WKWebView configured the way the editor page and the PDF export are
// (BUG-061): an allowed picture and an SVG load, a picture outside the folders and a missing one do not.
// Run with tools/tests/document-files-tests.sh.

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Never>?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
}

@main
struct DocumentFileSchemeHandlerTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("document-handler-\(UUID().uuidString)", isDirectory: true)
        let project = base.appendingPathComponent("project", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: project.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        func png() -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            return rep.representation(using: .png, properties: [:])!
        }
        try png().write(to: project.appendingPathComponent("docs/a b.png"))
        try png().write(to: outside.appendingPathComponent("secret.png"))
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10'><rect width='20' height='10' fill='red'/></svg>".utf8)
            .write(to: project.appendingPathComponent("docs/logo.svg"))

        func address(_ path: String) -> String {
            var components = URLComponents()
            components.scheme = DocumentFiles.scheme
            components.host = ""
            components.path = path
            return components.string!
        }

        let handler = DocumentFileSchemeHandler()
        handler.allowedRoots = { [project] }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: DocumentFileSchemeHandler.scheme)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let loader = Loader()
        web.navigationDelegate = loader
        let page = """
        <html><body>
        <img id="ok" src="\(address(project.path + "/docs/a b.png"))">
        <img id="svg" src="\(address(project.path + "/docs/logo.svg"))">
        <img id="outside" src="\(address(outside.path + "/secret.png"))">
        <img id="missing" src="\(address(project.path + "/docs/none.png"))">
        </body></html>
        """
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loader.done = continuation
            web.loadHTMLString(page, baseURL: URL(fileURLWithPath: "/"))
        }
        // The load event waits for the pictures; a short extra wait covers a slow answer.
        try await Task.sleep(nanoseconds: 700_000_000)
        let raw = try await web.callAsyncJavaScript("""
        return JSON.stringify(Array.from(document.images).map(function (i) { return [i.id, i.complete && i.naturalWidth, i.naturalHeight]; }));
        """, contentWorld: .page) as? String
        let rows = (try? JSONSerialization.jsonObject(with: Data((raw ?? "[]").utf8))) as? [[Any]] ?? []
        var sizes: [String: [Int]] = [:]
        for row in rows { if let id = row[0] as? String { sizes[id] = [(row[1] as? Int) ?? 0, (row[2] as? Int) ?? 0] } }

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("ok   \(name)") } else { failures += 1; print("FAIL \(name) \(detail)") }
        }
        check("an allowed picture with a space in its name loads at its size", sizes["ok"] == [12, 8], "\(sizes)")
        check("an SVG loads (declared as image/svg+xml)", sizes["svg"] == [20, 10], "\(sizes)")
        check("a picture outside the folders is refused", sizes["outside"] == [0, 0], "\(sizes)")
        check("a missing picture does not load", sizes["missing"] == [0, 0], "\(sizes)")
        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
