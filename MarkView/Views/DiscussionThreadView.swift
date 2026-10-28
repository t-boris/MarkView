import SwiftUI
import WebKit

/// The conversation of a discussion as a web page (`Editor/discussion.html`): each answer drawn in the form that fits it.
/// Swift sends the turns and the live answer; the page requests drawing saves and Markdown copies.
struct DiscussionThreadView: NSViewRepresentable {
    var turns: [DiscussionTurn]
    var live: DiscussionStore.Live?
    var dark: Bool

    static var pageURL: URL? { Bundle.main.url(forResource: "discussion", withExtension: "html", subdirectory: "Editor") }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "discussion")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.view = view
        if let page = Self.pageURL { view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(turns: turns, live: live, dark: dark)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        private var ready = false
        private var sentTurns: [DiscussionTurn]?
        private var sentLive: DiscussionStore.Live??
        private var sentDark: Bool?
        private var wanted: (turns: [DiscussionTurn], live: DiscussionStore.Live?, dark: Bool)?

        func update(turns: [DiscussionTurn], live: DiscussionStore.Live?, dark: Bool) {
            wanted = (turns, live, dark)
            flush()
        }

        private func flush() {
            guard ready, let view, let wanted else { return }
            if sentDark != wanted.dark { sentDark = wanted.dark; view.evaluateJavaScript("mvSetTheme(\(wanted.dark))") }
            if sentTurns != wanted.turns {
                sentTurns = wanted.turns
                view.evaluateJavaScript("mvSetTurns(\(Self.literal(Self.json(wanted.turns.map { ["question": $0.question, "answer": $0.answer] }))))")
            }
            if sentLive == nil || sentLive! != wanted.live {
                sentLive = .some(wanted.live)
                if let live = wanted.live {
                    view.evaluateJavaScript("mvSetLive(\(Self.literal(Self.json(["question": live.question, "text": live.text, "status": live.status]))))")
                } else {
                    view.evaluateJavaScript("mvSetLive(null)")
                }
            }
        }

        /// A plain JSON value as text. Takes no `Any` downcasts: an empty array casts to every array type, which once recursed forever.
        private static func json(_ value: Any) -> String {
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return "[]" }
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        /// A JSON text as a JavaScript string literal.
        private static func literal(_ text: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]), let array = String(data: data, encoding: .utf8) else { return "\"[]\"" }
            return String(array.dropFirst().dropLast())
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                sentTurns = nil; sentLive = nil; sentDark = nil
                flush()
            case "copy":
                guard let text = body["text"] as? String, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "save":
                guard let name = body["name"] as? String, let data = body["data"] as? String else { return }
                let bytes = (body["base64"] as? Bool == true) ? Data(base64Encoded: data) : data.data(using: .utf8)
                guard let bytes else { return }
                DispatchQueue.main.async { Self.save(bytes, suggested: name) }
            default: break
            }
        }

        private static func save(_ data: Data, suggested: String) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggested
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url, options: .atomic)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else if action.targetFrame == nil {
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
