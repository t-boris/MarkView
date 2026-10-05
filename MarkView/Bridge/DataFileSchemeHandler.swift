import Foundation
import WebKit

/// `markview-data:///<absolute path>`: the bytes of a data file (table, Parquet, SQLite, log) for
/// the editor page's data viewers (Task 84). The page cannot read `file://`, and a large or binary
/// file must not travel as a JavaScript string. Only files open in a data tab of the window are
/// served (`isAllowed`); everything else gets 403.
final class DataFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "markview-data"

    var isAllowed: (URL) -> Bool = { _ in false }

    static func address(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = url.standardizedFileURL.path
        return components.string ?? "\(scheme):///"
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let file = URL(fileURLWithPath: requestURL.path)
        guard isAllowed(file) else { return respond(task, url: requestURL, status: 403, data: Data()) }
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
            DispatchQueue.main.async {
                self.respond(task, url: requestURL, status: data == nil ? 404 : 200, data: data ?? Data())
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, data: Data) {
        let headers = ["Content-Type": "application/octet-stream", "Content-Length": String(data.count),
                       "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
