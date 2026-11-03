import Foundation
import UniformTypeIdentifiers
import WebKit

/// `mvproto://site/<path>`: the files of a prototype's `site/` folder for the Prototype Studio preview.
///
/// A page loaded with `loadFileURL` gets an opaque origin per file, so WebKit hides the message, file
/// and line of every error thrown in a sibling script (`app.js`, `data.js`, `screens/*.js`) and reports
/// only "Script error." (BUG-047). Served through one scheme, all files share an origin, the preview
/// receives the real error and the generated pages can read each other with `fetch`.
/// Only files inside the root are served; everything else gets 403 or 404.
final class PrototypeSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mvproto"
    static let host = "site"

    /// The `site/` folder that is served; the preview keeps it equal to its session's folder.
    var root: URL

    /// Tasks that were started and not yet answered or stopped (main thread only): WebKit raises an
    /// exception when a stopped task is answered.
    private var open = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// The address of `path` (relative to `site/`, "" for the index) with an optional fragment.
    static func address(of path: String, fragment: String = "") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        if !fragment.isEmpty { components.fragment = String(fragment.drop(while: { $0 == "#" })) }
        return components.url
    }

    enum Lookup: Equatable {
        case file(URL)
        case forbidden
        case missing
    }

    /// The file that the request path names under `root`: a directory means its `index.html`. A path
    /// that leaves `root`, by `..` or by a symbolic link, is forbidden.
    static func lookup(path requestPath: String, in root: URL) -> Lookup {
        let decoded = requestPath.removingPercentEncoding ?? requestPath
        if decoded.contains("\0") { return .forbidden }
        let parts = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains("..") { return .forbidden }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var target = parts.reduce(base) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else { return .forbidden }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return .missing }
        if isDirectory.boolValue {
            target = target.appendingPathComponent("index.html").resolvingSymlinksInPath()
            guard target.path.hasPrefix(base.path + "/") else { return .forbidden }
            var isIndexDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isIndexDirectory), !isIndexDirectory.boolValue
            else { return .missing }
        }
        return .file(target)
    }

    /// The Content-Type of a served file. Text types name their encoding: generated files are UTF-8.
    static func contentType(of file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "txt", "md": return "text/plain; charset=utf-8"
        case "wasm": return "application/wasm"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let id = ObjectIdentifier(task as AnyObject)
        open.insert(id)
        let root = self.root
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Self.lookup(path: requestURL.path, in: root)
            var data: Data?
            var type = "text/plain; charset=utf-8"
            if case .file(let file) = outcome {
                data = try? Data(contentsOf: file, options: .mappedIfSafe)
                type = Self.contentType(of: file)
            }
            DispatchQueue.main.async {
                guard self.open.remove(id) != nil else { return }
                switch outcome {
                case .file where data != nil: self.respond(task, url: requestURL, status: 200, type: type, data: data ?? Data())
                case .forbidden: self.respond(task, url: requestURL, status: 403, type: type, data: Data())
                default: self.respond(task, url: requestURL, status: 404, type: type, data: Data())
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        open.remove(ObjectIdentifier(task as AnyObject))
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, type: String, data: Data) {
        // No caching: the files change under the preview whenever the assistant writes a screen.
        let headers = ["Content-Type": type, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
