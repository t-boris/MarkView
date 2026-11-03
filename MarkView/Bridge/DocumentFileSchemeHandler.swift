import Foundation
import WebKit

/// Serves `markview-doc:///<absolute path>` to the editor page: the pictures a document refers to by a relative path (BUG-061).
/// What may be served is decided by `DocumentFiles.resolve`; everything else gets 403, a file that cannot be read gets 404.
///
/// A request the page gives up (the document is rendered again, the tab changes) is stopped by WebKit, and answering a stopped
/// task raises an exception, so the tasks still wanted are tracked and the answer is dropped for the others.
final class DocumentFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = DocumentFiles.scheme

    /// The folders a picture may come from, asked for on every request because tabs open and close.
    var allowedRoots: () -> [URL] = { [] }

    /// Only touched on the main thread, where WebKit starts and stops tasks.
    private var wanted = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let key = ObjectIdentifier(task as AnyObject)
        wanted.insert(key)
        switch DocumentFiles.resolve(requestURL, roots: allowedRoots()) {
        case .forbidden:
            respond(task, key: key, url: requestURL, status: 403, contentType: "text/plain", data: Data())
        case .file(let file, let contentType):
            DispatchQueue.global(qos: .userInitiated).async {
                let data = try? Data(contentsOf: file, options: .mappedIfSafe)
                DispatchQueue.main.async {
                    self.respond(task, key: key, url: requestURL, status: data == nil ? 404 : 200, contentType: contentType, data: data ?? Data())
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        wanted.remove(ObjectIdentifier(task as AnyObject))
    }

    private func respond(_ task: WKURLSchemeTask, key: ObjectIdentifier, url: URL, status: Int, contentType: String, data: Data) {
        guard wanted.remove(key) != nil else { return }
        let headers = ["Content-Type": contentType, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return task.didFailWithError(URLError(.badServerResponse))
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
